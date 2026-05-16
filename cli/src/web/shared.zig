const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const avatars = @import("avatars.zig");
const html = @import("html.zig");
const response = @import("response.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Config = repo_mod.Config;
const Repo = repo_mod.Repo;
const countIndexedEvents = index.countIndexedEvents;
const countNonEmptyLines = util.countNonEmptyLines;
const gitChecked = git.gitChecked;
const appendJsonString = json_writer.appendJsonString;
const loadConfig = repo_mod.loadConfig;

const default_web_shortcut_leader = "Space";
const default_web_shortcut_keys = "A S D F J K L E R U I O W Q P Z X C V B N M G H Y T";
const default_web_shortcut_timeout_ms: u64 = 900;
const asset_version = "20260516-projects";

const WebStats = struct {
    inbox_refs: usize = 0,
    staged_refs: usize = 0,
    events: usize = 0,
    issues: usize = 0,
    pulls: usize = 0,
};

pub const Href = html.Href;
pub const PathHref = html.PathHref;
pub const Class = html.Class;
pub const ClassList = html.ClassList;
pub const ClassAttr = html.ClassAttr;
pub const TrustedHtml = html.TrustedHtml;
pub const JsonString = html.JsonString;
pub const GroupedUnsigned = html.GroupedUnsigned;
pub const Percent = html.Percent;

pub const literalHref = html.literalHref;
pub const codeHref = html.codeHref;
pub const codeHrefWithView = html.codeHrefWithView;
pub const rawHref = html.rawHref;
pub const commitsHref = html.commitsHref;
pub const blameHref = html.blameHref;
pub const commitHref = html.commitHref;
pub const issueHref = html.issueHref;
pub const pullHref = html.pullHref;
pub const class = html.class;
pub const classes = html.classes;
pub const classAttr = html.classAttr;
pub const appendHtml = html.appendHtml;
pub const trustedHtml = html.trustedHtml;
pub const jsonString = html.jsonString;
pub const groupedUnsigned = html.groupedUnsigned;
pub const percent = html.percent;
pub const appendTemplate = html.appendTemplate;
pub const appendHref = html.appendHref;
pub const appendOptionalAttr = html.appendOptionalAttr;
pub const appendUrlEncoded = html.appendUrlEncoded;
pub const appendFmt = html.appendFmt;
pub const appendRelativeTime = time.appendRelativeTime;
pub const appendAvatar = avatars.appendAvatar;
pub const sendRedirect = response.sendRedirect;
pub const sendPlainResponse = response.sendPlainResponse;
pub const sendResponse = response.sendResponse;
pub const sendBinaryResponse = response.sendBinaryResponse;
const appendUserAvatar = avatars.appendUserAvatar;

pub const Button = struct {
    label: []const u8,
    href: Href,
    kind: []const u8 = "secondary",
};

const WorkItemReferenceKind = enum {
    issue,
    pull,
};

pub const InternalReferenceResolver = struct {
    allocator: Allocator,
    db: ?index.SqliteDb = null,

    pub fn init(allocator: Allocator, repo: Repo) InternalReferenceResolver {
        if (!(index.isIndexFresh(allocator, repo) catch false)) {
            return .{ .allocator = allocator };
        }

        const db = index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, true) catch {
            return .{ .allocator = allocator };
        };
        return .{ .allocator = allocator, .db = db };
    }

    pub fn deinit(self: *InternalReferenceResolver) void {
        if (self.db) |*db| db.deinit();
        self.db = null;
    }

    pub fn hrefForHashReference(self: *InternalReferenceResolver, token: []const u8) Href {
        if (self.matchesWorkItem(.issue, token)) return issueHref(token);
        if (self.matchesWorkItem(.pull, token)) return pullHref(token);
        if (util.isObjectRefPrefix(token)) return commitHref(token);
        return issueHref(token);
    }

    fn matchesWorkItem(self: *InternalReferenceResolver, kind: WorkItemReferenceKind, token: []const u8) bool {
        if (self.db == null) return false;
        if (util.isObjectRefPrefix(token) and (self.matchesObjectHashRef(kind, token) catch false)) return true;
        if (positiveDecimalReferenceNumber(token)) |number| {
            if (self.matchesLegacyNumber(kind, number) catch false) return true;
        }
        return false;
    }

    fn matchesObjectHashRef(self: *InternalReferenceResolver, kind: WorkItemReferenceKind, token: []const u8) !bool {
        const sql_text: []const u8 = switch (kind) {
            .issue => "SELECT id FROM issues ORDER BY id",
            .pull => "SELECT id FROM pulls ORDER BY id",
        };
        const db = if (self.db) |*value| value else return false;
        var stmt = try db.prepare(sql_text);
        defer stmt.deinit();

        while (try stmt.step()) {
            const id = try stmt.columnTextDup(self.allocator, 0);
            defer self.allocator.free(id);
            var ref_buf: [util.max_object_ref_len]u8 = undefined;
            const candidate_ref = util.objectRefPrefix(ref_buf[0..token.len], id);
            if (asciiEqlIgnoreCase(candidate_ref, token)) return true;
        }
        return false;
    }

    fn matchesLegacyNumber(self: *InternalReferenceResolver, kind: WorkItemReferenceKind, number: i64) !bool {
        const db = if (self.db) |*value| value else return false;
        var stmt = try db.prepare(
            \\SELECT 1
            \\FROM legacy_aliases
            \\WHERE provider = 'github'
            \\  AND object_kind = ?
            \\  AND number = ?
            \\LIMIT 1
        );
        defer stmt.deinit();
        try stmt.bindText(1, workItemReferenceKindName(kind));
        try stmt.bindInt64(2, number);
        return try stmt.step();
    }
};

fn workItemReferenceKindName(kind: WorkItemReferenceKind) []const u8 {
    return switch (kind) {
        .issue => "issue",
        .pull => "pull",
    };
}

pub const Pagination = struct {
    page: usize = 1,
    per_page: usize,

    pub fn offset(self: Pagination) usize {
        return (self.page - 1) * self.per_page;
    }

    pub fn queryLimit(self: Pagination) usize {
        return self.per_page + 1;
    }
};

pub fn issueReferenceEnd(value: []const u8, start: usize) ?usize {
    if (start >= value.len or value[start] != '#') return null;
    const token_start = start + 1;
    if (token_start >= value.len or !std.ascii.isHex(value[token_start])) return null;

    var end = token_start;
    while (end < value.len and std.ascii.isHex(value[end])) : (end += 1) {}
    if (end < value.len and isReferenceTrailingIdentifier(value[end])) return null;

    const token = value[token_start..end];
    if (isPositiveDecimalReference(token) or util.isObjectRefPrefix(token)) return end;
    return null;
}

pub fn appendIssueReferenceLink(buf: *std.ArrayList(u8), allocator: Allocator, issue_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, issueHref(issue_ref));
    try buf.appendSlice(allocator, "\">#");
    try appendHtml(buf, allocator, issue_ref);
    try buf.appendSlice(allocator, "</a>");
}

pub fn appendIssueLinkedText(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (issueReferenceEnd(value, i)) |end| {
            if (plain_start < i) try appendHtml(buf, allocator, value[plain_start..i]);
            try appendIssueReferenceLink(buf, allocator, value[i + 1 .. end]);
            i = end;
            plain_start = i;
            continue;
        }
        i += 1;
    }
    if (plain_start < value.len) try appendHtml(buf, allocator, value[plain_start..]);
}

pub fn appendInternalReferenceLinkedText(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    resolver: *InternalReferenceResolver,
    value: []const u8,
) !void {
    try appendInternalReferenceLinkedTextWithDefaultHref(buf, allocator, resolver, value, null);
}

pub fn appendInternalReferenceLinkedTextWithDefaultHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    resolver: *InternalReferenceResolver,
    value: []const u8,
    default_href: ?Href,
) !void {
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (issueReferenceEnd(value, i)) |end| {
            if (plain_start < i) try appendLinkedTextPlainSegment(buf, allocator, value[plain_start..i], default_href);
            try appendInternalReferenceLink(buf, allocator, resolver, value[i + 1 .. end]);
            i = end;
            plain_start = i;
            continue;
        }
        i += 1;
    }
    if (plain_start < value.len) try appendLinkedTextPlainSegment(buf, allocator, value[plain_start..], default_href);
}

fn appendLinkedTextPlainSegment(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    value: []const u8,
    default_href: ?Href,
) !void {
    const href = default_href orelse {
        try appendHtml(buf, allocator, value);
        return;
    };
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, href);
    try buf.appendSlice(allocator, "\">");
    try appendHtml(buf, allocator, value);
    try buf.appendSlice(allocator, "</a>");
}

fn appendInternalReferenceLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    resolver: *InternalReferenceResolver,
    token: []const u8,
) !void {
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, resolver.hrefForHashReference(token));
    try buf.appendSlice(allocator, "\">#");
    try appendHtml(buf, allocator, token);
    try buf.appendSlice(allocator, "</a>");
}

fn isPositiveDecimalReference(value: []const u8) bool {
    if (value.len == 0) return false;
    var has_non_zero = false;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
        if (c != '0') has_non_zero = true;
    }
    return has_non_zero;
}

fn positiveDecimalReferenceNumber(value: []const u8) ?i64 {
    if (!isPositiveDecimalReference(value)) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn isReferenceTrailingIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

pub fn currentPrincipalOwned(allocator: Allocator, repo: Repo) !?[]u8 {
    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound, CliError.ConfigInvalid => return null,
        else => return err,
    };
    defer cfg.deinit();
    return try allocator.dupe(u8, cfg.principal);
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
        \\  <link rel="stylesheet" href="/vendor/devicon/devicon.min.css?v={asset_version}">
        \\  <link rel="stylesheet" href="/vendor/katex/katex.min.css">
        \\  <link rel="stylesheet" href="/style.css?v={asset_version}">
    , .{ .asset_version = asset_version });
    try appendShortcutConfigScript(buf, allocator, cfg_opt);
    try appendTemplate(buf, allocator,
        \\</head>
        \\<body>
        \\<header class="topbar">
        \\  <a class="brand" href="/"><img class="brand-logo" src="/logo.svg" alt="" width="47" height="32"><span>{repo_name}</span></a>
        \\  <nav>
    , .{ .repo_name = std.fs.path.basename(repo.root) });
    try appendNavLink(buf, allocator, active, "code", "/", "Code", "icon-code", null);
    try appendNavLink(buf, allocator, active, "issues", "/issues", "Issues", "icon-issues", stats.issues);
    try appendNavLink(buf, allocator, active, "pulls", "/pulls", "Pull Requests", "icon-pull-request", stats.pulls);
    try appendNavLink(buf, allocator, active, "actions", "/workflows", "Workflows", "icon-workflow", null);
    try appendNavLink(buf, allocator, active, "projects", "/projects", "Projects", "icon-projects", null);
    try appendSettingsNavLink(buf, allocator, active);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="topbar-actions">
    );
    try appendTemplate(buf, allocator,
        \\  <button class="theme-toggle" type="button" data-theme-toggle aria-pressed="false" aria-label="Toggle dark mode" title="Toggle dark mode">
        \\    <span class="theme-toggle-track" aria-hidden="true"><span class="theme-toggle-thumb"></span></span>
        \\    <span class="theme-toggle-label" data-theme-label>Light</span>
        \\  </button>
    , .{});
    if (cfg_opt) |cfg| {
        try appendUserMenu(buf, allocator, cfg);
    }
    try appendTemplate(buf, allocator,
        \\  </div>
        \\</header>
        \\<main class="page page-{active}">
    , .{ .active = active });

    if (cfg_opt == null) {
        try buf.appendSlice(allocator,
            \\<section class="init-banner">
            \\  <strong>Gitomi is not initialized.</strong>
            \\  <span>Run <code>gt init</code> before creating signed issues from the web UI.</span>
            \\</section>
        );
    }
}

fn appendUserMenu(buf: *std.ArrayList(u8), allocator: Allocator, cfg: Config) !void {
    try appendTemplate(buf, allocator,
        \\<details class="user-menu" data-popover-menu>
        \\  <summary aria-label="User menu">
    , .{});
    try appendUserAvatar(buf, allocator, cfg.principal);
    try appendTemplate(buf, allocator,
        \\    <span class="user-menu-label"><strong>{principal}</strong><span>{device}</span></span>
        \\  </summary>
        \\  <div class="user-menu-popover" role="menu">
        \\    <div class="user-menu-section">
        \\      <span class="user-menu-kicker">User</span>
        \\      <strong>{principal}</strong>
        \\      <span>{device}</span>
        \\    </div>
        \\    <div class="user-menu-section">
        \\      <span class="user-menu-kicker">Repository ID</span>
        \\      <code>{repo_id}</code>
        \\    </div>
        \\  </div>
        \\</details>
    , .{
        .principal = cfg.principal,
        .device = cfg.device,
        .repo_id = cfg.repo_id,
    });
}

fn appendShortcutConfigScript(buf: *std.ArrayList(u8), allocator: Allocator, cfg_opt: ?Config) !void {
    var leader: []const u8 = default_web_shortcut_leader;
    var keys: []const u8 = default_web_shortcut_keys;
    var timeout_ms: u64 = default_web_shortcut_timeout_ms;

    if (cfg_opt) |cfg| {
        if (cfg.web_shortcut_leader) |value| leader = value;
        if (cfg.web_shortcut_keys) |value| keys = value;
        if (cfg.web_shortcut_timeout_ms) |value| timeout_ms = value;
    }

    try buf.appendSlice(allocator, "<script>\nwindow.gitomiShortcutConfig = { leader: ");
    try appendJsonString(buf, allocator, leader);
    try buf.appendSlice(allocator, ", keys: ");
    try appendJsonString(buf, allocator, keys);
    try std.fmt.format(buf.writer(allocator), ", sequenceTimeoutMs: {d}", .{timeout_ms});
    try buf.appendSlice(allocator, " };\n</script>\n");
}

pub fn appendShellEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\</main>
        \\<script src="/theme.js?v={asset_version}"></script>
        \\<script src="/ui.js?v={asset_version}"></script>
        \\<script src="/shortcuts.js?v={asset_version}"></script>
        \\<script src="/tree.js?v={asset_version}"></script>
        \\<script src="/code.js?v={asset_version}"></script>
        \\<script src="/projects.js?v={asset_version}"></script>
        \\<script src="/vendor/marked/marked.umd.min.js"></script>
        \\<script src="/vendor/dompurify/purify.min.js"></script>
        \\<script src="/vendor/katex/katex.min.js"></script>
        \\<script src="/vendor/katex/auto-render.min.js"></script>
        \\<script src="/vendor/mermaid/mermaid.min.js"></script>
        \\<script src="/markdown.js?v={asset_version}"></script>
        \\<script src="/vendor/hljs/all-languages.min.js"></script>
        \\<script src="/highlight/zig.js?v={asset_version}"></script>
        \\<script src="/highlight/solidity.js?v={asset_version}"></script>
        \\<script src="/highlight/tla.js?v={asset_version}"></script>
        \\<script src="/highlight/init.js?v={asset_version}"></script>
        \\<script src="/diff.js?v={asset_version}"></script>
        \\<script src="/merge.js?v={asset_version}"></script>
        \\</body>
        \\</html>
    , .{ .asset_version = asset_version });
}

pub fn appendNavLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    active: []const u8,
    id: []const u8,
    href: []const u8,
    label: []const u8,
    icon: []const u8,
    count: ?usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="{href}"
    , .{
        .class_attr = classAttr("", &.{class("active", std.mem.eql(u8, active, id))}),
        .href = href,
    });
    if (count != null) {
        try appendTemplate(buf, allocator,
            \\ data-nav-count="{id}"
        , .{ .id = id });
    }
    try appendTemplate(buf, allocator,
        \\><span class="button-icon {icon}" aria-hidden="true"></span><span>{label}</span>
    , .{
        .icon = icon,
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

fn appendSettingsNavLink(buf: *std.ArrayList(u8), allocator: Allocator, active: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="/settings"><span class="button-icon icon-settings" aria-hidden="true"></span><span>Settings</span></a>
    , .{ .class_attr = classAttr("", &.{class("active", isSettingsActive(active))}) });
}

fn isSettingsActive(active: []const u8) bool {
    return std.mem.eql(u8, active, "events") or std.mem.eql(u8, active, "labels") or std.mem.eql(u8, active, "access");
}

pub fn appendSettingsLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator, active: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-page-layout settings-page-layout">
        \\  <aside class="project-page-sidebar settings-page-sidebar">
        \\    <nav class="project-page-tabs settings-page-tabs" aria-label="Settings sections">
    );
    try appendSettingsTab(buf, allocator, active, "events", "/events", "icon-history", "Activity");
    try appendSettingsTab(buf, allocator, active, "labels", "/labels", "icon-labels", "Labels");
    try appendSettingsTab(buf, allocator, active, "access", "/access", "icon-users", "Access");
    try buf.appendSlice(allocator,
        \\    </nav>
        \\  </aside>
        \\  <div class="settings-page-content">
    );
}

pub fn appendSettingsLayoutEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
    );
}

fn appendSettingsTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    active: []const u8,
    id: []const u8,
    href: []const u8,
    icon: []const u8,
    label: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="{href}"><span class="button-icon {icon}" aria-hidden="true"></span><span>{label}</span></a>
    , .{
        .classes = classes("project-page-tab", &.{class("active", std.mem.eql(u8, active, id))}),
        .href = href,
        .icon = icon,
        .label = label,
    });
}

pub fn renderNavStatsJson(allocator: Allocator, repo: Repo) ![]u8 {
    try index.ensureIndex(allocator, repo);
    const stats = try loadWebStats(allocator, repo);
    return std.fmt.allocPrint(
        allocator,
        "{{\"issues\":{d},\"pulls\":{d}}}",
        .{ stats.issues, stats.pulls },
    );
}

pub fn appendEmptyState(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, detail: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="empty"><strong>{title}</strong><p>{detail}</p></div>
    , .{
        .title = title,
        .detail = detail,
    });
}

pub const MarkdownEditorOptions = struct {
    name: []const u8 = "body",
    rows: usize = 7,
    placeholder: []const u8 = "Leave a comment",
    value: []const u8 = "",
    required: bool = true,
};

pub const MarkdownSourceOptions = struct {
    ref: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const MarkdownTaskSummary = struct {
    done: usize = 0,
    total: usize = 0,

    pub fn hasTasks(self: MarkdownTaskSummary) bool {
        return self.total != 0;
    }
};

const MarkdownFenceMarker = struct {
    char: u8,
    len: usize,
};

const MarkdownTaskMarker = struct {
    checked: bool,
};

pub fn markdownTaskSummary(markdown: []const u8) MarkdownTaskSummary {
    var summary: MarkdownTaskSummary = .{};
    var in_fence = false;
    var fence: MarkdownFenceMarker = .{ .char = 0, .len = 0 };

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (markdownFenceMarker(line)) |marker| {
            if (!in_fence) {
                in_fence = true;
                fence = marker;
            } else if (marker.char == fence.char and marker.len >= fence.len) {
                in_fence = false;
            }
            continue;
        }
        if (in_fence) continue;

        if (markdownTaskMarker(line)) |marker| {
            summary.total += 1;
            if (marker.checked) summary.done += 1;
        }
    }

    return summary;
}

pub fn appendMarkdownTaskProgress(buf: *std.ArrayList(u8), allocator: Allocator, summary: MarkdownTaskSummary) !void {
    if (!summary.hasTasks()) return;

    try appendTemplate(buf, allocator,
        \\<span class="issue-task-progress" title="{done} of {total} tasks done"><span class="issue-task-progress-icon" aria-hidden="true"></span>
    , .{
        .done = summary.done,
        .total = summary.total,
    });
    if (summary.done == summary.total) {
        try appendTemplate(buf, allocator, "{total} {task_word} done", .{
            .total = summary.total,
            .task_word = if (summary.total == 1) "task" else "tasks",
        });
    } else {
        try appendTemplate(buf, allocator, "{done} of {total} {task_word}", .{
            .done = summary.done,
            .total = summary.total,
            .task_word = if (summary.total == 1) "task" else "tasks",
        });
    }
    try buf.appendSlice(allocator, "</span>");
}

fn markdownFenceMarker(line: []const u8) ?MarkdownFenceMarker {
    var i: usize = 0;
    while (i < line.len and i < 4 and line[i] == ' ') : (i += 1) {}
    if (i >= line.len) return null;

    const char = line[i];
    if (char != '`' and char != '~') return null;

    var len: usize = 0;
    while (i + len < line.len and line[i + len] == char) : (len += 1) {}
    if (len < 3) return null;
    return .{ .char = char, .len = len };
}

fn markdownTaskMarker(line: []const u8) ?MarkdownTaskMarker {
    var i: usize = 0;
    while (i < line.len and isMarkdownWhitespace(line[i])) : (i += 1) {}
    if (i >= line.len) return null;

    switch (line[i]) {
        '-', '*', '+' => {
            i += 1;
            if (i >= line.len or !isMarkdownWhitespace(line[i])) return null;
            while (i < line.len and isMarkdownWhitespace(line[i])) : (i += 1) {}
        },
        '0'...'9' => {
            while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
            if (i >= line.len or (line[i] != '.' and line[i] != ')')) return null;
            i += 1;
            if (i >= line.len or !isMarkdownWhitespace(line[i])) return null;
            while (i < line.len and isMarkdownWhitespace(line[i])) : (i += 1) {}
        },
        else => return null,
    }

    if (i + 2 >= line.len or line[i] != '[' or line[i + 2] != ']') return null;
    const marker = line[i + 1];
    if (marker != ' ' and marker != 'x' and marker != 'X') return null;
    if (i + 3 < line.len and !isMarkdownWhitespace(line[i + 3])) return null;

    return .{ .checked = marker == 'x' or marker == 'X' };
}

fn isMarkdownWhitespace(char: u8) bool {
    return char == ' ' or char == '\t';
}

pub fn appendMarkdownSource(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    markdown: []const u8,
    options: MarkdownSourceOptions,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(markdown.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, markdown);

    try buf.appendSlice(allocator, "<script type=\"application/octet-stream\" data-markdown-source data-markdown-encoding=\"base64\"");
    if (options.ref) |value| {
        try buf.appendSlice(allocator, " data-markdown-ref=\"");
        try appendHtml(buf, allocator, value);
        try buf.appendSlice(allocator, "\"");
    }
    if (options.path) |value| {
        try buf.appendSlice(allocator, " data-markdown-path=\"");
        try appendHtml(buf, allocator, value);
        try buf.appendSlice(allocator, "\"");
    }
    try buf.append(allocator, '>');
    try buf.appendSlice(allocator, encoded);
    try buf.appendSlice(allocator, "</script>");
}

pub fn appendMarkdownEditor(buf: *std.ArrayList(u8), allocator: Allocator, options: MarkdownEditorOptions) !void {
    try appendTemplate(buf, allocator,
        \\    <div class="markdown-editor" data-markdown-editor>
        \\      <div class="markdown-editor-tabs" role="tablist" aria-label="Markdown editor mode">
        \\        <button class="active" type="button" role="tab" aria-selected="true" data-markdown-tab="write">Write</button>
        \\        <button type="button" role="tab" aria-selected="false" data-markdown-tab="preview">Preview</button>
        \\      </div>
        \\      <div class="markdown-editor-toolbar" aria-label="Markdown formatting">
        \\        <button type="button" data-markdown-action="heading" aria-label="Heading" title="Heading">H</button>
        \\        <button type="button" data-markdown-action="bold" aria-label="Bold" title="Bold"><strong>B</strong></button>
        \\        <button type="button" data-markdown-action="italic" aria-label="Italic" title="Italic"><em>I</em></button>
        \\        <button type="button" data-markdown-action="quote" aria-label="Quote" title="Quote"><span class="md-icon md-icon-quote" aria-hidden="true"></span></button>
        \\        <button type="button" data-markdown-action="code" aria-label="Code" title="Code"><span class="md-icon md-icon-code" aria-hidden="true"></span></button>
        \\        <button type="button" data-markdown-action="link" aria-label="Link" title="Link"><span class="md-icon md-icon-link" aria-hidden="true"></span></button>
        \\        <span class="markdown-editor-divider" aria-hidden="true"></span>
        \\        <button type="button" data-markdown-action="unordered-list" aria-label="Bulleted list" title="Bulleted list"><span class="md-icon md-icon-ul" aria-hidden="true"></span></button>
        \\        <button type="button" data-markdown-action="ordered-list" aria-label="Numbered list" title="Numbered list"><span class="md-icon md-icon-ol" aria-hidden="true"></span></button>
        \\        <button type="button" data-markdown-action="task-list" aria-label="Task list" title="Task list"><span class="md-icon md-icon-task" aria-hidden="true"></span></button>
        \\        <span class="markdown-editor-divider" aria-hidden="true"></span>
        \\        <button type="button" data-markdown-action="mention" aria-label="Mention" title="Mention">@</button>
        \\        <button type="button" data-markdown-action="reference" aria-label="Issue reference" title="Issue reference">#</button>
        \\      </div>
        \\      <textarea name="{name}" rows="{rows}" placeholder="{placeholder}"
    , .{
        .name = options.name,
        .rows = options.rows,
        .placeholder = options.placeholder,
    });
    if (options.required) try buf.appendSlice(allocator, " required");
    try appendTemplate(buf, allocator,
        \\ data-markdown-input>{value}</textarea>
        \\      <div class="markdown-editor-preview markdown-body" data-markdown-preview hidden></div>
        \\    </div>
    , .{ .value = options.value });
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

pub fn appendDetailBackButton(buf: *std.ArrayList(u8), allocator: Allocator, href: Href, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="detail-back-nav" aria-label="Detail navigation"><a class="detail-back-button" href="{href}" aria-label="{label}" title="{label}"><span class="button-icon icon-arrow-left" aria-hidden="true"></span></a></nav>
    , .{
        .href = href,
        .label = label,
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
    const repo_name = std.fs.path.basename(repo.root);
    const owner_name = if (std.fs.path.dirname(repo.root)) |parent| std.fs.path.basename(parent) else "local";
    try appendTemplate(buf, allocator,
        \\<section class="repo-head">
        \\  <div>
        \\    <h1><span class="repo-owner">{owner_name}</span><span class="repo-separator">/</span>{repo_name}</h1>
        \\  </div>
        \\  <div class="repo-actions">
        \\    <span class="branch-pill">{ref}</span>
    , .{
        .owner_name = owner_name,
        .repo_name = repo_name,
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

pub fn renderIndexingPageIfStale(
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
    return_target: []const u8,
) !?[]u8 {
    if (index.isIndexFresh(allocator, repo) catch false) return null;
    return try renderIndexingPopoverPage(allocator, repo, title, active, return_target);
}

fn renderIndexingPopoverPage(
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
        \\<section class="indexing-popover" role="dialog" aria-modal="false" aria-labelledby="indexing-popover-title" data-index-popover>
        \\  <div class="indexing-cue">
        \\    <span class="index-spinner-wrap" aria-hidden="true"><span class="index-spinner"></span></span>
        \\    <div class="indexing-copy">
        \\      <p class="eyebrow">Index refresh</p>
        \\      <h2 id="indexing-popover-title">Updating Gitomi index</h2>
        \\      <p class="muted">Reading Gitomi events and refreshing local projections. This page will continue automatically.</p>
        \\      <p class="indexing-status" role="status" aria-live="polite" data-index-status>Starting index rebuild...</p>
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
        \\  var status = document.querySelector("[data-index-status]");
        \\  var startedAt = Date.now();
        \\  var messages = [
        \\    [0, "Starting index rebuild..."],
        \\    [1500, "Scanning Gitomi refs and snapshots..."],
        \\    [5000, "Replaying imported events into the local projection..."],
        \\    [15000, "Still indexing. Large imports can take a few minutes."],
        \\    [45000, "Still working. The page will open automatically when the index is ready."]
        \\  ];
        \\  function statusText(base) {
        \\    var seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
        \\    return base + " " + seconds + "s elapsed.";
        \\  }
        \\  function updateStatus() {
        \\    if (!status) return;
        \\    var elapsed = Date.now() - startedAt;
        \\    var text = messages[0][1];
        \\    for (var i = 0; i < messages.length; i += 1) {
        \\      if (elapsed >= messages[i][0]) text = messages[i][1];
        \\    }
        \\    status.textContent = statusText(text);
        \\  }
        \\  updateStatus();
        \\  var statusTimer = window.setInterval(updateStatus, 2500);
        \\  fetch("/index/rebuild", { cache: "no-store" }).then(function (response) {
        \\    if (!response.ok) throw new Error("index rebuild failed");
        \\    window.clearInterval(statusTimer);
        \\    if (status) status.textContent = "Index ready. Opening page...";
        \\    window.location.replace(next);
        \\  }).catch(function () {
        \\    window.clearInterval(statusTimer);
        \\    if (status) status.textContent = "Index update did not finish. Retrying...";
        \\    setTimeout(function () { window.location.reload(); }, 2500);
        \\  });
        \\}());
        \\</script>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn paginationFromTarget(allocator: Allocator, target: []const u8, default_per_page: usize, max_per_page: usize) !Pagination {
    const page_value = try queryValueOwned(allocator, target, "page");
    defer if (page_value) |value| allocator.free(value);
    const per_page_value = try queryValueOwned(allocator, target, "per_page");
    defer if (per_page_value) |value| allocator.free(value);

    const per_page = parsePositiveQueryUsize(per_page_value, default_per_page, max_per_page);
    return .{
        .page = parsePositiveQueryUsize(page_value, 1, 1_000_000),
        .per_page = per_page,
    };
}

fn parsePositiveQueryUsize(raw: ?[]const u8, fallback: usize, max_value: usize) usize {
    const value = raw orelse return fallback;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return fallback;
    if (parsed == 0) return fallback;
    return @min(parsed, max_value);
}

pub fn appendPaginationQueryParams(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    first: *bool,
    pagination: Pagination,
    page: usize,
    default_per_page: usize,
) !void {
    if (page > 1) {
        var page_buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&page_buf, "{d}", .{page});
        try appendQueryParam(buf, allocator, first, "page", value);
    }
    if (pagination.per_page != default_per_page) {
        var per_page_buf: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&per_page_buf, "{d}", .{pagination.per_page});
        try appendQueryParam(buf, allocator, first, "per_page", value);
    }
}

pub fn appendQueryParam(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, name: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, if (first.*) "?" else "&amp;");
    first.* = false;
    try appendUrlEncoded(buf, allocator, name);
    try buf.append(allocator, '=');
    try appendUrlEncoded(buf, allocator, value);
}

pub fn appendPaginationNav(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    aria_label: []const u8,
    summary: []const u8,
    previous_href: ?[]const u8,
    next_href: ?[]const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="pagination" aria-label="{aria_label}">
        \\  <span class="pagination-summary">{summary}</span>
        \\  <span class="pagination-actions">
    , .{
        .aria_label = aria_label,
        .summary = summary,
    });
    try appendPaginationAction(buf, allocator, "Previous", previous_href);
    try appendPaginationAction(buf, allocator, "Next", next_href);
    try buf.appendSlice(allocator,
        \\  </span>
        \\</nav>
    );
}

fn appendPaginationAction(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, href: ?[]const u8) !void {
    if (href) |value| {
        try buf.appendSlice(allocator, "<a class=\"button secondary pagination-link\" href=\"");
        try buf.appendSlice(allocator, value);
        try appendTemplate(buf, allocator, "\">{label}</a>", .{ .label = label });
    } else {
        try appendTemplate(buf, allocator, "<span class=\"button secondary pagination-link disabled\" aria-disabled=\"true\">{label}</span>", .{ .label = label });
    }
}

pub fn paginationSummaryOwned(allocator: Allocator, pagination: Pagination, shown: usize, total: ?usize) ![]u8 {
    if (shown == 0) return std.fmt.allocPrint(allocator, "Page {d}", .{pagination.page});
    const first = pagination.offset() + 1;
    const last = pagination.offset() + shown;
    if (total) |value| {
        return std.fmt.allocPrint(allocator, "Showing {d}-{d} of {d}", .{ first, last, value });
    }
    return std.fmt.allocPrint(allocator, "Showing {d}-{d}", .{ first, last });
}

pub fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var fields = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const raw_key = field[0..equals];
        const raw_value = if (equals < field.len) field[equals + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < value.len) {
            const decoded = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch null;
            if (decoded) |byte| {
                try out.append(allocator, byte);
                i += 3;
            } else {
                try out.append(allocator, c);
                i += 1;
            }
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn loadWebStats(allocator: Allocator, repo: Repo) !WebStats {
    var stats = WebStats{};
    stats.inbox_refs = countRefsWithPrefix(allocator, "refs/gitomi/inbox") catch 0;
    stats.staged_refs = countRefsWithPrefix(allocator, "refs/gitomi/staging") catch 0;

    if (!(index.isIndexFresh(allocator, repo) catch false)) return stats;
    stats.events = countIndexedEvents(allocator, repo) catch 0;
    stats.issues = index.countOpenIssues(allocator, repo) catch 0;
    stats.pulls = index.countOpenPulls(allocator, repo) catch 0;
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

test "markdownTaskSummary counts tasks outside fenced code blocks" {
    const summary = markdownTaskSummary(
        \\- [ ] Open task
        \\- [x] Done task
        \\  - [X] Nested done task
        \\1. [ ] Ordered task
        \\```
        \\- [x] Ignored task
        \\```
        \\Paragraph
    );

    try std.testing.expectEqual(@as(usize, 4), summary.total);
    try std.testing.expectEqual(@as(usize, 2), summary.done);
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

test "web pagination query parsing and params clamp values" {
    const pagination = try paginationFromTarget(std.testing.allocator, "/issues?page=3&per_page=250", 25, 100);
    try std.testing.expectEqual(@as(usize, 3), pagination.page);
    try std.testing.expectEqual(@as(usize, 100), pagination.per_page);
    try std.testing.expectEqual(@as(usize, 200), pagination.offset());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var first = true;
    try appendQueryParam(&buf, std.testing.allocator, &first, "state", "open");
    try appendPaginationQueryParams(&buf, std.testing.allocator, &first, pagination, 4, 25);
    try std.testing.expectEqualStrings("?state=open&amp;page=4&amp;per_page=100", buf.items);
}

test "web detail back button renders accessible icon link" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendDetailBackButton(&buf, std.testing.allocator, literalHref("/issues"), "Back to issues");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "class=\"detail-back-button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "aria-label=\"Back to issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "icon-arrow-left") != null);
}

test "web avatar renders vendored nouns asset svg" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendAvatar(&buf, std.testing.allocator, "A&B <user>", "extra");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nouns-avatar-svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "title=\"A&amp;B &lt;user&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "viewBox=\"0 0 320 320\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<rect width=\"100%\" height=\"100%\" fill=\"#") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<rect width=\"") != null);
}

test "web issue linked text autolinks legacy and hash references" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendIssueLinkedText(&buf, std.testing.allocator, "Refs #42, #A1B2C3D, not #abc, #abcdef0g, or #018f0000-uuid.");

    try std.testing.expectEqualStrings("Refs <a href=\"/issues/42\">#42</a>, <a href=\"/issues/A1B2C3D\">#A1B2C3D</a>, not #abc, #abcdef0g, or #018f0000-uuid.", buf.items);
}

test "web internal reference linked text prefers work items before commits" {
    const allocator = std.testing.allocator;
    var db = try index.SqliteDb.openWithOptions(allocator, ":memory:", index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE, true, .{ .enable_wal = false });
    var close_db = true;
    defer if (close_db) db.deinit();

    try db.exec(
        \\CREATE TABLE issues(id TEXT NOT NULL);
        \\CREATE TABLE pulls(id TEXT NOT NULL);
        \\CREATE TABLE legacy_aliases(provider TEXT NOT NULL, object_kind TEXT NOT NULL, object_id TEXT NOT NULL, number INTEGER NOT NULL);
        \\INSERT INTO issues(id) VALUES ('issue-object-1');
        \\INSERT INTO pulls(id) VALUES ('pull-object-1');
        \\INSERT INTO legacy_aliases(provider, object_kind, object_id, number) VALUES ('github', 'issue', 'issue-object-1', 42);
        \\INSERT INTO legacy_aliases(provider, object_kind, object_id, number) VALUES ('github', 'pull', 'pull-object-1', 42);
    );

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, "issue-object-1");
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, "pull-object-1");

    var resolver = InternalReferenceResolver{ .allocator = allocator, .db = db };
    close_db = false;
    defer resolver.deinit();

    const input = try std.fmt.allocPrint(allocator, "Issue #{s}, pull #{s}, fallback #abcdef0, legacy #42.", .{ issue_ref, pull_ref });
    defer allocator.free(input);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendInternalReferenceLinkedText(&buf, allocator, &resolver, input);

    const issue_href = try std.fmt.allocPrint(allocator, "href=\"/issues/{s}\"", .{issue_ref});
    defer allocator.free(issue_href);
    const pull_href = try std.fmt.allocPrint(allocator, "href=\"/pulls/{s}\"", .{pull_ref});
    defer allocator.free(pull_href);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, issue_href) != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, pull_href) != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/commit?sha=abcdef0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues/42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/pulls/42\"") == null);
}
