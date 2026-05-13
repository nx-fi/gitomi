const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const IndexedEvent = index.IndexedEvent;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const ensureIndex = index.ensureIndex;
const freeIndexedEvent = index.freeIndexedEvent;
const indexedEventFromStmt = index.indexedEventFromStmt;
const index_event_columns = index.index_event_columns;
const sqlite = index.sqlite;

pub fn renderEventsPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Events", "events");
    try buf.appendSlice(allocator,
        \\<section class="panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Control plane</p>
        \\      <h1>Event Log</h1>
        \\    </div>
        \\  </div>
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Event</th><th>Object</th><th>Actor</th><th>Commit</th><th>Ref</th></tr></thead>
        \\      <tbody>
    );

    try ensureIndex(allocator, repo);
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
        try buf.appendSlice(allocator, "<tr><td colspan=\"5\" class=\"empty-cell\">No Gitomi events found.</td></tr>");
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
    try buf.appendSlice(allocator, "<tr id=\"");
    try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
    try buf.appendSlice(allocator, "\"><td><span class=\"event-type\">");
    try appendHtml(buf, allocator, if (event.valid_json) event.event_type else "invalid-event");
    try buf.appendSlice(allocator, "</span></td><td>");
    try appendHtml(buf, allocator, event.object_kind);
    if (event.object_id.len != 0) {
        try buf.appendSlice(allocator, " <code>#");
        try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        try buf.appendSlice(allocator, "</code>");
    }
    try buf.appendSlice(allocator, "</td><td>");
    try appendHtml(buf, allocator, event.actor_principal);
    if (event.actor_device.len != 0) {
        try buf.appendSlice(allocator, "/");
        try appendHtml(buf, allocator, event.actor_device);
    }
    try buf.appendSlice(allocator, "</td><td><code>");
    try appendHtml(buf, allocator, event.commit[0..@min(event.commit.len, 12)]);
    try buf.appendSlice(allocator, "</code></td><td><code>");
    try appendHtml(buf, allocator, event.ref);
    try buf.appendSlice(allocator, "</code></td></tr>");
}
