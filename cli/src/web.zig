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
const labels_page = @import("web/labels.zig");
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
const csrf_token_byte_len = 32;
const csrf_token_len = csrf_token_byte_len * 2;
const CsrfToken = [csrf_token_len]u8;
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

const WebContext = struct {
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    request: HttpRequest,
    csrf_token: []const u8,
};

const RouteHandler = *const fn (WebContext) anyerror!void;

const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: RouteHandler,
};

const exact_routes = [_]Route{
    .{ .method = "GET", .path = "/style.css", .handler = handleStyleCss },
    .{ .method = "GET", .path = "/logo.svg", .handler = handleLogoSvg },
    .{ .method = "GET", .path = "/theme.js", .handler = handleThemeJs },
    .{ .method = "GET", .path = "/ui.js", .handler = handleUiJs },
    .{ .method = "GET", .path = "/shortcuts.js", .handler = handleShortcutsJs },
    .{ .method = "GET", .path = "/tree.js", .handler = handleTreeJs },
    .{ .method = "GET", .path = "/code.js", .handler = handleCodeJs },
    .{ .method = "GET", .path = "/projects.js", .handler = handleProjectsJs },
    .{ .method = "GET", .path = "/markdown.js", .handler = handleMarkdownJs },
    .{ .method = "GET", .path = "/vendor/hljs/all-languages.js", .handler = handleHighlightAllJs },
    .{ .method = "GET", .path = "/highlight/zig.js", .handler = handleHighlightZigJs },
    .{ .method = "GET", .path = "/highlight/solidity.js", .handler = handleHighlightSolidityJs },
    .{ .method = "GET", .path = "/highlight/tla.js", .handler = handleHighlightTlaJs },
    .{ .method = "GET", .path = "/highlight/init.js", .handler = handleHighlightInitJs },
    .{ .method = "GET", .path = "/diff.js", .handler = handleDiffJs },
    .{ .method = "GET", .path = "/merge.js", .handler = handleMergeJs },
    .{ .method = "GET", .path = "/raw", .handler = handleRaw },
    .{ .method = "GET", .path = "/index/rebuild", .handler = handleIndexRebuild },
    .{ .method = "GET", .path = "/nav/stats", .handler = handleNavStats },
    .{ .method = "GET", .path = "/", .handler = handleCodePage },
    .{ .method = "GET", .path = "/code", .handler = handleCodePage },
    .{ .method = "POST", .path = "/code/sync", .handler = handleCodeSyncPost },
    .{ .method = "GET", .path = "/blame", .handler = handleBlamePage },
    .{ .method = "GET", .path = "/commits", .handler = handleCommitsPage },
    .{ .method = "GET", .path = "/commit", .handler = handleCommitPage },
    .{ .method = "GET", .path = "/overview", .handler = handleOverviewPage },
    .{ .method = "GET", .path = "/issues", .handler = handleIssuesPage },
    .{ .method = "GET", .path = "/pulls", .handler = handlePullsPage },
    .{ .method = "GET", .path = "/prs", .handler = handlePullsPage },
    .{ .method = "GET", .path = "/projects", .handler = handleProjectsPage },
    .{ .method = "GET", .path = "/new-project", .handler = handleNewProjectPage },
    .{ .method = "POST", .path = "/projects", .handler = handleProjectPost },
    .{ .method = "POST", .path = "/projects/items", .handler = handleProjectItemPost },
    .{ .method = "GET", .path = "/milestones", .handler = handleMilestonesPage },
    .{ .method = "GET", .path = "/new-milestone", .handler = handleNewMilestonePage },
    .{ .method = "POST", .path = "/milestones", .handler = handleMilestonePost },
    .{ .method = "GET", .path = "/access", .handler = handleAccessPage },
    .{ .method = "POST", .path = "/access/roles", .handler = handleAccessRolePost },
    .{ .method = "POST", .path = "/access/devices", .handler = handleAccessDevicePost },
    .{ .method = "GET", .path = "/settings", .handler = handleSettingsPage },
    .{ .method = "GET", .path = "/labels", .handler = handleLabelsPage },
    .{ .method = "POST", .path = "/labels", .handler = handleLabelsPost },
    .{ .method = "GET", .path = "/actions", .handler = handleActionsPage },
    .{ .method = "POST", .path = "/actions/request", .handler = handleActionsRequestPost },
    .{ .method = "POST", .path = "/actions/run-requested", .handler = handleRunRequestedPost },
    .{ .method = "GET", .path = "/events", .handler = handleEventsPage },
    .{ .method = "GET", .path = "/refs", .handler = handleRefsPage },
    .{ .method = "POST", .path = "/refs/sync", .handler = handleRefsSyncPost },
    .{ .method = "GET", .path = "/new-issue", .handler = handleNewIssuePage },
    .{ .method = "POST", .path = "/issues", .handler = handleIssuePost },
    .{ .method = "GET", .path = "/new-pull", .handler = handleNewPullPage },
    .{ .method = "GET", .path = "/new-pr", .handler = handleNewPullPage },
    .{ .method = "POST", .path = "/pulls", .handler = handlePullPost },
    .{ .method = "GET", .path = "/favicon.ico", .handler = handleFavicon },
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

    const csrf_token = generateCsrfToken();

    if (options.once) {
        const connection = try server.accept();
        defer connection.stream.close();
        try handleWebConnectionLogged(allocator, repo, connection.stream, csrf_token[0..]);
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
        pool.spawn(handleWebConnectionTask, .{ allocator, repo, connection, &permits, csrf_token[0..] }) catch |err| {
            connection.stream.close();
            permits.post();
            return err;
        };
    }
}

fn generateCsrfToken() CsrfToken {
    var random_bytes: [csrf_token_byte_len]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var token: CsrfToken = undefined;
    const hex = "0123456789abcdef";
    for (random_bytes, 0..) |byte, i| {
        const hi: usize = @intCast(byte >> 4);
        const lo: usize = @intCast(byte & 0x0f);
        token[i * 2] = hex[hi];
        token[i * 2 + 1] = hex[lo];
    }
    return token;
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

fn handleWebConnectionTask(allocator: Allocator, repo: Repo, connection: std.net.Server.Connection, permits: *std.Thread.Semaphore, csrf_token: []const u8) void {
    defer permits.post();
    defer connection.stream.close();
    handleWebConnectionLogged(allocator, repo, connection.stream, csrf_token) catch {};
}

fn handleWebConnectionLogged(allocator: Allocator, repo: Repo, stream: std.net.Stream, csrf_token: []const u8) !void {
    handleWebConnection(allocator, repo, stream, csrf_token) catch |err| {
        if (isClientDisconnect(err)) return;
        try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
    };
}

fn isClientDisconnect(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn handleWebConnection(allocator: Allocator, repo: Repo, stream: std.net.Stream, csrf_token: []const u8) !void {
    const raw = readHttpRequest(allocator, stream) catch {
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer allocator.free(raw);

    const request = parseHttpRequest(raw) catch {
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };

    const ctx = WebContext{
        .allocator = allocator,
        .repo = repo,
        .stream = stream,
        .request = request,
        .csrf_token = csrf_token,
    };

    if (try dispatchExactRoute(ctx)) return;
    if (try sendVendorAsset(allocator, stream, request.method, request.path)) return;

    if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const issue_ref = pathRefWithSuffix(request.path, "/issues/", "/edit") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try issues_page.handleIssueEditPost(allocator, repo, stream, issue_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/checklist")) {
        const issue_ref = pathRefWithSuffix(request.path, "/issues/", "/checklist") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try issues_page.handleIssueChecklistPost(allocator, repo, stream, issue_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/comments")) {
        const issue_ref = pathRefWithSuffix(request.path, "/issues/", "/comments") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try issues_page.handleIssueCommentPost(allocator, repo, stream, issue_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/sidebar")) {
        const issue_ref = pathRefWithSuffix(request.path, "/issues/", "/sidebar") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try issues_page.handleIssueSidebarPost(allocator, repo, stream, issue_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/issues/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const issue_ref = pathRefWithSuffix(request.path, "/issues/", "/edit") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try sendOwnedHtml(ctx, try issues_page.renderIssueEditPage(allocator, repo, issue_ref, request.target));
        return;
    }

    if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/issues/")) {
        const issue_ref = request.path["/issues/".len..];
        try sendOwnedHtml(ctx, try issues_page.renderIssueDetailPage(allocator, repo, issue_ref));
        return;
    }

    if (std.mem.eql(u8, request.method, "GET") and pullPathHasSuffix(request.path, "/conflicts")) {
        const pull_ref = pullRefWithSuffix(request.path, "/conflicts") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try sendOwnedHtml(ctx, try pulls_page.renderPullMergeEditorPage(allocator, repo, pull_ref, request.target, null));
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and pullPathHasSuffix(request.path, "/conflicts")) {
        const pull_ref = pullRefWithSuffix(request.path, "/conflicts") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try pulls_page.handlePullConflictPost(allocator, repo, stream, pull_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and pullPathHasSuffix(request.path, "/checklist")) {
        const pull_ref = pullRefWithSuffix(request.path, "/checklist") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try pulls_page.handlePullChecklistPost(allocator, repo, stream, pull_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and pullPathHasSuffix(request.path, "/comments")) {
        const pull_ref = pullRefWithSuffix(request.path, "/comments") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try pulls_page.handlePullCommentPost(allocator, repo, stream, pull_ref, request.body);
        return;
    }

    if (std.mem.eql(u8, request.method, "GET")) {
        if (pullRefFromPath(request.path)) |pull_ref| {
            try sendOwnedHtml(ctx, try pulls_page.renderPullDetailPage(allocator, repo, pull_ref, request.target));
            return;
        }
    }

    if (std.mem.eql(u8, request.method, "GET") and std.mem.startsWith(u8, request.path, "/milestones/") and std.mem.endsWith(u8, request.path, "/edit")) {
        const milestone_ref = pathRefWithSuffix(request.path, "/milestones/", "/edit") orelse {
            try sendPlainNotFound(ctx);
            return;
        };
        try sendOwnedHtml(ctx, try milestones_page.renderMilestoneFormFromRef(allocator, repo, milestone_ref));
        return;
    }

    if (std.mem.eql(u8, request.method, "POST") and std.mem.startsWith(u8, request.path, "/milestones/")) {
        const milestone_ref = request.path["/milestones/".len..];
        if (milestone_ref.len == 0 or std.mem.indexOfScalar(u8, milestone_ref, '/') != null) {
            try sendPlainNotFound(ctx);
            return;
        }
        try milestones_page.handleMilestonePost(allocator, repo, stream, milestone_ref, request.body);
        return;
    }

    try sendNotFound(ctx);
}

fn dispatchExactRoute(ctx: WebContext) !bool {
    for (exact_routes) |route| {
        if (std.mem.eql(u8, ctx.request.method, route.method) and std.mem.eql(u8, ctx.request.path, route.path)) {
            try route.handler(ctx);
            return true;
        }
    }
    return false;
}

fn sendTextAsset(ctx: WebContext, content_type: []const u8, body: []const u8) !void {
    try shared.sendResponse(ctx.allocator, ctx.stream, 200, "OK", content_type, body, null);
}

fn sendOwnedHtml(ctx: WebContext, body: []u8) !void {
    try sendOwnedResponse(ctx, 200, "OK", "text/html", body, null);
}

fn sendOwnedResponse(
    ctx: WebContext,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []u8,
    extra: ?[]const u8,
) !void {
    defer ctx.allocator.free(body);
    try shared.sendResponse(ctx.allocator, ctx.stream, status, reason, content_type, body, extra);
}

fn sendPlainNotFound(ctx: WebContext) !void {
    try shared.sendPlainResponse(ctx.allocator, ctx.stream, 404, "Not Found", "Not found\n");
}

fn sendNotFound(ctx: WebContext) !void {
    try sendOwnedResponse(ctx, 404, "Not Found", "text/html", try renderNotFoundPage(ctx.allocator, ctx.repo), null);
}

fn pathRefWithSuffix(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const ref_start = prefix.len;
    const ref_end = path.len - suffix.len;
    if (ref_start >= ref_end or path[ref_end - 1] == '/') return null;
    return path[ref_start..ref_end];
}

fn pullPathHasSuffix(path: []const u8, suffix: []const u8) bool {
    return pullPrefix(path) != null and std.mem.endsWith(u8, path, suffix);
}

fn pullRefWithSuffix(path: []const u8, suffix: []const u8) ?[]const u8 {
    const prefix = pullPrefix(path) orelse return null;
    return pathRefWithSuffix(path, prefix, suffix);
}

fn pullRefFromPath(path: []const u8) ?[]const u8 {
    const prefix = pullPrefix(path) orelse return null;
    return path[prefix.len..];
}

fn pullPrefix(path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "/pulls/")) return "/pulls/";
    if (std.mem.startsWith(u8, path, "/prs/")) return "/prs/";
    return null;
}

fn handleStyleCss(ctx: WebContext) !void {
    try sendTextAsset(ctx, "text/css", web_css);
}

fn handleLogoSvg(ctx: WebContext) !void {
    try sendTextAsset(ctx, "image/svg+xml", logo_svg);
}

fn handleThemeJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", theme_js);
}

fn handleUiJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", ui_js);
}

fn handleShortcutsJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", shortcuts_js);
}

fn handleTreeJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", tree_js);
}

fn handleCodeJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", code_js);
}

fn handleProjectsJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", projects_js);
}

fn handleMarkdownJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", markdown_js);
}

fn handleHighlightAllJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", highlight_js);
}

fn handleHighlightZigJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", highlight_zig_js);
}

fn handleHighlightSolidityJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", solidity_js);
}

fn handleHighlightTlaJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", tla_js);
}

fn handleHighlightInitJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", highlight_init_js);
}

fn handleDiffJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", diff_js);
}

fn handleMergeJs(ctx: WebContext) !void {
    try sendTextAsset(ctx, "application/javascript", merge_js);
}

fn handleRaw(ctx: WebContext) !void {
    const raw_blob_opt = explorer.loadRawBlob(ctx.allocator, ctx.repo, ctx.request.target) catch |err| switch (err) {
        error.BlobTooLarge => {
            try shared.sendPlainResponse(ctx.allocator, ctx.stream, 413, "Payload Too Large", "Blob too large\n");
            return;
        },
        else => return err,
    };
    if (raw_blob_opt) |raw_blob| {
        var blob = raw_blob;
        defer blob.deinit(ctx.allocator);
        try sendRawBlobResponse(ctx.allocator, ctx.stream, blob, ctx.request.range);
    } else {
        try shared.sendPlainResponse(ctx.allocator, ctx.stream, 404, "Not Found", "Blob not found\n");
    }
}

fn handleIndexRebuild(ctx: WebContext) !void {
    try index.ensureIndex(ctx.allocator, ctx.repo);
    try shared.sendResponse(ctx.allocator, ctx.stream, 204, "No Content", "text/plain", "", null);
}

fn handleNavStats(ctx: WebContext) !void {
    try sendOwnedResponse(ctx, 200, "OK", "application/json", try shared.renderNavStatsJson(ctx.allocator, ctx.repo), "Cache-Control: no-store\r\n");
}

fn handleCodePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try explorer.renderCodePage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleCodeSyncPost(ctx: WebContext) !void {
    try explorer.handleCodeSyncPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleBlamePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try explorer.renderBlamePage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleCommitsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try commits_page.renderCommitsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleCommitPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try commits_page.renderCommitPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleOverviewPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try overview_page.renderHomePage(ctx.allocator, ctx.repo));
}

fn handleIssuesPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try issues_page.renderIssuesPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handlePullsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try pulls_page.renderPullsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleProjectsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try projects_page.renderProjectsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleNewProjectPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try projects_page.renderProjectFormFromTarget(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleProjectPost(ctx: WebContext) !void {
    try projects_page.handleProjectPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleProjectItemPost(ctx: WebContext) !void {
    try projects_page.handleProjectItemPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleMilestonesPage(ctx: WebContext) !void {
    try shared.sendRedirect(ctx.allocator, ctx.stream, "/projects#milestones");
}

fn handleNewMilestonePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try milestones_page.renderNewMilestoneForm(ctx.allocator, ctx.repo));
}

fn handleMilestonePost(ctx: WebContext) !void {
    try milestones_page.handleMilestonePost(ctx.allocator, ctx.repo, ctx.stream, null, ctx.request.body);
}

fn handleAccessPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try access_page.renderAccessPage(ctx.allocator, ctx.repo));
}

fn handleSettingsPage(ctx: WebContext) !void {
    try shared.sendRedirect(ctx.allocator, ctx.stream, "/events");
}

fn handleLabelsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try labels_page.renderLabelsPage(ctx.allocator, ctx.repo));
}

fn handleLabelsPost(ctx: WebContext) !void {
    try labels_page.handleLabelsPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleAccessRolePost(ctx: WebContext) !void {
    try access_page.handleAccessRolePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleAccessDevicePost(ctx: WebContext) !void {
    try access_page.handleAccessDevicePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleActionsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try actions_page.renderActionsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleActionsRequestPost(ctx: WebContext) !void {
    try actions_page.handleActionsRequestPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleRunRequestedPost(ctx: WebContext) !void {
    try actions_page.handleRunRequestedPost(ctx.allocator, ctx.stream, ctx.request.body);
}

fn handleEventsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try events_page.renderEventsPage(ctx.allocator, ctx.repo));
}

fn handleRefsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try refs_page.renderRefsPage(ctx.allocator, ctx.repo, ctx.request.target, ctx.csrf_token));
}

fn handleRefsSyncPost(ctx: WebContext) !void {
    try refs_page.handleRefsSyncPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token);
}

fn handleNewIssuePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try issues_page.renderIssueFormFromTarget(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleIssuePost(ctx: WebContext) !void {
    try issues_page.handleIssuePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleNewPullPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try pulls_page.renderPullForm(ctx.allocator, ctx.repo, null, "", "", "", "", false));
}

fn handlePullPost(ctx: WebContext) !void {
    try pulls_page.handlePullPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleFavicon(ctx: WebContext) !void {
    try shared.sendResponse(ctx.allocator, ctx.stream, 204, "No Content", "text/plain", "", null);
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
const projects_js = @embedFile("web/projects.js");
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
