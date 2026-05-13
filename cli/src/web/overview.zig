const std = @import("std");
const git = @import("../git.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendFmt = shared.appendFmt;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const ensureIndex = index.ensureIndex;
const freeIndexedEvent = index.freeIndexedEvent;
const indexedEventFromStmt = index.indexedEventFromStmt;
const index_event_columns = index.index_event_columns;
const sqlite = index.sqlite;

pub fn renderHomePage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Overview", "overview");

    const branch = try git.currentBranch(allocator);
    defer allocator.free(branch);
    const changes = git.workingTreeChangeCount(allocator) catch 0;

    try buf.appendSlice(allocator,
        \\<section class="panel hero">
        \\  <div>
        \\    <p class="eyebrow">Local repository</p>
        \\    <h1>
    );
    try appendHtml(&buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator, "</h1><p class=\"muted\">");
    try appendHtml(&buf, allocator, repo.root);
    try buf.appendSlice(allocator,
        \\</p>
        \\  </div>
        \\  <div class="repo-visual" aria-hidden="true">
        \\    <span></span><span></span><span></span><span></span><span></span><span></span>
        \\  </div>
        \\</section>
        \\<section class="grid two">
        \\  <div class="panel">
        \\    <h2>Repository</h2>
        \\    <dl class="facts">
        \\      <div><dt>Branch</dt><dd>
    );
    try appendHtml(&buf, allocator, branch);
    try buf.appendSlice(allocator, "</dd></div><div><dt>Working tree</dt><dd>");
    try appendFmt(&buf, allocator, "{d} change{s}", .{ changes, if (changes == 1) "" else "s" });
    try buf.appendSlice(allocator,
        \\</dd></div><div><dt>Git directory</dt><dd>
    );
    try appendHtml(&buf, allocator, repo.git_dir);
    try buf.appendSlice(allocator,
        \\</dd></div>
        \\    </dl>
        \\  </div>
        \\  <div class="panel">
        \\    <div class="section-head">
        \\      <h2>Recent Activity</h2>
        \\      <a class="button secondary" href="/events">View all</a>
        \\    </div>
    );
    try appendEventList(&buf, allocator, repo, 6);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendEventList(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, limit: usize) !void {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal LIMIT ?");
    defer stmt.deinit();
    if (limit > std.math.maxInt(i64)) return error.ValueTooLarge;
    try stmt.bindInt64(1, @intCast(limit));

    try buf.appendSlice(allocator, "<div class=\"activity-list\">");
    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try buf.appendSlice(allocator, "<article><span class=\"dot\"></span><div><strong>");
        try appendHtml(buf, allocator, if (event.valid_json) event.event_type else "invalid-event");
        try buf.appendSlice(allocator, "</strong><p>");
        try appendHtml(buf, allocator, event.subject);
        try buf.appendSlice(allocator, "</p><small>");
        try appendHtml(buf, allocator, event.actor_principal);
        if (event.object_id.len != 0) {
            try buf.appendSlice(allocator, " / #");
            try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        }
        try buf.appendSlice(allocator, "</small></div></article>");
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(buf, allocator, "No activity yet.", "Gitomi events will appear here after issues, pull requests, or workflow runs are recorded.");
    }
    try buf.appendSlice(allocator, "</div>");
}
