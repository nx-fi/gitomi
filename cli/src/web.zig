const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const issue = @import("issue.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const Config = repo_mod.Config;
const out = io.out;
const eprint = io.eprint;
const discoverRepo = repo_mod.discoverRepo;
const loadConfig = repo_mod.loadConfig;
const ensureIndex = index.ensureIndex;
const indexedEventFromStmt = index.indexedEventFromStmt;
const freeIndexedEvent = index.freeIndexedEvent;
const index_event_columns = index.index_event_columns;
const IndexedEvent = index.IndexedEvent;
const SqliteDb = index.SqliteDb;
const sqlite = index.sqlite;
const createIssueOpenedEvent = issue.createIssueOpenedEvent;
const gitChecked = git.gitChecked;
const runCommand = git.runCommand;
const countNonEmptyLines = util.countNonEmptyLines;
const splitCommaFields = util.splitCommaFields;
const countIndexedEvents = index.countIndexedEvents;

const max_http_request = 64 * 1024;
pub const default_host = "127.0.0.1";
pub const default_port = 8080;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    once: bool = false,
};

pub const HttpRequest = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    body: []const u8,
};

const WebStats = struct {
    inbox_refs: usize = 0,
    staged_refs: usize = 0,
    events: usize = 0,
    issues: usize = 0,
};

pub fn serve(allocator: Allocator, repo: Repo, options: Options) !void {
    const bind_host: []const u8 = if (std.mem.eql(u8, options.host, "localhost")) default_host else options.host;
    const address = std.net.Address.parseIp(bind_host, options.port) catch {
        try eprint("gt web: invalid host or port {s}:{d}\n", .{ options.host, options.port });
        return CliError.UserError;
    };

    var server = try address.listen(.{ .reuse_address = true, .kernel_backlog = 32 });
    defer server.deinit();

    const actual_port = server.listen_address.getPort();
    try out("Gitomi web listening at http://{s}:{d}/\n", .{ options.host, actual_port });
    if (!options.once) {
        try out("Press Ctrl-C to stop.\n", .{});
    }

    while (true) {
        const connection = try server.accept();
        handleWebConnection(allocator, repo, connection.stream) catch |err| {
            try eprint("gt web: request failed: {s}\n", .{@errorName(err)});
        };
        connection.stream.close();

        if (options.once) break;
    }
}

pub fn handleWebConnection(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    const raw = readHttpRequest(allocator, stream) catch {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };
    defer allocator.free(raw);

    const request = parseHttpRequest(raw) catch {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Bad request\n");
        return;
    };

    if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/style.css")) {
        try sendResponse(allocator, stream, 200, "OK", "text/css", web_css, null);
    } else if (std.mem.eql(u8, request.method, "GET") and (std.mem.eql(u8, request.path, "/") or std.mem.eql(u8, request.path, "/overview"))) {
        const body = try renderHomePage(allocator, repo);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/issues")) {
        const body = try renderIssuesPage(allocator, repo);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/events")) {
        const body = try renderEventsPage(allocator, repo);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/refs")) {
        const body = try renderRefsPage(allocator, repo);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/new-issue")) {
        const body = try renderIssueForm(allocator, repo, null, "", "", "", "");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 200, "OK", "text/html", body, null);
    } else if (std.mem.eql(u8, request.method, "POST") and std.mem.eql(u8, request.path, "/issues")) {
        try handleIssuePost(allocator, repo, stream, request.body);
    } else if (std.mem.eql(u8, request.method, "GET") and std.mem.eql(u8, request.path, "/favicon.ico")) {
        try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
    } else {
        const body = try renderNotFoundPage(allocator, repo);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 404, "Not Found", "text/html", body, null);
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

pub fn handleIssuePost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const title_owned = (try formValueOwned(allocator, form_body, "title")) orelse try allocator.dupe(u8, "");
    defer allocator.free(title_owned);
    const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
    defer allocator.free(body_owned);
    const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
    defer allocator.free(labels_owned);
    const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
    defer allocator.free(assignees_owned);

    const title = std.mem.trim(u8, title_owned, " \t\r\n");
    if (title.len == 0) {
        const body = try renderIssueForm(allocator, repo, "Title is required.", title_owned, body_owned, labels_owned, assignees_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var labels = try splitCommaFields(allocator, labels_owned);
    defer labels.deinit(allocator);
    var assignees = try splitCommaFields(allocator, assignees_owned);
    defer assignees.deinit(allocator);

    createIssueOpenedEvent(allocator, title, body_owned, labels.items, assignees.items) catch {
        const body = try renderIssueForm(
            allocator,
            repo,
            "Could not create the issue. Check that Gitomi is initialized and Git commit signing is configured.",
            title_owned,
            body_owned,
            labels_owned,
            assignees_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/issues");
}

pub fn renderHomePage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Overview", "overview");

    const branch = try currentBranch(allocator);
    defer allocator.free(branch);
    const changes = workingTreeChangeCount(allocator) catch 0;

    try buf.appendSlice(allocator,
        \\<section class="panel hero">
        \\  <div>
        \\    <p class="eyebrow">Local repository</p>
        \\    <h1>
    );
    try appendHtml(&buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator, "</h1><p class=\"muted\">");
    try appendHtml(&buf, allocator, repo.root);
    try buf.appendSlice(allocator,
        \\</p>
        \\  </div>
        \\  <div class="repo-visual" aria-hidden="true">
        \\    <span></span><span></span><span></span><span></span><span></span><span></span>
        \\  </div>
        \\</section>
        \\<section class="grid two">
        \\  <div class="panel">
        \\    <h2>Repository</h2>
        \\    <dl class="facts">
        \\      <div><dt>Branch</dt><dd>
    );
    try appendHtml(&buf, allocator, branch);
    try buf.appendSlice(allocator, "</dd></div><div><dt>Working tree</dt><dd>");
    try appendFmt(&buf, allocator, "{d} change{s}", .{ changes, if (changes == 1) "" else "s" });
    try buf.appendSlice(allocator,
        \\</dd></div><div><dt>Git directory</dt><dd>
    );
    try appendHtml(&buf, allocator, repo.git_dir);
    try buf.appendSlice(allocator,
        \\</dd></div>
        \\    </dl>
        \\  </div>
        \\  <div class="panel">
        \\    <div class="section-head">
        \\      <h2>Recent Activity</h2>
        \\      <a class="button secondary" href="/events">View all</a>
        \\    </div>
    );
    try appendEventList(&buf, allocator, repo, 6);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssuesPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Issues", "issues");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Issues</p>
        \\      <h1>Local Issue Tracker</h1>
        \\    </div>
        \\    <a class="button primary" href="/new-issue">New issue</a>
        \\  </div>
        \\  <div class="list">
    );

    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events WHERE event_type = 'issue.opened' ORDER BY ordinal");
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        const title = issueTitleFromSubject(event.subject);

        try buf.appendSlice(allocator, "<article class=\"issue-row\"><div class=\"issue-main\"><div class=\"issue-title\"><span class=\"state open\">Open</span><a href=\"/events#");
        try appendHtml(&buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(&buf, allocator, title);
        try buf.appendSlice(allocator, "</a></div><p class=\"muted\">#");
        try appendHtml(&buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        try buf.appendSlice(allocator, " opened by ");
        try appendHtml(&buf, allocator, event.actor_principal);
        try buf.appendSlice(allocator, " at ");
        try appendHtml(&buf, allocator, event.occurred_at);
        try buf.appendSlice(allocator, "</p></div></article>");
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyState(&buf, allocator, "No issues yet.", "Create the first local issue from this browser UI or with gt issue open.");
    }

    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderEventsPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Events", "events");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Control plane</p>
        \\      <h1>Event Log</h1>
        \\    </div>
        \\  </div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Event</th><th>Object</th><th>Actor</th><th>Commit</th><th>Ref</th></tr></thead>
        \\      <tbody>
    );

    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal");
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try appendEventTableRow(&buf, allocator, event);
        shown += 1;
    }

    if (shown == 0) {
        try buf.appendSlice(allocator, "<tr><td colspan=\"5\" class=\"empty-cell\">No Gitomi events found.</td></tr>");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderRefsPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Refs", "refs");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Git references</p>
        \\      <h1>Branches, Tags, and Gitomi Refs</h1>
        \\    </div>
        \\  </div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Ref</th><th>Object</th><th>Updated</th></tr></thead>
        \\      <tbody>
    );

    const refs = gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname:short)%09%(committerdate:relative)",
        "refs/heads",
        "refs/tags",
        "refs/gitomi",
    }) catch try allocator.dupe(u8, "");
    defer allocator.free(refs);

    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ref = cols.next() orelse "";
        const oid = cols.next() orelse "";
        const updated = cols.next() orelse "";
        try buf.appendSlice(allocator, "<tr><td><code>");
        try appendHtml(&buf, allocator, ref);
        try buf.appendSlice(allocator, "</code></td><td><code>");
        try appendHtml(&buf, allocator, oid);
        try buf.appendSlice(allocator, "</code></td><td>");
        try appendHtml(&buf, allocator, updated);
        try buf.appendSlice(allocator, "</td></tr>");
        shown += 1;
    }

    if (shown == 0) {
        try buf.appendSlice(allocator, "<tr><td colspan=\"3\" class=\"empty-cell\">No refs found.</td></tr>");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderIssueForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    title_value: []const u8,
    body_value: []const u8,
    labels_value: []const u8,
    assignees_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Issue", "issues");
    try buf.appendSlice(allocator,
        \\<section class="panel form-panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Issues</p>
        \\      <h1>New Issue</h1>
        \\    </div>
        \\  </div>
    );
    if (error_message) |message| {
        try buf.appendSlice(allocator, "<div class=\"flash error\">");
        try appendHtml(&buf, allocator, message);
        try buf.appendSlice(allocator, "</div>");
    }
    try buf.appendSlice(allocator,
        \\  <form method="post" action="/issues" class="issue-form">
        \\    <label>Title<input name="title" value="
    );
    try appendHtml(&buf, allocator, title_value);
    try buf.appendSlice(allocator,
        \\" autofocus required></label>
        \\    <label>Body<textarea name="body" rows="8">
    );
    try appendHtml(&buf, allocator, body_value);
    try buf.appendSlice(allocator,
        \\</textarea></label>
        \\    <div class="grid two">
        \\      <label>Labels<input name="labels" value="
    );
    try appendHtml(&buf, allocator, labels_value);
    try buf.appendSlice(allocator,
        \\" placeholder="bug, docs"></label>
        \\      <label>Assignees<input name="assignees" value="
    );
    try appendHtml(&buf, allocator, assignees_value);
    try buf.appendSlice(allocator,
        \\" placeholder="alice, bob"></label>
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/issues">Cancel</a>
        \\      <button class="button primary" type="submit">Create issue</button>
        \\    </div>
        \\  </form>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderNotFoundPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendShellStart(&buf, allocator, repo, "Not Found", "");
    try appendEmptyState(&buf, allocator, "Page not found.", "The local Gitomi web UI does not have a route for that path.");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn appendShellStart(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
) !void {
    const stats = try loadWebStats(allocator, repo);
    var cfg_opt: ?Config = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound, CliError.ConfigInvalid => null,
        else => return err,
    };
    defer if (cfg_opt) |*cfg| cfg.deinit();

    try buf.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>
    );
    try appendHtml(buf, allocator, title);
    try buf.appendSlice(allocator,
        \\ - Gitomi</title>
        \\  <link rel="stylesheet" href="/style.css">
        \\</head>
        \\<body>
        \\<header class="topbar">
        \\  <a class="brand" href="/"><span class="brand-mark">gt</span><span>
    );
    try appendHtml(buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator,
        \\</span></a>
        \\  <nav>
    );
    try appendNavLink(buf, allocator, active, "overview", "/", "Overview");
    try appendNavLink(buf, allocator, active, "issues", "/issues", "Issues");
    try appendNavLink(buf, allocator, active, "events", "/events", "Events");
    try appendNavLink(buf, allocator, active, "refs", "/refs", "Refs");
    try buf.appendSlice(allocator,
        \\  </nav>
        \\</header>
        \\<main>
        \\<section class="stats">
    );
    try appendStat(buf, allocator, "Issues", stats.issues);
    try appendStat(buf, allocator, "Events", stats.events);
    try appendStat(buf, allocator, "Inbox refs", stats.inbox_refs);
    try appendStat(buf, allocator, "Staged refs", stats.staged_refs);
    try buf.appendSlice(allocator, "</section>");

    if (cfg_opt) |cfg| {
        try buf.appendSlice(allocator, "<section class=\"init-banner ready\"><strong>");
        try appendHtml(buf, allocator, cfg.principal);
        try buf.appendSlice(allocator, "/");
        try appendHtml(buf, allocator, cfg.device);
        try buf.appendSlice(allocator, "</strong><span>");
        try appendHtml(buf, allocator, cfg.repo_id);
        try buf.appendSlice(allocator, "</span></section>");
    } else {
        try buf.appendSlice(allocator,
            \\<section class="init-banner">
            \\  <strong>Gitomi is not initialized.</strong>
            \\  <span>Run <code>gt init</code> before creating signed issues from the web UI.</span>
            \\</section>
        );
    }
}

pub fn appendShellEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\</main>
        \\</body>
        \\</html>
    );
}

pub fn appendNavLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    active: []const u8,
    id: []const u8,
    href: []const u8,
    label: []const u8,
) !void {
    try buf.appendSlice(allocator, "<a");
    if (std.mem.eql(u8, active, id)) try buf.appendSlice(allocator, " class=\"active\"");
    try buf.appendSlice(allocator, " href=\"");
    try appendHtml(buf, allocator, href);
    try buf.appendSlice(allocator, "\">");
    try appendHtml(buf, allocator, label);
    try buf.appendSlice(allocator, "</a>");
}

pub fn appendStat(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, value: usize) !void {
    try buf.appendSlice(allocator, "<div><strong>");
    try appendFmt(buf, allocator, "{d}", .{value});
    try buf.appendSlice(allocator, "</strong><span>");
    try appendHtml(buf, allocator, label);
    try buf.appendSlice(allocator, "</span></div>");
}

pub fn appendEventList(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, limit: usize) !void {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal LIMIT ?");
    defer stmt.deinit();
    if (limit > std.math.maxInt(i64)) return error.ValueTooLarge;
    try stmt.bindInt64(1, @intCast(limit));

    try buf.appendSlice(allocator, "<div class=\"activity-list\">");
    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try buf.appendSlice(allocator, "<article><span class=\"dot\"></span><div><strong>");
        try appendHtml(buf, allocator, if (event.valid_json) event.event_type else "invalid-event");
        try buf.appendSlice(allocator, "</strong><p>");
        try appendHtml(buf, allocator, event.subject);
        try buf.appendSlice(allocator, "</p><small>");
        try appendHtml(buf, allocator, event.actor_principal);
        if (event.object_id.len != 0) {
            try buf.appendSlice(allocator, " / #");
            try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        }
        try buf.appendSlice(allocator, "</small></div></article>");
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(buf, allocator, "No activity yet.", "Gitomi events will appear here after issues, pull requests, or workflow runs are recorded.");
    }
    try buf.appendSlice(allocator, "</div>");
}

pub fn appendEventTableRow(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    try buf.appendSlice(allocator, "<tr id=\"");
    try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
    try buf.appendSlice(allocator, "\"><td><span class=\"event-type\">");
    try appendHtml(buf, allocator, if (event.valid_json) event.event_type else "invalid-event");
    try buf.appendSlice(allocator, "</span></td><td>");
    try appendHtml(buf, allocator, event.object_kind);
    if (event.object_id.len != 0) {
        try buf.appendSlice(allocator, " <code>#");
        try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        try buf.appendSlice(allocator, "</code>");
    }
    try buf.appendSlice(allocator, "</td><td>");
    try appendHtml(buf, allocator, event.actor_principal);
    if (event.actor_device.len != 0) {
        try buf.appendSlice(allocator, "/");
        try appendHtml(buf, allocator, event.actor_device);
    }
    try buf.appendSlice(allocator, "</td><td><code>");
    try appendHtml(buf, allocator, event.commit[0..@min(event.commit.len, 12)]);
    try buf.appendSlice(allocator, "</code></td><td><code>");
    try appendHtml(buf, allocator, event.ref);
    try buf.appendSlice(allocator, "</code></td></tr>");
}

pub fn appendEmptyState(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, detail: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"empty\"><strong>");
    try appendHtml(buf, allocator, title);
    try buf.appendSlice(allocator, "</strong><p>");
    try appendHtml(buf, allocator, detail);
    try buf.appendSlice(allocator, "</p></div>");
}

fn loadWebStats(allocator: Allocator, repo: Repo) !WebStats {
    try ensureIndex(allocator, repo);
    const inbox_refs = try countRefsWithPrefix(allocator, "refs/gitomi/inbox");
    const staged_refs = try countRefsWithPrefix(allocator, "refs/gitomi/staging");
    const events = try countIndexedEvents(allocator, repo);
    const issues = try countIssueOpenedEvents(allocator, repo);
    return .{
        .inbox_refs = inbox_refs,
        .staged_refs = staged_refs,
        .events = events,
        .issues = issues,
    };
}

fn countRefsWithPrefix(allocator: Allocator, prefix: []const u8) !usize {
    const refs = try gitChecked(allocator, &.{
        "for-each-ref",
        "--format=%(refname)",
        prefix,
    });
    defer allocator.free(refs);
    return countNonEmptyLines(refs);
}

fn countIssueOpenedEvents(allocator: Allocator, repo: Repo) !usize {
    return index.countIssueOpenedEvents(allocator, repo);
}

fn currentBranch(allocator: Allocator) ![]u8 {
    return git.currentBranch(allocator);
}

fn workingTreeChangeCount(allocator: Allocator) !usize {
    return git.workingTreeChangeCount(allocator);
}

pub fn issueTitleFromSubject(subject: []const u8) []const u8 {
    const marker = " #";
    const marker_index = std.mem.indexOf(u8, subject, marker) orelse return subject;
    const after_marker = subject[marker_index + marker.len ..];
    const title_index = std.mem.indexOfScalar(u8, after_marker, ' ') orelse return subject;
    const title = std.mem.trim(u8, after_marker[title_index + 1 ..], " \t\r\n");
    return if (title.len == 0) subject else title;
}

pub fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidFormEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidFormEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidFormEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, default_host) or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "localhost");
}

pub fn sendRedirect(allocator: Allocator, stream: std.net.Stream, location: []const u8) !void {
    const extra = try std.fmt.allocPrint(allocator, "Location: {s}\r\n", .{location});
    defer allocator.free(extra);
    try sendResponse(allocator, stream, 303, "See Other", "text/plain", "See Other\n", extra);
}

pub fn sendPlainResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    body: []const u8,
) !void {
    try sendResponse(allocator, stream, status, reason, "text/plain", body, null);
}

pub fn sendResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: ?[]const u8,
) !void {
    const headers = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n{s}\r\n",
        .{ status, reason, content_type, body.len, extra_headers orelse "" },
    );
    defer allocator.free(headers);
    try stream.writeAll(headers);
    try stream.writeAll(body);
}

pub fn appendHtml(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

pub fn appendFmt(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}

const web_css =
    \\:root {
    \\  color-scheme: light;
    \\  --bg: #f6f8fa;
    \\  --panel: #ffffff;
    \\  --border: #d0d7de;
    \\  --border-strong: #afb8c1;
    \\  --text: #1f2328;
    \\  --muted: #59636e;
    \\  --blue: #0969da;
    \\  --green: #1a7f37;
    \\  --green-bg: #dafbe1;
    \\  --red: #cf222e;
    \\  --red-bg: #ffebe9;
    \\  --shadow: 0 1px 2px rgba(31, 35, 40, 0.07);
    \\}
    \\* { box-sizing: border-box; }
    \\body {
    \\  margin: 0;
    \\  background: var(--bg);
    \\  color: var(--text);
    \\  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\}
    \\a { color: var(--blue); text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\code {
    \\  font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\  background: #f6f8fa;
    \\  border: 1px solid var(--border);
    \\  border-radius: 6px;
    \\  padding: 2px 5px;
    \\}
    \\.topbar {
    \\  position: sticky;
    \\  top: 0;
    \\  z-index: 1;
    \\  display: flex;
    \\  align-items: center;
    \\  gap: 24px;
    \\  min-height: 58px;
    \\  padding: 0 24px;
    \\  background: #24292f;
    \\  color: #ffffff;
    \\  border-bottom: 1px solid #1f2328;
    \\}
    \\.brand {
    \\  display: inline-flex;
    \\  align-items: center;
    \\  gap: 10px;
    \\  color: #ffffff;
    \\  font-weight: 700;
    \\}
    \\.brand:hover { text-decoration: none; }
    \\.brand-mark {
    \\  display: inline-grid;
    \\  place-items: center;
    \\  width: 32px;
    \\  height: 32px;
    \\  border: 1px solid rgba(255,255,255,0.28);
    \\  border-radius: 7px;
    \\  background: #ffffff;
    \\  color: #24292f;
    \\  font: 700 13px/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\}
    \\.topbar nav {
    \\  display: flex;
    \\  align-items: stretch;
    \\  gap: 4px;
    \\  align-self: stretch;
    \\}
    \\.topbar nav a {
    \\  display: inline-flex;
    \\  align-items: center;
    \\  padding: 0 12px;
    \\  color: #d0d7de;
    \\  border-bottom: 2px solid transparent;
    \\}
    \\.topbar nav a.active {
    \\  color: #ffffff;
    \\  border-bottom-color: #f78166;
    \\}
    \\main {
    \\  width: min(1180px, calc(100vw - 32px));
    \\  margin: 20px auto 48px;
    \\}
    \\.stats {
    \\  display: grid;
    \\  grid-template-columns: repeat(4, minmax(0, 1fr));
    \\  gap: 12px;
    \\  margin-bottom: 14px;
    \\}
    \\.stats div {
    \\  min-width: 0;
    \\  padding: 14px 16px;
    \\  background: var(--panel);
    \\  border: 1px solid var(--border);
    \\  border-radius: 8px;
    \\  box-shadow: var(--shadow);
    \\}
    \\.stats strong {
    \\  display: block;
    \\  font-size: 24px;
    \\  line-height: 1.1;
    \\}
    \\.stats span {
    \\  display: block;
    \\  margin-top: 4px;
    \\  color: var(--muted);
    \\}
    \\.init-banner {
    \\  display: flex;
    \\  justify-content: space-between;
    \\  gap: 12px;
    \\  margin-bottom: 16px;
    \\  padding: 12px 14px;
    \\  background: #fff8c5;
    \\  border: 1px solid #d4a72c;
    \\  border-radius: 8px;
    \\}
    \\.init-banner.ready {
    \\  background: #ddf4ff;
    \\  border-color: #54aeef;
    \\}
    \\.init-banner span {
    \\  color: var(--muted);
    \\  overflow-wrap: anywhere;
    \\}
    \\.panel {
    \\  background: var(--panel);
    \\  border: 1px solid var(--border);
    \\  border-radius: 8px;
    \\  box-shadow: var(--shadow);
    \\}
    \\.hero {
    \\  display: grid;
    \\  grid-template-columns: minmax(0, 1fr) 260px;
    \\  gap: 24px;
    \\  align-items: center;
    \\  min-height: 176px;
    \\  margin-bottom: 16px;
    \\  padding: 24px;
    \\}
    \\.hero h1,
    \\.section-head h1,
    \\.panel h2 {
    \\  margin: 0;
    \\  line-height: 1.2;
    \\}
    \\.hero h1 { font-size: 28px; }
    \\.panel h2 { font-size: 18px; }
    \\.eyebrow {
    \\  margin: 0 0 5px;
    \\  color: var(--muted);
    \\  font-size: 12px;
    \\  font-weight: 700;
    \\  text-transform: uppercase;
    \\}
    \\.muted { color: var(--muted); }
    \\.repo-visual {
    \\  display: grid;
    \\  grid-template-columns: repeat(6, 1fr);
    \\  gap: 7px;
    \\  align-items: end;
    \\  height: 92px;
    \\  padding: 12px;
    \\  border: 1px solid var(--border);
    \\  border-radius: 8px;
    \\  background: #f6f8fa;
    \\}
    \\.repo-visual span {
    \\  display: block;
    \\  border-radius: 5px 5px 2px 2px;
    \\  background: #2da44e;
    \\}
    \\.repo-visual span:nth-child(1) { height: 32%; background: #54aeef; }
    \\.repo-visual span:nth-child(2) { height: 62%; }
    \\.repo-visual span:nth-child(3) { height: 46%; background: #a475f9; }
    \\.repo-visual span:nth-child(4) { height: 82%; }
    \\.repo-visual span:nth-child(5) { height: 58%; background: #bf8700; }
    \\.repo-visual span:nth-child(6) { height: 74%; }
    \\.grid {
    \\  display: grid;
    \\  gap: 16px;
    \\}
    \\.grid.two {
    \\  grid-template-columns: repeat(2, minmax(0, 1fr));
    \\}
    \\.section-head {
    \\  display: flex;
    \\  align-items: center;
    \\  justify-content: space-between;
    \\  gap: 16px;
    \\  padding: 16px;
    \\  border-bottom: 1px solid var(--border);
    \\}
    \\.facts {
    \\  margin: 0;
    \\  padding: 16px;
    \\}
    \\.facts div {
    \\  display: grid;
    \\  grid-template-columns: 128px minmax(0, 1fr);
    \\  gap: 14px;
    \\  padding: 10px 0;
    \\  border-bottom: 1px solid #f0f2f4;
    \\}
    \\.facts div:last-child { border-bottom: 0; }
    \\.facts dt { color: var(--muted); }
    \\.facts dd {
    \\  margin: 0;
    \\  min-width: 0;
    \\  overflow-wrap: anywhere;
    \\}
    \\.activity-list article,
    \\.issue-row {
    \\  display: flex;
    \\  gap: 12px;
    \\  padding: 14px 16px;
    \\  border-top: 1px solid var(--border);
    \\}
    \\.activity-list article:first-child,
    \\.issue-row:first-child {
    \\  border-top: 0;
    \\}
    \\.dot {
    \\  width: 10px;
    \\  height: 10px;
    \\  margin-top: 6px;
    \\  border-radius: 50%;
    \\  background: var(--green);
    \\  flex: 0 0 auto;
    \\}
    \\.activity-list strong,
    \\.issue-title {
    \\  font-weight: 700;
    \\}
    \\.activity-list p,
    \\.issue-row p {
    \\  margin: 2px 0;
    \\}
    \\.activity-list small {
    \\  color: var(--muted);
    \\}
    \\.list { min-height: 92px; }
    \\.issue-main { min-width: 0; }
    \\.issue-title {
    \\  display: flex;
    \\  align-items: center;
    \\  gap: 9px;
    \\  min-width: 0;
    \\}
    \\.state {
    \\  display: inline-flex;
    \\  align-items: center;
    \\  height: 22px;
    \\  padding: 0 8px;
    \\  border-radius: 999px;
    \\  font-size: 12px;
    \\  font-weight: 700;
    \\}
    \\.state.open {
    \\  color: var(--green);
    \\  background: var(--green-bg);
    \\}
    \\.button {
    \\  display: inline-flex;
    \\  align-items: center;
    \\  justify-content: center;
    \\  min-height: 34px;
    \\  padding: 0 12px;
    \\  border: 1px solid var(--border-strong);
    \\  border-radius: 6px;
    \\  font-weight: 700;
    \\  cursor: pointer;
    \\}
    \\.button:hover { text-decoration: none; }
    \\.button.primary {
    \\  color: #ffffff;
    \\  background: #1f883d;
    \\  border-color: #1f883d;
    \\}
    \\.button.secondary {
    \\  color: var(--text);
    \\  background: #f6f8fa;
    \\}
    \\.table-wrap {
    \\  overflow-x: auto;
    \\}
    \\table {
    \\  width: 100%;
    \\  border-collapse: collapse;
    \\}
    \\th, td {
    \\  padding: 10px 12px;
    \\  border-top: 1px solid var(--border);
    \\  text-align: left;
    \\  vertical-align: top;
    \\}
    \\thead th {
    \\  color: var(--muted);
    \\  background: #f6f8fa;
    \\  border-top: 0;
    \\  font-size: 12px;
    \\}
    \\.event-type {
    \\  font-weight: 700;
    \\}
    \\.empty,
    \\.empty-cell {
    \\  padding: 28px 16px;
    \\  color: var(--muted);
    \\  text-align: center;
    \\}
    \\.empty strong {
    \\  display: block;
    \\  color: var(--text);
    \\  font-size: 16px;
    \\}
    \\.empty p { margin: 6px 0 0; }
    \\.form-panel { max-width: 820px; }
    \\.issue-form {
    \\  display: grid;
    \\  gap: 14px;
    \\  padding: 16px;
    \\}
    \\label {
    \\  display: grid;
    \\  gap: 6px;
    \\  color: var(--text);
    \\  font-weight: 700;
    \\}
    \\input,
    \\textarea {
    \\  width: 100%;
    \\  min-width: 0;
    \\  border: 1px solid var(--border-strong);
    \\  border-radius: 6px;
    \\  padding: 9px 10px;
    \\  color: var(--text);
    \\  background: #ffffff;
    \\  font: inherit;
    \\}
    \\textarea {
    \\  resize: vertical;
    \\  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\}
    \\.form-actions {
    \\  display: flex;
    \\  justify-content: flex-end;
    \\  gap: 8px;
    \\}
    \\.flash {
    \\  margin: 16px 16px 0;
    \\  padding: 10px 12px;
    \\  border-radius: 6px;
    \\  font-weight: 700;
    \\}
    \\.flash.error {
    \\  color: var(--red);
    \\  background: var(--red-bg);
    \\  border: 1px solid #ff8182;
    \\}
    \\@media (max-width: 760px) {
    \\  .topbar {
    \\    position: static;
    \\    flex-direction: column;
    \\    align-items: stretch;
    \\    gap: 10px;
    \\    padding: 12px 16px 0;
    \\  }
    \\  .topbar nav {
    \\    overflow-x: auto;
    \\    min-height: 42px;
    \\  }
    \\  main {
    \\    width: min(100vw - 20px, 1180px);
    \\    margin-top: 12px;
    \\  }
    \\  .stats,
    \\  .grid.two,
    \\  .hero {
    \\    grid-template-columns: 1fr;
    \\  }
    \\  .repo-visual { display: none; }
    \\  .init-banner,
    \\  .section-head {
    \\    align-items: flex-start;
    \\    flex-direction: column;
    \\  }
    \\  .facts div {
    \\    grid-template-columns: 1fr;
    \\    gap: 3px;
    \\  }
    \\}
;

test "web form decoding handles spaces and escapes" {
    const decoded = try percentDecodeForm(std.testing.allocator, "hello+local%2Fworld%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello local/world!", decoded);

    const value = (try formValueOwned(std.testing.allocator, "title=First+issue&labels=bug%2Cdocs", "labels")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bug,docs", value);
}

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

test "web issue titles come from issue opened subjects" {
    try std.testing.expectEqualStrings("Indexed issue", issueTitleFromSubject("issue.opened #018f000 Indexed issue"));
    try std.testing.expectEqualStrings("custom subject", issueTitleFromSubject("custom subject"));
}
