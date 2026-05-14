const std = @import("std");
const index = @import("../index.zig");
const project_mod = @import("../project.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const util = @import("../util.zig");
const issues_page = @import("issues.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const Button = shared.Button;
const appendEmptyState = shared.appendEmptyState;
const appendPill = shared.appendPill;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const createProjectCreatedEvent = project_mod.createProjectCreatedEvent;
const formValueOwned = issues_page.formValueOwned;
const issueHref = shared.issueHref;
const literalHref = shared.literalHref;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;

pub fn renderProjectsPage(allocator: Allocator, repo: Repo) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Projects", "projects", "/projects")) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Projects", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(&buf, allocator, "Projects", "Kanban Boards", Button{
        .label = "New project",
        .href = literalHref("/new-project"),
        .kind = "primary",
    });
    try buf.appendSlice(allocator, "</section>");
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var projects = try db.prepare(
        \\SELECT name FROM (
        \\  SELECT name FROM projects
        \\  UNION
        \\  SELECT project AS name FROM issue_projects
        \\)
        \\ORDER BY name
    );
    defer projects.deinit();

    var shown: usize = 0;
    while (try projects.step()) {
        const project = try projects.columnTextDup(allocator, 0);
        defer allocator.free(project);
        try appendProjectBoard(&buf, allocator, &db, project);
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(&buf, allocator, "No project boards yet.", "Create the first project from this browser UI or with gt project create.");
    }

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendProjectBoard(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel kanban-panel">
        \\  <div class="section-head">
        \\    <div>
        \\      <p class="eyebrow">Project</p>
        \\      <h1>{project}</h1>
        \\    </div>
        \\  </div>
    , .{ .project = project });

    try appendProjectSummary(buf, allocator, db, project);
    try buf.appendSlice(allocator,
        \\  <div class="kanban-board">
    );

    var columns = try db.prepare(
        \\SELECT column_name FROM (
        \\  SELECT pc.column_name AS column_name
        \\  FROM project_columns pc
        \\  JOIN projects p ON p.id = pc.project_id
        \\  WHERE p.name = ?
        \\  UNION
        \\  SELECT column_name
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\)
        \\ORDER BY column_name
    );
    defer columns.deinit();
    try columns.bindText(1, project);
    try columns.bindText(2, project);
    var shown_column = false;
    while (try columns.step()) {
        const column = try columns.columnTextDup(allocator, 0);
        defer allocator.free(column);
        try appendProjectColumn(buf, allocator, db, project, column);
        shown_column = true;
    }
    if (!shown_column) try appendProjectColumn(buf, allocator, db, project, "");
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );
}

fn appendProjectSummary(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8) !void {
    var stmt = try db.prepare(
        \\SELECT description, state
        \\FROM projects
        \\WHERE name = ?
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    if (!(try stmt.step())) return;
    const description = try stmt.columnTextDup(allocator, 0);
    defer allocator.free(description);
    const state = try stmt.columnTextDup(allocator, 1);
    defer allocator.free(state);
    try buf.appendSlice(allocator, "<div class=\"project-summary\">");
    try appendStatePill(buf, allocator, state);
    if (description.len != 0) {
        try appendTemplate(buf, allocator,
            \\<p class="muted">{description}</p>
        , .{ .description = description });
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectColumn(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, project: []const u8, column: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"kanban-column\"><header><h2>");
    if (column.len == 0) {
        try buf.appendSlice(allocator, "No column");
    } else {
        try appendTemplate(buf, allocator, "{column}", .{ .column = column });
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

        const short_id = id[0..@min(id.len, 7)];
        try buf.appendSlice(allocator, "<article class=\"kanban-card\"><div>");
        try appendStatePill(buf, allocator, state);
        try appendTemplate(buf, allocator,
            \\<a href="{href}">{title}</a></div><p class="muted">#{id} opened by {author} at {opened_at}</p></article>
        , .{
            .href = issueHref(short_id),
            .id = short_id,
            .title = title,
            .author = author,
            .opened_at = opened_at,
        });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<div class=\"empty-cell\">No issues</div>");
    try buf.appendSlice(allocator, "</div></section>");
}

pub fn renderProjectForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "New Project", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel form-panel\">");
    try appendSectionHead(&buf, allocator, "Projects", "New Project", null);
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try appendTemplate(&buf, allocator,
        \\  <form method="post" action="/projects" class="issue-form">
        \\    <label>Name<input name="name" value="{name_value}" autofocus required></label>
        \\    <label>Description<textarea name="description" rows="5">{description_value}</textarea></label>
        \\    <label>Columns<input name="columns" value="{columns_value}" placeholder="Todo, In Progress, Done"></label>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/projects">Cancel</a>
        \\      <button class="button primary" type="submit">Create project</button>
        \\    </div>
        \\  </form>
        \\</section>
    , .{
        .name_value = name_value,
        .description_value = description_value,
        .columns_value = columns_value,
    });
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn handleProjectPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
    defer allocator.free(name_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const columns_owned = (try formValueOwned(allocator, form_body, "columns")) orelse try allocator.dupe(u8, "");
    defer allocator.free(columns_owned);

    const name = std.mem.trim(u8, name_owned, " \t\r\n");
    if (name.len == 0) {
        const body = try renderProjectForm(allocator, repo, "Name is required.", name_owned, description_owned, columns_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var columns = try splitCommaFields(allocator, columns_owned);
    defer columns.deinit(allocator);

    createProjectCreatedEvent(allocator, name, description_owned, columns.items) catch {
        const body = try renderProjectForm(
            allocator,
            repo,
            "Could not create the project. Check that Gitomi is initialized and Git commit signing is configured.",
            name_owned,
            description_owned,
            columns_owned,
        );
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };

    try sendRedirect(allocator, stream, "/projects");
}
