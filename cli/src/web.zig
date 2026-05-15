const std = @import("std");
const actions_page = @import("web/actions.zig");
const commits_page = @import("web/commits.zig");
const errors = @import("errors.zig");
const events_page = @import("web/events.zig");
const explorer = @import("web/explorer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const access_page = @import("web/access.zig");
const issues_page = @import("web/issues.zig");
const milestones_page = @import("web/milestones.zig");
const overview_page = @import("web/overview.zig");
const projects_page = @import("web/projects.zig");
const pulls_page = @import("web/pulls.zig");
const refs_page = @import("web/refs.zig");
const repo_mod = @import("repo.zig");
const shared = @import("web/shared.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const out = io.out;
const eprint = io.eprint;

const max_http_request = 10 * 1024 * 1024;
const default_worker_count = 8;
const default_port_attempt_limit = 128;
pub const default_host = "127.0.0.1";
pub const default_port = 12655;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    port_supplied: bool = false,
    once: bool = false,
    worker_count: usize = default_worker_count,
};

pub const HttpRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    body: []const u8,
    range: ?ByteRange = null,
};

pub const ByteRange = struct {
    start: ?usize,
    end: ?usize,
};

pub fn serve(allocator: Allocator, repo: Repo, options: Options) !void {
    const bind_host: []const u8 = if (std.mem.eql(u8, options.host, "localhost")) default_host else options.host;
    var server = try listenWeb(bind_host, options);
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

fn listenWeb(bind_host: []const u8, options: Options) !std.net.Server {
    var port = options.port;
    var attempts: usize = 0;
    while (true) {
        const address = std.net.Address.parseIp(bind_host, port) catch {
            try eprint("gt web: invalid host or port {s}:{d}\n", .{ options.host, port });
            return CliError.InvalidArgument;
        };

        return address.listen(.{ .reuse_address = false, .kernel_backlog = 32 }) catch |err| {
            if (options.port_supplied or err != error.AddressInUse) return err;
            attempts += 1;
            if (attempts >= default_port_attempt_limit) {
                try eprint("gt web: could not find an available port after {d} attempts starting from {d}\n", .{ attempts, options.port });
                return CliError.UserError;
            }

            const increment = std.crypto.random.intRangeAtMost(u16, 1, 10);
            if (port > std.math.maxInt(u16) - increment) {
                try eprint("gt web: no available port found before 65535\n", .{});
                return CliError.UserError;
            }
            port += increment;
            continue;
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
        if (isClientDisconnect(err)) return;
        try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
    };
}

fn isClientDisconnect(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
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
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/ui.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", ui_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/shortcuts.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", shortcuts_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/tree.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", tree_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/code.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", code_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/markdown.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", markdown_js, null);
    } else if (try sendVendorAsset(allocator, stream, request.method, request.path)) {
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/vendor/hljs/all-languages.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", highlight_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/highlight/zig.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", highlight_zig_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/highlight/solidity.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", solidity_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/highlight/tla.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", tla_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/highlight/init.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", highlight_init_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/diff.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", diff_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/merge.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", merge_js, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/raw")) {
        const raw_blob_opt = explorer.loadRawBlob(allocator, repo, request.target) catch |err| switch (err) {
            error.BlobTooLarge => {
                try shared.sendPlainResponse(allocator, stream, 413, "Payload Too Large", "Blob too large\n");
                return;
            },
            else => return err,
        };
        if (raw_blob_opt) |raw_blob| {
            var blob = raw_blob;
            defer blob.deinit(allocator);
            try sendRawBlobResponse(allocator, stream, blob, request.range);
        } else {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Blob not found\n");
        }
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/index/rebuild")) {
        try index.ensureIndex(allocator, repo);
        try shared.sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/nav/stats")) {
        const body = try shared.renderNavStatsJson(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "application/json", body, "Cache-Control: no-store\r\n");
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.eql(u8, request.path, "/") or std.mem.eql(u8, request.path, "/code"))) {
        const body = try explorer.renderCodePage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/code/sync")) {
        try explorer.handleCodeSyncPost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/blame")) {
        const body = try explorer.renderBlamePage(allocator, repo, request.target);
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
        const body = try issues_page.renderIssuesPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const issue_ref_start = "/issues/".len;
        const issue_ref_end = request.path.len - "/edit".len;
        if (issue_ref_start >= issue_ref_end or request.path[issue_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const issue_ref = request.path[issue_ref_start..issue_ref_end];
        try issues_page.handleIssueEditPost(allocator, repo, stream, issue_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/checklist")) {
        const issue_ref_start = "/issues/".len;
        const issue_ref_end = request.path.len - "/checklist".len;
        if (issue_ref_start >= issue_ref_end or request.path[issue_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const issue_ref = request.path[issue_ref_start..issue_ref_end];
        try issues_page.handleIssueChecklistPost(allocator, repo, stream, issue_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/comments")) {
        const issue_ref_start = "/issues/".len;
        const issue_ref_end = request.path.len - "/comments".len;
        if (issue_ref_start >= issue_ref_end or request.path[issue_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const issue_ref = request.path[issue_ref_start..issue_ref_end];
        try issues_page.handleIssueCommentPost(allocator, repo, stream, issue_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/sidebar")) {
        const issue_ref_start = "/issues/".len;
        const issue_ref_end = request.path.len - "/sidebar".len;
        if (issue_ref_start >= issue_ref_end or request.path[issue_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const issue_ref = request.path[issue_ref_start..issue_ref_end];
        try issues_page.handleIssueSidebarPost(allocator, repo, stream, issue_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const issue_ref_start = "/issues/".len;
        const issue_ref_end = request.path.len - "/edit".len;
        if (issue_ref_start >= issue_ref_end or request.path[issue_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const issue_ref = request.path[issue_ref_start..issue_ref_end];
        const body = try issues_page.renderIssueEditPage(allocator, repo, issue_ref, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/issues/")) {
        const issue_ref = request.path["/issues/".len..];
        const body = try issues_page.renderIssueDetailPage(allocator, repo, issue_ref);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.eql(u8, request.path, "/pulls") or std.mem.eql(u8, request.path, "/prs"))) {
        const body = try pulls_page.renderPullsPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and ((std.mem.startsWith(u8, request.path, "/pulls/") or std.mem.startsWith(u8, request.path, "/prs/")) and std.mem.endsWith(u8, request.path, "/conflicts"))) {
        const prefix = if (std.mem.startsWith(u8, request.path, "/pulls/")) "/pulls/" else "/prs/";
        const pull_ref_start = prefix.len;
        const pull_ref_end = request.path.len - "/conflicts".len;
        if (pull_ref_start >= pull_ref_end or request.path[pull_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const pull_ref = request.path[pull_ref_start..pull_ref_end];
        const body = try pulls_page.renderPullMergeEditorPage(allocator, repo, pull_ref, request.target, null);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and ((std.mem.startsWith(u8, request.path, "/pulls/") or std.mem.startsWith(u8, request.path, "/prs/")) and std.mem.endsWith(u8, request.path, "/conflicts"))) {
        const prefix = if (std.mem.startsWith(u8, request.path, "/pulls/")) "/pulls/" else "/prs/";
        const pull_ref_start = prefix.len;
        const pull_ref_end = request.path.len - "/conflicts".len;
        if (pull_ref_start >= pull_ref_end or request.path[pull_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const pull_ref = request.path[pull_ref_start..pull_ref_end];
        try pulls_page.handlePullConflictPost(allocator, repo, stream, pull_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and ((std.mem.startsWith(u8, request.path, "/pulls/") or std.mem.startsWith(u8, request.path, "/prs/")) and std.mem.endsWith(u8, request.path, "/checklist"))) {
        const prefix = if (std.mem.startsWith(u8, request.path, "/pulls/")) "/pulls/" else "/prs/";
        const pull_ref_start = prefix.len;
        const pull_ref_end = request.path.len - "/checklist".len;
        if (pull_ref_start >= pull_ref_end or request.path[pull_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const pull_ref = request.path[pull_ref_start..pull_ref_end];
        try pulls_page.handlePullChecklistPost(allocator, repo, stream, pull_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and ((std.mem.startsWith(u8, request.path, "/pulls/") or std.mem.startsWith(u8, request.path, "/prs/")) and std.mem.endsWith(u8, request.path, "/comments"))) {
        const prefix = if (std.mem.startsWith(u8, request.path, "/pulls/")) "/pulls/" else "/prs/";
        const pull_ref_start = prefix.len;
        const pull_ref_end = request.path.len - "/comments".len;
        if (pull_ref_start >= pull_ref_end or request.path[pull_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const pull_ref = request.path[pull_ref_start..pull_ref_end];
        try pulls_page.handlePullCommentPost(allocator, repo, stream, pull_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.startsWith(u8, request.path, "/pulls/") or std.mem.startsWith(u8, request.path, "/prs/"))) {
        const pull_ref = if (std.mem.startsWith(u8, request.path, "/pulls/"))
            request.path["/pulls/".len..]
        else
            request.path["/prs/".len..];
        const body = try pulls_page.renderPullDetailPage(allocator, repo, pull_ref, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/projects")) {
        const body = try projects_page.renderProjectsPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/new-project")) {
        const body = try projects_page.renderProjectFormFromTarget(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/projects")) {
        try projects_page.handleProjectPost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/milestones")) {
        const body = try milestones_page.renderMilestonesPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/new-milestone")) {
        const body = try milestones_page.renderNewMilestoneForm(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/milestones")) {
        try milestones_page.handleMilestonePost(allocator, repo, stream, null, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/milestones/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const milestone_ref_start = "/milestones/".len;
        const milestone_ref_end = request.path.len - "/edit".len;
        if (milestone_ref_start >= milestone_ref_end or request.path[milestone_ref_end - 1] == '/') {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        const milestone_ref = request.path[milestone_ref_start..milestone_ref_end];
        const body = try milestones_page.renderMilestoneFormFromRef(allocator, repo, milestone_ref);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/milestones/")) {
        const milestone_ref = request.path["/milestones/".len..];
        if (milestone_ref.len == 0 or std.mem.indexOfScalar(u8, milestone_ref, '/') != null) {
            try shared.sendPlainResponse(allocator, stream, 404, "Not Found", "Not found\n");
            return;
        }
        try milestones_page.handleMilestonePost(allocator, repo, stream, milestone_ref, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/access")) {
        const body = try access_page.renderAccessPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/access/roles")) {
        try access_page.handleAccessRolePost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/access/devices")) {
        try access_page.handleAccessDevicePost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/actions")) {
        const body = try actions_page.renderActionsPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/actions/request")) {
        try actions_page.handleActionsRequestPost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/actions/run-requested")) {
        try actions_page.handleRunRequestedPost(allocator, stream);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/events")) {
        const body = try events_page.renderEventsPage(allocator, repo);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/refs")) {
        const body = try refs_page.renderRefsPage(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/refs/sync")) {
        try refs_page.handleRefsSyncPost(allocator, repo, stream);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/new-issue")) {
        const body = try issues_page.renderIssueFormFromTarget(allocator, repo, request.target);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/issues")) {
        try issues_page.handleIssuePost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.eql(u8, request.path, "/new-pull") or std.mem.eql(u8, request.path, "/new-pr"))) {
        const body = try pulls_page.renderPullForm(allocator, repo, null, "", "", "", "", false);
        defer allocator.free(body);
        try shared.sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/pulls")) {
        try pulls_page.handlePullPost(allocator, repo, stream, request.body);
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
        .range = parseRangeHeader(headers),
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

fn parseRangeHeader(headers: []const u8) ?ByteRange {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "range")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return parseByteRange(value);
    }
    return null;
}

fn parseByteRange(value: []const u8) ?ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_raw = std.mem.trim(u8, spec[0..dash], " \t");
    const end_raw = std.mem.trim(u8, spec[dash + 1 ..], " \t");
    if (start_raw.len == 0 and end_raw.len == 0) return null;
    return .{
        .start = if (start_raw.len == 0) null else std.fmt.parseUnsigned(usize, start_raw, 10) catch return null,
        .end = if (end_raw.len == 0) null else std.fmt.parseUnsigned(usize, end_raw, 10) catch return null,
    };
}

fn renderNotFoundPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try shared.appendShellStart(&buf, allocator, repo, "Not Found", "");
    try shared.appendEmptyState(&buf, allocator, "Page not found.", "The local Gitomi web UI does not have a route for that path.");
    try shared.appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

const raw_blob_headers = "Accept-Ranges: bytes\r\nCache-Control: no-store\r\nContent-Security-Policy: sandbox\r\n";

const ResolvedRange = struct {
    start: usize,
    end: usize,
};

fn sendRawBlobResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    blob: explorer.RawBlob,
    range: ?ByteRange,
) !void {
    if (range) |requested| {
        if (resolveByteRange(requested, blob.body.len)) |resolved| {
            const extra = try std.fmt.allocPrint(
                allocator,
                raw_blob_headers ++ "Content-Range: bytes {d}-{d}/{d}\r\n",
                .{ resolved.start, resolved.end, blob.body.len },
            );
            defer allocator.free(extra);
            try shared.sendBinaryResponse(
                allocator,
                stream,
                206,
                "Partial Content",
                blob.content_type,
                blob.body[resolved.start .. resolved.end + 1],
                extra,
            );
            return;
        }

        const extra = try std.fmt.allocPrint(
            allocator,
            raw_blob_headers ++ "Content-Range: bytes */{d}\r\n",
            .{blob.body.len},
        );
        defer allocator.free(extra);
        try shared.sendBinaryResponse(allocator, stream, 416, "Range Not Satisfiable", "text/plain", "", extra);
        return;
    }

    try shared.sendBinaryResponse(allocator, stream, 200, "OK", blob.content_type, blob.body, raw_blob_headers);
}

fn sendVendorAsset(
    allocator: Allocator,
    stream: std.net.Stream,
    method: []const u8,
    path: []const u8,
) !bool {
    if (!std.mem.eql(u8, method, "GET")) return false;
    if (std.mem.eql(u8, path, "/vendor/marked/marked.umd.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", marked_js, null);
        return true;
    }
    if (std.mem.eql(u8, path, "/vendor/dompurify/purify.min.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", dompurify_js, null);
        return true;
    }
    if (std.mem.eql(u8, path, "/vendor/katex/katex.min.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", katex_js, null);
        return true;
    }
    if (std.mem.eql(u8, path, "/vendor/katex/auto-render.min.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", katex_auto_render_js, null);
        return true;
    }
    if (std.mem.eql(u8, path, "/vendor/katex/katex.min.css")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "text/css", katex_css, null);
        return true;
    }
    if (std.mem.eql(u8, path, "/vendor/mermaid/mermaid.min.js")) {
        try shared.sendResponse(allocator, stream, 200, "OK", "application/javascript", mermaid_js, null);
        return true;
    }
    for (katex_fonts) |font| {
        if (std.mem.eql(u8, path, font.path)) {
            try shared.sendBinaryResponse(allocator, stream, 200, "OK", "font/woff2", font.body, null);
            return true;
        }
    }
    return false;
}

fn resolveByteRange(range: ByteRange, len: usize) ?ResolvedRange {
    if (len == 0) return null;

    if (range.start) |start| {
        if (start >= len) return null;
        var end = range.end orelse len - 1;
        if (end < start) return null;
        end = @min(end, len - 1);
        return .{ .start = start, .end = end };
    }

    const suffix_len = range.end orelse return null;
    if (suffix_len == 0) return null;
    if (suffix_len >= len) return .{ .start = 0, .end = len - 1 };
    return .{ .start = len - suffix_len, .end = len - 1 };
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, default_host) or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "localhost");
}

const web_css = @embedFile("web/style.css");
const logo_svg = @embedFile("web/logo.svg");
const theme_js = @embedFile("web/theme.js");
const ui_js = @embedFile("web/ui.js");
const shortcuts_js = @embedFile("web/shortcuts.js");
const tree_js = @embedFile("web/tree.js");
const code_js = @embedFile("web/code.js");
const markdown_js = @embedFile("web/markdown.js");
const marked_js = @embedFile("web/vendor/marked/marked.umd.js");
const dompurify_js = @embedFile("web/vendor/dompurify/purify.min.js");
const katex_js = @embedFile("web/vendor/katex/katex.min.js");
const katex_auto_render_js = @embedFile("web/vendor/katex/auto-render.min.js");
const katex_css = @embedFile("web/vendor/katex/katex.min.css");
const mermaid_js = @embedFile("web/vendor/mermaid/mermaid.min.js");
const highlight_js = @embedFile("web/vendor/hljs/all-languages.js");
const highlight_zig_js = @embedFile("web/highlight/zig.js");
const solidity_js = @embedFile("web/highlight/solidity.js");
const tla_js = @embedFile("web/highlight/tla.js");
const highlight_init_js = @embedFile("web/highlight/init.js");
const diff_js = @embedFile("web/diff.js");
const merge_js = @embedFile("web/merge.js");

const FontAsset = struct {
    path: []const u8,
    body: []const u8,
};

const katex_fonts = [_]FontAsset{
    .{ .path = "/vendor/katex/fonts/KaTeX_AMS-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_AMS-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Caligraphic-Bold.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Caligraphic-Bold.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Caligraphic-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Caligraphic-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Fraktur-Bold.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Fraktur-Bold.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Fraktur-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Fraktur-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Main-Bold.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Main-Bold.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Main-BoldItalic.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Main-BoldItalic.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Main-Italic.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Main-Italic.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Main-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Main-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Math-BoldItalic.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Math-BoldItalic.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Math-Italic.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Math-Italic.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_SansSerif-Bold.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Bold.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_SansSerif-Italic.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Italic.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_SansSerif-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Script-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Script-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Size1-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Size1-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Size2-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Size2-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Size3-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Size3-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Size4-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Size4-Regular.woff2") },
    .{ .path = "/vendor/katex/fonts/KaTeX_Typewriter-Regular.woff2", .body = @embedFile("web/vendor/katex/fonts/KaTeX_Typewriter-Regular.woff2") },
};

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
    try std.testing.expect(request.range == null);
}

test "web request parser accepts byte ranges" {
    const raw =
        "GET /raw?path=movie.mp4 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Range: bytes=10-99\r\n" ++
        "\r\n";
    const request = try parseHttpRequest(raw);
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expect(request.range != null);
    try std.testing.expectEqual(@as(?usize, 10), request.range.?.start);
    try std.testing.expectEqual(@as(?usize, 99), request.range.?.end);
}
