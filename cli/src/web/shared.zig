const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const github_live = @import("../providers/github/live.zig");
const index = @import("../index.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const util = @import("../util.zig");
const avatars = @import("shared/avatars.zig");
const html = @import("shared/html.zig");
const response = @import("shared/response.zig");
const time = @import("shared/time.zig");

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
const asset_version = "20260519-root-file-commits";

const WebStats = struct {
    inbox_refs: usize = 0,
    staged_refs: usize = 0,
    events: usize = 0,
    issues: usize = 0,
    pulls: usize = 0,
    unread_notifications: usize = 0,
};

const ShellOptions = struct {
    load_user_role: bool = true,
};

const CurrentUserRole = struct {
    state: State = .not_initialized,
    role: ?[]u8 = null,

    const State = enum {
        not_initialized,
        not_loaded,
        no_role,
        loaded,
        unavailable,
    };

    fn deinit(self: *CurrentUserRole, allocator: Allocator) void {
        if (self.role) |value| allocator.free(value);
        self.* = .{};
    }
};

const TopbarNotificationRow = struct {
    event_hash: []u8,
    object_kind: []u8,
    object_id: []u8,
    event_type: []u8,
    actor_principal: []u8,
    occurred_at: []u8,
    read_at: []u8,
    title: []u8,

    fn deinit(self: *TopbarNotificationRow, allocator: Allocator) void {
        allocator.free(self.event_hash);
        allocator.free(self.object_kind);
        allocator.free(self.object_id);
        allocator.free(self.event_type);
        allocator.free(self.actor_principal);
        allocator.free(self.occurred_at);
        allocator.free(self.read_at);
        allocator.free(self.title);
    }
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
pub const appendAvatarWithUrl = avatars.appendAvatarWithUrl;
pub const appendGitIdentityAvatar = avatars.appendGitIdentityAvatar;
pub const appendAvatarWithIdentity = avatars.appendAvatarWithIdentity;
pub const sendRedirect = response.sendRedirect;
pub const sendPlainResponse = response.sendPlainResponse;
pub const sendResponse = response.sendResponse;
pub const sendBinaryResponse = response.sendBinaryResponse;
const appendUserAvatarFromGitIdentity = avatars.appendUserAvatarFromGitIdentity;

pub const localWriteBlockedMessage =
    "Gitomi blocked this write because the local inbox changed while the action was running. Refresh the page and try again; duplicate submission was not written.";

pub fn writeFailureStatus(err: anyerror) u16 {
    return if (err == CliError.LocalInboxChanged) 409 else 500;
}

pub fn writeFailureReason(err: anyerror) []const u8 {
    return if (err == CliError.LocalInboxChanged) "Conflict" else "Internal Server Error";
}

pub fn writeFailureMessage(err: anyerror, fallback: []const u8) []const u8 {
    return if (err == CliError.LocalInboxChanged) localWriteBlockedMessage else fallback;
}

pub const Button = struct {
    label: []const u8,
    href: Href,
    kind: []const u8 = "secondary",
};

const WorkItemReferenceKind = enum {
    issue,
    pull,
};

const LegacyProviderKind = enum {
    github,
    gitlab,
};

const max_internal_reference_links_per_text: usize = 64;

pub const LegacyReference = struct {
    provider: []u8,
    number: i64,

    pub fn deinit(self: *LegacyReference, allocator: Allocator) void {
        allocator.free(self.provider);
    }
};

pub const LegacyRemoteLinks = struct {
    github_base: ?[]u8 = null,
    gitlab_base: ?[]u8 = null,
    origin_repo_path: ?[]u8 = null,

    pub fn deinit(self: *LegacyRemoteLinks, allocator: Allocator) void {
        if (self.github_base) |value| allocator.free(value);
        if (self.gitlab_base) |value| allocator.free(value);
        if (self.origin_repo_path) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const InternalReferenceResolver = struct {
    allocator: Allocator,
    db: ?index.SqliteDb = null,
    object_refs: ?WorkItemObjectRefIndex = null,
    object_refs_failed: bool = false,

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
        if (self.object_refs) |*object_refs| object_refs.deinit(self.allocator);
        self.object_refs = null;
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
        const refs = (try self.workItemObjectRefs()) orelse return false;
        return refs.contains(kind, token);
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

    fn workItemObjectRefs(self: *InternalReferenceResolver) !?*WorkItemObjectRefIndex {
        if (self.object_refs) |*object_refs| return object_refs;
        if (self.object_refs_failed) return null;

        const db = if (self.db) |*value| value else return null;
        self.object_refs = WorkItemObjectRefIndex.load(self.allocator, db) catch |err| {
            self.object_refs_failed = true;
            return err;
        };
        return &self.object_refs.?;
    }
};

const WorkItemObjectRefIndex = struct {
    issues: ObjectRefList = .{},
    pulls: ObjectRefList = .{},

    fn load(allocator: Allocator, db: *index.SqliteDb) !WorkItemObjectRefIndex {
        var refs: WorkItemObjectRefIndex = .{};
        errdefer refs.deinit(allocator);

        try refs.issues.loadFromTable(allocator, db, "issues");
        try refs.pulls.loadFromTable(allocator, db, "pulls");
        refs.issues.sort();
        refs.pulls.sort();

        return refs;
    }

    fn deinit(self: *WorkItemObjectRefIndex, allocator: Allocator) void {
        self.issues.deinit(allocator);
        self.pulls.deinit(allocator);
    }

    fn contains(self: *const WorkItemObjectRefIndex, kind: WorkItemReferenceKind, token: []const u8) bool {
        return switch (kind) {
            .issue => self.issues.containsPrefix(token),
            .pull => self.pulls.containsPrefix(token),
        };
    }
};

const ObjectRefList = struct {
    refs: std.ArrayList([util.max_object_ref_len]u8) = .empty,

    fn loadFromTable(self: *ObjectRefList, allocator: Allocator, db: *index.SqliteDb, comptime table: []const u8) !void {
        var stmt = try db.prepare("SELECT id FROM " ++ table);
        defer stmt.deinit();

        while (try stmt.step()) {
            const id = try stmt.columnTextDup(allocator, 0);
            defer allocator.free(id);

            var object_ref: [util.max_object_ref_len]u8 = undefined;
            _ = util.objectRefPrefix(object_ref[0..], id);
            try self.refs.append(allocator, object_ref);
        }
    }

    fn sort(self: *ObjectRefList) void {
        std.mem.sort([util.max_object_ref_len]u8, self.refs.items, {}, objectRefLessThan);
    }

    fn containsPrefix(self: *const ObjectRefList, token: []const u8) bool {
        var low: usize = 0;
        var high: usize = self.refs.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (objectRefPrefixLessThanToken(self.refs.items[mid][0..], token)) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low >= self.refs.items.len) return false;
        return asciiStartsWithIgnoreCase(self.refs.items[low][0..], token);
    }

    fn deinit(self: *ObjectRefList, allocator: Allocator) void {
        self.refs.deinit(allocator);
    }
};

fn objectRefLessThan(_: void, a: [util.max_object_ref_len]u8, b: [util.max_object_ref_len]u8) bool {
    return std.mem.lessThan(u8, a[0..], b[0..]);
}

fn objectRefPrefixLessThanToken(object_ref: []const u8, token: []const u8) bool {
    std.debug.assert(object_ref.len >= token.len);
    for (token, 0..) |c, i| {
        const token_c = std.ascii.toLower(c);
        if (object_ref[i] < token_c) return true;
        if (object_ref[i] > token_c) return false;
    }
    return false;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return asciiEqlIgnoreCase(value[0..prefix.len], prefix);
}

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

pub fn appendPullReferenceLink(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8) !void {
    try buf.appendSlice(allocator, "<a href=\"");
    try appendHref(buf, allocator, pullHref(pull_ref));
    try buf.appendSlice(allocator, "\">#");
    try appendHtml(buf, allocator, pull_ref);
    try buf.appendSlice(allocator, "</a>");
}

pub fn appendIssueReferenceText(buf: *std.ArrayList(u8), allocator: Allocator, issue_ref: []const u8) !void {
    try buf.append(allocator, '#');
    try appendHtml(buf, allocator, issue_ref);
}

pub fn appendPullReferenceText(buf: *std.ArrayList(u8), allocator: Allocator, pull_ref: []const u8) !void {
    try buf.append(allocator, '#');
    try appendHtml(buf, allocator, pull_ref);
}

pub fn loadLegacyRemoteLinks(allocator: Allocator, repo: Repo) LegacyRemoteLinks {
    var links: LegacyRemoteLinks = .{};
    var result = git.runCommand(allocator, &.{ "git", "-C", repo.root, "remote", "get-url", "origin" }, null, 512 * 1024) catch return links;
    defer result.deinit();
    if (result.exitCode() != 0) return links;

    const origin_url = std.mem.trim(u8, result.stdout, " \t\r\n");
    const parsed = remoteWebBaseOwned(allocator, origin_url) catch null;
    if (parsed) |web_base| {
        switch (web_base.provider) {
            .github => links.github_base = web_base.base,
            .gitlab => links.gitlab_base = web_base.base,
        }
    }

    if (remoteRepositoryPath(origin_url)) |path| {
        if (isSafeRemotePath(path)) {
            links.origin_repo_path = allocator.dupe(u8, path) catch null;
        }
    }
    return links;
}

fn remoteRepositoryPath(raw_url: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return null;

    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        path = rest[slash + 1 ..];
    } else {
        const at = std.mem.indexOfScalar(u8, url, '@') orelse return null;
        const colon = std.mem.indexOfScalarPos(u8, url, at + 1, ':') orelse return null;
        path = url[colon + 1 ..];
    }

    path = std.mem.trim(u8, path, " /\t\r\n");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    path = std.mem.trimRight(u8, path, "/");
    return if (path.len == 0) null else path;
}

fn legacyFallbackWebBaseFromOriginPathOwned(allocator: Allocator, kind: LegacyProviderKind, path: []const u8) !?[]u8 {
    return switch (kind) {
        .github => {
            if (!looksLikeGithubOwnerRepo(path)) return null;
            return try std.fmt.allocPrint(allocator, "https://www.github.com/{s}", .{path});
        },
        .gitlab => {
            if (!isSafeRemotePath(path)) return null;
            return try std.fmt.allocPrint(allocator, "https://gitlab.com/{s}", .{path});
        },
    };
}

fn looksLikeGithubOwnerRepo(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    const owner = parts.next() orelse return false;
    const repo = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return isSafeRemotePathSegment(owner) and isSafeRemotePathSegment(repo);
}

fn isSafeRemotePath(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (!isSafeRemotePathSegment(part)) return false;
        count += 1;
    }
    return count >= 2;
}

fn isSafeRemotePathSegment(value: []const u8) bool {
    if (value.len == 0 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    return std.mem.indexOfAny(u8, value, " \t\r\n\x00\\?#") == null;
}

pub fn loadLegacyReference(allocator: Allocator, db: *index.SqliteDb, object_kind: []const u8, object_id: []const u8) !?LegacyReference {
    var stmt = try db.prepare(
        \\SELECT provider, number
        \\FROM legacy_aliases
        \\WHERE object_kind = ?
        \\  AND object_id = ?
        \\  AND lower(provider) IN ('github', 'gitlab')
        \\ORDER BY CASE lower(provider)
        \\  WHEN 'github' THEN 0
        \\  WHEN 'gitlab' THEN 1
        \\  ELSE 2
        \\END
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, object_kind);
    try stmt.bindText(2, object_id);
    if (!(try stmt.step())) return null;
    return .{
        .provider = try stmt.columnTextDup(allocator, 0),
        .number = stmt.columnInt64(1),
    };
}

pub fn appendLegacyIssueReference(buf: *std.ArrayList(u8), allocator: Allocator, remote_links: *const LegacyRemoteLinks, provider: []const u8, number: i64) !void {
    try appendLegacyReference(buf, allocator, remote_links, provider, "issue", number);
}

pub fn appendLegacyPullReference(buf: *std.ArrayList(u8), allocator: Allocator, remote_links: *const LegacyRemoteLinks, provider: []const u8, number: i64) !void {
    try appendLegacyReference(buf, allocator, remote_links, provider, "pull", number);
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
    var linked_references: usize = 0;
    while (i < value.len) {
        if (issueReferenceEnd(value, i)) |end| {
            if (linked_references >= max_internal_reference_links_per_text) {
                i = end;
                continue;
            }
            if (plain_start < i) try appendLinkedTextPlainSegment(buf, allocator, value[plain_start..i], default_href);
            try appendInternalReferenceLink(buf, allocator, resolver, value[i + 1 .. end]);
            linked_references += 1;
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

fn appendShellStylesheets(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\  <link rel="stylesheet" href="/vendor/devicon/devicon.min.css?v={asset_version}">
        \\  <link rel="stylesheet" href="/vendor/katex/katex.min.css">
        \\  <link rel="stylesheet" href="/style.css?v={asset_version}">
    , .{ .asset_version = asset_version });
}

fn appendCustomThemeBootstrapScript(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  <script>
        \\    (function () {
        \\      try {
        \\        var css = localStorage.getItem("gitomi.theme.customCss");
        \\        if (!css) return;
        \\        var style = document.createElement("style");
        \\        style.id = "gitomi-custom-theme-tokens";
        \\        style.setAttribute("data-custom-theme-tokens", "");
        \\        style.textContent = css;
        \\        document.head.appendChild(style);
        \\      } catch (_) {}
        \\    }());
        \\  </script>
    );
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

fn appendLegacyReference(buf: *std.ArrayList(u8), allocator: Allocator, remote_links: *const LegacyRemoteLinks, provider: []const u8, object_kind: []const u8, number: i64) !void {
    const label = legacyProviderLabel(provider);
    if (try legacyExternalUrlOwned(allocator, remote_links, provider, object_kind, number)) |external_url| {
        defer allocator.free(external_url);
        try buf.appendSlice(allocator, "<a class=\"legacy-provider-link\" href=\"");
        try appendHref(buf, allocator, literalHref(external_url));
        try buf.appendSlice(allocator, "\" target=\"_blank\" rel=\"noopener noreferrer\" aria-label=\"Open ");
        try appendHtml(buf, allocator, label);
        try buf.append(allocator, ' ');
        try std.fmt.format(buf.writer(allocator), "#{d}", .{number});
        try buf.appendSlice(allocator, " externally\">");
        try appendHtml(buf, allocator, label);
        try std.fmt.format(buf.writer(allocator), "<span class=\"legacy-provider-number\">#{d}</span>", .{number});
        try buf.appendSlice(allocator, "<span class=\"legacy-external-icon\" aria-hidden=\"true\"></span></a>");
        return;
    } else {
        try buf.appendSlice(allocator, "<span class=\"legacy-provider-label\">");
        try appendHtml(buf, allocator, label);
        try buf.appendSlice(allocator, "</span>");
    }
    try buf.append(allocator, ' ');

    const number_ref = try std.fmt.allocPrint(allocator, "{d}", .{number});
    defer allocator.free(number_ref);
    if (std.mem.eql(u8, object_kind, "pull")) {
        try appendPullReferenceLink(buf, allocator, number_ref);
    } else {
        try appendIssueReferenceLink(buf, allocator, number_ref);
    }
}

fn legacyExternalUrlOwned(allocator: Allocator, remote_links: *const LegacyRemoteLinks, provider: []const u8, object_kind: []const u8, number: i64) !?[]u8 {
    if (legacyProviderKind(provider)) |kind| {
        switch (kind) {
            .github => {
                if (remote_links.github_base) |base| return try githubLegacyUrlOwned(allocator, base, object_kind, number);
                if (remote_links.origin_repo_path) |path| {
                    const base = (try legacyFallbackWebBaseFromOriginPathOwned(allocator, kind, path)) orelse return null;
                    defer allocator.free(base);
                    return try githubLegacyUrlOwned(allocator, base, object_kind, number);
                }
            },
            .gitlab => {
                if (remote_links.gitlab_base) |base| return try gitlabLegacyUrlOwned(allocator, base, object_kind, number);
                if (remote_links.origin_repo_path) |path| {
                    const base = (try legacyFallbackWebBaseFromOriginPathOwned(allocator, kind, path)) orelse return null;
                    defer allocator.free(base);
                    return try gitlabLegacyUrlOwned(allocator, base, object_kind, number);
                }
            },
        }
    }
    return null;
}

fn githubLegacyUrlOwned(allocator: Allocator, base: []const u8, object_kind: []const u8, number: i64) ![]u8 {
    const path = if (std.mem.eql(u8, object_kind, "pull")) "pull" else "issues";
    return try std.fmt.allocPrint(allocator, "{s}/{s}/{d}", .{ base, path, number });
}

fn gitlabLegacyUrlOwned(allocator: Allocator, base: []const u8, object_kind: []const u8, number: i64) ![]u8 {
    const path = if (std.mem.eql(u8, object_kind, "pull")) "merge_requests" else "issues";
    return try std.fmt.allocPrint(allocator, "{s}/-/{s}/{d}", .{ base, path, number });
}

fn legacyProviderLabel(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "github")) return "GitHub";
    if (std.ascii.eqlIgnoreCase(provider, "gitlab")) return "GitLab";
    return provider;
}

fn legacyProviderKind(provider: []const u8) ?LegacyProviderKind {
    if (std.ascii.eqlIgnoreCase(provider, "github")) return .github;
    if (std.ascii.eqlIgnoreCase(provider, "gitlab")) return .gitlab;
    return null;
}

const RemoteWebBase = struct {
    provider: LegacyProviderKind,
    base: []u8,
};

fn remoteWebBaseOwned(allocator: Allocator, raw_url: []const u8) !?RemoteWebBase {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return null;

    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const scheme = url[0..scheme_end];
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const authority = rest[0..slash];
        const path = rest[slash + 1 ..];
        const userinfo_end = std.mem.lastIndexOfScalar(u8, authority, '@');
        const host = if (userinfo_end) |idx| authority[idx + 1 ..] else authority;
        const web_scheme = if (std.ascii.eqlIgnoreCase(scheme, "http")) "http" else "https";
        return try remoteWebBaseFromHostPathOwned(allocator, web_scheme, host, path);
    }

    const at = std.mem.indexOfScalar(u8, url, '@') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, url, at + 1, ':') orelse return null;
    return try remoteWebBaseFromHostPathOwned(allocator, "https", url[at + 1 .. colon], url[colon + 1 ..]);
}

fn remoteWebBaseFromHostPathOwned(allocator: Allocator, scheme: []const u8, raw_host: []const u8, raw_path: []const u8) !?RemoteWebBase {
    const host = std.mem.trim(u8, raw_host, " \t\r\n");
    if (host.len == 0) return null;
    const provider = legacyProviderKindForHost(host) orelse return null;
    var path = std.mem.trim(u8, raw_path, " /\t\r\n");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    path = std.mem.trimRight(u8, path, "/");
    if (path.len == 0) return null;
    if (provider == .github) {
        if (!looksLikeGithubOwnerRepo(path)) return null;
    } else if (!isSafeRemotePath(path)) {
        return null;
    }
    const web_host = if (provider == .github and isPublicGithubHost(host)) "www.github.com" else host;
    return .{
        .provider = provider,
        .base = try std.fmt.allocPrint(allocator, "{s}://{s}/{s}", .{ scheme, web_host, path }),
    };
}

fn legacyProviderKindForHost(host: []const u8) ?LegacyProviderKind {
    if (asciiContainsIgnoreCase(host, "github")) return .github;
    if (asciiContainsIgnoreCase(host, "gitlab")) return .gitlab;
    return null;
}

fn isPublicGithubHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "github.com") or std.ascii.eqlIgnoreCase(host, "www.github.com");
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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
    try appendShellStartWithOptions(buf, allocator, repo, title, active, .{});
}

fn appendShellStartWithOptions(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    title: []const u8,
    active: []const u8,
    options: ShellOptions,
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
        \\      var assetVersion =
    );
    try appendJsonString(buf, allocator, asset_version);
    try buf.appendSlice(allocator,
        \\;
        \\      try {
        \\        var storedTheme = localStorage.getItem("gitomi.theme");
        \\        var storedMode = localStorage.getItem("gitomi.themeMode");
        \\        var legacyMode = storedTheme === "light" || storedTheme === "dark" ? storedTheme : null;
        \\        var legacyCustomMode = localStorage.getItem("gitomi.theme.customMode");
        \\        var systemMode = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
        \\        var theme = storedTheme === "capucine" ? "terminal" :
        \\          (storedTheme === "terminal" || storedTheme === "modern" ? storedTheme : "gitomi");
        \\        var mode = storedMode === "light" || storedMode === "dark" ? storedMode :
        \\          legacyMode || (legacyCustomMode === "light" || legacyCustomMode === "dark" ? legacyCustomMode : systemMode);
        \\        document.documentElement.dataset.theme = theme;
        \\        document.documentElement.dataset.themeMode = mode;
        \\        document.documentElement.style.colorScheme = mode;
        \\        window.gitomiThemeAssetVersion = assetVersion;
        \\        document.write('<link id="gitomi-theme-stylesheet" rel="stylesheet" data-theme-stylesheet href="/themes/' + theme + '.css?v=' + encodeURIComponent(assetVersion) + '">');
        \\      } catch (_) {
        \\        document.documentElement.dataset.theme = "gitomi";
        \\        document.documentElement.dataset.themeMode = "light";
        \\        document.write('<link id="gitomi-theme-stylesheet" rel="stylesheet" data-theme-stylesheet href="/themes/gitomi.css?v=' + encodeURIComponent(assetVersion) + '">');
        \\      }
        \\    }());
        \\  </script>
        \\  <title>
    );
    try appendHtml(buf, allocator, title);
    try buf.appendSlice(allocator,
        \\ - Gitomi</title>
        \\  <link rel="icon" href="/logo.svg" type="image/svg+xml">
    );
    try appendShellStylesheets(buf, allocator);
    try appendCustomThemeBootstrapScript(buf, allocator);
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
    try appendNavLink(buf, allocator, active, "actions", "/pipelines", "Pipelines", "icon-workflow", null);
    try appendNavLink(buf, allocator, active, "projects", "/projects", "Projects", "icon-projects", null);
    try appendSettingsNavLink(buf, allocator, active);
    try buf.appendSlice(allocator,
        \\  </nav>
        \\  <div class="topbar-actions">
    );
    try appendTopbarSyncMenu(buf, allocator, topbarSyncProminent(active));
    const topbar_principal: ?[]const u8 = if (cfg_opt) |cfg| cfg.principal else null;
    try appendTopbarInboxMenu(buf, allocator, repo, topbar_principal, stats.unread_notifications);
    try buf.appendSlice(allocator,
        \\  <div class="topbar-account-area" role="group" aria-label="Account and status">
    );
    try appendLiveModeControl(buf, allocator, github_live.runtimeStatus());
    try appendTemplate(buf, allocator,
        \\  <button class="theme-toggle" type="button" data-theme-toggle aria-pressed="false" aria-label="Toggle dark mode" title="Toggle dark mode">
        \\    <span class="button-icon theme-toggle-icon theme-toggle-icon-light icon-sun" aria-hidden="true"></span>
        \\    <span class="button-icon theme-toggle-icon theme-toggle-icon-dark icon-moon" aria-hidden="true"></span>
        \\  </button>
    , .{});
    if (cfg_opt) |cfg| {
        try appendUserMenu(buf, allocator, repo, cfg, options.load_user_role);
    }
    try appendTemplate(buf, allocator,
        \\  </div>
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

fn appendTopbarSyncMenu(buf: *std.ArrayList(u8), allocator: Allocator, prominent: bool) !void {
    try appendTemplate(buf, allocator,
        \\<details class="{classes}" data-popover-menu>
        \\  <summary class="topbar-sync-button" aria-label="Sync Gitomi refs with origin" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span><span class="topbar-sync-label">Sync refs</span><span class="root-caret" aria-hidden="true"></span></summary>
        \\  <form class="root-action-popover root-sync-popover topbar-sync-popover" method="post" action="/code/sync" role="menu">
        \\    <button type="submit" name="action" value="exchange" role="menuitem">Exchange Gitomi refs</button>
        \\    <button type="submit" name="action" value="import" role="menuitem">Import remote Gitomi refs</button>
        \\    <button type="submit" name="action" value="publish" role="menuitem">Publish local Gitomi refs</button>
        \\    <button type="submit" name="action" value="prune" role="menuitem">Prune deleted remote branches</button>
        \\  </form>
        \\</details>
    , .{ .classes = classes("topbar-sync-menu", &.{class("compact", !prominent)}) });
}

fn topbarSyncProminent(active: []const u8) bool {
    return std.mem.eql(u8, active, "code") or
        std.mem.eql(u8, active, "commits") or
        std.mem.eql(u8, active, "refs") or
        std.mem.eql(u8, active, "events") or
        std.mem.eql(u8, active, "labels") or
        std.mem.eql(u8, active, "models") or
        std.mem.eql(u8, active, "access");
}

fn appendTopbarInboxMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    principal: ?[]const u8,
    unread_count: usize,
) !void {
    const empty_rows: []TopbarNotificationRow = &.{};
    var rows: []TopbarNotificationRow = empty_rows;
    var rows_owned = false;
    if (principal) |value| {
        if (index.isIndexFresh(allocator, repo) catch false) {
            if (loadTopbarNotificationRows(allocator, repo, value, 5) catch null) |loaded| {
                rows = loaded;
                rows_owned = true;
            }
        }
    }
    defer if (rows_owned) freeTopbarNotificationRows(allocator, rows);

    try buf.appendSlice(allocator,
        \\<details class="topbar-inbox-menu" data-popover-menu>
        \\  <summary class="topbar-inbox-button" aria-label="Inbox" title="Inbox">
        \\    <span class="button-icon icon-history" aria-hidden="true"></span>
    );
    if (unread_count != 0) {
        try appendTemplate(buf, allocator,
            \\    <span class="topbar-inbox-count">{count}</span>
        , .{ .count = unread_count });
    }
    try buf.appendSlice(allocator,
        \\  </summary>
        \\  <div class="topbar-inbox-popover" role="menu">
        \\    <div class="topbar-inbox-head">
        \\      <strong>Inbox</strong>
        \\      <span>
    );
    if (unread_count == 0) {
        try buf.appendSlice(allocator, "No unread");
    } else {
        try appendTemplate(buf, allocator, "{count} unread", .{ .count = unread_count });
    }
    try buf.appendSlice(allocator,
        \\</span>
        \\    </div>
    );
    if (principal == null) {
        try buf.appendSlice(allocator,
            \\    <div class="topbar-inbox-empty">Initialize Gitomi to use notifications.</div>
        );
    } else if (rows.len == 0) {
        try buf.appendSlice(allocator,
            \\    <div class="topbar-inbox-empty">No notifications.</div>
        );
    } else {
        for (rows) |row| try appendTopbarNotificationRow(buf, allocator, row);
    }
    try buf.appendSlice(allocator,
        \\    <a class="topbar-inbox-all" href="/inbox" role="menuitem">Open inbox</a>
        \\  </div>
        \\</details>
    );
}

fn appendTopbarNotificationRow(buf: *std.ArrayList(u8), allocator: Allocator, row: TopbarNotificationRow) !void {
    const href = if (std.mem.eql(u8, row.object_kind, "pull"))
        pullHref(row.object_id)
    else
        issueHref(row.object_id);
    const kind_label = if (std.mem.eql(u8, row.object_kind, "pull")) "PR" else "Issue";
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, row.object_id);
    try appendTemplate(buf, allocator,
        \\    <a class="topbar-inbox-row {read_class}" href="{href}" role="menuitem">
        \\      <span class="topbar-inbox-row-kicker">{kind_label} #{object_ref}</span>
        \\      <strong>{title}</strong>
        \\      <span class="topbar-inbox-row-meta">{event_type} by {actor}</span>
        \\      <span class="topbar-inbox-row-time">
    , .{
        .read_class = if (row.read_at.len == 0) "unread" else "read",
        .href = href,
        .kind_label = kind_label,
        .object_ref = object_ref,
        .title = if (row.title.len == 0) row.event_type else row.title,
        .event_type = row.event_type,
        .actor = row.actor_principal,
    });
    try appendRelativeTime(buf, allocator, row.occurred_at);
    try buf.appendSlice(allocator,
        \\</span>
        \\    </a>
    );
}

fn appendLiveModeControl(buf: *std.ArrayList(u8), allocator: Allocator, status: github_live.RuntimeStatus) !void {
    if (!status.available) {
        try appendTemplate(buf, allocator,
            \\<span class="live-mode-control unavailable" title="Start gt web with --live to enable live mode" aria-label="Live mode unavailable">
            \\  <span class="live-mode-dot" aria-hidden="true"></span>
            \\  <span class="live-mode-label">Live</span>
            \\  <span class="live-mode-track" aria-hidden="true"><span class="live-mode-thumb"></span></span>
            \\</span>
        , .{});
        return;
    }

    const next_value = if (status.active) "false" else "true";
    const pressed = if (status.active) "true" else "false";
    const state_class = if (status.active) "active" else "inactive";
    const title = if (status.active) "Turn live mode off" else "Turn live mode on";
    try appendTemplate(buf, allocator,
        \\<form class="live-mode-control {state_class}" method="post" action="/live-mode" title="{title}">
        \\  <input type="hidden" name="enabled" value="{next_value}">
        \\  <button class="live-mode-switch" type="submit" aria-pressed="{pressed}" aria-label="{title}">
        \\    <span class="live-mode-dot" aria-hidden="true"></span>
        \\    <span class="live-mode-label">Live</span>
        \\    <span class="live-mode-track" aria-hidden="true"><span class="live-mode-thumb"></span></span>
        \\  </button>
        \\</form>
    , .{
        .state_class = state_class,
        .title = title,
        .next_value = next_value,
        .pressed = pressed,
    });
}

fn appendUserMenu(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, cfg: Config, load_user_role: bool) !void {
    const git_user_name = try gitUserNameOwned(allocator);
    defer if (git_user_name) |value| allocator.free(value);
    const git_user_email = try gitUserEmailOwned(allocator);
    defer if (git_user_email) |value| allocator.free(value);
    const display_name = git_user_name orelse cfg.principal;
    const display_email = git_user_email orelse cfg.principal;
    const avatar_url = try identityAvatarUrlForCurrentUserOwned(allocator, cfg.principal, git_user_name, git_user_email);
    defer if (avatar_url) |value| allocator.free(value);
    var current_role = try currentUserRbacRoleOwned(allocator, repo, cfg, load_user_role);
    defer current_role.deinit(allocator);
    try appendTemplate(buf, allocator,
        \\<details class="user-menu" data-popover-menu>
        \\  <summary aria-label="User menu">
    , .{});
    try appendUserAvatarFromGitIdentity(buf, allocator, display_name, display_email, avatar_url orelse "");
    try appendTemplate(buf, allocator,
        \\    <span class="user-menu-label"><strong>{display_name}</strong><span>{device}</span></span>
        \\  </summary>
        \\  <div class="user-menu-popover" role="menu">
        \\    <div class="user-menu-section">
        \\      <span class="user-menu-kicker">User</span>
        \\      <strong>{display_name}</strong>
        \\      <span>{principal}</span>
        \\      <span>{device}</span>
        \\    </div>
        \\    <div class="user-menu-section">
        \\      <span class="user-menu-kicker">Repository ID</span>
        \\      <code>{repo_id}</code>
        \\    </div>
    , .{
        .display_name = display_name,
        .principal = cfg.principal,
        .device = cfg.device,
        .repo_id = cfg.repo_id,
    });
    try appendCurrentUserRoleSection(buf, allocator, current_role);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</details>
    );
}

fn appendCurrentUserRoleSection(buf: *std.ArrayList(u8), allocator: Allocator, current_role: CurrentUserRole) !void {
    switch (current_role.state) {
        .not_initialized,
        .not_loaded,
        => return,
        .loaded => {
            const role = current_role.role orelse return;
            try appendTemplate(buf, allocator,
                \\    <div class="user-menu-section">
                \\      <span class="user-menu-kicker">RBAC Role</span>
                \\      <span><span class="access-role-pill user-menu-role-pill">{role}</span></span>
                \\    </div>
            , .{ .role = role });
        },
        .no_role => {
            try buf.appendSlice(allocator,
                \\    <div class="user-menu-section">
                \\      <span class="user-menu-kicker">RBAC Role</span>
                \\      <span class="user-menu-role-muted">No role</span>
                \\    </div>
            );
        },
        .unavailable => {
            try buf.appendSlice(allocator,
                \\    <div class="user-menu-section">
                \\      <span class="user-menu-kicker">RBAC Role</span>
                \\      <span class="user-menu-role-muted">Unavailable</span>
                \\    </div>
            );
        },
    }
}

fn currentUserRbacRoleOwned(allocator: Allocator, repo: Repo, cfg: Config, load_user_role: bool) !CurrentUserRole {
    const genesis_oid = git.resolveOptionalRef(allocator, repo_mod.genesis_ref) catch return .{ .state = .unavailable };
    defer if (genesis_oid) |oid| allocator.free(oid);
    if (genesis_oid == null) return .{ .state = .not_initialized };
    if (!load_user_role) return .{ .state = .not_loaded };

    const role = index.roleForPrincipal(allocator, repo, cfg.principal) catch return .{ .state = .unavailable };
    if (role) |value| return .{ .state = .loaded, .role = value };
    return .{ .state = .no_role };
}

pub fn appendCurrentActorAvatar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    current_actor: ?[]const u8,
    extra_class: []const u8,
) !void {
    const label = current_actor orelse "Current user";
    const git_user_name = try gitUserNameOwned(allocator);
    defer if (git_user_name) |value| allocator.free(value);
    const git_user_email = try gitUserEmailOwned(allocator);
    defer if (git_user_email) |value| allocator.free(value);
    const display_name = git_user_name orelse label;
    const display_email = git_user_email orelse label;
    const avatar_url = try identityAvatarUrlForCurrentUserOwned(allocator, label, git_user_name, git_user_email);
    defer if (avatar_url) |value| allocator.free(value);
    try appendGitIdentityAvatar(buf, allocator, display_name, display_email, avatar_url orelse "", extra_class);
}

pub fn appendResolvedGitIdentityAvatar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    email: []const u8,
    extra_class: []const u8,
) !void {
    const avatar_url = try identityAvatarUrlForGitIdentityOwned(allocator, name, email);
    defer if (avatar_url) |value| allocator.free(value);
    try appendGitIdentityAvatar(buf, allocator, name, email, avatar_url orelse "", extra_class);
}

pub const LocalDisplayIdentity = struct {
    allocator: Allocator,
    name: ?[]u8 = null,
    email: ?[]u8 = null,

    pub fn deinit(self: *LocalDisplayIdentity) void {
        const allocator = self.allocator;
        if (self.name) |value| self.allocator.free(value);
        if (self.email) |value| self.allocator.free(value);
        self.* = .{ .allocator = allocator };
    }

    pub fn displayNameFor(self: LocalDisplayIdentity, actor: []const u8) []const u8 {
        if (self.name) |name| {
            if (self.email) |email| {
                if (std.ascii.eqlIgnoreCase(actor, email)) return name;
            }
        }
        return actor;
    }
};

pub fn loadLocalDisplayIdentity(allocator: Allocator) !LocalDisplayIdentity {
    var identity = LocalDisplayIdentity{ .allocator = allocator };
    errdefer identity.deinit();
    identity.name = try gitUserNameOwned(allocator);
    identity.email = try gitUserEmailOwned(allocator);
    return identity;
}

fn gitUserNameOwned(allocator: Allocator) !?[]u8 {
    const output = gitChecked(allocator, &.{ "config", "user.name" }) catch return null;
    defer allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn gitUserEmailOwned(allocator: Allocator) !?[]u8 {
    const output = gitChecked(allocator, &.{ "config", "user.email" }) catch return null;
    defer allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn identityAvatarUrlForGitIdentityOwned(allocator: Allocator, name: []const u8, email: []const u8) !?[]u8 {
    if (try identityAvatarUrlForAliasOwned(allocator, name)) |avatar_url| return avatar_url;
    return try identityAvatarUrlForAliasOwned(allocator, email);
}

fn identityAvatarUrlForCurrentUserOwned(allocator: Allocator, principal: []const u8, git_user_name: ?[]const u8, git_user_email: ?[]const u8) !?[]u8 {
    if (git_user_name) |value| {
        if (try identityAvatarUrlForAliasOwned(allocator, value)) |avatar_url| return avatar_url;
    }
    if (git_user_email) |value| {
        if (try identityAvatarUrlForAliasOwned(allocator, value)) |avatar_url| return avatar_url;
    }
    return try identityAvatarUrlForAliasOwned(allocator, principal);
}

fn identityAvatarUrlForAliasOwned(allocator: Allocator, alias: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, alias, " \t\r\n");
    if (trimmed.len == 0) return null;

    var repo = repo_mod.discoverRepo(allocator) catch return null;
    defer repo.deinit();
    if (!(index.isIndexFresh(allocator, repo) catch false)) return null;

    var db = index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false) catch return null;
    defer db.deinit();
    var stmt = db.prepare(
        \\SELECT i.avatar_url
        \\FROM identity_aliases a
        \\JOIN identities i ON i.id = a.identity_id
        \\WHERE lower(a.alias_value) = lower(?) AND i.avatar_url <> ''
        \\ORDER BY CASE a.alias_kind WHEN 'display' THEN 0 WHEN 'email' THEN 1 ELSE 2 END
        \\LIMIT 1
    ) catch return null;
    defer stmt.deinit();
    try stmt.bindText(1, trimmed);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
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
        \\<script src="/fuzzy-search.js?v={asset_version}"></script>
        \\<script src="/tree.js?v={asset_version}"></script>
        \\<script src="/code.js?v={asset_version}"></script>
        \\<script src="/pdf.js?v={asset_version}"></script>
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
    return std.mem.eql(u8, active, "theme") or std.mem.eql(u8, active, "models") or std.mem.eql(u8, active, "events") or std.mem.eql(u8, active, "access");
}

pub fn appendSettingsLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator, active: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-page-layout settings-page-layout">
        \\  <aside class="project-page-sidebar settings-page-sidebar">
        \\    <nav class="project-page-tabs settings-page-tabs" aria-label="Settings sections">
    );
    try appendSettingsTab(buf, allocator, active, "events", "/events", "icon-history", "Activity");
    try appendSettingsTab(buf, allocator, active, "theme", "/settings/theme", "icon-theme", "Theme");
    try appendSettingsTab(buf, allocator, active, "models", "/settings/models", "icon-models", "AI Models");
    try appendSettingsTab(buf, allocator, active, "access", "/access", "icon-users", "Access");
    try buf.appendSlice(allocator,
        \\    </nav>
        \\  </aside>
        \\  <div class="project-page-content settings-page-content">
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

pub fn appendWorkItemsLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator, active: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<div class="project-page-layout work-items-layout">
        \\  <aside class="project-page-sidebar work-items-sidebar">
        \\    <nav class="project-page-tabs work-items-tabs" aria-label="Work item sections">
    );
    try appendWorkItemsTab(buf, allocator, active, "issues", "/issues", "icon-issues", "Issues");
    try appendWorkItemsTab(buf, allocator, active, "pulls", "/pulls", "icon-pull-request", "Pull Requests");
    try buf.appendSlice(allocator, "<hr class=\"work-items-tabs-separator\" aria-hidden=\"true\">");
    try appendWorkItemsTab(buf, allocator, active, "labels", "/labels", "icon-labels", "Labels");
    try buf.appendSlice(allocator,
        \\    </nav>
        \\  </aside>
        \\  <div class="project-page-content work-items-content">
    );
}

pub fn appendWorkItemsLayoutEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
    );
}

fn appendWorkItemsTab(
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

    const progress_degrees = markdownTaskProgressDegrees(summary);
    try appendTemplate(buf, allocator,
        \\<span class="issue-task-progress" title="{done} of {total} tasks done" style="--issue-task-progress: {progress_degrees}deg"><span class="issue-task-progress-icon" aria-hidden="true"></span>
    , .{
        .done = summary.done,
        .total = summary.total,
        .progress_degrees = progress_degrees,
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

fn markdownTaskProgressDegrees(summary: MarkdownTaskSummary) usize {
    if (summary.total == 0) return 0;
    const done = @min(summary.done, summary.total);
    return (done * 360 + summary.total / 2) / summary.total;
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
        \\      <div class="markdown-editor-head">
        \\        <div class="markdown-editor-tabs" role="tablist" aria-label="Markdown editor mode">
        \\          <button class="active" type="button" role="tab" aria-selected="true" data-markdown-tab="write">Write</button>
        \\          <button type="button" role="tab" aria-selected="false" data-markdown-tab="preview">Preview</button>
        \\        </div>
        \\        <div class="markdown-editor-toolbar" aria-label="Markdown formatting">
        \\          <button type="button" data-markdown-action="heading" aria-label="Heading" title="Heading">H</button>
        \\          <button type="button" data-markdown-action="bold" aria-label="Bold" title="Bold"><strong>B</strong></button>
        \\          <button type="button" data-markdown-action="italic" aria-label="Italic" title="Italic"><em>I</em></button>
        \\          <button type="button" data-markdown-action="quote" aria-label="Quote" title="Quote"><span class="md-icon md-icon-quote" aria-hidden="true"></span></button>
        \\          <button type="button" data-markdown-action="code" aria-label="Code" title="Code"><span class="md-icon md-icon-code" aria-hidden="true"></span></button>
        \\          <button type="button" data-markdown-action="link" aria-label="Link" title="Link"><span class="md-icon md-icon-link" aria-hidden="true"></span></button>
        \\          <span class="markdown-editor-divider" aria-hidden="true"></span>
        \\          <button type="button" data-markdown-action="unordered-list" aria-label="Bulleted list" title="Bulleted list"><span class="md-icon md-icon-ul" aria-hidden="true"></span></button>
        \\          <button type="button" data-markdown-action="ordered-list" aria-label="Numbered list" title="Numbered list"><span class="md-icon md-icon-ol" aria-hidden="true"></span></button>
        \\          <button type="button" data-markdown-action="task-list" aria-label="Task list" title="Task list"><span class="md-icon md-icon-task" aria-hidden="true"></span></button>
        \\          <span class="markdown-editor-divider" aria-hidden="true"></span>
        \\          <button type="button" data-markdown-action="mention" aria-label="Mention" title="Mention">@</button>
        \\          <button type="button" data-markdown-action="reference" aria-label="Issue reference" title="Issue reference">#</button>
    , .{});
    try appendTemplate(buf, allocator,
        \\        </div>
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
    _ = href;
    try appendTemplate(buf, allocator,
        \\<nav class="detail-back-nav" aria-label="Detail navigation"><button class="detail-back-button" type="button" data-history-back aria-label="{label}" title="{label}"><span class="button-icon icon-arrow-left" aria-hidden="true"></span></button></nav>
    , .{
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

    try appendShellStartWithOptions(&buf, allocator, repo, title, active, .{ .load_user_role = false });
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
        \\  var popover = document.querySelector("[data-index-popover]");
        \\  function restorePreviousView() {
        \\    if (!popover) return;
        \\    try {
        \\      var storage = window.sessionStorage;
        \\      if (!storage) return;
        \\      var raw = storage.getItem("gitomi.indexViewSnapshot.v1");
        \\      if (!raw) return;
        \\      var snapshot = JSON.parse(raw);
        \\      if (!snapshot || snapshot.version !== 1 || !snapshot.header || !snapshot.main) return;
        \\      var headerTemplate = document.createElement("template");
        \\      headerTemplate.innerHTML = snapshot.header;
        \\      var restoredHeader = headerTemplate.content.firstElementChild;
        \\      var mainTemplate = document.createElement("template");
        \\      mainTemplate.innerHTML = snapshot.main;
        \\      var restoredMain = mainTemplate.content.firstElementChild;
        \\      if (!restoredHeader || !restoredHeader.matches(".topbar")) return;
        \\      if (!restoredMain || !restoredMain.matches("main.page")) return;
        \\      var header = document.querySelector(".topbar");
        \\      var main = document.querySelector("main.page");
        \\      if (header) header.replaceWith(restoredHeader);
        \\      if (main) {
        \\        Array.from(main.attributes).forEach(function (attribute) {
        \\          main.removeAttribute(attribute.name);
        \\        });
        \\        Array.from(restoredMain.attributes).forEach(function (attribute) {
        \\          main.setAttribute(attribute.name, attribute.value);
        \\        });
        \\        main.innerHTML = restoredMain.innerHTML;
        \\      }
        \\      document.body.className = snapshot.bodyClass || "";
        \\      document.title = snapshot.title || document.title;
        \\      (document.querySelector("main.page") || document.body).appendChild(popover);
        \\      if (typeof snapshot.url === "string" && snapshot.url.charAt(0) === "/" && snapshot.url.charAt(1) !== "/" && window.history && window.history.replaceState) {
        \\        window.history.replaceState(null, "", snapshot.url);
        \\      }
        \\      var restoreScroll = function () {
        \\        window.scrollTo(Number(snapshot.scrollX) || 0, Number(snapshot.scrollY) || 0);
        \\      };
        \\      if (window.requestAnimationFrame) window.requestAnimationFrame(restoreScroll);
        \\      else restoreScroll();
        \\    } catch (_) {}
        \\  }
        \\  restorePreviousView();
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
    if (previous_href == null and next_href == null) return;

    try appendTemplate(buf, allocator,
        \\<nav class="pagination" aria-label="{aria_label}">
        \\  <span class="pagination-summary">{summary}</span>
        \\  <span class="pagination-actions">
    , .{
        .aria_label = aria_label,
        .summary = summary,
    });
    if (previous_href) |href| try appendPaginationAction(buf, allocator, "Previous", href);
    if (next_href) |href| try appendPaginationAction(buf, allocator, "Next", href);
    try buf.appendSlice(allocator,
        \\  </span>
        \\</nav>
    );
}

fn appendPaginationAction(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, href: []const u8) !void {
    try buf.appendSlice(allocator, "<a class=\"button secondary pagination-link\" href=\"");
    try buf.appendSlice(allocator, href);
    try appendTemplate(buf, allocator, "\">{label}</a>", .{ .label = label });
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
    return formValueOwned(allocator, target[query_start + 1 ..], wanted_key);
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

pub fn formValuesOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !std.ArrayList([]u8) {
    var values: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStringList(allocator, &values);

    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        const value = try percentDecodeForm(allocator, raw_value);
        errdefer allocator.free(value);
        try values.append(allocator, value);
    }

    return values;
}

pub fn isSafeReturnTarget(value: []const u8, allowed_prefix: []const u8) bool {
    if (value.len == 0 or allowed_prefix.len == 0) return false;
    if (allowed_prefix[0] != '/') return false;
    if (value[0] != '/') return false;
    if (value.len > 1 and value[1] == '/') return false;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return false;
    if (!std.mem.startsWith(u8, value, allowed_prefix)) return false;
    if (value.len == allowed_prefix.len) return true;
    return value[allowed_prefix.len] == '?' or value[allowed_prefix.len] == '/';
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

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn freeOwnedStringList(allocator: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |item| allocator.free(item);
    values.deinit(allocator);
}

test "web form decoding handles spaces and escapes" {
    const decoded = try percentDecodeForm(std.testing.allocator, "hello+local%2Fworld%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello local/world!", decoded);

    const value = (try formValueOwned(std.testing.allocator, "title=First+issue&labels=bug%2Cdocs", "labels")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("bug,docs", value);
}

test "web form values returns all matching fields" {
    var values = try formValuesOwned(std.testing.allocator, "issue=one&ignored=1&issue=two%203", "issue");
    defer freeOwnedStringList(std.testing.allocator, &values);

    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("one", values.items[0]);
    try std.testing.expectEqualStrings("two 3", values.items[1]);
}

test "web return targets stay under allowed prefixes" {
    try std.testing.expect(isSafeReturnTarget("/issues", "/issues"));
    try std.testing.expect(isSafeReturnTarget("/issues?state=open", "/issues"));
    try std.testing.expect(isSafeReturnTarget("/issues/abc123", "/issues"));
    try std.testing.expect(!isSafeReturnTarget("/issues-next", "/issues"));
    try std.testing.expect(!isSafeReturnTarget("//issues", "/issues"));
    try std.testing.expect(!isSafeReturnTarget("/issues\nLocation:/pulls", "/issues"));
}

fn loadWebStats(allocator: Allocator, repo: Repo) !WebStats {
    var stats = WebStats{};
    stats.inbox_refs = countRefsWithPrefix(allocator, "refs/gitomi/inbox") catch 0;
    stats.staged_refs = countRefsWithPrefix(allocator, "refs/gitomi/staging") catch 0;

    if (!(index.isIndexFresh(allocator, repo) catch false)) return stats;
    stats.events = countIndexedEvents(allocator, repo) catch 0;
    stats.issues = index.countOpenIssues(allocator, repo) catch 0;
    stats.pulls = index.countOpenPulls(allocator, repo) catch 0;
    const principal = currentPrincipalOwned(allocator, repo) catch null;
    defer if (principal) |value| allocator.free(value);
    if (principal) |value| {
        stats.unread_notifications = countUnreadNotifications(allocator, repo, value) catch 0;
    }
    return stats;
}

fn countUnreadNotifications(allocator: Allocator, repo: Repo, principal: []const u8) !usize {
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT COUNT(*)
        \\FROM notification_inbox
        \\WHERE principal = ?
        \\  AND read_at = ''
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    if (!(try stmt.step())) return 0;
    const count = stmt.columnInt64(0);
    return if (count <= 0) 0 else @as(usize, @intCast(count));
}

fn loadTopbarNotificationRows(allocator: Allocator, repo: Repo, principal: []const u8, limit: usize) ![]TopbarNotificationRow {
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT n.event_hash, n.object_kind, n.object_id, n.event_type, n.actor_principal,
        \\       n.occurred_at, n.read_at, COALESCE(i.title, p.title, '')
        \\FROM notification_inbox n
        \\LEFT JOIN issues i ON n.object_kind = 'issue' AND i.id = n.object_id
        \\LEFT JOIN pulls p ON n.object_kind = 'pull' AND p.id = n.object_id
        \\WHERE n.principal = ?
        \\ORDER BY CASE WHEN n.read_at = '' THEN 0 ELSE 1 END, n.occurred_at DESC, n.event_hash DESC
        \\LIMIT ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, principal);
    try stmt.bindInt64(2, @intCast(limit));

    var rows: std.ArrayList(TopbarNotificationRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try stmt.step()) {
        try rows.append(allocator, .{
            .event_hash = try stmt.columnTextDup(allocator, 0),
            .object_kind = try stmt.columnTextDup(allocator, 1),
            .object_id = try stmt.columnTextDup(allocator, 2),
            .event_type = try stmt.columnTextDup(allocator, 3),
            .actor_principal = try stmt.columnTextDup(allocator, 4),
            .occurred_at = try stmt.columnTextDup(allocator, 5),
            .read_at = try stmt.columnTextDup(allocator, 6),
            .title = try stmt.columnTextDup(allocator, 7),
        });
    }
    return try rows.toOwnedSlice(allocator);
}

fn freeTopbarNotificationRows(allocator: Allocator, rows: []TopbarNotificationRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
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

test "appendMarkdownTaskProgress renders proportional CSS progress" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendMarkdownTaskProgress(&buf, std.testing.allocator, .{ .done = 3, .total = 4 });
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "style=\"--issue-task-progress: 270deg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">3 of 4 tasks<") != null);

    buf.clearRetainingCapacity();
    try appendMarkdownTaskProgress(&buf, std.testing.allocator, .{ .done = 4, .total = 4 });
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "style=\"--issue-task-progress: 360deg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">4 tasks done<") != null);
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

test "web pagination nav renders only available actions" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendPaginationNav(&buf, std.testing.allocator, "Issue pages", "Showing 1-25", null, null);
    try std.testing.expectEqualStrings("", buf.items);

    buf.clearRetainingCapacity();
    try appendPaginationNav(&buf, std.testing.allocator, "Issue pages", "Showing 1-25", null, "/issues?page=2");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Previous") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Next") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?page=2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "pagination-link disabled") == null);

    buf.clearRetainingCapacity();
    try appendPaginationNav(&buf, std.testing.allocator, "Issue pages", "Showing 51-75", "/issues?page=2", null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Previous") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Next") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?page=2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "pagination-link disabled") == null);

    buf.clearRetainingCapacity();
    try appendPaginationNav(&buf, std.testing.allocator, "Issue pages", "Showing 26-50", "/issues", "/issues?page=3");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Previous") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Next") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues?page=3\"") != null);
}

test "web detail back button renders accessible history button" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendDetailBackButton(&buf, std.testing.allocator, literalHref("/issues"), "Back to issues");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "class=\"detail-back-button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<button") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "type=\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-history-back") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues\"") == null);
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

test "web avatar renders remote candidates before generated fallback" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendAvatar(&buf, std.testing.allocator, "octocat", "");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-avatar-source=\"github\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "https://github.com/octocat.png?size=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nouns-avatar-svg") != null);

    buf.clearRetainingCapacity();
    try appendAvatar(&buf, std.testing.allocator, "User@example.com", "");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-avatar-source=\"github\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-avatar-source=\"gravatar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "https://www.gravatar.com/avatar/") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "d=404") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nouns-avatar-svg") != null);
}

test "web shell stylesheets are local assets" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendShellStylesheets(&buf, std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "://") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@latest") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/vendor/devicon/devicon.min.css?v=") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/style.css?v=") != null);
}

test "web work item reference links point to detail pages" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendIssueReferenceLink(&buf, std.testing.allocator, "abc1234");
    try buf.append(std.testing.allocator, ' ');
    try appendPullReferenceLink(&buf, std.testing.allocator, "def5678");

    try std.testing.expectEqualStrings("<a href=\"/issues/abc1234\">#abc1234</a> <a href=\"/pulls/def5678\">#def5678</a>", buf.items);
}

test "web work item reference text omits self links" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendIssueReferenceText(&buf, std.testing.allocator, "abc1234");
    try buf.append(std.testing.allocator, ' ');
    try appendPullReferenceText(&buf, std.testing.allocator, "def5678");

    try std.testing.expectEqualStrings("#abc1234 #def5678", buf.items);
}

test "local display identity maps current email to username" {
    var identity = LocalDisplayIdentity{
        .allocator = std.testing.allocator,
        .name = try std.testing.allocator.dupe(u8, "0kenx"),
        .email = try std.testing.allocator.dupe(u8, "km@nxfi.app"),
    };
    defer identity.deinit();

    try std.testing.expectEqualStrings("0kenx", identity.displayNameFor("KM@NXFI.APP"));
    try std.testing.expectEqualStrings("import-bot", identity.displayNameFor("import-bot"));
}

test "web legacy references link provider and number externally" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var remotes = LegacyRemoteLinks{
        .github_base = try std.testing.allocator.dupe(u8, "https://www.github.com/Owner/Repo"),
        .gitlab_base = try std.testing.allocator.dupe(u8, "https://gitlab.com/group/repo"),
    };
    defer remotes.deinit(std.testing.allocator);

    try appendLegacyIssueReference(&buf, std.testing.allocator, &remotes, "Github", 3);
    try buf.append(std.testing.allocator, ' ');
    try appendLegacyPullReference(&buf, std.testing.allocator, &remotes, "gitlab", 4);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"https://www.github.com/Owner/Repo/issues/3\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">GitHub<span class=\"legacy-provider-number\">#3</span><span class=\"legacy-external-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues/3\">#3</a>") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"https://gitlab.com/group/repo/-/merge_requests/4\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">GitLab<span class=\"legacy-provider-number\">#4</span><span class=\"legacy-external-icon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/pulls/4\">#4</a>") == null);
}

test "web remote url parsing finds GitHub and GitLab web bases" {
    const github = (try remoteWebBaseOwned(std.testing.allocator, "git@GitHub.com:Owner/Repo.git")).?;
    defer std.testing.allocator.free(github.base);
    try std.testing.expectEqual(LegacyProviderKind.github, github.provider);
    try std.testing.expectEqualStrings("https://www.github.com/Owner/Repo", github.base);

    const gitlab = (try remoteWebBaseOwned(std.testing.allocator, "https://gitlab.com/group/sub/repo.git")).?;
    defer std.testing.allocator.free(gitlab.base);
    try std.testing.expectEqual(LegacyProviderKind.gitlab, gitlab.provider);
    try std.testing.expectEqualStrings("https://gitlab.com/group/sub/repo", gitlab.base);
}

test "web provider origin fallback derives repo paths from SSH aliases" {
    try std.testing.expectEqualStrings("nx-fi/gitomi", remoteRepositoryPath("git@nx-fi:nx-fi/gitomi.git").?);
    try std.testing.expectEqualStrings("group/sub/repo", remoteRepositoryPath("git@gitlab-alias:group/sub/repo.git").?);

    const github_base = (try legacyFallbackWebBaseFromOriginPathOwned(std.testing.allocator, .github, "nx-fi/gitomi")).?;
    defer std.testing.allocator.free(github_base);
    try std.testing.expectEqualStrings("https://www.github.com/nx-fi/gitomi", github_base);

    const gitlab_base = (try legacyFallbackWebBaseFromOriginPathOwned(std.testing.allocator, .gitlab, "group/sub/repo")).?;
    defer std.testing.allocator.free(gitlab_base);
    try std.testing.expectEqualStrings("https://gitlab.com/group/sub/repo", gitlab_base);

    try std.testing.expect((try legacyFallbackWebBaseFromOriginPathOwned(std.testing.allocator, .github, "group/sub/repo")) == null);
}

test "web legacy references use import provider with origin path fallback" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var github_remotes = LegacyRemoteLinks{
        .origin_repo_path = try std.testing.allocator.dupe(u8, "nx-fi/gitomi"),
    };
    defer github_remotes.deinit(std.testing.allocator);

    try appendLegacyIssueReference(&buf, std.testing.allocator, &github_remotes, "github", 23);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"https://www.github.com/nx-fi/gitomi/issues/23\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">GitHub<span class=\"legacy-provider-number\">#23</span><span class=\"legacy-external-icon\"") != null);

    buf.clearRetainingCapacity();
    var gitlab_remotes = LegacyRemoteLinks{
        .origin_repo_path = try std.testing.allocator.dupe(u8, "group/sub/repo"),
    };
    defer gitlab_remotes.deinit(std.testing.allocator);

    try appendLegacyPullReference(&buf, std.testing.allocator, &gitlab_remotes, "gitlab", 7);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"https://gitlab.com/group/sub/repo/-/merge_requests/7\" target=\"_blank\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">GitLab<span class=\"legacy-provider-number\">#7</span><span class=\"legacy-external-icon\"") != null);
}

test "web issue linked text autolinks legacy and hash references" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendIssueLinkedText(&buf, std.testing.allocator, "Refs #42, #A1B2C3D, not #abc, #abcdef0g, or #018f0000-uuid.");

    try std.testing.expectEqualStrings("Refs <a href=\"/issues/42\">#42</a>, <a href=\"/issues/A1B2C3D\">#A1B2C3D</a>, not #abc, #abcdef0g, or #018f0000-uuid.", buf.items);
}

test "web work item layout links shared management pages" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendWorkItemsLayoutStart(&buf, std.testing.allocator, "pulls");
    try appendWorkItemsLayoutEnd(&buf, std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/issues\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/pulls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/milestones\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/labels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "work-items-tabs-separator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "project-page-tab active") != null);
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

test "web internal reference resolver caches object refs per request" {
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
    );

    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, "issue-object-1");
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, "pull-object-1");

    var resolver = InternalReferenceResolver{ .allocator = allocator, .db = db };
    close_db = false;
    defer resolver.deinit();

    _ = resolver.hrefForHashReference("abcdef0");
    if (resolver.db) |*resolver_db| try resolver_db.exec("DROP TABLE issues; DROP TABLE pulls;");

    switch (resolver.hrefForHashReference(issue_ref)) {
        .issue => |value| try std.testing.expectEqualStrings(issue_ref, value),
        else => try std.testing.expect(false),
    }
    switch (resolver.hrefForHashReference(pull_ref)) {
        .pull => |value| try std.testing.expectEqualStrings(pull_ref, value),
        else => try std.testing.expect(false),
    }
}

test "web internal reference linked text caps resolved references per value" {
    const allocator = std.testing.allocator;
    var resolver = InternalReferenceResolver{ .allocator = allocator };
    defer resolver.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    for (0..max_internal_reference_links_per_text + 1) |_| {
        try input.appendSlice(allocator, "#abcdef0 ");
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendInternalReferenceLinkedText(&buf, allocator, &resolver, input.items);

    try std.testing.expectEqual(
        max_internal_reference_links_per_text,
        countSubstrings(buf.items, "<a href=\"/commit?sha=abcdef0\">#abcdef0</a>"),
    );
    try std.testing.expectEqual(max_internal_reference_links_per_text + 1, countSubstrings(buf.items, "#abcdef0"));
}

test "web topbar sync prominence follows repository and admin contexts" {
    try std.testing.expect(topbarSyncProminent("code"));
    try std.testing.expect(topbarSyncProminent("refs"));
    try std.testing.expect(topbarSyncProminent("access"));
    try std.testing.expect(!topbarSyncProminent("issues"));
    try std.testing.expect(!topbarSyncProminent("pulls"));
    try std.testing.expect(!topbarSyncProminent("projects"));
}

fn countSubstrings(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index_pos| {
        count += 1;
        start = index_pos + needle.len;
    }
    return count;
}
