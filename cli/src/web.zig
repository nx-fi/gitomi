const std = @import("std");
const actions_page = @import("web/actions.zig");
const commits_page = @import("web/commits.zig");
const errors = @import("errors.zig");
const events_page = @import("web/events.zig");
const explorer = @import("web/explorer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const github_live = @import("providers/github/live.zig");
const access_page = @import("web/access.zig");
const issues_page = @import("web/issues.zig");
const labels_page = @import("web/labels.zig");
const models_page = @import("web/models.zig");
const milestones_page = @import("web/milestones.zig");
const overview_page = @import("web/overview.zig");
const projects_page = @import("web/projects.zig");
const pulls_page = @import("web/pulls.zig");
const refs_page = @import("web/refs.zig");
const repo_mod = @import("repo.zig");
const shared = @import("web/shared.zig");
const theme_settings_page = @import("web/theme_settings.zig");
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

const WebContext = struct {
    allocator: Allocator,
    repo: Repo,
    csrf_token: []const u8,
    stream: std.net.Stream,
    request: zwf.Request,
    response: zwf.Response,
};

const WebAppContext = struct {
    repo: Repo,
    csrf_token: []const u8,
};

const WebRouter = zwf.Router(WebContext);
const Route = WebRouter.Route;

const routes = [_]Route{
    Route.static("/style.css", "text/css", web_css),
    Route.static("/styles/base.css", "text/css", style_base_css),
    Route.static("/styles/issues-list.css", "text/css", style_issues_list_css),
    Route.static("/styles/pulls.css", "text/css", style_pulls_css),
    Route.static("/styles/merge-editor.css", "text/css", style_merge_editor_css),
    Route.static("/styles/issues-detail.css", "text/css", style_issues_detail_css),
    Route.static("/styles/projects.css", "text/css", style_projects_css),
    Route.static("/styles/controls.css", "text/css", style_controls_css),
    Route.static("/styles/labels.css", "text/css", style_labels_css),
    Route.static("/styles/milestones.css", "text/css", style_milestones_css),
    Route.static("/styles/settings.css", "text/css", style_settings_css),
    Route.static("/styles/refs-worktrees.css", "text/css", style_refs_worktrees_css),
    Route.static("/styles/actions.css", "text/css", style_actions_css),
    Route.static("/styles/status-indexing.css", "text/css", style_status_indexing_css),
    Route.static("/styles/code-browser.css", "text/css", style_code_browser_css),
    Route.static("/styles/commits.css", "text/css", style_commits_css),
    Route.static("/styles/diff.css", "text/css", style_diff_css),
    Route.static("/styles/markdown.css", "text/css", style_markdown_css),
    Route.static("/styles/forms-overrides.css", "text/css", style_forms_overrides_css),
    Route.static("/styles/responsive.css", "text/css", style_responsive_css),
    Route.static("/styles/shortcuts.css", "text/css", style_shortcuts_css),
    Route.static("/themes/gitomi.css", "text/css", gitomi_theme_css),
    Route.static("/themes/capucine.css", "text/css", capucine_theme_css),
    Route.static("/themes/modern.css", "text/css", modern_theme_css),
    Route.static("/logo.svg", "image/svg+xml", logo_svg),
    Route.static("/theme.js", "application/javascript", theme_js),
    Route.static("/ui.js", "application/javascript", ui_js),
    Route.static("/shortcuts.js", "application/javascript", shortcuts_js),
    Route.static("/tree.js", "application/javascript", tree_js),
    Route.static("/code.js", "application/javascript", code_js),
    Route.static("/pdf.js", "application/javascript", pdf_js),
    Route.static("/projects.js", "application/javascript", projects_js),
    Route.static("/markdown.js", "application/javascript", markdown_js),
    Route.static("/vendor/pdfjs/build/pdf.mjs", "application/javascript", pdfjs_mjs),
    Route.static("/vendor/pdfjs/build/pdf.worker.mjs", "application/javascript", pdfjs_worker_mjs),
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
    Route.post("/live-mode", handleLiveModePost),
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
    Route.post("/projects/properties", handleProjectPropertiesPost),
    Route.post("/projects/items", handleProjectItemPost),
    Route.get("/milestones", handleMilestonesPage),
    Route.get("/milestones/:ref/edit", handleMilestoneEditPage),
    Route.get("/milestones/:ref", handleMilestoneDetailPage),
    Route.get("/new-milestone", handleNewMilestonePage),
    Route.post("/milestones", handleMilestonePost),
    Route.post("/milestones/:ref", handleMilestoneRefPost),
    Route.get("/access", handleAccessPage),
    Route.post("/access/roles", handleAccessRolePost),
    Route.post("/access/devices", handleAccessDevicePost),
    Route.get("/settings", handleSettingsPage),
    Route.get("/settings/theme", handleSettingsThemePage),
    Route.get("/settings/models", handleSettingsModelsPage),
    Route.post("/settings/models", handleSettingsModelsPost),
    Route.get("/settings/labels", handleLabelsPage),
    Route.post("/settings/labels", handleLabelsPost),
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
    Route.post("/refs/delete", handleRefsDeletePost),
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

    const csrf_token = try zwf.csrf.generateTokenOwned(allocator);
    defer allocator.free(csrf_token);

    const app_context = WebAppContext{
        .repo = repo,
        .csrf_token = csrf_token,
    };
    try zwf.server.serveConnections(WebAppContext, allocator, app_context, &server, options, handleWebConnectionLogged);
}

fn handleWebConnectionLogged(allocator: Allocator, app_context: WebAppContext, stream: std.net.Stream) !void {
    handleWebConnectionWithContext(allocator, app_context, stream) catch |err| {
        if (zwf.server.isClientDisconnect(err)) return;
        try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
    };
}

pub fn handleWebConnection(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    const csrf_token = try zwf.csrf.generateTokenOwned(allocator);
    defer allocator.free(csrf_token);
    try handleWebConnectionWithContext(allocator, .{
        .repo = repo,
        .csrf_token = csrf_token,
    }, stream);
}

fn handleWebConnectionWithContext(allocator: Allocator, app_context: WebAppContext, stream: std.net.Stream) !void {
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
        .repo = app_context.repo,
        .csrf_token = app_context.csrf_token,
        .stream = stream,
        .request = request,
        .response = zwf.Response.initWithRequest(allocator, stream, request),
    };

    if (!isValidCsrfRequest(request)) {
        try shared.sendPlainResponse(allocator, stream, 403, "Forbidden", "Forbidden\n");
        return;
    }
    if (try zwf.middleware.sendStaticAssets(ctx.response, ctx.request, &vendor_assets)) return;

    const router = WebRouter.init(&routes);
    if (try router.match(request.method, request.path)) |route_match| {
        ctx.request = request.withParams(route_match.params);
        switch (route_match.route.action) {
            .handler => |handler| handler(ctx) catch |err| {
                if (err == CliError.LocalInboxChanged) {
                    try shared.sendPlainResponse(ctx.allocator, ctx.stream, 409, "Conflict", shared.localWriteBlockedMessage);
                    return;
                }
                return err;
            },
            .static_asset => |asset| try zwf.middleware.sendCachedAsset(ctx.response, ctx.request, asset),
        }
        return;
    }

    try sendNotFound(ctx);
}

fn requestHasTrustedOrigin(request: zwf.Request) bool {
    if (request.headerValue("origin")) |origin| {
        return httpUrlHasRequestHost(request, origin);
    }
    if (request.headerValue("referer")) |referer| {
        return httpUrlHasRequestHost(request, referer);
    }
    return false;
}

fn httpUrlHasRequestHost(request: zwf.Request, value: []const u8) bool {
    const host = request.headerValue("host") orelse return false;
    const rest = stripPrefixIgnoreCase(value, "http://") orelse return false;
    const authority_end = firstUrlAuthorityTerminator(rest);
    const authority = rest[0..authority_end];
    if (authority.len == 0) return false;
    return std.ascii.eqlIgnoreCase(authority, host);
}

fn stripPrefixIgnoreCase(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (value.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    return value[prefix.len..];
}

fn firstUrlAuthorityTerminator(value: []const u8) usize {
    for (value, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') return i;
    }
    return value.len;
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
    if (!isSameOriginPost(ctx.request)) {
        try shared.sendPlainResponse(ctx.allocator, ctx.stream, 403, "Forbidden", "Forbidden\n");
        return;
    }
    try explorer.handleCodeSyncPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleLiveModePost(ctx: WebContext) !void {
    var form = try ctx.request.formValues(ctx.allocator);
    defer form.deinit();

    const enabled_raw = form.value("enabled") orelse "false";
    const enabled = std.ascii.eqlIgnoreCase(enabled_raw, "true") or
        std.mem.eql(u8, enabled_raw, "1") or
        std.ascii.eqlIgnoreCase(enabled_raw, "on");

    if (!github_live.setRuntimeActive(enabled)) {
        try shared.sendPlainResponse(ctx.allocator, ctx.stream, 409, "Conflict", "Live mode is not available\n");
        return;
    }

    const location = try sameOriginRefererTargetOwned(ctx.allocator, ctx.request, "/");
    defer ctx.allocator.free(location);
    try shared.sendRedirect(ctx.allocator, ctx.stream, location);
}

fn isSameOriginPost(request: HttpRequest) bool {
    const host_header = request.headerValue("host") orelse return false;
    const request_authority = parseAuthority(host_header) orelse return false;
    if (!isLoopbackHost(request_authority.host)) return false;

    if (request.headerValue("origin")) |origin| {
        return sourceUrlMatchesAuthority(origin, request_authority);
    }
    if (request.headerValue("referer")) |referer| {
        return sourceUrlMatchesAuthority(referer, request_authority);
    }
    return false;
}

const Authority = struct {
    host: []const u8,
    port: ?u16,
};

fn sourceUrlMatchesAuthority(value: []const u8, expected: Authority) bool {
    const authority = parseSourceAuthority(value) orelse return false;
    return authoritiesMatch(authority, expected);
}

fn sameOriginRefererTargetOwned(allocator: Allocator, request: HttpRequest, fallback: []const u8) ![]u8 {
    const referer = request.headerValue("referer") orelse return try allocator.dupe(u8, fallback);
    const host_header = request.headerValue("host") orelse return try allocator.dupe(u8, fallback);
    const expected = parseAuthority(host_header) orelse return try allocator.dupe(u8, fallback);
    if (!sourceUrlMatchesAuthority(referer, expected)) return try allocator.dupe(u8, fallback);
    const target = sourceUrlTarget(referer) orelse return try allocator.dupe(u8, fallback);
    if (!isSafeRedirectTarget(target)) return try allocator.dupe(u8, fallback);
    return try allocator.dupe(u8, target);
}

fn sourceUrlTarget(value: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse return null;
    const rest = value[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse return "/";
    return rest[authority_end..];
}

fn isSafeRedirectTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/') return false;
    if (target.len > 1 and target[1] == '/') return false;
    return std.mem.indexOfAny(u8, target, "\r\n") == null;
}

fn authoritiesMatch(actual: Authority, expected: Authority) bool {
    if (actual.port != expected.port) return false;
    if (isLoopbackHost(expected.host)) return isLoopbackHost(actual.host);
    return std.ascii.eqlIgnoreCase(actual.host, expected.host);
}

fn parseSourceAuthority(value: []const u8) ?Authority {
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    const rest = value[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return parseAuthority(rest[0..authority_end]);
}

fn parseAuthority(value: []const u8) ?Authority {
    if (value.len == 0) return null;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return null;
        const host = value[1..close];
        if (host.len == 0) return null;
        if (close + 1 == value.len) return .{ .host = host, .port = null };
        if (value[close + 1] != ':') return null;
        const port_text = value[close + 2 ..];
        if (port_text.len == 0) return null;
        return .{
            .host = host,
            .port = std.fmt.parseUnsigned(u16, port_text, 10) catch return null,
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse {
        return .{ .host = value, .port = null };
    };
    const host = value[0..colon];
    const port_text = value[colon + 1 ..];
    if (host.len == 0 or port_text.len == 0) return null;
    if (std.mem.indexOfScalar(u8, host, ':') != null) return null;
    return .{
        .host = host,
        .port = std.fmt.parseUnsigned(u16, port_text, 10) catch return null,
    };
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
    try sendOwnedHtml(ctx, try issues_page.renderIssueDetailPage(ctx.allocator, ctx.repo, issue_ref, ctx.csrf_token));
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
        if (!try requireCsrfToken(ctx)) return;
        try issues_page.handleIssueChecklistPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "comments")) {
        if (!try requireCsrfToken(ctx)) return;
        try issues_page.handleIssueCommentPost(ctx.allocator, ctx.repo, ctx.stream, issue_ref, ctx.csrf_token, ctx.request.body);
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
    try sendOwnedHtml(ctx, try pulls_page.renderPullMergeEditorPage(ctx.allocator, ctx.repo, pull_ref, ctx.request.target, ctx.csrf_token, null));
}

fn handlePullDetailPage(ctx: WebContext) !void {
    const pull_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try pulls_page.renderPullDetailPage(ctx.allocator, ctx.repo, pull_ref, ctx.request.target, ctx.csrf_token));
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
        if (!requestHasTrustedOrigin(ctx.request)) {
            try shared.sendPlainResponse(ctx.allocator, ctx.stream, 403, "Forbidden", "Forbidden\n");
            return;
        }
        try pulls_page.handlePullConflictPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.csrf_token, ctx.request.body);
    } else if (std.mem.eql(u8, action, "merge")) {
        if (!requestHasTrustedOrigin(ctx.request)) {
            try shared.sendPlainResponse(ctx.allocator, ctx.stream, 403, "Forbidden", "Forbidden\n");
            return;
        }
        try pulls_page.handlePullMergePost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.csrf_token, ctx.request.body);
    } else if (std.mem.eql(u8, action, "checklist")) {
        if (!try requireCsrfToken(ctx)) return;
        try pulls_page.handlePullChecklistPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "comments")) {
        try pulls_page.handlePullCommentPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.request.body);
    } else if (std.mem.eql(u8, action, "sidebar")) {
        if (!try requireCsrfToken(ctx)) return;
        try pulls_page.handlePullSidebarPost(ctx.allocator, ctx.repo, ctx.stream, pull_ref, ctx.csrf_token, ctx.request.body);
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

fn handleProjectPropertiesPost(ctx: WebContext) !void {
    try projects_page.handleProjectPropertiesPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleMilestonesPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try milestones_page.renderMilestonesPage(ctx.allocator, ctx.repo, ctx.request.target));
}

fn handleMilestoneDetailPage(ctx: WebContext) !void {
    const milestone_ref = ctx.request.param("ref") orelse {
        try sendPlainNotFound(ctx);
        return;
    };
    try sendOwnedHtml(ctx, try milestones_page.renderMilestoneDetailPage(ctx.allocator, ctx.repo, milestone_ref, ctx.request.target));
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
    try sendOwnedHtml(ctx, try access_page.renderAccessPage(ctx.allocator, ctx.repo, ctx.csrf_token[0..]));
}

fn handleSettingsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try theme_settings_page.renderThemePage(ctx.allocator, ctx.repo));
}

fn handleSettingsThemePage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try theme_settings_page.renderThemePage(ctx.allocator, ctx.repo));
}

fn handleSettingsModelsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try models_page.renderModelsPage(ctx.allocator, ctx.repo, ctx.request.target, ctx.csrf_token));
}

fn handleSettingsModelsPost(ctx: WebContext) !void {
    try models_page.handleModelsPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token);
}

fn handleLabelsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try labels_page.renderLabelsPage(ctx.allocator, ctx.repo, ctx.csrf_token));
}

fn handleLabelsPost(ctx: WebContext) !void {
    if (!(try zwf.csrf.verifyRequest(ctx.allocator, ctx.request, ctx.csrf_token))) {
        try ctx.response.plain(403, "Forbidden", "Invalid CSRF token\n");
        return;
    }
    try labels_page.handleLabelsPost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body);
}

fn handleAccessRolePost(ctx: WebContext) !void {
    try access_page.handleAccessRolePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token[0..]);
}

fn handleAccessDevicePost(ctx: WebContext) !void {
    try access_page.handleAccessDevicePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token[0..]);
}

fn handleActionsPage(ctx: WebContext) !void {
    try sendOwnedHtml(ctx, try actions_page.renderActionsPage(ctx.allocator, ctx.repo, ctx.request.target, ctx.csrf_token));
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
    if (!try requireSameOriginActionPost(ctx)) return;
    if (!try requireCsrfToken(ctx)) return;
    try actions_page.handleActionsRequestPost(ctx.allocator, ctx.repo, ctx.stream, ctx.csrf_token, ctx.request.body);
}

fn handleRunRequestedPost(ctx: WebContext) !void {
    if (!try requireSameOriginActionPost(ctx)) return;
    if (!try requireCsrfToken(ctx)) return;
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

fn handleRefsDeletePost(ctx: WebContext) !void {
    try refs_page.handleRefsDeletePost(ctx.allocator, ctx.repo, ctx.stream, ctx.request.body, ctx.csrf_token);
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
    try sendOwnedHtml(ctx, try pulls_page.renderPullForm(ctx.allocator, ctx.repo, ctx.csrf_token, null, "", "", "", "", false));
}

fn handlePullPost(ctx: WebContext) !void {
    try pulls_page.handlePullPost(ctx.allocator, ctx.repo, ctx.stream, ctx.csrf_token, ctx.request.body);
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

fn isValidCsrfRequest(request: HttpRequest) bool {
    if (request.method != .POST) return true;
    return isSameOriginPost(request);
}

fn requireCsrfToken(ctx: WebContext) !bool {
    if (requestHasValidCsrfToken(ctx.allocator, ctx.request, ctx.csrf_token)) return true;
    try shared.sendPlainResponse(ctx.allocator, ctx.stream, 403, "Forbidden", "Invalid CSRF token\n");
    return false;
}

fn requestHasValidCsrfToken(allocator: Allocator, request: HttpRequest, expected: []const u8) bool {
    return zwf.csrf.verifyRequest(allocator, request, expected) catch false;
}

fn requireSameOriginActionPost(ctx: WebContext) !bool {
    if (isSameOriginBrowserRequest(ctx.request)) return true;
    try shared.sendPlainResponse(ctx.allocator, ctx.stream, 403, "Forbidden", "Forbidden: same-origin request required\n");
    return false;
}

fn isSameOriginBrowserRequest(request: HttpRequest) bool {
    const host = request.headerValue("host") orelse return false;
    // Reject Host values that are not loopback addresses to prevent DNS rebinding:
    // an attacker cannot serve evil.example pointing to 127.0.0.1 and have the
    // loopback check pass, because evil.example is not a recognised loopback name.
    if (!isLoopbackHost(hostnameFromHeader(host))) return false;
    if (request.headerValue("origin")) |origin| {
        return sourceMatchesHost(origin, host);
    }
    if (request.headerValue("referer")) |referer| {
        return sourceMatchesHost(referer, host);
    }
    return false;
}

fn sourceMatchesHost(source: []const u8, host: []const u8) bool {
    const source_host = httpSourceHost(source) orelse return false;
    return std.ascii.eqlIgnoreCase(source_host, std.mem.trim(u8, host, " \t"));
}

fn httpSourceHost(source: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t");
    const rest = if (std.mem.startsWith(u8, trimmed, "http://"))
        trimmed["http://".len..]
    else
        return null;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// Extracts the hostname from a Host header value, stripping the optional port.
/// Examples: "127.0.0.1:12655" → "127.0.0.1", "[::1]:12655" → "::1", "localhost" → "localhost".
fn hostnameFromHeader(host_header: []const u8) []const u8 {
    if (host_header.len > 0 and host_header[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_header, ']') orelse return host_header;
        if (close > 1) return host_header[1..close];
        return host_header;
    }
    if (std.mem.lastIndexOfScalar(u8, host_header, ':')) |colon| {
        return host_header[0..colon];
    }
    return host_header;
}

fn isForbiddenCrossOriginWrite(request: HttpRequest) bool {
    if (!isWriteMethod(request.method)) return false;

    if (request.headerValue("sec-fetch-site")) |site| {
        if (std.ascii.eqlIgnoreCase(site, "cross-site")) return true;
    }

    if (request.headerValue("origin")) |origin| {
        return !sourceUrlMatchesRequestHost(origin, request);
    }

    if (request.headerValue("referer")) |referer| {
        return !sourceUrlMatchesRequestHost(referer, request);
    }

    return false;
}

fn isWriteMethod(method: zwf.Method) bool {
    return switch (method) {
        .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
}

fn sourceUrlMatchesRequestHost(source: []const u8, request: HttpRequest) bool {
    const host_header = request.headerValue("host") orelse return false;
    const request_authority = parseAuthority(host_header) orelse return false;
    return sourceUrlMatchesAuthority(source, request_authority);
}

pub fn parseContentLength(headers: []const u8) !usize {
    return zwf.request.parseContentLength(headers);
}

test "merge origin guard accepts same-origin posts" {
    const request = try zwf.Request.parse(
        "POST /pulls/1/merge HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:8080\r\n" ++
            "Origin: http://127.0.0.1:8080\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(requestHasTrustedOrigin(request));
}

test "merge origin guard accepts same-origin referers" {
    const request = try zwf.Request.parse(
        "POST /pulls/1/merge HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "Referer: http://localhost:8080/pulls/1\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(requestHasTrustedOrigin(request));
}

test "merge origin guard rejects cross-origin posts" {
    const request = try zwf.Request.parse(
        "POST /pulls/1/merge HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:8080\r\n" ++
            "Origin: http://attacker.example\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!requestHasTrustedOrigin(request));
}

test "merge origin guard rejects cross-origin referers" {
    const request = try zwf.Request.parse(
        "POST /pulls/1/merge HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "Referer: http://evil.example/form.html\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!requestHasTrustedOrigin(request));
}

test "merge origin guard rejects missing provenance headers" {
    const request = try zwf.Request.parse(
        "POST /pulls/1/merge HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:8080\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!requestHasTrustedOrigin(request));
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
    return std.ascii.eqlIgnoreCase(host, default_host) or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

const web_css = @embedFile("web/style.css");
const style_base_css = @embedFile("web/styles/base.css");
const style_issues_list_css = @embedFile("web/styles/issues-list.css");
const style_pulls_css = @embedFile("web/styles/pulls.css");
const style_merge_editor_css = @embedFile("web/styles/merge-editor.css");
const style_issues_detail_css = @embedFile("web/styles/issues-detail.css");
const style_projects_css = @embedFile("web/styles/projects.css");
const style_controls_css = @embedFile("web/styles/controls.css");
const style_labels_css = @embedFile("web/styles/labels.css");
const style_milestones_css = @embedFile("web/styles/milestones.css");
const style_settings_css = @embedFile("web/styles/settings.css");
const style_refs_worktrees_css = @embedFile("web/styles/refs-worktrees.css");
const style_actions_css = @embedFile("web/styles/actions.css");
const style_status_indexing_css = @embedFile("web/styles/status-indexing.css");
const style_code_browser_css = @embedFile("web/styles/code-browser.css");
const style_commits_css = @embedFile("web/styles/commits.css");
const style_diff_css = @embedFile("web/styles/diff.css");
const style_markdown_css = @embedFile("web/styles/markdown.css");
const style_forms_overrides_css = @embedFile("web/styles/forms-overrides.css");
const style_responsive_css = @embedFile("web/styles/responsive.css");
const style_shortcuts_css = @embedFile("web/styles/shortcuts.css");
const gitomi_theme_css = @embedFile("web/themes/gitomi.css");
const capucine_theme_css = @embedFile("web/themes/capucine.css");
const modern_theme_css = @embedFile("web/themes/modern.css");
const logo_svg = @embedFile("web/logo.svg");
const theme_js = @embedFile("web/theme.js");
const ui_js = @embedFile("web/ui.js");
const shortcuts_js = @embedFile("web/shortcuts.js");
const tree_js = @embedFile("web/tree.js");
const code_js = @embedFile("web/code.js");
const pdf_js = @embedFile("web/pdf.js");
const projects_js = @embedFile("web/projects.js");
const markdown_js = @embedFile("web/markdown.js");
const pdfjs_mjs = @embedFile("web/vendor/pdfjs/build/pdf.mjs");
const pdfjs_worker_mjs = @embedFile("web/vendor/pdfjs/build/pdf.worker.mjs");
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
    try std.testing.expectEqualStrings("127.0.0.1", request.headerValue("host").?);
    try std.testing.expect(request.headerValue("origin") == null);
    try std.testing.expect(request.headerValue("referer") == null);
    try std.testing.expect(request.range == null);
    try std.testing.expectEqualStrings("127.0.0.1", request.headerValue("host").?);
}

test "web request rejects cross-origin writes" {
    const raw =
        "POST /projects HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://evil.example\r\n" ++
        "Sec-Fetch-Site: cross-site\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "name=evil";
    const request = try parseHttpRequest(raw);
    try std.testing.expect(isForbiddenCrossOriginWrite(request));
}

test "web request accepts same-origin writes" {
    const raw =
        "POST /projects HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Sec-Fetch-Site: same-origin\r\n" ++
        "Content-Length: 8\r\n" ++
        "\r\n" ++
        "name=ok!";
    const request = try parseHttpRequest(raw);
    try std.testing.expect(!isForbiddenCrossOriginWrite(request));
}

test "web code sync requires trusted same-origin post headers" {
    const same_origin = try parseHttpRequest(
        "POST /code/sync HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Origin: http://localhost:12655\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "action=exchange",
    );
    try std.testing.expect(isSameOriginPost(same_origin));

    const same_referer = try parseHttpRequest(
        "POST /code/sync HTTP/1.1\r\n" ++
            "Host: localhost:12655\r\n" ++
            "Referer: http://127.0.0.1:12655/code\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "action=exchange",
    );
    try std.testing.expect(isSameOriginPost(same_referer));

    const rebinding_attempt = try parseHttpRequest(
        "POST /code/sync HTTP/1.1\r\n" ++
            "Host: attacker.test:12655\r\n" ++
            "Origin: http://attacker.test:12655\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "action=exchange",
    );
    try std.testing.expect(!isSameOriginPost(rebinding_attempt));

    const missing_origin = try parseHttpRequest(
        "POST /code/sync HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "action=exchange",
    );
    try std.testing.expect(!isSameOriginPost(missing_origin));
}

test "live mode post redirects only to same-origin referer targets" {
    const same_origin = try parseHttpRequest(
        "POST /live-mode HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Referer: http://localhost:12655/issues?state=open#top\r\n" ++
            "Content-Length: 12\r\n" ++
            "\r\n" ++
            "enabled=true",
    );
    const target = try sameOriginRefererTargetOwned(std.testing.allocator, same_origin, "/");
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("/issues?state=open#top", target);

    const cross_origin = try parseHttpRequest(
        "POST /live-mode HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Referer: http://example.test/issues\r\n" ++
            "Content-Length: 12\r\n" ++
            "\r\n" ++
            "enabled=true",
    );
    const fallback = try sameOriginRefererTargetOwned(std.testing.allocator, cross_origin, "/");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("/", fallback);
}

test "web CSRF validation requires same-origin POST metadata" {
    const same_origin = try parseHttpRequest(
        "POST /issues HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Origin: http://127.0.0.1:12655\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(isValidCsrfRequest(same_origin));

    const same_referer = try parseHttpRequest(
        "POST /issues HTTP/1.1\r\n" ++
            "Host: localhost:12655\r\n" ++
            "Referer: http://localhost:12655/new-issue\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(isValidCsrfRequest(same_referer));

    const rebinding_attempt = try parseHttpRequest(
        "POST /issues HTTP/1.1\r\n" ++
            "Host: attacker.test:12655\r\n" ++
            "Origin: http://attacker.test:12655\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!isValidCsrfRequest(rebinding_attempt));

    const cross_origin = try parseHttpRequest(
        "POST /issues HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Origin: https://attacker.example\r\n" ++
            "Referer: http://127.0.0.1:12655/new-issue\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!isValidCsrfRequest(cross_origin));

    const missing_metadata = try parseHttpRequest(
        "POST /issues HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:12655\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );
    try std.testing.expect(!isValidCsrfRequest(missing_metadata));
}

test "actions csrf guard accepts same-origin posts with token" {
    const body = "_csrf=action-token";
    const raw =
        "POST /actions/request HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const request = try parseHttpRequest(raw);
    try std.testing.expect(isSameOriginBrowserRequest(request));
    try std.testing.expect(try zwf.csrf.verifyRequest(std.testing.allocator, request, "action-token"));
}

test "actions csrf guard rejects cross-origin and missing browser source" {
    const cross_origin =
        "POST /actions/request HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://evil.example\r\n" ++
        "Referer: http://127.0.0.1:12655/actions\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    const cross_origin_request = try parseHttpRequest(cross_origin);
    try std.testing.expect(!isSameOriginBrowserRequest(cross_origin_request));

    const missing_source =
        "POST /actions/request HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    const missing_source_request = try parseHttpRequest(missing_source);
    try std.testing.expect(!isSameOriginBrowserRequest(missing_source_request));
}

test "actions csrf token rejects same-origin post without token" {
    const raw =
        "POST /actions/request HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    const request = try parseHttpRequest(raw);
    try std.testing.expect(isSameOriginBrowserRequest(request));
    try std.testing.expect(!try zwf.csrf.verifyRequest(std.testing.allocator, request, "action-token"));
}

test "actions csrf guard rejects dns-rebound non-loopback host" {
    // A DNS-rebinding attack sends a matching Origin/Host pair but with a
    // non-loopback hostname; the loopback check must reject it.
    const dns_rebound =
        "POST /actions/request HTTP/1.1\r\n" ++
        "Host: evil.example:12655\r\n" ++
        "Origin: http://evil.example:12655\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    const dns_rebound_request = try parseHttpRequest(dns_rebound);
    try std.testing.expect(!isSameOriginBrowserRequest(dns_rebound_request));
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

test "label posts require matching csrf form token" {
    const body = "_csrf=local-token&action=create&new_label=bug";
    const raw =
        "POST /labels HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const request = try parseHttpRequest(raw);

    try std.testing.expect(try zwf.csrf.verifyRequest(std.testing.allocator, request, "local-token"));
    try std.testing.expect(!try zwf.csrf.verifyRequest(std.testing.allocator, request, "other-token"));
}

test "label csrf rejects form post without token" {
    const body = "action=create&new_label=bug";
    const raw =
        "POST /labels HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const request = try parseHttpRequest(raw);

    try std.testing.expect(!try zwf.csrf.verifyRequest(std.testing.allocator, request, "local-token"));
}

test "checklist posts require explicit csrf token" {
    const body = "body=updated";
    const header_raw =
        "POST /issues/abc/checklist HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "X-CSRF-Token: local-token\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const header_request = try parseHttpRequest(header_raw);
    try std.testing.expect(isValidCsrfRequest(header_request));
    try std.testing.expect(requestHasValidCsrfToken(std.testing.allocator, header_request, "local-token"));
    try std.testing.expect(!requestHasValidCsrfToken(std.testing.allocator, header_request, "other-token"));

    const missing_raw =
        "POST /issues/abc/checklist HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const missing_request = try parseHttpRequest(missing_raw);
    try std.testing.expect(isValidCsrfRequest(missing_request));
    try std.testing.expect(!requestHasValidCsrfToken(std.testing.allocator, missing_request, "local-token"));
}

test "issue comment posts require explicit csrf token" {
    const body = "_csrf=local-token&body=hello";
    const raw =
        "POST /issues/abc/comments HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const request = try parseHttpRequest(raw);
    try std.testing.expect(isValidCsrfRequest(request));
    try std.testing.expect(requestHasValidCsrfToken(std.testing.allocator, request, "local-token"));

    const missing_body = "body=hello";
    const missing_raw =
        "POST /issues/abc/comments HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{missing_body.len}) ++ "\r\n" ++
        "\r\n" ++
        missing_body;
    const missing_request = try parseHttpRequest(missing_raw);
    try std.testing.expect(isValidCsrfRequest(missing_request));
    try std.testing.expect(!requestHasValidCsrfToken(std.testing.allocator, missing_request, "local-token"));
}

test "pull conflict posts require trusted origin and explicit csrf token" {
    const body = "_csrf=local-token&expected_base_oid=base&expected_head_oid=head";
    const raw =
        "POST /pulls/1/conflicts HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const request = try parseHttpRequest(raw);
    try std.testing.expect(isValidCsrfRequest(request));
    try std.testing.expect(requestHasTrustedOrigin(request));
    try std.testing.expect(requestHasValidCsrfToken(std.testing.allocator, request, "local-token"));
    try std.testing.expect(!requestHasValidCsrfToken(std.testing.allocator, request, "other-token"));

    const missing_body = "expected_base_oid=base&expected_head_oid=head";
    const missing_raw =
        "POST /pulls/1/conflicts HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: http://127.0.0.1:12655\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{missing_body.len}) ++ "\r\n" ++
        "\r\n" ++
        missing_body;
    const missing_request = try parseHttpRequest(missing_raw);
    try std.testing.expect(isValidCsrfRequest(missing_request));
    try std.testing.expect(requestHasTrustedOrigin(missing_request));
    try std.testing.expect(!requestHasValidCsrfToken(std.testing.allocator, missing_request, "local-token"));

    const cross_origin_raw =
        "POST /pulls/1/conflicts HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:12655\r\n" ++
        "Origin: https://attacker.example\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++ "\r\n" ++
        "\r\n" ++
        body;
    const cross_origin_request = try parseHttpRequest(cross_origin_raw);
    try std.testing.expect(!isValidCsrfRequest(cross_origin_request));
    try std.testing.expect(!requestHasTrustedOrigin(cross_origin_request));
}

test "web vendor javascript assets use minified filenames" {
    for (vendor_assets) |asset| {
        if (std.mem.eql(u8, asset.content_type, "application/javascript")) {
            try expectVendorJavascriptMinifiedPath(asset.path);
        }
    }
    try expectVendorJavascriptMinifiedPath("/vendor/hljs/all-languages.min.js");
}

test "web devicon stylesheets and fonts are vendored" {
    try expectVendorAsset("/vendor/devicon/devicon.min.css", "text/css", false);
    try expectVendorAsset("/vendor/devicon/fonts/devicon.eot", "application/vnd.ms-fontobject", true);
    try expectVendorAsset("/vendor/devicon/fonts/devicon.ttf", "font/ttf", true);
    try expectVendorAsset("/vendor/devicon/fonts/devicon.woff", "font/woff", true);
    try expectVendorAsset("/vendor/devicon/fonts/devicon.svg", "image/svg+xml", true);
}

test "web PDF preview assets are routed" {
    try expectStaticRoute("/pdf.js", "application/javascript", false);
    try expectStaticRoute("/vendor/pdfjs/build/pdf.mjs", "application/javascript", false);
    try expectStaticRoute("/vendor/pdfjs/build/pdf.worker.mjs", "application/javascript", false);
}

test "web theme stylesheets are routed" {
    try expectStaticRoute("/themes/gitomi.css", "text/css", false);
    try expectStaticRoute("/themes/capucine.css", "text/css", false);
    try expectStaticRoute("/themes/modern.css", "text/css", false);
}

test "web split stylesheets are routed" {
    try expectStaticRoute("/style.css", "text/css", false);
    try expectStaticRoute("/styles/base.css", "text/css", false);
    try expectStaticRoute("/styles/issues-list.css", "text/css", false);
    try expectStaticRoute("/styles/pulls.css", "text/css", false);
    try expectStaticRoute("/styles/merge-editor.css", "text/css", false);
    try expectStaticRoute("/styles/issues-detail.css", "text/css", false);
    try expectStaticRoute("/styles/projects.css", "text/css", false);
    try expectStaticRoute("/styles/controls.css", "text/css", false);
    try expectStaticRoute("/styles/labels.css", "text/css", false);
    try expectStaticRoute("/styles/milestones.css", "text/css", false);
    try expectStaticRoute("/styles/settings.css", "text/css", false);
    try expectStaticRoute("/styles/refs-worktrees.css", "text/css", false);
    try expectStaticRoute("/styles/actions.css", "text/css", false);
    try expectStaticRoute("/styles/status-indexing.css", "text/css", false);
    try expectStaticRoute("/styles/code-browser.css", "text/css", false);
    try expectStaticRoute("/styles/commits.css", "text/css", false);
    try expectStaticRoute("/styles/diff.css", "text/css", false);
    try expectStaticRoute("/styles/markdown.css", "text/css", false);
    try expectStaticRoute("/styles/forms-overrides.css", "text/css", false);
    try expectStaticRoute("/styles/responsive.css", "text/css", false);
    try expectStaticRoute("/styles/shortcuts.css", "text/css", false);
}

fn expectStaticRoute(path: []const u8, content_type: []const u8, binary: bool) !void {
    for (routes) |route| {
        if (!std.mem.eql(u8, route.path, path)) continue;
        switch (route.action) {
            .static_asset => |asset| {
                try std.testing.expectEqualStrings(content_type, asset.content_type);
                try std.testing.expectEqual(binary, asset.binary);
                try std.testing.expect(asset.body.len > 0);
                return;
            },
            .handler => return error.ExpectedStaticRoute,
        }
    }
    return error.MissingStaticRoute;
}

fn expectVendorAsset(path: []const u8, content_type: []const u8, binary: bool) !void {
    for (vendor_assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) {
            try std.testing.expectEqualStrings(content_type, asset.content_type);
            try std.testing.expectEqual(binary, asset.binary);
            try std.testing.expect(asset.body.len > 0);
            return;
        }
    }
    return error.MissingVendorAsset;
}

fn expectVendorJavascriptMinifiedPath(path: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, path, "/vendor/"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".min.js") or std.mem.endsWith(u8, path, ".min.mjs"));
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
