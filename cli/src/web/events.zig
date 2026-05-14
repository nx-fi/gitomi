const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

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

pub fn renderEventsPage(allocator: Allocator, repo: Repo) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Events", "events", "/events")) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Events", "events");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(&buf, allocator, "Control plane", "Event Log", null);
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Event</th><th>Object</th><th>Actor</th><th>Commit</th><th>Ref</th></tr></thead>
        \\      <tbody>
    );

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal");
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try appendEventTableRow(&buf, allocator, event);
        shown += 1;
    }

    if (shown == 0) {
        try appendEmptyCell(&buf, allocator, 5, "No Gitomi events found.");
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

fn appendEventTableRow(buf: *std.ArrayList(u8), allocator: Allocator, event: IndexedEvent) !void {
    const object_short = event.object_id[0..@min(event.object_id.len, 7)];
    try appendTemplate(buf, allocator,
        \\<tr id="{object_id}"><td><span class="event-type">{event_type}</span></td><td>{object_kind}
    , .{
        .object_id = object_short,
        .event_type = if (event.valid_json) event.event_type else "invalid-event",
        .object_kind = event.object_kind,
    });
    if (event.object_id.len != 0) {
        try appendTemplate(buf, allocator, " <code>#{object_id}</code>", .{ .object_id = object_short });
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
