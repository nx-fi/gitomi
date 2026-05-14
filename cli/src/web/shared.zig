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

pub const Href = union(enum) {
    literal: []const u8,
    code: PathHref,
    raw: PathHref,
    commits: PathHref,
    blame: PathHref,
    commit: []const u8,
    issue: []const u8,
};

pub const PathHref = struct {
    ref: []const u8,
    path: []const u8 = "",
    view: ?[]const u8 = null,
};

pub const Class = struct {
    name: []const u8,
    enabled: bool = true,
};

pub const ClassList = struct {
    base: []const u8,
    extra: []const Class = &.{},
};

pub const ClassAttr = struct {
    value: ClassList,
};

pub const Button = struct {
    label: []const u8,
    href: Href,
    kind: []const u8 = "secondary",
};

pub fn literalHref(value: []const u8) Href {
    return .{ .literal = value };
}

pub fn codeHref(ref: []const u8, path: []const u8) Href {
    return .{ .code = .{ .ref = ref, .path = path } };
}

pub fn codeHrefWithView(ref: []const u8, path: []const u8, view: []const u8) Href {
    return .{ .code = .{ .ref = ref, .path = path, .view = view } };
}

pub fn rawHref(ref: []const u8, path: []const u8) Href {
    return .{ .raw = .{ .ref = ref, .path = path } };
}

pub fn commitsHref(ref: []const u8, path: []const u8) Href {
    return .{ .commits = .{ .ref = ref, .path = path } };
}

pub fn blameHref(ref: []const u8, path: []const u8) Href {
    return .{ .blame = .{ .ref = ref, .path = path } };
}

pub fn commitHref(hash: []const u8) Href {
    return .{ .commit = hash };
}

pub fn issueHref(short_id: []const u8) Href {
    return .{ .issue = short_id };
}

pub fn class(name: []const u8, enabled: bool) Class {
    return .{ .name = name, .enabled = enabled };
}

pub fn classes(base: []const u8, extra: []const Class) ClassList {
    return .{ .base = base, .extra = extra };
}

pub fn classAttr(base: []const u8, extra: []const Class) ClassAttr {
    return .{ .value = classes(base, extra) };
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
    try appendTemplate(buf, allocator,
        \\ - Gitomi</title>
        \\  <link rel="icon" href="/logo.svg" type="image/svg+xml">
        \\  <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/devicon.min.css">
        \\  <link rel="stylesheet" href="/style.css">
        \\</head>
        \\<body>
        \\<header class="topbar">
        \\  <a class="brand" href="/"><img class="brand-logo" src="/logo.svg" alt="" width="32" height="32"><span>{repo_name}</span></a>
        \\  <nav>
    , .{ .repo_name = std.fs.path.basename(repo.root) });
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
        \\<script src="/code.js"></script>
        \\<script src="/markdown.js"></script>
        \\<script src="/vendor/hljs/all-languages.js"></script>
        \\<script src="/highlight/zig.js"></script>
        \\<script src="/highlight/solidity.js"></script>
        \\<script src="/highlight/tla.js"></script>
        \\<script src="/highlight/init.js"></script>
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
        \\<a{class_attr} href="{href}">{label}
    , .{
        .class_attr = classAttr("", &.{class("active", std.mem.eql(u8, active, id))}),
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

pub fn appendEmptyCell(buf: *std.ArrayList(u8), allocator: Allocator, colspan: usize, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<tr><td colspan="{colspan}" class="empty-cell">{message}</td></tr>
    , .{
        .colspan = colspan,
        .message = message,
    });
}

pub fn appendInlineEmpty(buf: *std.ArrayList(u8), allocator: Allocator, message: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="empty inline-empty"><strong>{message}</strong></div>
    , .{ .message = message });
}

pub fn appendButtonLink(buf: *std.ArrayList(u8), allocator: Allocator, button: Button) !void {
    try appendTemplate(buf, allocator,
        \\<a class="button {kind}" href="{href}">{label}</a>
    , .{
        .kind = button.kind,
        .href = button.href,
        .label = button.label,
    });
}

pub fn appendSectionHead(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    eyebrow: []const u8,
    title: []const u8,
    action: ?Button,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="section-head">
        \\  <div>
        \\    <p class="eyebrow">{eyebrow}</p>
        \\    <h1>{title}</h1>
        \\  </div>
    , .{
        .eyebrow = eyebrow,
        .title = title,
    });
    if (action) |button| try appendButtonLink(buf, allocator, button);
    try buf.appendSlice(allocator, "</div>");
}

pub fn appendRepoHeader(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    actions: []const Button,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="repo-head">
        \\  <div>
        \\    <p class="eyebrow">Repository</p>
        \\    <h1>{repo_name}</h1>
        \\  </div>
        \\  <div class="repo-actions">
        \\    <span class="branch-pill">{ref}</span>
    , .{
        .repo_name = std.fs.path.basename(repo.root),
        .ref = ref,
    });
    for (actions) |button| try appendButtonLink(buf, allocator, button);
    try buf.appendSlice(allocator, "</div></section>");
}

pub fn appendStatePill(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="state {state}">{state}</span>
    , .{ .state = state });
}

pub fn appendPill(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="pill">{label}</span>
    , .{ .label = label });
}

pub fn appendFact(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, value: anytype) !void {
    try appendTemplate(buf, allocator,
        \\<div><dt>{label}</dt><dd>{value}</dd></div>
    , .{
        .label = label,
        .value = value,
    });
}

pub fn appendOptionalAttr(buf: *std.ArrayList(u8), allocator: Allocator, comptime name: []const u8, value: anytype) !void {
    if (value) |payload| {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "=\"");
        try appendTemplateValue(buf, allocator, payload);
        try buf.append(allocator, '"');
    }
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

pub const JsonString = struct {
    value: []const u8,
};

pub fn jsonString(value: []const u8) JsonString {
    return .{ .value = value };
}

pub const GroupedUnsigned = struct {
    value: u64,
};

pub fn groupedUnsigned(value: u64) GroupedUnsigned {
    return .{ .value = value };
}

pub const Percent = struct {
    value: u64,
    total: u64,
};

pub fn percent(value: u64, total: u64) Percent {
    return .{ .value = value, .total = total };
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
    if (T == Href) {
        try appendHref(buf, allocator, value);
        return;
    }
    if (T == ClassList) {
        try appendClassValue(buf, allocator, value);
        return;
    }
    if (T == ClassAttr) {
        try appendClassAttrValue(buf, allocator, value);
        return;
    }
    if (T == JsonString) {
        try appendJsonString(buf, allocator, value.value);
        return;
    }
    if (T == GroupedUnsigned) {
        try appendGroupedUnsigned(buf, allocator, value.value);
        return;
    }
    if (T == Percent) {
        try appendPercent(buf, allocator, value.value, value.total);
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

pub fn appendHref(buf: *std.ArrayList(u8), allocator: Allocator, href: Href) !void {
    switch (href) {
        .literal => |value| try appendHtml(buf, allocator, value),
        .code => |value| try appendPathHref(buf, allocator, "/code", value),
        .raw => |value| try appendPathHref(buf, allocator, "/raw", value),
        .commits => |value| try appendPathHref(buf, allocator, "/commits", value),
        .blame => |value| try appendPathHref(buf, allocator, "/blame", value),
        .commit => |hash| {
            try buf.appendSlice(allocator, "/commit?sha=");
            try appendUrlEncoded(buf, allocator, hash);
        },
        .issue => |short_id| {
            try buf.appendSlice(allocator, "/issues/");
            try appendUrlEncoded(buf, allocator, short_id);
        },
    }
}

fn appendPathHref(buf: *std.ArrayList(u8), allocator: Allocator, route: []const u8, href: PathHref) !void {
    try buf.appendSlice(allocator, route);
    try buf.appendSlice(allocator, "?ref=");
    try appendUrlEncoded(buf, allocator, href.ref);
    if (href.path.len != 0) {
        try buf.appendSlice(allocator, "&amp;path=");
        try appendUrlEncoded(buf, allocator, href.path);
    }
    if (href.view) |view| {
        try buf.appendSlice(allocator, "&amp;view=");
        try appendUrlEncoded(buf, allocator, view);
    }
}

pub fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0f]);
        }
    }
}

fn appendClassValue(buf: *std.ArrayList(u8), allocator: Allocator, value: ClassList) !void {
    var wrote = false;
    if (value.base.len != 0) {
        try appendHtml(buf, allocator, value.base);
        wrote = true;
    }
    for (value.extra) |item| {
        if (!item.enabled) continue;
        if (wrote) try buf.append(allocator, ' ');
        try appendHtml(buf, allocator, item.name);
        wrote = true;
    }
}

fn appendClassAttrValue(buf: *std.ArrayList(u8), allocator: Allocator, attr: ClassAttr) !void {
    if (!classListHasValue(attr.value)) return;
    try buf.appendSlice(allocator, " class=\"");
    try appendClassValue(buf, allocator, attr.value);
    try buf.append(allocator, '"');
}

fn classListHasValue(value: ClassList) bool {
    if (value.base.len != 0) return true;
    for (value.extra) |item| {
        if (item.enabled) return true;
    }
    return false;
}

fn appendGroupedUnsigned(buf: *std.ArrayList(u8), allocator: Allocator, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&digits, "{d}", .{value});
    for (text, 0..) |c, i| {
        if (i != 0 and (text.len - i) % 3 == 0) try buf.append(allocator, ',');
        try buf.append(allocator, c);
    }
}

fn appendPercent(buf: *std.ArrayList(u8), allocator: Allocator, value: u64, total: u64) !void {
    const tenths = percentTenths(value, total);
    try std.fmt.format(buf.writer(allocator), "{d}.{d}%", .{ tenths / 10, tenths % 10 });
}

fn percentTenths(value: u64, total: u64) u64 {
    if (total == 0) return 0;
    const scaled = (@as(u128, value) * 1000 + @as(u128, total) / 2) / @as(u128, total);
    return @intCast(@min(scaled, 1000));
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

test "web template supports typed href classes and formatters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendTemplate(&buf, std.testing.allocator, "<a{class_attr} href=\"{href}\">{lines} {share}</a>", .{
        .class_attr = classAttr("button", &.{class("active", true)}),
        .href = codeHrefWithView("feature/test", "src/a b.zig", "preview"),
        .lines = groupedUnsigned(12_345),
        .share = percent(5, 6),
    });

    try std.testing.expectEqualStrings("<a class=\"button active\" href=\"/code?ref=feature/test&amp;path=src/a%20b.zig&amp;view=preview\">12,345 83.3%</a>", buf.items);
}
