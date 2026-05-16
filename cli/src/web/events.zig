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

pub fn renderEventsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Activity", "events", target)) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const pagination = try shared.paginationFromTarget(allocator, target, events_default_page_size, events_max_page_size);

    try appendShellStart(&buf, allocator, repo, "Activity", "events");
    try shared.appendSettingsLayoutStart(&buf, allocator, "events");
    try buf.appendSlice(allocator, "<section class=\"panel settings-panel activity-panel\">");
    try appendSectionHead(&buf, allocator, "Settings", "Activity", null);
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Event</th><th>Object</th><th>Actor</th><th>Commit</th><th>Ref</th></tr></thead>
        \\      <tbody>
    );

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const total_events = try countEvents(&db);
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal DESC LIMIT ? OFFSET ?");
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(pagination.per_page));
    try stmt.bindInt64(2, @intCast(pagination.offset()));

    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try appendEventTableRow(&buf, allocator, event);
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyCell(&buf, allocator, 5, if (pagination.page > 1) "No events on this page." else "No Gitomi events found.");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
    );
    if (shown != 0 or pagination.page > 1) {
        try appendEventsPagination(&buf, allocator, pagination, shown, total_events);
    }
    try buf.appendSlice(allocator, "</section>");
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn countEvents(db: *SqliteDb) !usize {
    var stmt = try db.prepare("SELECT COUNT(*) FROM events");
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

fn eventsHrefOwned(allocator: Allocator, pagination: shared.Pagination, page: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "/events");
    var first = true;
    try shared.appendPaginationQueryParams(&buf, allocator, &first, pagination, page, events_default_page_size);
    return buf.toOwnedSlice(allocator);
}

fn appendEventsPagination(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    pagination: shared.Pagination,
    shown: usize,
    total_events: usize,
) !void {
    const has_next_page = pagination.offset() + shown < total_events;
    const previous_href = if (pagination.page > 1) try eventsHrefOwned(allocator, pagination, pagination.page - 1) else null;
    defer if (previous_href) |href| allocator.free(href);
    const next_href = if (has_next_page) try eventsHrefOwned(allocator, pagination, pagination.page + 1) else null;
    defer if (next_href) |href| allocator.free(href);
    const summary = try shared.paginationSummaryOwned(allocator, pagination, shown, total_events);
    defer allocator.free(summary);
    try shared.appendPaginationNav(buf, allocator, "Activity pages", summary, previous_href, next_href);
}

fn appendEventTableRow(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = if (event.object_id.len == 0) "" else util.shortObjectRef(&object_ref_buf, event.object_id);
    try appendTemplate(buf, allocator,
        \\<tr id="{object_id}"><td><span class="event-type">{event_type}</span></td><td>{object_kind}
    , .{
        .object_id = object_ref,
        .event_type = if (event.valid_json) event.event_type else "invalid-event",
        .object_kind = event.object_kind,
    });
    if (event.object_id.len != 0) {
        try appendTemplate(buf, allocator, " <code>#{object_id}</code>", .{ .object_id = object_ref });
    }
    try appendTemplate(buf, allocator, "</td><td>{actor_principal}", .{
        .actor_principal = event.actor_principal,
    });
    if (event.actor_device.len != 0) {
        try appendTemplate(buf, allocator, "/{actor_device}", .{ .actor_device = event.actor_device });
    }
    try appendTemplate(buf, allocator,
        \\</td><td><code>{commit}</code></td><td><code>{ref}</code></td></tr>
    , .{
        .commit = event.commit[0..@min(event.commit.len, 12)],
        .ref = event.ref,
    });
}
