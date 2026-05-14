const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Config = repo_mod.Config;
const Repo = repo_mod.Repo;
const countIndexedEvents = index.countIndexedEvents;
const countNonEmptyLines = util.countNonEmptyLines;
const gitChecked = git.gitChecked;
const appendJsonString = json_writer.appendJsonString;
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
    try appendNavLink(buf, allocator, active, "projects", "/projects", "Projects", null);
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
        try appendTemplate(buf, allocator,
            \\<section class="init-banner ready"><strong>{principal}/{device}</strong><span>{repo_id}</span></section>
        , .{
            .principal = cfg.principal,
            .device = cfg.device,
            .repo_id = cfg.repo_id,
        });
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
        \\<script src="/markdown.js"></script>
        \\<script src="/highlight.js"></script>
        \\<script src="/diff.js"></script>
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
    try appendTemplate(buf, allocator,
        \\<a{active_class} href="{href}">{label}
    , .{
        .active_class = trustedHtml(if (std.mem.eql(u8, active, id)) " class=\"active\"" else ""),
        .href = href,
        .label = label,
    });
    if (count) |value| {
        if (value > 0) {
            try appendTemplate(buf, allocator,
                \\<span class="nav-badge">{value}</span>
            , .{ .value = value });
        }
    }
    try buf.appendSlice(allocator, "</a>");
}

pub fn appendEmptyState(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, detail: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="empty"><strong>{title}</strong><p>{detail}</p></div>
    , .{
        .title = title,
        .detail = detail,
    });
}

pub fn renderIndexingPageIfStale(
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
    return_target: []const u8,
) !?[]u8 {
    if (index.isIndexFresh(allocator, repo) catch false) return null;
    return try renderIndexingPage(allocator, repo, title, active, return_target);
}

fn renderIndexingPage(
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
    return_target: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, title, active);
    try buf.appendSlice(allocator,
        \\<section class="panel indexing-panel">
        \\  <div class="indexing-cue">
        \\    <span class="index-spinner" aria-hidden="true"></span>
        \\    <div>
        \\      <p class="eyebrow">Index refresh</p>
        \\      <h1>Updating Gitomi index</h1>
        \\      <p class="muted">Reading Gitomi events and refreshing local projections. This page will continue automatically.</p>
        \\    </div>
        \\  </div>
        \\  <div class="index-progress" aria-hidden="true"><span></span></div>
        \\</section>
        \\<script>
        \\(function () {
        \\  var next =
    );
    try appendJsonString(&buf, allocator, return_target);
    try buf.appendSlice(allocator,
        \\;
        \\  fetch("/index/rebuild", { cache: "no-store" }).then(function () {
        \\    window.location.replace(next);
        \\  }).catch(function () {
        \\    setTimeout(function () { window.location.reload(); }, 2500);
        \\  });
        \\}());
        \\</script>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
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

pub const TrustedHtml = struct {
    value: []const u8,
};

pub fn trustedHtml(value: []const u8) TrustedHtml {
    return .{ .value = value };
}

pub fn appendTemplate(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    comptime template: []const u8,
    values: anytype,
) !void {
    comptime var cursor: usize = 0;
    inline while (cursor < template.len) {
        comptime var token = cursor;
        inline while (token < template.len and template[token] != '{' and template[token] != '}') : (token += 1) {}

        if (token > cursor) try buf.appendSlice(allocator, template[cursor..token]);
        if (token == template.len) {
            cursor = token;
            continue;
        }

        if (template[token] == '{') {
            if (token + 1 < template.len and template[token + 1] == '{') {
                try buf.append(allocator, '{');
                cursor = token + 2;
                continue;
            }

            comptime var end = token + 1;
            inline while (end < template.len and template[end] != '}') : (end += 1) {
                if (template[end] == '{') @compileError("nested HTML template placeholder");
            }
            if (end == template.len) @compileError("unclosed HTML template placeholder");
            if (end == token + 1) @compileError("empty HTML template placeholder");

            try appendTemplateValue(buf, allocator, @field(values, template[token + 1 .. end]));
            cursor = end + 1;
            continue;
        }

        if (token + 1 < template.len and template[token + 1] == '}') {
            try buf.append(allocator, '}');
            cursor = token + 2;
            continue;
        }
        @compileError("unescaped closing brace in HTML template");
    }
}

fn appendTemplateValue(buf: *std.ArrayList(u8), allocator: Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == TrustedHtml) {
        try buf.appendSlice(allocator, value.value);
        return;
    }

    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one, .slice => {
                const slice: []const u8 = value;
                try appendHtml(buf, allocator, slice);
            },
            .many, .c => {
                const slice: [:0]const u8 = std.mem.span(value);
                try appendHtml(buf, allocator, slice);
            },
        },
        .array => {
            const slice: []const u8 = &value;
            try appendHtml(buf, allocator, slice);
        },
        .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
        .int, .comptime_int => try std.fmt.format(buf.writer(allocator), "{d}", .{value}),
        .float, .comptime_float => try std.fmt.format(buf.writer(allocator), "{d}", .{value}),
        .@"enum", .enum_literal => try appendHtml(buf, allocator, @tagName(value)),
        .optional => if (value) |payload| try appendTemplateValue(buf, allocator, payload),
        else => @compileError("unsupported HTML template value type: " ++ @typeName(T)),
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

pub fn sendBinaryResponse(
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
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n{s}\r\n",
        .{ status, reason, content_type, body.len, extra_headers orelse "" },
    );
    defer allocator.free(headers);
    try stream.writeAll(headers);
    try stream.writeAll(body);
}

fn loadWebStats(allocator: Allocator, repo: Repo) !WebStats {
    var stats = WebStats{};
    stats.inbox_refs = countRefsWithPrefix(allocator, "refs/gitomi/inbox") catch 0;
    stats.staged_refs = countRefsWithPrefix(allocator, "refs/gitomi/staging") catch 0;

    if (!(index.isIndexFresh(allocator, repo) catch false)) return stats;
    stats.events = countIndexedEvents(allocator, repo) catch 0;
    stats.issues = index.countIssueOpenedEvents(allocator, repo) catch 0;
    return stats;
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

test "web template escapes placeholders" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendTemplate(&buf, std.testing.allocator, "<p class=\"{class}\">{body}</p>", .{
        .class = "a&b",
        .body = "<hello> \"world\"",
    });

    try std.testing.expectEqualStrings("<p class=\"a&amp;b\">&lt;hello&gt; &quot;world&quot;</p>", buf.items);
}

test "web template supports raw values braces and numbers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendTemplate(&buf, std.testing.allocator, "<script>{{x:{count}}}</script>{raw}", .{
        .count = 3,
        .raw = trustedHtml("<span>ok</span>"),
    });

    try std.testing.expectEqualStrings("<script>{x:3}</script><span>ok</span>", buf.items);
}
