const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const nouns_assets = @import("vendor/nouns-assets/image_data.zig");

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

const WebStats = struct {
    inbox_refs: usize = 0,
    staged_refs: usize = 0,
    events: usize = 0,
    issues: usize = 0,
    pulls: usize = 0,
};

pub const Href = union(enum) {
    literal: []const u8,
    code: PathHref,
    raw: PathHref,
    commits: PathHref,
    blame: PathHref,
    commit: []const u8,
    issue: []const u8,
    pull: []const u8,
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

pub fn issueHref(issue_ref: []const u8) Href {
    return .{ .issue = issue_ref };
}

pub fn pullHref(pull_ref: []const u8) Href {
    return .{ .pull = pull_ref };
}

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

pub fn appendRelativeTime(buf: *std.ArrayList(u8), allocator: Allocator, timestamp: []const u8) !void {
    const label = try relativeTimeLabelOwned(allocator, timestamp);
    defer allocator.free(label);
    try appendTemplate(buf, allocator,
        \\<time datetime="{timestamp}" data-relative-time>{label}</time>
    , .{
        .timestamp = timestamp,
        .label = label,
    });
}

fn relativeTimeLabelOwned(allocator: Allocator, timestamp: []const u8) ![]u8 {
    const parsed = parseRfc3339Timestamp(timestamp) orelse return allocator.dupe(u8, timestamp);
    return relativeDurationOwned(allocator, std.time.timestamp() - parsed);
}

fn relativeDurationOwned(allocator: Allocator, delta_seconds: i64) ![]u8 {
    const future = delta_seconds < -30;
    const seconds = if (delta_seconds < 0) -delta_seconds else delta_seconds;
    if (seconds < 60) return allocator.dupe(u8, if (future) "in less than a minute" else "just now");

    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    const week = 7 * day;
    const month = 30 * day;
    const year = 365 * day;

    if (seconds >= year) return relativeUnitOwned(allocator, future, @divFloor(seconds, year), "year");
    if (seconds >= month) return relativeUnitOwned(allocator, future, @divFloor(seconds, month), "month");
    if (seconds >= week) return relativeUnitOwned(allocator, future, @divFloor(seconds, week), "week");
    if (seconds >= day) return relativeUnitOwned(allocator, future, @divFloor(seconds, day), "day");
    if (seconds >= hour) return relativeUnitOwned(allocator, future, @divFloor(seconds, hour), "hour");
    return relativeUnitOwned(allocator, future, @divFloor(seconds, minute), "minute");
}

fn relativeUnitOwned(allocator: Allocator, future: bool, value: i64, unit: []const u8) ![]u8 {
    if (future) {
        return std.fmt.allocPrint(allocator, "in {d} {s}{s}", .{ value, unit, if (value == 1) "" else "s" });
    }
    return std.fmt.allocPrint(allocator, "{d} {s}{s} ago", .{ value, unit, if (value == 1) "" else "s" });
}

fn parseRfc3339Timestamp(value: []const u8) ?i64 {
    if (value.len < "0000-00-00T00:00:00Z".len) return null;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;

    const year = parseFixedInt(value[0..4]) orelse return null;
    const month = parseFixedInt(value[5..7]) orelse return null;
    const day = parseFixedInt(value[8..10]) orelse return null;
    const hour = parseFixedInt(value[11..13]) orelse return null;
    const minute = parseFixedInt(value[14..16]) orelse return null;
    const second = parseFixedInt(value[17..19]) orelse return null;

    if (year < 1970 or year > 9999) return null;
    if (month < 1 or month > 12) return null;
    const epoch_month: std.time.epoch.Month = @enumFromInt(@as(u4, @intCast(month)));
    const days_in_month: i64 = std.time.epoch.getDaysInMonth(@as(std.time.epoch.Year, @intCast(year)), epoch_month);
    if (day < 1 or day > days_in_month) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var cursor: usize = 19;
    if (cursor < value.len and value[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < value.len and std.ascii.isDigit(value[cursor])) cursor += 1;
        if (cursor == fraction_start) return null;
    }

    const offset_seconds = parseRfc3339Offset(value[cursor..]) orelse return null;
    const local_seconds = daysFromCivil(year, month, day) * @as(i64, std.time.epoch.secs_per_day) + hour * 3600 + minute * 60 + second;
    return local_seconds - offset_seconds;
}

fn parseFixedInt(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn parseRfc3339Offset(value: []const u8) ?i64 {
    if (std.mem.eql(u8, value, "Z")) return 0;
    if (value.len != 6 or value[3] != ':') return null;
    const sign: i64 = switch (value[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const hours = parseFixedInt(value[1..3]) orelse return null;
    const minutes = parseFixedInt(value[4..6]) orelse return null;
    if (hours > 23 or minutes > 59) return null;
    return sign * (hours * 3600 + minutes * 60);
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var adjusted_year = year;
    if (month <= 2) adjusted_year -= 1;
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + if (month > 2) @as(i64, -3) else @as(i64, 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
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

fn isReferenceTrailingIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
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
        \\  <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/devicon.min.css">
        \\  <link rel="stylesheet" href="/vendor/katex/katex.min.css">
        \\  <link rel="stylesheet" href="/style.css">
    , .{});
    try appendShortcutConfigScript(buf, allocator, cfg_opt);
    try appendTemplate(buf, allocator,
        \\</head>
        \\<body>
        \\<header class="topbar">
        \\  <a class="brand" href="/"><img class="brand-logo" src="/logo.svg" alt="" width="47" height="32"><span>{repo_name}</span></a>
        \\  <nav>
    , .{ .repo_name = std.fs.path.basename(repo.root) });
    try appendNavLink(buf, allocator, active, "code", "/", "Code", null);
    try appendNavLink(buf, allocator, active, "commits", "/commits", "Commits", null);
    try appendNavLink(buf, allocator, active, "issues", "/issues", "Issues", stats.issues);
    try appendNavLink(buf, allocator, active, "pulls", "/pulls", "PRs", stats.pulls);
    try appendNavLink(buf, allocator, active, "projects", "/projects", "Projects", null);
    try appendNavLink(buf, allocator, active, "milestones", "/milestones", "Milestones", null);
    try appendNavLink(buf, allocator, active, "access", "/access", "Access", null);
    try appendNavLink(buf, allocator, active, "actions", "/actions", "Actions", null);
    try appendNavLink(buf, allocator, active, "events", "/events", "Events", null);
    try appendNavLink(buf, allocator, active, "refs", "/refs", "Refs", null);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="topbar-actions">
    );
    if (cfg_opt) |cfg| {
        try appendUserMenu(buf, allocator, cfg);
    }
    try appendTemplate(buf, allocator,
        \\  <button class="theme-toggle" type="button" data-theme-toggle aria-pressed="false" aria-label="Toggle dark mode" title="Toggle dark mode">
        \\    <span class="theme-toggle-track" aria-hidden="true"><span class="theme-toggle-thumb"></span></span>
        \\    <span class="theme-toggle-label" data-theme-label>Light</span>
        \\  </button>
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

pub fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "issue-avatar", extra_class, name);
}

fn appendUserAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try appendAvatarContainer(buf, allocator, "user-avatar", "", name);
}

fn appendAvatarContainer(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    base_class: []const u8,
    extra_class: []const u8,
    name: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<span class="{base_class} nouns-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
        .base_class = base_class,
        .extra_class = extra_class,
        .name = name,
    });
    try appendNounsAvatarSvg(buf, allocator, nounsAvatarSeed(name));
    try buf.appendSlice(allocator, "</span>");
}

const NounsAvatarSeed = struct {
    background: usize,
    body: usize,
    accessory: usize,
    head: usize,
    glasses: usize,
};

fn nounsAvatarSeed(name: []const u8) NounsAvatarSeed {
    const hash = fnv1a64(name);
    return .{
        .background = @intCast(hash % nouns_assets.bgcolors.len),
        .body = @intCast((hash >> 8) % nouns_assets.bodies.len),
        .accessory = @intCast((hash >> 20) % nouns_assets.accessories.len),
        .head = @intCast((hash >> 32) % nouns_assets.heads.len),
        .glasses = @intCast((hash >> 48) % nouns_assets.glasses.len),
    };
}

fn fnv1a64(value: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (value) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn appendNounsAvatarSvg(buf: *std.ArrayList(u8), allocator: Allocator, seed: NounsAvatarSeed) !void {
    try appendTemplate(buf, allocator,
        \\<svg class="nouns-avatar-svg" width="320" height="320" viewBox="0 0 320 320" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges">
        \\<rect width="100%" height="100%" fill="#{background}" />
    , .{ .background = nouns_assets.bgcolors[seed.background] });
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.bodies[seed.body]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.accessories[seed.accessory]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.heads[seed.head]);
    try appendNounsAvatarPartSvg(buf, allocator, nouns_assets.glasses[seed.glasses]);
    try buf.appendSlice(allocator,
        \\</svg>
    );
}

fn appendNounsAvatarPartSvg(buf: *std.ArrayList(u8), allocator: Allocator, data: []const u8) !void {
    if (!std.mem.startsWith(u8, data, "0x") or data.len < 12) return error.InvalidNounsAsset;

    const top: u16 = try hexByteAt(data, 4);
    const right: u16 = try hexByteAt(data, 6);
    const left: u16 = try hexByteAt(data, 10);
    if (right <= left) return;

    var current_x: u16 = left;
    var current_y: u16 = top;
    var cursor: usize = 12;
    while (cursor + 4 <= data.len) : (cursor += 4) {
        var draw_length: u16 = try hexByteAt(data, cursor);
        const color_index: usize = try hexByteAt(data, cursor + 2);
        while (draw_length > 0) {
            const length = @min(draw_length, right - current_x);
            if (length == 0) return error.InvalidNounsAsset;
            if (color_index != 0) {
                if (color_index >= nouns_assets.palette.len) return error.InvalidNounsAsset;
                try appendTemplate(buf, allocator,
                    \\<rect width="{width}" height="10" x="{x}" y="{y}" fill="#{color}" />
                , .{
                    .width = length * 10,
                    .x = current_x * 10,
                    .y = current_y * 10,
                    .color = nouns_assets.palette[color_index],
                });
            }
            current_x += length;
            if (current_x == right) {
                current_x = left;
                current_y += 1;
            }
            draw_length -= length;
        }
    }
}

fn hexByteAt(data: []const u8, offset: usize) !u8 {
    if (offset + 2 > data.len) return error.InvalidNounsAsset;
    return std.fmt.parseInt(u8, data[offset .. offset + 2], 16) catch error.InvalidNounsAsset;
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
    try buf.appendSlice(allocator,
        \\</main>
        \\<script src="/theme.js"></script>
        \\<script src="/ui.js"></script>
        \\<script src="/shortcuts.js"></script>
        \\<script src="/tree.js"></script>
        \\<script src="/code.js"></script>
        \\<script src="/vendor/marked/marked.umd.js"></script>
        \\<script src="/vendor/dompurify/purify.min.js"></script>
        \\<script src="/vendor/katex/katex.min.js"></script>
        \\<script src="/vendor/katex/auto-render.min.js"></script>
        \\<script src="/vendor/mermaid/mermaid.min.js"></script>
        \\<script src="/markdown.js"></script>
        \\<script src="/vendor/hljs/all-languages.js"></script>
        \\<script src="/highlight/zig.js"></script>
        \\<script src="/highlight/solidity.js"></script>
        \\<script src="/highlight/tla.js"></script>
        \\<script src="/highlight/init.js"></script>
        \\<script src="/diff.js"></script>
        \\<script src="/merge.js"></script>
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
    @setEvalBranchQuota(10_000);
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
        .issue => |issue_ref| {
            try buf.appendSlice(allocator, "/issues/");
            try appendUrlEncoded(buf, allocator, issue_ref);
        },
        .pull => |pull_ref| {
            try buf.appendSlice(allocator, "/pulls/");
            try appendUrlEncoded(buf, allocator, pull_ref);
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
