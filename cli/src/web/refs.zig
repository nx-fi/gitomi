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

const FlashKind = enum {
    success,
    failure,
};

const Flash = struct {
    kind: FlashKind,
    message: []const u8,
};

const refs_default_page_size = 50;
const refs_max_page_size = 200;

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

pub fn renderRefsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const flash: ?Flash = if (hasQueryToken(target, "sync=ok"))
        .{ .kind = .success, .message = "Sync completed against origin." }
    else
        null;
    const pagination = try shared.paginationFromTarget(allocator, target, refs_default_page_size, refs_max_page_size);
    return renderRefsPageWithFlash(allocator, repo, flash, refKindFilterFromTarget(target), pagination);
}

pub fn handleRefsSyncPost(allocator: Allocator, repo: Repo, stream: std.net.Stream) !void {
    sync.syncPull(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err);
        return;
    };
    sync.syncPush(allocator, "origin") catch |err| {
        try sendSyncFailure(allocator, repo, stream, err);
        return;
    };
    try sendRedirect(allocator, stream, "/refs?sync=ok");
}

fn sendSyncFailure(allocator: Allocator, repo: Repo, stream: std.net.Stream, err: anyerror) !void {
    const message = try std.fmt.allocPrint(allocator, "Sync failed: {s}. Check that origin is reachable and the Gitomi refs are valid.", .{@errorName(err)});
    defer allocator.free(message);
    const body = try renderRefsPageWithFlash(allocator, repo, .{ .kind = .failure, .message = message }, .all, .{ .per_page = refs_default_page_size });
    defer allocator.free(body);
    try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
}

fn renderRefsPageWithFlash(allocator: Allocator, repo: Repo, flash: ?Flash, filter: RefKindFilter, pagination: shared.Pagination) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Refs", "refs");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendRefsHeader(&buf, allocator);
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

    const total_matching_refs = refCountForFilter(counts, filter);
    var matched: usize = 0;
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ref = cols.next() orelse "";
        if (!refMatchesKindFilter(ref, filter)) continue;
        matched += 1;
        if (matched <= pagination.offset()) continue;
        if (shown >= pagination.per_page) break;
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
        try appendEmptyCell(&buf, allocator, 4, if (pagination.page > 1) "No refs on this page." else if (filter == .all) "No refs found." else "No matching refs found.");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
    );
    if (shown != 0 or pagination.page > 1) {
        try appendRefsPagination(&buf, allocator, filter, pagination, shown, total_matching_refs);
    }
    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn refCountForFilter(counts: RefCounts, filter: RefKindFilter) usize {
    return switch (filter) {
        .all => counts.all,
        .branches => counts.branches,
        .tags => counts.tags,
    };
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

fn appendRefsHeader(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<div class="section-head refs-head">
        \\  <div>
        \\    <p class="eyebrow">Git references</p>
        \\    <h1>Branches, Tags, Remote Tracking, and Gitomi Refs</h1>
        \\  </div>
        \\  <form method="post" action="/refs/sync" class="refs-sync-form">
        \\    <button class="button primary refs-sync-button" type="submit" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span><span>Sync</span></button>
        \\  </form>
        \\</div>
    );
}

fn refsFilterHref(filter: RefKindFilter) []const u8 {
    return switch (filter) {
        .all => "/refs",
        .branches => "/refs?type=branches",
        .tags => "/refs?type=tags",
    };
}

fn refsHrefOwned(allocator: Allocator, filter: RefKindFilter, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/refs");
    var first = true;
    switch (filter) {
        .all => {},
        .branches => try shared.appendQueryParam(&buf, allocator, &first, "type", "branches"),
        .tags => try shared.appendQueryParam(&buf, allocator, &first, "type", "tags"),
    }
    try shared.appendPaginationQueryParams(&buf, allocator, &first, pagination, page, refs_default_page_size);
    return buf.toOwnedSlice(allocator);
}

fn appendRefsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filter: RefKindFilter,
    pagination: shared.Pagination,
    shown: usize,
    total_matching_refs: usize,
) !void {
    const has_next_page = pagination.offset() + shown < total_matching_refs;
    const previous_href = if (pagination.page > 1) try refsHrefOwned(allocator, filter, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try refsHrefOwned(allocator, filter, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, total_matching_refs);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Reference pages", summary, previous_href, next_href);
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
