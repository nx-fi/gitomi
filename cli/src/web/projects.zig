const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const sqlite = index.sqlite;

pub fn renderProjectsPage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Projects", "projects");
    try index.ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var projects = try db.prepare("SELECT DISTINCT project FROM issue_projects ORDER BY project");
    defer projects.deinit();

    var shown: usize = 0;
    while (try projects.step()) {
        const project = try projects.columnTextDup(allocator, 0);
        defer allocator.free(project);
        try appendProjectBoard(&buf, allocator, &db, project);
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(&buf, allocator, "No project boards yet.", "Import GitHub project cards or assign issues to projects to populate kanban boards.");
    }

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendProjectBoard(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<section class="panel kanban-panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h1>
    );
    try appendHtml(buf, allocator, project);
    try buf.appendSlice(allocator,
        \\</h1>
        \\    </div>
        \\  </div>
        \\  <div class="kanban-board">
    );

    var columns = try db.prepare(
        \\SELECT DISTINCT column_name
        \\FROM issue_projects
        \\WHERE project = ?
        \\ORDER BY column_name
    );
    defer columns.deinit();
    try columns.bindText(1, project);
    while (try columns.step()) {
        const column = try columns.columnTextDup(allocator, 0);
        defer allocator.free(column);
        try appendProjectColumn(buf, allocator, db, project, column);
    }
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectColumn(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, column: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"kanban-column\"><header><h2>");
    if (column.len == 0) {
        try buf.appendSlice(allocator, "No column");
    } else {
        try appendHtml(buf, allocator, column);
    }
    try buf.appendSlice(allocator, "</h2></header><div class=\"kanban-cards\">");

    var cards = try db.prepare(
        \\SELECT DISTINCT i.id, i.title, i.state,
        \\       COALESCE(NULLIF(m.source_author, ''), i.author_principal),
        \\       i.opened_at
        \\FROM issue_projects p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = i.id
        \\WHERE p.project = ? AND p.column_name = ?
        \\ORDER BY i.opened_at DESC, i.id DESC
    );
    defer cards.deinit();
    try cards.bindText(1, project);
    try cards.bindText(2, column);
    var shown = false;
    while (try cards.step()) {
        const id = try cards.columnTextDup(allocator, 0);
        defer allocator.free(id);
        const title = try cards.columnTextDup(allocator, 1);
        defer allocator.free(title);
        const state = try cards.columnTextDup(allocator, 2);
        defer allocator.free(state);
        const author = try cards.columnTextDup(allocator, 3);
        defer allocator.free(author);
        const opened_at = try cards.columnTextDup(allocator, 4);
        defer allocator.free(opened_at);

        try buf.appendSlice(allocator, "<article class=\"kanban-card\"><div><span class=\"state ");
        try appendHtml(buf, allocator, state);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, state);
        try buf.appendSlice(allocator, "</span><a href=\"/issues/");
        try appendHtml(buf, allocator, id[0..@min(id.len, 7)]);
        try buf.appendSlice(allocator, "\">");
        try appendHtml(buf, allocator, title);
        try buf.appendSlice(allocator, "</a></div><p class=\"muted\">#");
        try appendHtml(buf, allocator, id[0..@min(id.len, 7)]);
        try buf.appendSlice(allocator, " opened by ");
        try appendHtml(buf, allocator, author);
        try buf.appendSlice(allocator, " at ");
        try appendHtml(buf, allocator, opened_at);
        try buf.appendSlice(allocator, "</p></article>");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"empty-cell\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}
