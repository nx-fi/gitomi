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
const worktrees_page = @import("web/worktrees.zig");
const zwf = @import("zwf.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const out = io.out;
const eprint = io.eprint;

pub const default_host = zwf.default_host;
pub const default_port = zwf.default_port;

pub const Options = zwf.ServerOptions;

pub const HttpRequest = zwf.Request;
pub const ByteRange = zwf.ByteRange;
const csrf_token_byte_len = 32;
const csrf_token_len = csrf_token_byte_len * 2;
const CsrfToken = [csrf_token_len]u8;

var web_csrf_token: CsrfToken = undefined;
var web_csrf_token_ready = false;

const WebContext = struct {
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    request: zwf.Request,
    response: zwf.Response,
    csrf_token: []const u8,
};

const WebRouter = zwf.Router(WebContext);
const Route = WebRouter.Route;

const routes = [_]Route{
    Route.static("/style.css", "text/css", web_css),
    Route.static("/logo.svg", "image/svg+xml", logo_svg),
    Route.static("/theme.js", "application/javascript", theme_js),
    Route.static("/ui.js", "application/javascript", ui_js),
    Route.static("/shortcuts.js", "application/javascript", shortcuts_js),
    Route.static("/tree.js", "application/javascript", tree_js),
    Route.static("/code.js", "application/javascript", code_js),
    Route.static("/projects.js", "application/javascript", projects_js),
    Route.static("/markdown.js", "application/javascript", markdown_js),
    Route.static("/vendor/hljs/all-languages.min.js", "application/javascript", highlight_js),
    Route.static("/highlight/zig.js", "application/javascript", highlight_zig_js),
    Route.static("/highlight/solidity.js", "application/javascript", solidity_js),
    Route.static("/highlight/tla.js", "application/javascript", tla_js),
    Route.static("/highlight/init.js", "application/javascript", highlight_init_js),
    Route.static("/diff.js", "application/javascript", diff_js),
    Route.static("/merge.js", "application/javascript", merge_js),
    Route.get("/raw", handleRaw),
    Route.get("/index/rebuild", handleIndexRebuild),
    Route.get("/nav/stats", handleNavStats),
    Route.get("/", handleCodePage),
    Route.get("/code/root/:component", handleCodeRootComponent),
    Route.get("/code", handleCodePage),
    Route.post("/code/sync", handleCodeSyncPost),
    Route.get("/blame", handleBlamePage),
    Route.get("/commits", handleCommitsPage),
    Route.get("/commit", handleCommitPage),
    Route.get("/overview", handleOverviewPage),
    Route.get("/issues", handleIssuesPage),
    Route.get("/issues/:ref/edit", handleIssueEditPage),
    Route.get("/issues/:ref", handleIssueDetailPage),
    Route.post("/issues", handleIssuePost),
    Route.post("/issues/:ref/:action", handleIssueActionPost),
    Route.get("/pulls", handlePullsPage),
    Route.get("/prs", handlePullsPage),
    Route.get("/pulls/:ref/conflicts", handlePullConflictsPage),
    Route.get("/prs/:ref/conflicts", handlePullConflictsPage),
    Route.get("/pulls/:ref", handlePullDetailPage),
    Route.get("/prs/:ref", handlePullDetailPage),
    Route.post("/pulls", handlePullPost),
    Route.post("/pulls/:ref/:action", handlePullActionPost),
    Route.post("/prs/:ref/:action", handlePullActionPost),
    Route.get("/projects", handleProjectsPage),
    Route.get("/new-project", handleNewProjectPage),
    Route.post("/projects", handleProjectPost),
    Route.post("/projects/items", handleProjectItemPost),
    Route.get("/milestones", handleMilestonesPage),
    Route.get("/milestones/:ref/edit", handleMilestoneEditPage),
    Route.get("/new-milestone", handleNewMilestonePage),
    Route.post("/milestones", handleMilestonePost),
    Route.post("/milestones/:ref", handleMilestoneRefPost),
    Route.get("/access", handleAccessPage),
    Route.post("/access/roles", handleAccessRolePost),
    Route.post("/access/devices", handleAccessDevicePost),
    Route.get("/settings", handleSettingsPage),
    Route.get("/labels", handleLabelsPage),
    Route.post("/labels", handleLabelsPost),
    Route.get("/workflows", handleActionsPage),
    Route.post("/workflows/request", handleActionsRequestPost),
    Route.post("/workflows/run-requested", handleRunRequestedPost),
    Route.get("/actions", handleActionsRedirect),
    Route.post("/actions/request", handleActionsRequestRedirect),
    Route.post("/actions/run-requested", handleRunRequestedRedirect),
    Route.get("/events", handleEventsPage),
    Route.get("/refs", handleRefsPage),
    Route.post("/refs/sync", handleRefsSyncPost),
    Route.get("/worktrees", handleWorktreesPage),
    Route.get("/new-issue", handleNewIssuePage),
    Route.get("/new-pull", handleNewPullPage),
    Route.get("/new-pr", handleNewPullPage),
    Route.get("/favicon.ico", handleFavicon),
};

pub fn serve(allocator: Allocator, repo: Repo, options: Options) !void {
    const bind_host = zwf.server.bindHost(options);
    var server = zwf.server.listen(bind_host, options) catch |err| switch (err) {
        error.InvalidHost => {
            try eprint("gt web: invalid host or port {s}:{d}\n", .{ options.host, options.port });
            return CliError.InvalidArgument;
        },
        error.NoAvailablePort => {
            try eprint("gt web: could not find an available port after {d} attempts starting from {d}\n", .{ options.port_attempt_limit, options.port });
            return CliError.UserError;
        },
        else => return err,
    };
    defer server.deinit();

    const actual_port = server.listen_address.getPort();
    try out("Gitomi web listening at http://{s}:{d}/\n", .{ options.host, actual_port });
    if (!options.once) {
        try out("Press Ctrl-C to stop.\n", .{});
    }

    web_csrf_token = generateCsrfToken();
    web_csrf_token_ready = true;
    try zwf.server.serveConnections(Repo, allocator, repo, &server, options, handleWebConnectionLogged);
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

fn handleWebConnectionLogged(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    handleWebConnection(allocator, repo, stream) catch |err| {
        if (zwf.server.isClientDisconnect(err)) return;
        try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
    };
}

pub fn handleWebConnection(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    if (!web_csrf_token_ready) {
        web_csrf_token = generateCsrfToken();
        web_csrf_token_ready = true;
    }

    const raw = readHttpRequest(allocator, stream) catch |err| {
        if (err == error.EndOfStream) return;
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer allocator.free(raw);

    var request = zwf.Request.parseOwned(allocator, raw) catch {
        try shared.sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer request.deinit(allocator);

    var ctx = WebContext{
        .allocator = allocator,
        .repo = repo,
        .stream = stream,
        .request = request,
        .response = zwf.Response.initWithRequest(allocator, stream, request),
        .csrf_token = web_csrf_token[0..],
    };

    if (try zwf.middleware.sendStaticAssets(ctx.response, ctx.request, &vendor_assets)) return;

    const router = WebRouter.init(&routes);
    if (try router.match(request.method, request.path)) |route_match| {
        ctx.request = request.withParams(route_match.params);
        switch (route_match.route.action) {
            .handler => |handler| try handler(ctx),
            .static_asset => |asset| try zwf.middleware.sendCachedAsset(ctx.response, ctx.request, asset),
        }
        return;
    }

    try sendNotFound(ctx);
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
    try ctx.response.owned(status, reason, content_type, body, extra);
}

fn sendPlainNotFound(ctx: WebContext) !void {
    try ctx.response.notFound();
}

fn sendNotFound(ctx: WebContext) !void {
    try sendOwnedResponse(ctx, 404, "Not Found", "text/html", try renderNotFoundPage(ctx.allocator, ctx.repo), null);
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

fn handleCodeRootComponent(ctx: WebContext) !void {
    const component = ctx.request.param("component") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    const body = try explorer.renderCodeRootComponent(ctx.allocator, ctx.repo, ctx.request.target, component) orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedResponse(ctx, 200, "OK", "text/html", body, "Cache-Control: no-store\r\n");
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

fn handleIssueEditPage(ctx: WebContext) !void {
    const issue_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try issues_page.renderIssueEditPage(ctx.allocator, ctx.repo, issue_ref, ctx.request.target));
}

fn handleIssueDetailPage(ctx: WebContext) !void {
    const issue_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try issues_page.renderIssueDetailPage(ctx.allocator, ctx.repo, issue_ref));
}

fn handleIssueActionPost(ctx: WebContext) !void {
    const issue_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    const action = ctx.request.param("action") orelse {
        try sendPlainNotFound(ctx);
        return;
    };

    if (std.mem.eql(u8, action, "edit")) {
        try issues_page.handleIssueEditPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "checklist")) {
        try issues_page.handleIssueChecklistPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "comments")) {
        try issues_page.handleIssueCommentPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "sidebar")) {
        try issues_page.handleIssueSidebarPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.request.body);
    } else {
        try sendPlainNotFound(ctx);
    }
}

fn handlePullsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try pulls_page.renderPullsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handlePullConflictsPage(ctx: WebContext) !void {
    const pull_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try pulls_page.renderPullMergeEditorPage(ctx.allocator, ctx.repo, pull_ref, ctx.request.target, null));
}

fn handlePullDetailPage(ctx: WebContext) !void {
    const pull_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try pulls_page.renderPullDetailPage(ctx.allocator, ctx.repo, pull_ref, ctx.request.target));
}

fn handlePullActionPost(ctx: WebContext) !void {
    const pull_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    const action = ctx.request.param("action") orelse {
        try sendPlainNotFound(ctx);
        return;
    };

    if (std.mem.eql(u8, action, "conflicts")) {
        try pulls_page.handlePullConflictPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "merge")) {
        try pulls_page.handlePullMergePost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "checklist")) {
        try pulls_page.handlePullChecklistPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "comments")) {
        try pulls_page.handlePullCommentPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else {
        try sendPlainNotFound(ctx);
    }
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

fn handleMilestoneEditPage(ctx: WebContext) !void {
    const milestone_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try milestones_page.renderMilestoneFormFromRef(ctx.allocator, ctx.repo, milestone_ref));
}

fn handleNewMilestonePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try milestones_page.renderNewMilestoneForm(ctx.allocator, ctx.repo));
}

fn handleMilestonePost(ctx: WebContext) !void {
    try milestones_page.handleMilestonePost(ctx.allocator, ctx.repo, ctx.stream, null, ctx.request.body);
}

fn handleMilestoneRefPost(ctx: WebContext) !void {
    const milestone_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try milestones_page.handleMilestonePost(ctx.allocator, ctx.repo, ctx.stream, milestone_ref, ctx.request.body);
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

fn handleActionsRedirect(ctx: WebContext) !void {
    try sendRedirectReplacingPath(ctx, "/actions", "/workflows", false);
}

fn handleActionsRequestRedirect(ctx: WebContext) !void {
    try sendRedirectReplacingPath(ctx, "/actions/request", "/workflows/request", true);
}

fn handleRunRequestedRedirect(ctx: WebContext) !void {
    try sendRedirectReplacingPath(ctx, "/actions/run-requested", "/workflows/run-requested", true);
}

fn handleActionsRequestPost(ctx: WebContext) !void {
    try actions_page.handleActionsRequestPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleRunRequestedPost(ctx: WebContext) !void {
    try actions_page.handleRunRequestedPost(ctx.allocator, ctx.stream, ctx.request.body);
}

fn handleEventsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try events_page.renderEventsPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleRefsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try refs_page.renderRefsPage(ctx.allocator, ctx.repo, ctx.request.target, ctx.csrf_token));
}

fn handleRefsSyncPost(ctx: WebContext) !void {
    try refs_page.handleRefsSyncPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token);
}

fn handleWorktreesPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try worktrees_page.renderWorktreesPage(ctx.allocator, ctx.repo));
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

fn sendRedirectReplacingPath(ctx: WebContext, old_path: []const u8, new_path: []const u8, preserve_method: bool) !void {
    const location = try redirectLocationReplacingPathOwned(ctx.allocator, ctx.request.target, old_path, new_path);
    defer ctx.allocator.free(location);
    if (preserve_method) {
        try sendTemporaryRedirect(ctx, location);
    } else {
        try shared.sendRedirect(ctx.allocator, ctx.stream, location);
    }
}

fn sendTemporaryRedirect(ctx: WebContext, location: []const u8) !void {
    try ctx.response.temporaryRedirect(location);
}

fn redirectLocationReplacingPathOwned(allocator: Allocator, target: []const u8, old_path: []const u8, new_path: []const u8) ![]u8 {
    const tail = if (target.len > old_path.len) target[old_path.len..] else "";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ new_path, tail });
}

pub fn readHttpRequest(allocator: Allocator, stream: std.net.Stream) ![]u8 {
    return zwf.server.readHttpRequest(allocator, stream);
}

pub fn parseHttpRequest(raw: []const u8) !HttpRequest {
    return zwf.Request.parse(raw);
}

pub fn parseHttpRequestOwned(allocator: Allocator, raw: []const u8) !HttpRequest {
    return zwf.Request.parseOwned(allocator, raw);
}

pub fn parseContentLength(headers: []const u8) !usize {
    return zwf.request.parseContentLength(headers);
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

const VendorAsset = zwf.StaticAsset;

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
const marked_js = @embedFile("web/vendor/marked/marked.umd.min.js");
const dompurify_js = @embedFile("web/vendor/dompurify/purify.min.js");
const katex_js = @embedFile("web/vendor/katex/katex.min.js");
const katex_auto_render_js = @embedFile("web/vendor/katex/auto-render.min.js");
const katex_css = @embedFile("web/vendor/katex/katex.min.css");
const devicon_css = @embedFile("web/vendor/devicon/devicon.min.css");
const mermaid_js = @embedFile("web/vendor/mermaid/mermaid.min.js");
const highlight_js = @embedFile("web/vendor/hljs/all-languages.min.js");
const highlight_zig_js = @embedFile("web/highlight/zig.js");
const solidity_js = @embedFile("web/highlight/solidity.js");
const tla_js = @embedFile("web/highlight/tla.js");
const highlight_init_js = @embedFile("web/highlight/init.js");
const diff_js = @embedFile("web/diff.js");
const merge_js = @embedFile("web/merge.js");

fn textVendorAsset(comptime path: []const u8, comptime content_type: []const u8, comptime body: []const u8) VendorAsset {
    return vendorAsset(path, content_type, body, false);
}

fn fontVendorAsset(comptime path: []const u8, comptime body: []const u8) VendorAsset {
    return vendorAsset(path, "font/woff2", body, true);
}

fn vendorAsset(
    comptime path: []const u8,
    comptime content_type: []const u8,
    comptime body: []const u8,
    comptime binary: bool,
) VendorAsset {
    return zwf.middleware.asset(path, content_type, body, binary);
}

const vendor_assets = [_]VendorAsset{
    textVendorAsset("/vendor/marked/marked.umd.min.js", "application/javascript", marked_js),
    textVendorAsset("/vendor/dompurify/purify.min.js", "application/javascript", dompurify_js),
    textVendorAsset("/vendor/katex/katex.min.js", "application/javascript", katex_js),
    textVendorAsset("/vendor/katex/auto-render.min.js", "application/javascript", katex_auto_render_js),
    textVendorAsset("/vendor/katex/katex.min.css", "text/css", katex_css),
    textVendorAsset("/vendor/devicon/devicon.min.css", "text/css", devicon_css),
    vendorAsset("/vendor/devicon/fonts/devicon.eot", "application/vnd.ms-fontobject", @embedFile("web/vendor/devicon/fonts/devicon.eot"), true),
    vendorAsset("/vendor/devicon/fonts/devicon.ttf", "font/ttf", @embedFile("web/vendor/devicon/fonts/devicon.ttf"), true),
    vendorAsset("/vendor/devicon/fonts/devicon.woff", "font/woff", @embedFile("web/vendor/devicon/fonts/devicon.woff"), true),
    vendorAsset("/vendor/devicon/fonts/devicon.svg", "image/svg+xml", @embedFile("web/vendor/devicon/fonts/devicon.svg"), true),
    textVendorAsset("/vendor/mermaid/mermaid.min.js", "application/javascript", mermaid_js),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_AMS-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_AMS-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Caligraphic-Bold.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Caligraphic-Bold.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Caligraphic-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Caligraphic-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Fraktur-Bold.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Fraktur-Bold.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Fraktur-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Fraktur-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Main-Bold.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Main-Bold.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Main-BoldItalic.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Main-BoldItalic.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Main-Italic.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Main-Italic.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Main-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Main-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Math-BoldItalic.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Math-BoldItalic.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Math-Italic.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Math-Italic.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_SansSerif-Bold.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Bold.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_SansSerif-Italic.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Italic.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_SansSerif-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_SansSerif-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Script-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Script-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Size1-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Size1-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Size2-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Size2-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Size3-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Size3-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Size4-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Size4-Regular.woff2")),
    fontVendorAsset("/vendor/katex/fonts/KaTeX_Typewriter-Regular.woff2", @embedFile("web/vendor/katex/fonts/KaTeX_Typewriter-Regular.woff2")),
};

test "web request parser separates method path and body" {
    const raw =
        "POST /issues?x=1 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "title=Smoke";
    const request = try parseHttpRequest(raw);
    try std.testing.expectEqual(zwf.Method.POST, request.method);
    try std.testing.expectEqualStrings("POST", request.method_text);
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
    try std.testing.expectEqual(zwf.Method.GET, request.method);
    try std.testing.expect(request.range != null);
    try std.testing.expectEqual(@as(?usize, 10), request.range.?.start);
    try std.testing.expectEqual(@as(?usize, 99), request.range.?.end);
}

test "web request parser accepts cache validators" {
    const raw =
        "GET /vendor/marked/marked.umd.min.js HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "If-None-Match: \"asset-etag\"\r\n" ++
        "\r\n";
    const request = try parseHttpRequest(raw);
    try std.testing.expectEqual(zwf.Method.GET, request.method);
    try std.testing.expect(request.headerValue("if-none-match") != null);
    try std.testing.expectEqualStrings("\"asset-etag\"", request.headerValue("if-none-match").?);
}

test "web vendor javascript assets use minified filenames" {
    for (vendor_assets) |asset| {
        if (std.mem.eql(u8, asset.content_type, "application/javascript")) {
            try expectVendorJavascriptMinifiedPath(asset.path);
        }
    }
    try expectVendorJavascriptMinifiedPath("/vendor/hljs/all-languages.min.js");
}

fn expectVendorJavascriptMinifiedPath(path: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, path, "/vendor/"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".min.js"));
}

test "web static asset etag matcher handles lists and weak tags" {
    try std.testing.expect(zwf.middleware.etagMatches("\"old\", \"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(zwf.middleware.etagMatches("W/\"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(zwf.middleware.etagMatches("*", "\"asset-etag\""));
    try std.testing.expect(!zwf.middleware.etagMatches("\"different\"", "\"asset-etag\""));
}

test "web actions redirects preserve query on workflows route" {
    const location = try redirectLocationReplacingPathOwned(std.testing.allocator, "/actions?workflow=ci&q=main", "/actions", "/workflows");
    defer std.testing.allocator.free(location);

    try std.testing.expectEqualStrings("/workflows?workflow=ci&q=main", location);
}
