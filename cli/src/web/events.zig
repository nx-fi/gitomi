const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const IndexedEvent = index.IndexedEvent;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyCell = shared.appendEmptyCell;
const appendHtml = shared.appendHtml;
const appendHref = shared.appendHref;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const ensureIndex = index.ensureIndex;
const freeIndexedEvent = index.freeIndexedEvent;
const indexedEventFromStmt = index.indexedEventFromStmt;
const index_event_columns = index.index_event_columns;
const sqlite = index.sqlite;

const events_default_page_size = 50;
const events_max_page_size = 200;
const activity_filter_option_limit = 200;

const event_search_columns = [_][]const u8{
    "event_type",
    "object_kind",
    "object_id",
    "actor_principal",
    "actor_device",
    "\"commit\"",
    "ref",
    "subject",
    "body",
    "event_hash",
    "occurred_at",
    "rejection_reason",
};

const ActivityFilters = struct {
    allocator: Allocator,
    q: ?[]u8 = null,
    project: ?[]u8 = null,
    event_type: ?[]u8 = null,
    object_kind: ?[]u8 = null,
    actor: ?[]u8 = null,
    status: ?[]u8 = null,

    fn deinit(self: *ActivityFilters) void {
        if (self.q) |value| self.allocator.free(value);
        if (self.project) |value| self.allocator.free(value);
        if (self.event_type) |value| self.allocator.free(value);
        if (self.object_kind) |value| self.allocator.free(value);
        if (self.actor) |value| self.allocator.free(value);
        if (self.status) |value| self.allocator.free(value);
    }
};

const ActivityFilterKind = enum {
    event_type,
    object_kind,
    actor,
    status,
};

const ActivityHrefOverride = struct {
    param_name: ?[]const u8 = null,
    param_value: ?[]const u8 = null,
    page: ?usize = null,
    per_page: ?usize = null,
};

pub fn renderEventsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Activity", "events", target)) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var filters = try activityFiltersFromTarget(allocator, target);
    defer filters.deinit();
    const pagination = try shared.paginationFromTarget(allocator, target, events_default_page_size, events_max_page_size);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const total_events = try countEvents(allocator, &db, filters);

    try appendShellStart(&buf, allocator, repo, "Activity", "events");
    try shared.appendSettingsLayoutStart(&buf, allocator, "events");
    try buf.appendSlice(allocator, "<section class=\"panel settings-panel activity-panel\">");
    try appendSectionHead(&buf, allocator, "Settings", "Activity", null);
    try appendActivityControls(&buf, allocator, &db, filters, pagination);
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table class="activity-table">
        \\      <thead><tr><th>Event</th><th>Object</th><th>Actor</th><th>Commit</th><th>Ref</th><th class="activity-payload-th">Payload</th></tr></thead>
        \\      <tbody>
    );

    const sql = try eventsSelectSqlOwned(allocator, filters);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var bind_index = try bindEventFilters(allocator, &stmt, filters, 1);
    try stmt.bindInt64(bind_index, @intCast(pagination.per_page));
    bind_index += 1;
    try stmt.bindInt64(bind_index, @intCast(pagination.offset()));

    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try appendEventTableRow(&buf, allocator, &db, event);
        shown += 1;
    }

    if (shown == 0) {
        const empty_message = if (pagination.page > 1)
            "No events on this page."
        else if (hasActivityFilters(filters))
            "No events match these filters."
        else
            "No Gitomi events found.";
        try appendEmptyCell(&buf, allocator, 6, empty_message);
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
    );
    if (shown != 0 or pagination.page > 1) {
        try appendEventsPagination(&buf, allocator, filters, pagination, shown, total_events);
    }
    try buf.appendSlice(allocator, "</section>");
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn activityFiltersFromTarget(allocator: Allocator, target: []const u8) !ActivityFilters {
    var filters = ActivityFilters{ .allocator = allocator };
    errdefer filters.deinit();
    filters.q = try queryTextFilterOwned(allocator, target, "q");
    filters.project = try queryTextFilterOwned(allocator, target, "project");
    filters.event_type = try queryTextFilterOwned(allocator, target, "type");
    filters.object_kind = try queryTextFilterOwned(allocator, target, "kind");
    filters.actor = try queryTextFilterOwned(allocator, target, "actor");
    filters.status = try queryTextFilterOwned(allocator, target, "status");
    return filters;
}

fn queryTextFilterOwned(allocator: Allocator, target: []const u8, name: []const u8) !?[]u8 {
    const owned = try shared.queryValueOwned(allocator, target, name) orelse return null;
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(owned);
        return null;
    }
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}

fn hasActivityFilters(filters: ActivityFilters) bool {
    return filters.q != null or
        filters.project != null or
        filters.event_type != null or
        filters.object_kind != null or
        filters.actor != null or
        filters.status != null;
}

fn countEvents(allocator: Allocator, db: *SqliteDb, filters: ActivityFilters) !usize {
    const sql = try eventsCountSqlOwned(allocator, filters);
    defer allocator.free(sql);
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    _ = try bindEventFilters(allocator, &stmt, filters, 1);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn countAllEvents(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM events");
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn eventsSelectSqlOwned(allocator: Allocator, filters: ActivityFilters) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "SELECT " ++ index_event_columns ++ " FROM events");
    try appendEventsWhere(&buf, allocator, filters);
    try buf.appendSlice(allocator, " ORDER BY ordinal DESC LIMIT ? OFFSET ?");
    return buf.toOwnedSlice(allocator);
}

fn eventsCountSqlOwned(allocator: Allocator, filters: ActivityFilters) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "SELECT COUNT(*) FROM events");
    try appendEventsWhere(&buf, allocator, filters);
    return buf.toOwnedSlice(allocator);
}

fn appendEventsWhere(buf: *std.ArrayList(u8), allocator: Allocator, filters: ActivityFilters) !void {
    var has_where = false;
    if (filters.q != null) {
        try appendWhereJoin(buf, allocator, &has_where);
        try appendEventSearchCondition(buf, allocator);
    }
    if (filters.project != null) {
        try appendWhereJoin(buf, allocator, &has_where);
        try buf.appendSlice(allocator,
            \\(
            \\  (object_kind = 'project' AND object_id IN (SELECT id FROM projects WHERE name = ?))
            \\  OR (object_kind = 'issue' AND object_id IN (
            \\    SELECT issue_id FROM issue_projects WHERE project = ?
            \\    UNION
            \\    SELECT pm.issue_id
            \\    FROM project_memberships pm
            \\    JOIN projects p ON p.id = pm.project_id
            \\    WHERE p.name = ?
            \\  ))
            \\)
        );
    }
    try appendExactEventFilter(buf, allocator, &has_where, "event_type", filters.event_type);
    try appendExactEventFilter(buf, allocator, &has_where, "object_kind", filters.object_kind);
    try appendExactEventFilter(buf, allocator, &has_where, "actor_principal", filters.actor);
    try appendExactEventFilter(buf, allocator, &has_where, "domain_status", filters.status);
}

fn appendWhereJoin(buf: *std.ArrayList(u8), allocator: Allocator, has_where: *bool) !void {
    try buf.appendSlice(allocator, if (has_where.*) " AND " else " WHERE ");
    has_where.* = true;
}

fn appendEventSearchCondition(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.append(allocator, '(');
    for (event_search_columns, 0..) |column, i| {
        if (i != 0) try buf.appendSlice(allocator, " OR ");
        try buf.appendSlice(allocator, column);
        try buf.appendSlice(allocator, " LIKE ? ESCAPE '\\'");
    }
    try buf.append(allocator, ')');
}

fn appendExactEventFilter(buf: *std.ArrayList(u8), allocator: Allocator, has_where: *bool, column: []const u8, value: ?[]const u8) !void {
    if (value == null) return;
    try appendWhereJoin(buf, allocator, has_where);
    try buf.appendSlice(allocator, column);
    try buf.appendSlice(allocator, " = ?");
}

fn bindEventFilters(allocator: Allocator, stmt: *index.SqliteStmt, filters: ActivityFilters, first_index: c_int) !c_int {
    var bind_index = first_index;
    if (filters.q) |query| {
        const pattern = try likePatternOwned(allocator, query);
        defer allocator.free(pattern);
        for (event_search_columns) |_| {
            try stmt.bindText(bind_index, pattern);
            bind_index += 1;
        }
    }
    if (filters.project) |value| {
        try stmt.bindText(bind_index, value);
        bind_index += 1;
        try stmt.bindText(bind_index, value);
        bind_index += 1;
        try stmt.bindText(bind_index, value);
        bind_index += 1;
    }
    if (filters.event_type) |value| {
        try stmt.bindText(bind_index, value);
        bind_index += 1;
    }
    if (filters.object_kind) |value| {
        try stmt.bindText(bind_index, value);
        bind_index += 1;
    }
    if (filters.actor) |value| {
        try stmt.bindText(bind_index, value);
        bind_index += 1;
    }
    if (filters.status) |value| {
        try stmt.bindText(bind_index, value);
        bind_index += 1;
    }
    return bind_index;
}

fn likePatternOwned(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '%');
    for (value) |c| {
        switch (c) {
            '%', '_', '\\' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '%');
    return buf.toOwnedSlice(allocator);
}

fn eventsHrefOwned(allocator: Allocator, filters: ActivityFilters, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendEventsHref(&buf, allocator, filters, .{
        .page = page,
        .per_page = pagination.per_page,
    });
    return buf.toOwnedSlice(allocator);
}

fn appendEventsHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: ActivityFilters, override: ActivityHrefOverride) !void {
    try buf.appendSlice(allocator, "/events");
    var first = true;
    if (activityHrefValue(filters, override, "q")) |value| try shared.appendQueryParam(buf, allocator, &first, "q", value);
    if (activityHrefValue(filters, override, "project")) |value| try shared.appendQueryParam(buf, allocator, &first, "project", value);
    if (activityHrefValue(filters, override, "type")) |value| try shared.appendQueryParam(buf, allocator, &first, "type", value);
    if (activityHrefValue(filters, override, "kind")) |value| try shared.appendQueryParam(buf, allocator, &first, "kind", value);
    if (activityHrefValue(filters, override, "actor")) |value| try shared.appendQueryParam(buf, allocator, &first, "actor", value);
    if (activityHrefValue(filters, override, "status")) |value| try shared.appendQueryParam(buf, allocator, &first, "status", value);
    if (override.page) |page| {
        const pagination = shared.Pagination{
            .page = page,
            .per_page = override.per_page orelse events_default_page_size,
        };
        try shared.appendPaginationQueryParams(buf, allocator, &first, pagination, page, events_default_page_size);
    }
}

fn activityHrefValue(filters: ActivityFilters, override: ActivityHrefOverride, name: []const u8) ?[]const u8 {
    if (override.param_name) |param| {
        if (std.mem.eql(u8, param, name)) return override.param_value;
    }
    if (std.mem.eql(u8, name, "q")) return filters.q;
    if (std.mem.eql(u8, name, "project")) return filters.project;
    if (std.mem.eql(u8, name, "type")) return filters.event_type;
    if (std.mem.eql(u8, name, "kind")) return filters.object_kind;
    if (std.mem.eql(u8, name, "actor")) return filters.actor;
    if (std.mem.eql(u8, name, "status")) return filters.status;
    return null;
}

fn appendActivityControls(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    filters: ActivityFilters,
    pagination: shared.Pagination,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="issues-toolbar activity-toolbar">
        \\  <form class="issues-search activity-search" action="/events" method="get">
        \\    <span class="issues-search-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" placeholder="Search activity" aria-label="Search activity">
    , .{
        .query = filters.q orelse "",
    });
    try appendHiddenActivityFilter(buf, allocator, "project", filters.project);
    try appendHiddenActivityFilter(buf, allocator, "type", filters.event_type);
    try appendHiddenActivityFilter(buf, allocator, "kind", filters.object_kind);
    try appendHiddenActivityFilter(buf, allocator, "actor", filters.actor);
    try appendHiddenActivityFilter(buf, allocator, "status", filters.status);
    if (pagination.per_page != events_default_page_size) {
        var per_page_buf: [32]u8 = undefined;
        const per_page = try std.fmt.bufPrint(&per_page_buf, "{d}", .{pagination.per_page});
        try appendHiddenActivityFilter(buf, allocator, "per_page", per_page);
    }
    try buf.appendSlice(allocator,
        \\  </form>
        \\  <div class="issues-toolbar-actions activity-toolbar-actions">
        \\    <div class="issues-filter-menus activity-filter-menus">
    );
    const total_events = try countAllEvents(db);
    try appendActivityFilterMenu(buf, allocator, db, filters, .event_type, total_events);
    try appendActivityFilterMenu(buf, allocator, db, filters, .object_kind, total_events);
    try appendActivityFilterMenu(buf, allocator, db, filters, .actor, total_events);
    try appendActivityFilterMenu(buf, allocator, db, filters, .status, total_events);
    try buf.appendSlice(allocator, "    </div>");
    if (hasActivityFilters(filters)) {
        try buf.appendSlice(allocator,
            \\    <a class="button secondary issue-tool-button activity-clear-button" href="/events">Clear</a>
        );
    }
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
    );
}

fn appendHiddenActivityFilter(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: ?[]const u8) !void {
    const actual = value orelse return;
    try appendTemplate(buf, allocator,
        \\    <input type="hidden" name="{name}" value="{value}">
    , .{
        .name = name,
        .value = actual,
    });
}

fn appendActivityFilterMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    filters: ActivityFilters,
    kind: ActivityFilterKind,
    total_events: usize,
) !void {
    const current = activityFilterValue(filters, kind);
    try buf.appendSlice(allocator, "<details class=\"issues-filter-menu");
    if (current != null) try buf.appendSlice(allocator, " active");
    try buf.appendSlice(allocator, "\" data-popover-menu><summary>");
    try appendHtml(buf, allocator, activityFilterLabel(kind));
    if (current) |value| {
        try buf.appendSlice(allocator, ": ");
        try appendHtml(buf, allocator, value);
    }
    try buf.appendSlice(allocator, "</summary><div class=\"issues-filter-popover\" role=\"menu\">");

    const all_href = try activityFilterHrefOwned(allocator, filters, activityFilterParam(kind), null);
    defer allocator.free(all_href);
    try appendActivityFilterOption(buf, allocator, all_href, activityFilterAllLabel(kind), total_events, current == null);

    var stmt = try db.prepare(activityFilterOptionsSql(kind));
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(activity_filter_option_limit));

    var shown: usize = 0;
    while (try stmt.step()) {
        const value = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(value);
        const count = @as(usize, @intCast(stmt.columnInt64(1)));
        const href = try activityFilterHrefOwned(allocator, filters, activityFilterParam(kind), value);
        defer allocator.free(href);
        const selected = if (current) |selected_value| std.mem.eql(u8, selected_value, value) else false;
        try appendActivityFilterOption(buf, allocator, href, value, count, selected);
        shown += 1;
    }

    if (shown == 0) {
        try appendTemplate(buf, allocator,
            \\<span class="issues-filter-empty">No {label}</span>
        , .{ .label = activityFilterEmptyLabel(kind) });
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendActivityFilterOption(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    href: []const u8,
    label: []const u8,
    count: usize,
    selected: bool,
) !void {
    try buf.appendSlice(allocator, "<a class=\"issues-filter-option");
    if (selected) try buf.appendSlice(allocator, " selected");
    try buf.appendSlice(allocator, "\" href=\"");
    try buf.appendSlice(allocator, href);
    try buf.appendSlice(allocator, "\" role=\"menuitem\"><span>");
    try appendHtml(buf, allocator, label);
    try buf.appendSlice(allocator, "</span><small>");
    try std.fmt.format(buf.writer(allocator), "{d}", .{count});
    try buf.appendSlice(allocator, "</small></a>");
}

fn activityFilterHrefOwned(
    allocator: Allocator,
    filters: ActivityFilters,
    param_name: []const u8,
    param_value: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendEventsHref(&buf, allocator, filters, .{
        .param_name = param_name,
        .param_value = param_value,
    });
    return buf.toOwnedSlice(allocator);
}

fn activityFilterValue(filters: ActivityFilters, kind: ActivityFilterKind) ?[]const u8 {
    return switch (kind) {
        .event_type => filters.event_type,
        .object_kind => filters.object_kind,
        .actor => filters.actor,
        .status => filters.status,
    };
}

fn activityFilterParam(kind: ActivityFilterKind) []const u8 {
    return switch (kind) {
        .event_type => "type",
        .object_kind => "kind",
        .actor => "actor",
        .status => "status",
    };
}

fn activityFilterLabel(kind: ActivityFilterKind) []const u8 {
    return switch (kind) {
        .event_type => "Event",
        .object_kind => "Object",
        .actor => "Actor",
        .status => "Status",
    };
}

fn activityFilterAllLabel(kind: ActivityFilterKind) []const u8 {
    return switch (kind) {
        .event_type => "All events",
        .object_kind => "All objects",
        .actor => "All actors",
        .status => "All statuses",
    };
}

fn activityFilterEmptyLabel(kind: ActivityFilterKind) []const u8 {
    return switch (kind) {
        .event_type => "event types",
        .object_kind => "object kinds",
        .actor => "actors",
        .status => "statuses",
    };
}

fn activityFilterOptionsSql(kind: ActivityFilterKind) []const u8 {
    return switch (kind) {
        .event_type =>
        \\SELECT event_type, COUNT(*) FROM events
        \\WHERE event_type != ''
        \\GROUP BY event_type
        \\ORDER BY lower(event_type), event_type
        \\LIMIT ?
        ,
        .object_kind =>
        \\SELECT object_kind, COUNT(*) FROM events
        \\WHERE object_kind != ''
        \\GROUP BY object_kind
        \\ORDER BY lower(object_kind), object_kind
        \\LIMIT ?
        ,
        .actor =>
        \\SELECT actor_principal, COUNT(*) FROM events
        \\WHERE actor_principal != ''
        \\GROUP BY actor_principal
        \\ORDER BY lower(actor_principal), actor_principal
        \\LIMIT ?
        ,
        .status =>
        \\SELECT domain_status, COUNT(*) FROM events
        \\WHERE domain_status != ''
        \\GROUP BY domain_status
        \\ORDER BY lower(domain_status), domain_status
        \\LIMIT ?
        ,
    };
}

fn appendEventsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: ActivityFilters,
    pagination: shared.Pagination,
    shown: usize,
    total_events: usize,
) !void {
    const has_next_page = pagination.offset() + shown < total_events;
    const previous_href = if (pagination.page > 1) try eventsHrefOwned(allocator, filters, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try eventsHrefOwned(allocator, filters, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, total_events);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Activity pages", summary, previous_href, next_href);
}

fn appendEventTableRow(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, event: IndexedEvent) !void {
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = if (event.object_id.len == 0) "" else util.shortObjectRef(&object_ref_buf, event.object_id);
    try appendTemplate(buf, allocator,
        \\<tr id="{object_id}"><td><span class="event-type">{event_type}</span></td>
    , .{
        .object_id = object_ref,
        .event_type = if (event.valid_json) event.event_type else "invalid-event",
    });
    try appendEventObjectCell(buf, allocator, db, event.object_kind, event.object_id);
    try appendTemplate(buf, allocator, "<td>{actor_principal}", .{
        .actor_principal = event.actor_principal,
    });
    if (event.actor_device.len != 0) {
        try appendTemplate(buf, allocator, "/{actor_device}", .{ .actor_device = event.actor_device });
    }
    try appendTemplate(buf, allocator,
        \\</td><td><code>{commit}</code></td><td><code>{ref}</code></td>
    , .{
        .commit = event.commit[0..@min(event.commit.len, 12)],
        .ref = event.ref,
    });
    try appendEventPayloadCell(buf, allocator, event);
    try buf.appendSlice(allocator, "</tr>");
}

fn appendEventPayloadCell(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    const payload_json = try eventPayloadJsonOwned(allocator, event);
    defer allocator.free(payload_json);

    try buf.appendSlice(allocator,
        \\<td class="activity-payload-cell"><details class="activity-payload-menu" data-popover-menu>
        \\  <summary class="activity-payload-trigger" aria-label="Show payload" title="Show payload"><span class="button-icon icon-file-code" aria-hidden="true"></span></summary>
        \\  <div class="activity-payload-popover" role="dialog" aria-label="Payload"><pre><code>
    );
    try appendHtml(buf, allocator, payload_json);
    try buf.appendSlice(allocator,
        \\</code></pre></div>
        \\</details></td>
    );
}

fn eventPayloadJsonOwned(allocator: Allocator, event: IndexedEvent) ![]u8 {
    if (!event.valid_json) return try allocator.dupe(u8, event.body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event.body, .{}) catch {
        return try allocator.dupe(u8, "Payload unavailable");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return try allocator.dupe(u8, "Payload unavailable"),
    };
    const payload = root.get("payload") orelse return try allocator.dupe(u8, "{}");

    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, &out.writer);
    return try out.toOwnedSlice();
}

fn appendEventObjectCell(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
) !void {
    try buf.appendSlice(allocator, "<td>");
    if (object_id.len == 0) {
        try shared.appendHtml(buf, allocator, object_kind);
        try buf.appendSlice(allocator, "</td>");
        return;
    }

    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    try shared.appendHtml(buf, allocator, object_kind);
    try buf.appendSlice(allocator, " <a href=\"");
    try appendEventObjectHref(buf, allocator, db, object_kind, object_id, object_ref);
    try appendTemplate(buf, allocator, "\"><code>#{object_id}</code></a></td>", .{ .object_id = object_ref });
}

fn appendEventObjectHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    object_kind: []const u8,
    object_id: []const u8,
    object_ref: []const u8,
) !void {
    if (std.mem.eql(u8, object_kind, "issue")) {
        try appendHref(buf, allocator, shared.issueHref(object_ref));
    } else if (std.mem.eql(u8, object_kind, "pull")) {
        try appendHref(buf, allocator, shared.pullHref(object_ref));
    } else if (std.mem.eql(u8, object_kind, "comment")) {
        try appendCommentObjectHref(buf, allocator, db, object_id, object_ref);
    } else if (std.mem.eql(u8, object_kind, "project")) {
        try appendProjectObjectHref(buf, allocator, db, object_id);
    } else if (std.mem.eql(u8, object_kind, "milestone")) {
        try buf.appendSlice(allocator, "/milestones/");
        try shared.appendUrlEncoded(buf, allocator, object_ref);
    } else if (std.mem.eql(u8, object_kind, "label")) {
        try buf.appendSlice(allocator, "/labels#label-");
        try shared.appendUrlEncoded(buf, allocator, object_id);
    } else if (std.mem.eql(u8, object_kind, "action")) {
        try buf.appendSlice(allocator, "/pipelines?q=");
        try shared.appendUrlEncoded(buf, allocator, object_id);
    } else if (std.mem.eql(u8, object_kind, "acl") or std.mem.eql(u8, object_kind, "identity")) {
        try buf.appendSlice(allocator, "/access");
    } else {
        try buf.appendSlice(allocator, "/events");
    }
}

fn appendCommentObjectHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    comment_id: []const u8,
    comment_ref: []const u8,
) !void {
    var stmt = try db.prepare("SELECT parent_kind, parent_id FROM comments WHERE id = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, comment_id);
    if (!(try stmt.step())) {
        try buf.appendSlice(allocator, "/events");
        return;
    }

    const parent_kind = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(parent_kind);
    const parent_id = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(parent_id);
    var parent_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const parent_ref = util.shortObjectRef(&parent_ref_buf, parent_id);

    if (std.mem.eql(u8, parent_kind, "pull")) {
        try appendHref(buf, allocator, shared.pullHref(parent_ref));
    } else {
        try appendHref(buf, allocator, shared.issueHref(parent_ref));
    }
    try buf.appendSlice(allocator, "#comment-");
    try shared.appendUrlEncoded(buf, allocator, comment_ref);
}

fn appendProjectObjectHref(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project_id: []const u8,
) !void {
    var stmt = try db.prepare("SELECT name FROM projects WHERE id = ? LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    if (!(try stmt.step())) {
        try buf.appendSlice(allocator, "/projects");
        return;
    }

    const project = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(project);
    try buf.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(buf, allocator, project);
}

test "activity object cell links issue object refs only" {
    var db = try SqliteDb.openWithOptions(
        std.testing.allocator,
        ":memory:",
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        true,
        .{ .enable_wal = false },
    );
    defer db.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendEventObjectCell(&buf, std.testing.allocator, &db, "issue", "018f0000-0000-7000-8000-000000000002");

    try std.testing.expect(std.mem.startsWith(u8, buf.items, "<td>issue <a href=\"/issues/"));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"><code>#") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\">issue <code>#") == null);
}

test "activity href preserves project filter" {
    var filters = ActivityFilters{
        .allocator = std.testing.allocator,
        .project = try std.testing.allocator.dupe(u8, "Release Plan"),
        .event_type = try std.testing.allocator.dupe(u8, "issue.updated"),
    };
    defer filters.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendEventsHref(&buf, std.testing.allocator, filters, .{});

    try std.testing.expectEqualStrings("/events?project=Release%20Plan&amp;type=issue.updated", buf.items);
}

test "activity project filter includes project and linked issue events" {
    var filters = ActivityFilters{
        .allocator = std.testing.allocator,
        .project = try std.testing.allocator.dupe(u8, "Release Plan"),
    };
    defer filters.deinit();

    const sql = try eventsCountSqlOwned(std.testing.allocator, filters);
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "object_kind = 'project'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "issue_projects WHERE project = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "project_memberships") != null);
}

test "activity object cell links comment refs only to their parent object anchor" {
    var db = try SqliteDb.openWithOptions(
        std.testing.allocator,
        ":memory:",
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        true,
        .{ .enable_wal = false },
    );
    defer db.deinit();
    try db.exec(
        \\CREATE TABLE comments (
        \\  id TEXT PRIMARY KEY,
        \\  parent_kind TEXT NOT NULL,
        \\  parent_id TEXT NOT NULL
        \\);
        \\INSERT INTO comments(id, parent_kind, parent_id)
        \\VALUES ('018f0000-0000-7000-8000-000000000003', 'pull', '018f0000-0000-7000-8000-000000000004');
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendEventObjectCell(&buf, std.testing.allocator, &db, "comment", "018f0000-0000-7000-8000-000000000003");

    try std.testing.expect(std.mem.startsWith(u8, buf.items, "<td>comment <a href=\"/pulls/"));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "#comment-") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"><code>#") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\">comment <code>#") == null);
}

test "activity payload cell renders parsed payload" {
    const event = IndexedEvent{
        .ref = "refs/gitomi/events/test",
        .commit = "0123456789abcdef",
        .event_hash = "hash",
        .tree = "tree",
        .subject = "subject",
        .empty_tree = false,
        .valid_json = true,
        .event_type = "issue.updated",
        .object_kind = "issue",
        .object_id = "018f0000-0000-7000-8000-000000000005",
        .actor_principal = "alice",
        .actor_device = "laptop",
        .seq = 1,
        .occurred_at = "2026-05-18T00:00:00Z",
        .domain_status = "accepted",
        .rejection_reason = "",
        .body = "{\"payload\":{\"title\":\"New title\",\"body\":\"<actual>\"}}",
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendEventPayloadCell(&buf, std.testing.allocator, event);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "activity-payload-trigger") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "&lt;actual&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "New title") != null);
}
