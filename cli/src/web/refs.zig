const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const sync = @import("../sync.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const appendEmptyCell = shared.appendEmptyCell;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const gitChecked = git.gitChecked;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sendPlainResponse = shared.sendPlainResponse;

const FlashKind = enum {
    success,
    failure,
};

const Flash = struct {
    kind: FlashKind,
    message: []const u8,
};

const RefKindFilter = enum {
    all,
    branches,
    tags,
};

const RefCounts = struct {
    all: usize = 0,
    branches: usize = 0,
    tags: usize = 0,
};

const RefScope = struct {
    label: []const u8,
    detail: []const u8,
    class: []const u8,
};

pub fn renderRefsPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    const flash: ?Flash = if (hasQueryToken(target, "sync=ok"))
        .{ .kind = .success, .message = "Sync completed against origin." }
    else
        null;
    return renderRefsPageWithFlash(allocator, repo, flash, refKindFilterFromTarget(target), csrf_token);
}

pub fn handleRefsSyncPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8, csrf_token: []const u8) !void {
    const csrf_ok = formValueEquals(allocator, form_body, "csrf_token", csrf_token) catch |err| switch (err) {
        error.InvalidFormEncoding => false,
        else => return err,
    };
    if (!csrf_ok) {
        try sendPlainResponse(allocator, stream, 403, "Forbidden", "Forbidden\n");
        return;
    }

    sync.syncPull(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err, csrf_token);
        return;
    };
    sync.syncPush(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err, csrf_token);
        return;
    };
    try sendRedirect(allocator, stream, "/refs?sync=ok");
}

fn sendSyncFailure(allocator: Allocator, repo: Repo, stream: std.net.Stream, err: anyerror, csrf_token: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "Sync failed: {s}. Check that origin is reachable and the Gitomi refs are valid.", .{@errorName(err)});
    defer allocator.free(message);
    const body = try renderRefsPageWithFlash(allocator, repo, .{ .kind = .failure, .message = message }, .all, csrf_token);
    defer allocator.free(body);
    try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
}

fn renderRefsPageWithFlash(allocator: Allocator, repo: Repo, flash: ?Flash, filter: RefKindFilter, csrf_token: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Refs", "refs");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendRefsHeader(&buf, allocator, csrf_token);
    if (flash) |item| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash {kind}">{message}</div>
        , .{
            .kind = switch (item.kind) {
                .success => "success",
                .failure => "error",
            },
            .message = item.message,
        });
    }

    const refs = gitChecked(allocator, &.{
        "for-each-ref",
        "--sort=refname",
        "--format=%(refname)%09%(objectname:short)%09%(committerdate:relative)",
        "refs/heads",
        "refs/remotes",
        "refs/tags",
        "refs/gitomi",
    }) catch try allocator.dupe(u8, "");
    defer allocator.free(refs);

    const counts = countRefsByKind(refs);
    try appendRefsFilters(&buf, allocator, filter, counts);

    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Location</th><th>Ref</th><th>Object</th><th>Updated</th></tr></thead>
        \\      <tbody>
    );

    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ref = cols.next() orelse "";
        if (!refMatchesKindFilter(ref, filter)) continue;
        const oid = cols.next() orelse "";
        const updated = cols.next() orelse "";
        const scope = classifyRef(ref);
        try appendTemplate(&buf, allocator,
            \\<tr><td><span class="ref-scope ref-scope-{class}">{scope}</span><span class="ref-scope-detail">{detail}</span></td><td><code>{ref}</code></td><td><code>{oid}</code></td><td>{updated}</td></tr>
        , .{
            .class = scope.class,
            .scope = scope.label,
            .detail = scope.detail,
            .ref = ref,
            .oid = oid,
            .updated = updated,
        });
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyCell(&buf, allocator, 4, if (filter == .all) "No refs found." else "No matching refs found.");
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

fn appendRefsFilters(buf: *std.ArrayList(u8), allocator: Allocator, active: RefKindFilter, counts: RefCounts) !void {
    try appendTemplate(buf, allocator,
        \\<div class="refs-filter-bar">
        \\  <nav class="refs-filter-tabs" aria-label="Reference type">
    , .{});
    try appendRefsFilterTab(buf, allocator, "All", counts.all, .all, active, "icon-code");
    try appendRefsFilterTab(buf, allocator, "Branches", counts.branches, .branches, active, "icon-branch");
    try appendRefsFilterTab(buf, allocator, "Tags", counts.tags, .tags, active, "icon-tag");
    try appendTemplate(buf, allocator,
        \\  </nav>
        \\</div>
    , .{});
}

fn appendRefsFilterTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    count: usize,
    tab_filter: RefKindFilter,
    active_filter: RefKindFilter,
    icon: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="{href}"><span class="button-icon {icon}" aria-hidden="true"></span><span>{label}</span><span class="refs-filter-count">{count}</span></a>
    , .{
        .class_attr = shared.classAttr("", &.{shared.class("active", tab_filter == active_filter)}),
        .href = refsFilterHref(tab_filter),
        .icon = icon,
        .label = label,
        .count = shared.groupedUnsigned(@intCast(count)),
    });
}

fn appendRefsHeader(buf: *std.ArrayList(u8), allocator: Allocator, csrf_token: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="section-head refs-head">
        \\  <div>
        \\    <p class="eyebrow">Git references</p>
        \\    <h1>Branches, Tags, Remote Tracking, and Gitomi Refs</h1>
        \\  </div>
        \\  <form method="post" action="/refs/sync" class="refs-sync-form">
        \\    <input type="hidden" name="csrf_token" value="{csrf_token}">
        \\    <button class="button primary refs-sync-button" type="submit" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span><span>Sync</span></button>
        \\  </form>
        \\</div>
    , .{ .csrf_token = csrf_token });
}


fn formValueEquals(allocator: Allocator, body: []const u8, wanted_key: []const u8, wanted_value: []const u8) !bool {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try shared.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;

        const value = try shared.percentDecodeForm(allocator, raw_value);
        defer allocator.free(value);
        return std.mem.eql(u8, value, wanted_value);
    }
    return false;
}

fn refsFilterHref(filter: RefKindFilter) []const u8 {
    return switch (filter) {
        .all => "/refs",
        .branches => "/refs?type=branches",
        .tags => "/refs?type=tags",
    };
}

fn refKindFilterFromTarget(target: []const u8) RefKindFilter {
    if (queryValueEquals(target, "type", "branches") or queryValueEquals(target, "filter", "branches") or
        queryValueEquals(target, "type", "branch") or queryValueEquals(target, "filter", "branch"))
    {
        return .branches;
    }
    if (queryValueEquals(target, "type", "tags") or queryValueEquals(target, "filter", "tags") or
        queryValueEquals(target, "type", "tag") or queryValueEquals(target, "filter", "tag"))
    {
        return .tags;
    }
    return .all;
}

fn queryValueEquals(target: []const u8, key: []const u8, expected: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.ascii.eqlIgnoreCase(pair[eq + 1 ..], expected);
    }
    return false;
}

fn countRefsByKind(refs: []const u8) RefCounts {
    var counts = RefCounts{};
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
        const ref = line[0..tab];
        counts.all += 1;
        if (refIsBranch(ref)) counts.branches += 1;
        if (refIsTag(ref)) counts.tags += 1;
    }
    return counts;
}

fn refMatchesKindFilter(ref: []const u8, filter: RefKindFilter) bool {
    return switch (filter) {
        .all => true,
        .branches => refIsBranch(ref),
        .tags => refIsTag(ref),
    };
}

fn refIsBranch(ref: []const u8) bool {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) return true;
    return std.mem.startsWith(u8, ref, "refs/remotes/") and !std.mem.endsWith(u8, ref, "/HEAD");
}

fn refIsTag(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, "refs/tags/");
}

fn classifyRef(ref: []const u8) RefScope {
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) {
        return .{ .label = "Remote", .detail = "tracking", .class = "remote" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/staging/")) {
        return .{ .label = "Remote", .detail = "staged by sync", .class = "remote" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/quarantine/")) {
        return .{ .label = "Local", .detail = "quarantined", .class = "local" };
    }
    if (std.mem.eql(u8, ref, "refs/gitomi/genesis")) {
        return .{ .label = "Gitomi", .detail = "trust root", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/inbox/")) {
        return .{ .label = "Gitomi", .detail = "authoritative inbox", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/snapshots/")) {
        return .{ .label = "Local cache", .detail = "snapshot", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/gitomi/runs/")) {
        return .{ .label = "Local", .detail = "workflow run", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        return .{ .label = "Local", .detail = "branch", .class = "local" };
    }
    if (std.mem.startsWith(u8, ref, "refs/tags/")) {
        return .{ .label = "Local", .detail = "tag", .class = "local" };
    }
    return .{ .label = "Local", .detail = "ref", .class = "local" };
}

fn hasQueryToken(target: []const u8, token: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair, token)) return true;
    }
    return false;
}

test "web refs classify local and remote refs" {
    try std.testing.expectEqualStrings("Local", classifyRef("refs/heads/main").label);
    try std.testing.expectEqualStrings("branch", classifyRef("refs/heads/main").detail);
    try std.testing.expectEqualStrings("Remote", classifyRef("refs/remotes/origin/main").label);
    try std.testing.expectEqualStrings("authoritative inbox", classifyRef("refs/gitomi/inbox/alice/laptop").detail);
    try std.testing.expectEqualStrings("snapshot", classifyRef("refs/gitomi/snapshots/019e").detail);
    try std.testing.expectEqualStrings("staged by sync", classifyRef("refs/gitomi/staging/origin/inbox/alice/laptop").detail);
    try std.testing.expectEqualStrings("quarantined", classifyRef("refs/gitomi/quarantine/origin/inbox/alice/laptop").detail);
}

test "web refs parse and apply branch tag filters" {
    try std.testing.expectEqual(RefKindFilter.all, refKindFilterFromTarget("/refs"));
    try std.testing.expectEqual(RefKindFilter.branches, refKindFilterFromTarget("/refs?type=branches"));
    try std.testing.expectEqual(RefKindFilter.branches, refKindFilterFromTarget("/refs?filter=branch"));
    try std.testing.expectEqual(RefKindFilter.tags, refKindFilterFromTarget("/refs?type=tags"));

    try std.testing.expect(refMatchesKindFilter("refs/heads/main", .branches));
    try std.testing.expect(refMatchesKindFilter("refs/remotes/origin/main", .branches));
    try std.testing.expect(!refMatchesKindFilter("refs/remotes/origin/HEAD", .branches));
    try std.testing.expect(!refMatchesKindFilter("refs/tags/v1.0.0", .branches));
    try std.testing.expect(refMatchesKindFilter("refs/tags/v1.0.0", .tags));
    try std.testing.expect(!refMatchesKindFilter("refs/gitomi/inbox/alice/laptop", .tags));
}

test "web refs counts refs by kind" {
    const counts = countRefsByKind(
        "refs/heads/main\tabc\t1 day ago\n" ++
            "refs/remotes/origin/main\tdef\t2 days ago\n" ++
            "refs/tags/v1\t123\t3 days ago\n" ++
            "refs/gitomi/genesis\t456\t4 days ago\n",
    );
    try std.testing.expectEqual(@as(usize, 4), counts.all);
    try std.testing.expectEqual(@as(usize, 2), counts.branches);
    try std.testing.expectEqual(@as(usize, 1), counts.tags);
}

test "refs sync csrf form validation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try formValueEquals(allocator, "csrf_token=abc123", "csrf_token", "abc123"));
    try std.testing.expect(try formValueEquals(allocator, "other=1&csrf_token=abc%20123", "csrf_token", "abc 123"));
    try std.testing.expect(!(try formValueEquals(allocator, "csrf_token=wrong", "csrf_token", "abc123")));
    try std.testing.expect(!(try formValueEquals(allocator, "other=abc123", "csrf_token", "abc123")));
}
