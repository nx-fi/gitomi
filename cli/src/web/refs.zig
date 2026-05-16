const std = @import("std");
const git = @import("../git.zig");
const issues_page = @import("issues.zig");
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
const sendPlainResponse = shared.sendPlainResponse;
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

const RefLocationFilter = enum {
    all,
    gitomi,
    local_cache,
    local,
    remote,
};

const RefSortField = enum {
    ref,
    updated,
};

const SortDirection = enum {
    asc,
    desc,
};

const RefSort = struct {
    field: RefSortField = .ref,
    direction: SortDirection = .asc,
};

const RefQuery = struct {
    kind: RefKindFilter = .all,
    location: RefLocationFilter = .all,
    sort: RefSort = .{},
};

const RefHrefOverride = struct {
    kind: ?RefKindFilter = null,
    location: ?RefLocationFilter = null,
    sort: ?RefSort = null,
    page: ?usize = null,
    per_page: ?usize = null,
};

const RefCounts = struct {
    all: usize = 0,
    branches: usize = 0,
    tags: usize = 0,
};

const RefLocationCounts = struct {
    all: usize = 0,
    gitomi: usize = 0,
    local_cache: usize = 0,
    local: usize = 0,
    remote: usize = 0,
};

const RefScope = struct {
    label: []const u8,
    detail: []const u8,
    class: []const u8,
};

const RefRow = struct {
    ref: []const u8,
    oid: []const u8,
    updated: []const u8,
    updated_timestamp: i64,
    scope: RefScope,
};

pub fn renderRefsPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    const flash: ?Flash = if (hasQueryToken(target, "sync=ok"))
        .{ .kind = .success, .message = "Sync completed against origin." }
    else
        null;
    const pagination = try shared.paginationFromTarget(allocator, target, refs_default_page_size, refs_max_page_size);
    return renderRefsPageWithFlash(allocator, repo, flash, refQueryFromTarget(target), pagination, csrf_token);
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
    const body = try renderRefsPageWithFlash(allocator, repo, .{ .kind = .failure, .message = message }, .{}, .{ .per_page = refs_default_page_size }, csrf_token);
    defer allocator.free(body);
    try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
}

fn renderRefsPageWithFlash(allocator: Allocator, repo: Repo, flash: ?Flash, query: RefQuery, pagination: shared.Pagination, csrf_token: []const u8) ![]u8 {
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
        "--format=%(refname)%09%(objectname:short)%09%(creatordate:unix)%09%(creatordate:relative)",
        "refs/heads",
        "refs/remotes",
        "refs/tags",
        "refs/gitomi",
    }) catch try allocator.dupe(u8, "");
    defer allocator.free(refs);

    const counts = countRefsByKind(refs);
    const rows = try parseRefRows(allocator, refs);
    defer allocator.free(rows);
    sortRefRows(rows, query.sort);

    const location_counts = countRefsByLocation(rows, query.kind);
    const total_matching_refs = refLocationCount(location_counts, query.location);
    try appendRefsFilters(&buf, allocator, query, counts);

    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr>
    );
    try appendLocationHeader(&buf, allocator, query, location_counts);
    try appendSortHeader(&buf, allocator, query, .ref, "Ref");
    try buf.appendSlice(allocator, "<th>Object</th>");
    try appendSortHeader(&buf, allocator, query, .updated, "Updated");
    try buf.appendSlice(allocator,
        \\</tr></thead>
        \\      <tbody>
    );

    var matched: usize = 0;
    var shown: usize = 0;
    for (rows) |row| {
        if (!refMatchesQuery(row, query)) continue;
        matched += 1;
        if (matched <= pagination.offset()) continue;
        if (shown >= pagination.per_page) break;
        try appendTemplate(&buf, allocator,
            \\<tr><td><span class="ref-scope ref-scope-{class}">{scope}</span><span class="ref-scope-detail">{detail}</span></td><td><code>{ref}</code></td><td><code>{oid}</code></td><td>{updated}</td></tr>
        , .{
            .class = row.scope.class,
            .scope = row.scope.label,
            .detail = row.scope.detail,
            .ref = row.ref,
            .oid = row.oid,
            .updated = row.updated,
        });
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyCell(&buf, allocator, 4, if (pagination.page > 1) "No refs on this page." else if (query.kind == .all and query.location == .all) "No refs found." else "No matching refs found.");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
    );
    if (shown != 0 or pagination.page > 1) {
        try appendRefsPagination(&buf, allocator, query, pagination, shown, total_matching_refs);
    }
    try buf.appendSlice(allocator, "</section>");
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendRefsFilters(buf: *std.ArrayList(u8), allocator: Allocator, query: RefQuery, counts: RefCounts) !void {
    try appendTemplate(buf, allocator,
        \\<div class="refs-filter-bar">
        \\  <nav class="refs-filter-tabs" aria-label="Reference type">
    , .{});
    try appendRefsFilterTab(buf, allocator, query, "All", counts.all, .all, "icon-code");
    try appendRefsFilterTab(buf, allocator, query, "Branches", counts.branches, .branches, "icon-branch");
    try appendRefsFilterTab(buf, allocator, query, "Tags", counts.tags, .tags, "icon-tag");
    try appendTemplate(buf, allocator,
        \\  </nav>
        \\</div>
    , .{});
}

fn appendRefsFilterTab(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    query: RefQuery,
    label: []const u8,
    count: usize,
    tab_filter: RefKindFilter,
    icon: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="
    , .{
        .class_attr = shared.classAttr("", &.{shared.class("active", tab_filter == query.kind)}),
    });
    try appendRefsHref(buf, allocator, query, .{ .kind = tab_filter });
    try appendTemplate(buf, allocator,
        \\"><span class="button-icon {icon}" aria-hidden="true"></span><span>{label}</span><span class="refs-filter-count">{count}</span></a>
    , .{
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
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;

        const value = try issues_page.percentDecodeForm(allocator, raw_value);
        defer allocator.free(value);
        return std.mem.eql(u8, value, wanted_value);
    }
    return false;
}

fn appendLocationHeader(buf: *std.ArrayList(u8), allocator: Allocator, query: RefQuery, counts: RefLocationCounts) !void {
    try appendTemplate(buf, allocator,
        \\<th class="refs-location-th"><details{classes} data-popover-menu><summary>{label}</summary><div class="refs-filter-popover" role="menu">
    , .{
        .classes = shared.classAttr("refs-column-menu", &.{shared.class("active", query.location != .all)}),
        .label = refLocationHeaderLabel(query.location),
    });
    try appendLocationMenuLink(buf, allocator, query, .all, "Any location", counts.all);
    try appendLocationMenuLink(buf, allocator, query, .gitomi, "Gitomi", counts.gitomi);
    try appendLocationMenuLink(buf, allocator, query, .local_cache, "Local cache", counts.local_cache);
    try appendLocationMenuLink(buf, allocator, query, .local, "Local", counts.local);
    try appendLocationMenuLink(buf, allocator, query, .remote, "Remote", counts.remote);
    try buf.appendSlice(allocator, "</div></details></th>");
}

fn appendLocationMenuLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    query: RefQuery,
    location: RefLocationFilter,
    label: []const u8,
    count: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{
        .classes = shared.classes("refs-filter-option", &.{shared.class("selected", query.location == location)}),
    });
    try appendRefsHref(buf, allocator, query, .{ .location = location });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><small>{count}</small></a>
    , .{
        .label = label,
        .count = shared.groupedUnsigned(@intCast(count)),
    });
}

fn appendSortHeader(buf: *std.ArrayList(u8), allocator: Allocator, query: RefQuery, field: RefSortField, label: []const u8) !void {
    const active = query.sort.field == field;
    const next_sort = nextRefSort(query.sort, field);
    try appendTemplate(buf, allocator,
        \\<th class="refs-sort-th" aria-sort="{aria_sort}"><a class="{classes}" href="
    , .{
        .aria_sort = refSortAria(active, query.sort.direction),
        .classes = shared.classes("refs-sort-link", &.{
            shared.class("active", active),
            shared.class("ascending", active and query.sort.direction == .asc),
            shared.class("descending", active and query.sort.direction == .desc),
        }),
    });
    try appendRefsHref(buf, allocator, query, .{ .sort = next_sort });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><span class="refs-sort-indicator" aria-hidden="true"></span></a></th>
    , .{ .label = label });
}

fn refsHrefOwned(allocator: Allocator, query: RefQuery, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendRefsHref(&buf, allocator, query, .{
        .page = page,
        .per_page = pagination.per_page,
    });
    return buf.toOwnedSlice(allocator);
}

fn appendRefsHref(buf: *std.ArrayList(u8), allocator: Allocator, query: RefQuery, override: RefHrefOverride) !void {
    try buf.appendSlice(allocator, "/refs");
    var first = true;
    switch (override.kind orelse query.kind) {
        .all => {},
        .branches => try shared.appendQueryParam(buf, allocator, &first, "type", "branches"),
        .tags => try shared.appendQueryParam(buf, allocator, &first, "type", "tags"),
    }
    switch (override.location orelse query.location) {
        .all => {},
        .gitomi => try shared.appendQueryParam(buf, allocator, &first, "location", "gitomi"),
        .local_cache => try shared.appendQueryParam(buf, allocator, &first, "location", "local-cache"),
        .local => try shared.appendQueryParam(buf, allocator, &first, "location", "local"),
        .remote => try shared.appendQueryParam(buf, allocator, &first, "location", "remote"),
    }
    try appendRefSortQueryParams(buf, allocator, &first, override.sort orelse query.sort);
    if (override.page) |page| {
        const pagination = shared.Pagination{
            .page = page,
            .per_page = override.per_page orelse refs_default_page_size,
        };
        try shared.appendPaginationQueryParams(buf, allocator, &first, pagination, page, refs_default_page_size);
    }
}

fn appendRefsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    query: RefQuery,
    pagination: shared.Pagination,
    shown: usize,
    total_matching_refs: usize,
) !void {
    const has_next_page = pagination.offset() + shown < total_matching_refs;
    const previous_href = if (pagination.page > 1) try refsHrefOwned(allocator, query, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try refsHrefOwned(allocator, query, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, total_matching_refs);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Reference pages", summary, previous_href, next_href);
}

fn refQueryFromTarget(target: []const u8) RefQuery {
    return .{
        .kind = refKindFilterFromTarget(target),
        .location = refLocationFilterFromTarget(target),
        .sort = refSortFromTarget(target),
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

fn refLocationFilterFromTarget(target: []const u8) RefLocationFilter {
    if (queryValueEquals(target, "location", "gitomi")) return .gitomi;
    if (queryValueEquals(target, "location", "local-cache") or queryValueEquals(target, "location", "local_cache") or
        queryValueEquals(target, "location", "cache"))
    {
        return .local_cache;
    }
    if (queryValueEquals(target, "location", "local")) return .local;
    if (queryValueEquals(target, "location", "remote")) return .remote;
    return .all;
}

fn refSortFromTarget(target: []const u8) RefSort {
    if (queryValueEquals(target, "sort", "ref-desc") or queryValueEquals(target, "sort", "-ref")) {
        return .{ .field = .ref, .direction = .desc };
    }
    if (queryValueEquals(target, "sort", "updated-asc")) {
        return .{ .field = .updated, .direction = .asc };
    }
    if (queryValueEquals(target, "sort", "updated-desc") or queryValueEquals(target, "sort", "-updated")) {
        return .{ .field = .updated, .direction = .desc };
    }

    const field: RefSortField = if (queryValueEquals(target, "sort", "updated")) .updated else .ref;
    var direction = refSortDefaultDirection(field);
    if (queryValueEquals(target, "dir", "asc") or queryValueEquals(target, "direction", "asc") or
        queryValueEquals(target, "order", "asc"))
    {
        direction = .asc;
    } else if (queryValueEquals(target, "dir", "desc") or queryValueEquals(target, "direction", "desc") or
        queryValueEquals(target, "order", "desc"))
    {
        direction = .desc;
    }
    return .{ .field = field, .direction = direction };
}

fn appendRefSortQueryParams(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, sort: RefSort) !void {
    if (sort.field == .ref and sort.direction == .asc) return;
    try shared.appendQueryParam(buf, allocator, first, "sort", switch (sort.field) {
        .ref => "ref",
        .updated => "updated",
    });
    if (sort.direction != refSortDefaultDirection(sort.field)) {
        try shared.appendQueryParam(buf, allocator, first, "dir", switch (sort.direction) {
            .asc => "asc",
            .desc => "desc",
        });
    }
}

fn nextRefSort(current: RefSort, field: RefSortField) RefSort {
    if (current.field == field) {
        return .{ .field = field, .direction = switch (current.direction) {
            .asc => .desc,
            .desc => .asc,
        } };
    }
    return .{ .field = field, .direction = refSortDefaultDirection(field) };
}

fn refSortDefaultDirection(field: RefSortField) SortDirection {
    return switch (field) {
        .ref => .asc,
        .updated => .desc,
    };
}

fn refSortAria(active: bool, direction: SortDirection) []const u8 {
    if (!active) return "none";
    return switch (direction) {
        .asc => "ascending",
        .desc => "descending",
    };
}

fn refLocationHeaderLabel(location: RefLocationFilter) []const u8 {
    return switch (location) {
        .all => "Location",
        .gitomi => "Location: Gitomi",
        .local_cache => "Location: Local cache",
        .local => "Location: Local",
        .remote => "Location: Remote",
    };
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

fn parseRefRows(allocator: Allocator, refs: []const u8) ![]RefRow {
    var rows: std.ArrayList(RefRow) = .empty;
    errdefer rows.deinit(allocator);

    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ref = cols.next() orelse "";
        const oid = cols.next() orelse "";
        const updated_unix = cols.next() orelse "";
        const updated = cols.next() orelse "";
        try rows.append(allocator, .{
            .ref = ref,
            .oid = oid,
            .updated = updated,
            .updated_timestamp = parseRefTimestamp(updated_unix),
            .scope = classifyRef(ref),
        });
    }

    return rows.toOwnedSlice(allocator);
}

fn parseRefTimestamp(raw: []const u8) i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i64, trimmed, 10) catch 0;
}

fn sortRefRows(rows: []RefRow, sort: RefSort) void {
    std.mem.sort(RefRow, rows, sort, struct {
        fn lessThan(active_sort: RefSort, lhs: RefRow, rhs: RefRow) bool {
            switch (active_sort.field) {
                .ref => {
                    const ref_order = std.mem.order(u8, lhs.ref, rhs.ref);
                    if (ref_order != .eq) return switch (active_sort.direction) {
                        .asc => ref_order == .lt,
                        .desc => ref_order == .gt,
                    };
                },
                .updated => {
                    if (lhs.updated_timestamp != rhs.updated_timestamp) {
                        return switch (active_sort.direction) {
                            .asc => lhs.updated_timestamp < rhs.updated_timestamp,
                            .desc => lhs.updated_timestamp > rhs.updated_timestamp,
                        };
                    }
                },
            }
            return std.mem.order(u8, lhs.ref, rhs.ref) == .lt;
        }
    }.lessThan);
}

fn countRefsByLocation(rows: []const RefRow, kind: RefKindFilter) RefLocationCounts {
    var counts = RefLocationCounts{};
    for (rows) |row| {
        if (!refMatchesKindFilter(row.ref, kind)) continue;
        counts.all += 1;
        switch (refScopeLocation(row.scope)) {
            .all => {},
            .gitomi => counts.gitomi += 1,
            .local_cache => counts.local_cache += 1,
            .local => counts.local += 1,
            .remote => counts.remote += 1,
        }
    }
    return counts;
}

fn refLocationCount(counts: RefLocationCounts, location: RefLocationFilter) usize {
    return switch (location) {
        .all => counts.all,
        .gitomi => counts.gitomi,
        .local_cache => counts.local_cache,
        .local => counts.local,
        .remote => counts.remote,
    };
}

fn refMatchesQuery(row: RefRow, query: RefQuery) bool {
    return refMatchesKindFilter(row.ref, query.kind) and refMatchesLocationFilter(row.scope, query.location);
}

fn refMatchesKindFilter(ref: []const u8, filter: RefKindFilter) bool {
    return switch (filter) {
        .all => true,
        .branches => refIsBranch(ref),
        .tags => refIsTag(ref),
    };
}

fn refMatchesLocationFilter(scope: RefScope, filter: RefLocationFilter) bool {
    return filter == .all or refScopeLocation(scope) == filter;
}

fn refScopeLocation(scope: RefScope) RefLocationFilter {
    if (std.mem.eql(u8, scope.label, "Gitomi")) return .gitomi;
    if (std.mem.eql(u8, scope.label, "Local cache")) return .local_cache;
    if (std.mem.eql(u8, scope.label, "Remote")) return .remote;
    return .local;
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

test "web refs parse location filter and sort query" {
    const query = refQueryFromTarget("/refs?type=branches&location=local-cache&sort=updated&dir=asc");
    try std.testing.expectEqual(RefKindFilter.branches, query.kind);
    try std.testing.expectEqual(RefLocationFilter.local_cache, query.location);
    try std.testing.expectEqual(RefSortField.updated, query.sort.field);
    try std.testing.expectEqual(SortDirection.asc, query.sort.direction);

    const updated_default = refQueryFromTarget("/refs?sort=updated");
    try std.testing.expectEqual(RefSortField.updated, updated_default.sort.field);
    try std.testing.expectEqual(SortDirection.desc, updated_default.sort.direction);

    try std.testing.expectEqual(SortDirection.desc, nextRefSort(.{ .field = .ref, .direction = .asc }, .ref).direction);
    try std.testing.expectEqual(SortDirection.desc, nextRefSort(.{ .field = .ref, .direction = .asc }, .updated).direction);
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

test "web refs filters locations and sorts materialized rows" {
    const rows = try parseRefRows(
        std.testing.allocator,
        "refs/gitomi/snapshots/a\t111\t30\t30 seconds ago\n" ++
            "refs/heads/main\t222\t20\t20 seconds ago\n" ++
            "refs/remotes/origin/main\t333\t40\t40 seconds ago\n" ++
            "refs/gitomi/inbox/alice/laptop\t444\t10\t10 seconds ago\n",
    );
    defer std.testing.allocator.free(rows);

    const location_counts = countRefsByLocation(rows, .all);
    try std.testing.expectEqual(@as(usize, 4), location_counts.all);
    try std.testing.expectEqual(@as(usize, 1), location_counts.gitomi);
    try std.testing.expectEqual(@as(usize, 1), location_counts.local_cache);
    try std.testing.expectEqual(@as(usize, 1), location_counts.local);
    try std.testing.expectEqual(@as(usize, 1), location_counts.remote);
    try std.testing.expect(refMatchesQuery(rows[0], .{ .location = .local_cache }));
    try std.testing.expect(!refMatchesQuery(rows[0], .{ .location = .gitomi }));

    sortRefRows(rows, .{ .field = .updated, .direction = .desc });
    try std.testing.expectEqualStrings("refs/remotes/origin/main", rows[0].ref);
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", rows[3].ref);

    sortRefRows(rows, .{ .field = .ref, .direction = .desc });
    try std.testing.expectEqualStrings("refs/remotes/origin/main", rows[0].ref);
}

test "web refs href preserves filters and sort" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendRefsHref(&buf, std.testing.allocator, .{
        .kind = .branches,
        .location = .local_cache,
        .sort = .{ .field = .updated, .direction = .desc },
    }, .{ .page = 2 });

    try std.testing.expectEqualStrings("/refs?type=branches&amp;location=local-cache&amp;sort=updated&amp;page=2", buf.items);
}

test "refs sync csrf form validation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try formValueEquals(allocator, "csrf_token=abc123", "csrf_token", "abc123"));
    try std.testing.expect(try formValueEquals(allocator, "other=1&csrf_token=abc%20123", "csrf_token", "abc 123"));
    try std.testing.expect(!(try formValueEquals(allocator, "csrf_token=wrong", "csrf_token", "abc123")));
    try std.testing.expect(!(try formValueEquals(allocator, "other=abc123", "csrf_token", "abc123")));
}
