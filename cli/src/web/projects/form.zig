const std = @import("std");
const event_writer_mod = @import("../../event_writer.zig");
const index = @import("../../index.zig");
const project_mod = @import("../../project.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_views = @import("views.zig");
const issues_page = @import("../issues.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const EventWriter = event_writer_mod.EventWriter;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const formValueOwned = issues_page.formValueOwned;
const looksLikeUuid = util.looksLikeUuid;
const newUuidV7 = util.newUuidV7;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;
const stageProjectCreatedEvent = project_mod.stageProjectCreatedEvent;
const stageProjectViewCreatedEvent = project_mod.stageProjectViewCreatedEvent;
const kanban_board_view_config = project_views.kanban_board_view_config;
const priority_table_view_config = project_views.priority_table_view_config;
const my_items_view_config = project_views.my_items_view_config;
const isProjectStatusValue = project_views.isProjectStatusValue;

const default_project_status_columns = "Draft, Todo, WIP, Review, Done, Failed";

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

    const project_id = try newUuidV7(allocator);
    defer allocator.free(project_id);

    try appendShellStart(&buf, allocator, repo, "New Project", "projects");
    try buf.appendSlice(allocator, "<section class=\"panel project-create-panel\">");
    try appendTemplate(&buf, allocator,
        \\<div class="project-create-head">
        \\  <div>
        \\    <p class="eyebrow">Projects</p>
        \\    <h1>Create project</h1>
        \\  </div>
        \\  <a class="button secondary" href="/projects" aria-label="Close create project">Close</a>
        \\</div>
    , .{});
    if (error_message) |message| {
        try appendTemplate(&buf, allocator,
            \\<div class="flash error">{message}</div>
        , .{ .message = message });
    }
    try buf.appendSlice(allocator, "<div class=\"project-create-layout\">");
    try appendProjectConfigForm(&buf, allocator, project_id, name_value, description_value, columns_value);
    try buf.appendSlice(allocator,
        \\</div>
        \\</section>
    );
    try appendProjectSubmitScript(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderProjectFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const name = try queryValueOwned(allocator, target, "name");
    defer if (name) |value| allocator.free(value);
    const description = try queryValueOwned(allocator, target, "description");
    defer if (description) |value| allocator.free(value);
    const columns = try queryValueOwned(allocator, target, "columns");
    defer if (columns) |value| allocator.free(value);

    return renderProjectForm(
        allocator,
        repo,
        null,
        name orelse "",
        description orelse "",
        columns orelse default_project_status_columns,
    );
}

pub fn handleProjectPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
    defer allocator.free(name_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const columns_owned = (try formValueOwned(allocator, form_body, "columns")) orelse try allocator.dupe(u8, "");
    defer allocator.free(columns_owned);
    const project_id_owned = (try formValueOwned(allocator, form_body, "project_id")) orelse try newUuidV7(allocator);
    defer allocator.free(project_id_owned);
    const project_id = std.mem.trim(u8, project_id_owned, " \t\r\n");

    const name = std.mem.trim(u8, name_owned, " \t\r\n");
    if (name.len == 0) {
        const body = try renderProjectForm(allocator, repo, "Name is required.", name_owned, description_owned, columns_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }
    if (!looksLikeUuid(project_id)) {
        const body = try renderProjectForm(allocator, repo, "Could not create the project. The create token was invalid; reload the form and try again.", name_owned, description_owned, columns_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    const effective_columns = if (std.mem.trim(u8, columns_owned, " \t\r\n").len == 0) default_project_status_columns else columns_owned;
    var columns = try splitCommaFields(allocator, effective_columns);
    defer columns.deinit(allocator);
    for (columns.items) |column| {
        if (!isProjectStatusValue(column)) {
            const body = try renderProjectForm(allocator, repo, "Status values must be Draft, Todo, WIP, Review, Done, or Failed.", name_owned, description_owned, effective_columns);
            defer allocator.free(body);
            try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
            return;
        }
    }

    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        createProject(allocator, project_id, name, description_owned, columns.items) catch {
            if (projectExistsAfterIndex(allocator, repo, project_id) catch false) {
                try sendRedirect(allocator, stream, "/projects");
                return;
            }
            if (attempt == 0) continue;
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
        return;
    }
}

fn createProject(
    allocator: Allocator,
    project_id: []const u8,
    name: []const u8,
    description: []const u8,
    columns: []const []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt project create");
    defer writer.deinit();

    const commit_oid = try stageProjectCreatedEvent(allocator, &writer, project_id, name, description, columns);
    defer allocator.free(commit_oid);
    try seedProjectViews(allocator, &writer, project_id);
    try writer.commitStaged();
}

fn projectExistsAfterIndex(allocator: Allocator, repo: Repo, project_id: []const u8) !bool {
    try index.ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT 1 FROM projects WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    return try stmt.step();
}

fn seedProjectViews(allocator: Allocator, writer: *EventWriter, project_id: []const u8) !void {
    try seedProjectView(allocator, writer, project_id, "Board", "board", 1, kanban_board_view_config);
    try seedProjectView(allocator, writer, project_id, "Prioritized", "table", 2, priority_table_view_config);
    try seedProjectView(allocator, writer, project_id, "My items", "table", 3, my_items_view_config);
}

fn seedProjectView(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    name: []const u8,
    layout: []const u8,
    position: i64,
    config_json: []const u8,
) !void {
    try stageProjectViewCreatedEvent(allocator, writer, project_id, name, layout, position, config_json);
}

fn appendProjectConfigForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    project_id: []const u8,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-config-card">
        \\  <div class="project-config-head">
        \\    <h2>Project details</h2>
        \\  </div>
        \\  <form method="post" action="/projects" class="issue-form project-form">
        \\    <input type="hidden" name="project_id" value="{project_id}">
        \\    <label>Name<input name="name" value="{name_value}" autofocus required></label>
    , .{
        .project_id = project_id,
        .name_value = name_value,
    });
    try appendTemplate(buf, allocator,
        \\    <label>Description<textarea name="description" rows="4">{description_value}</textarea></label>
        \\    <label>Status values<input name="columns" value="{columns_value}" placeholder="Draft, Todo, WIP, Review, Done, Failed"></label>
        \\    <div class="project-column-chips" aria-label="Status values">
    , .{
        .description_value = description_value,
        .columns_value = columns_value,
    });
    try appendColumnChips(buf, allocator, columns_value);
    try buf.appendSlice(allocator,
        \\    </div>
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/projects">Cancel</a>
        \\      <button class="button primary" type="submit">Create project</button>
        \\    </div>
        \\  </form>
        \\</div>
    );
}

fn appendColumnChips(buf: *std.ArrayList(u8), allocator: Allocator, columns_value: []const u8) !void {
    var parts = std.mem.splitScalar(u8, columns_value, ',');
    var shown = false;
    while (parts.next()) |part| {
        const column = std.mem.trim(u8, part, " \t\r\n");
        if (column.len == 0) continue;
        try appendTemplate(buf, allocator,
            \\<span>{column}</span>
        , .{ .column = column });
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span>Draft</span><span>Todo</span><span>WIP</span><span>Review</span><span>Done</span><span>Failed</span>");
}

fn appendProjectSubmitScript(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<script>
        \\(function () {
        \\  var form = document.querySelector(".project-form");
        \\  if (!form) return;
        \\  form.addEventListener("submit", function (event) {
        \\    if (form.dataset.projectSubmitState === "pending") {
        \\      event.preventDefault();
        \\      return;
        \\    }
        \\    form.dataset.projectSubmitState = "pending";
        \\    var submit = form.querySelector("button[type=submit]");
        \\    if (submit) {
        \\      submit.disabled = true;
        \\      submit.textContent = "Creating...";
        \\    }
        \\  });
        \\}());
        \\</script>
    );
}

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try issues_page.percentDecodeForm(allocator, raw_value);
    }
    return null;
}
