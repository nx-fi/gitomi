const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Config = repo_mod.Config;
const Repo = repo_mod.Repo;
const countIndexedEvents = index.countIndexedEvents;
const countNonEmptyLines = util.countNonEmptyLines;
const ensureIndex = index.ensureIndex;
const gitChecked = git.gitChecked;
const loadConfig = repo_mod.loadConfig;

const WebStats = struct {
    inbox_refs: usize = 0,
    staged_refs: usize = 0,
    events: usize = 0,
    issues: usize = 0,
};

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
        \\  <script>
        \\    (function () {
        \\      try {
        \\        var stored = localStorage.getItem("gitomi.theme");
        \\        var system = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
        \\        document.documentElement.dataset.theme = stored === "light" || stored === "dark" ? stored : system;
        \\      } catch (_) {
        \\        document.documentElement.dataset.theme = "light";
        \\      }
        \\    }());
        \\  </script>
        \\  <title>
    );
    try appendHtml(buf, allocator, title);
    try buf.appendSlice(allocator,
        \\ - Gitomi</title>
        \\  <link rel="icon" href="/logo.svg" type="image/svg+xml">
        \\  <link rel="stylesheet" href="/style.css">
        \\</head>
        \\<body>
        \\<header class="topbar">
        \\  <a class="brand" href="/"><img class="brand-logo" src="/logo.svg" alt="" width="32" height="32"><span>
    );
    try appendHtml(buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator,
        \\</span></a>
        \\  <nav>
    );
    try appendNavLink(buf, allocator, active, "code", "/", "Code", null);
    try appendNavLink(buf, allocator, active, "commits", "/commits", "Commits", null);
    try appendNavLink(buf, allocator, active, "issues", "/issues", "Issues", stats.issues);
    try appendNavLink(buf, allocator, active, "events", "/events", "Events", stats.events);
    try appendNavLink(buf, allocator, active, "refs", "/refs", "Refs", stats.inbox_refs + stats.staged_refs);
    try appendNavLink(buf, allocator, active, "overview", "/overview", "Overview", null);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <button class="theme-toggle" type="button" data-theme-toggle aria-pressed="false" aria-label="Toggle dark mode" title="Toggle dark mode">
        \\    <span class="theme-toggle-track" aria-hidden="true"><span class="theme-toggle-thumb"></span></span>
        \\    <span class="theme-toggle-label" data-theme-label>Light</span>
        \\  </button>
        \\</header>
        \\<main>
    );

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
        \\<script src="/theme.js"></script>
        \\<script src="/tree.js"></script>
        \\<script src="/highlight.js"></script>
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
    count: ?usize,
) !void {
    try buf.appendSlice(allocator, "<a");
    if (std.mem.eql(u8, active, id)) try buf.appendSlice(allocator, " class=\"active\"");
    try buf.appendSlice(allocator, " href=\"");
    try appendHtml(buf, allocator, href);
    try buf.appendSlice(allocator, "\">");
    try appendHtml(buf, allocator, label);
    if (count) |value| {
        if (value > 0) {
            try buf.appendSlice(allocator, "<span class=\"nav-badge\">");
            try appendFmt(buf, allocator, "{d}", .{value});
            try buf.appendSlice(allocator, "</span>");
        }
    }
    try buf.appendSlice(allocator, "</a>");
}

pub fn appendEmptyState(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, detail: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"empty\"><strong>");
    try appendHtml(buf, allocator, title);
    try buf.appendSlice(allocator, "</strong><p>");
    try appendHtml(buf, allocator, detail);
    try buf.appendSlice(allocator, "</p></div>");
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

fn loadWebStats(allocator: Allocator, repo: Repo) !WebStats {
    try ensureIndex(allocator, repo);
    const inbox_refs = try countRefsWithPrefix(allocator, "refs/gitomi/inbox");
    const staged_refs = try countRefsWithPrefix(allocator, "refs/gitomi/staging");
    const events = try countIndexedEvents(allocator, repo);
    const issues = try index.countIssueOpenedEvents(allocator, repo);
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
