const std = @import("std");
const event_writer_mod = @import("../../event_writer.zig");
const project_mod = @import("../../project.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const EventWriter = event_writer_mod.EventWriter;
const Repo = repo_mod.Repo;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const formValueOwned = shared.formValueOwned;
const newUuidV7 = util.newUuidV7;
const queryValueOwned = shared.queryValueOwned;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const stageProjectCreatedEvent = project_mod.stageProjectCreatedEvent;
const stageProjectViewCreatedEvent = project_mod.stageProjectViewCreatedEvent;
const kanban_board_view_config = project_views.kanban_board_view_config;
const priority_table_view_config = project_views.priority_table_view_config;
const my_items_view_config = project_views.my_items_view_config;

pub fn renderProjectForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    name_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

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
    try appendProjectConfigForm(&buf, allocator, name_value);
    try buf.appendSlice(allocator,
        \\</div>
        \\</section>
    );
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderProjectFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const name = try queryValueOwned(allocator, target, "name");
    defer if (name) |value| allocator.free(value);

    return renderProjectForm(
        allocator,
        repo,
        null,
        name orelse "",
    );
}

pub fn handleProjectPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
    defer allocator.free(name_owned);

    const name = std.mem.trim(u8, name_owned, " \t\r\n");
    if (name.len == 0) {
        const body = try renderProjectForm(allocator, repo, "Name is required.", name_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    const project_id = try newUuidV7(allocator);
    defer allocator.free(project_id);

    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        createProject(allocator, project_id, name) catch |err| {
            if (attempt == 0 and shared.writeFailureStatus(err) != 409) continue;
            const message = shared.writeFailureMessage(err, "Could not create the project. Check that Gitomi is initialized and Git commit signing is configured.");
            const body = try renderProjectForm(
                allocator,
                repo,
                message,
                name_owned,
            );
            defer allocator.free(body);
            try sendResponse(allocator, stream, shared.writeFailureStatus(err), shared.writeFailureReason(err), "text/html", body, null);
            return;
        };

        const location = try projectOverviewLocationOwned(allocator, name);
        defer allocator.free(location);
        try sendRedirect(allocator, stream, location);
        return;
    }
}

fn projectOverviewLocationOwned(allocator: Allocator, name: []const u8) ![]u8 {
    var location: std.ArrayList(u8) = .empty;
    errdefer location.deinit(allocator);
    try location.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(&location, allocator, name);
    return location.toOwnedSlice(allocator);
}

fn createProject(
    allocator: Allocator,
    project_id: []const u8,
    name: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt project create");
    defer writer.deinit();

    const commit_oid = try stageProjectCreatedEvent(allocator, &writer, project_id, name, "", &.{});
    defer allocator.free(commit_oid);
    try seedProjectViews(allocator, &writer, project_id);
    try writer.commitStaged();
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
    name_value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-config-card">
        \\  <div class="project-config-head">
        \\    <h2>Project details</h2>
        \\  </div>
        \\  <form method="post" action="/projects" class="issue-form project-form">
        \\    <label>Name<input name="name" value="{name_value}" autofocus required></label>
    , .{
        .name_value = name_value,
    });
    try buf.appendSlice(allocator,
        \\    <div class="form-actions">
        \\      <a class="button secondary" href="/projects">Cancel</a>
        \\      <button class="button primary" type="submit">Create project</button>
        \\    </div>
        \\  </form>
        \\</div>
    );
}

test "project create form only asks for name" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendProjectConfigForm(&buf, std.testing.allocator, "Release");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"project_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"description\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"columns\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Status values") == null);
}

test "project create redirects to overview location" {
    const location = try projectOverviewLocationOwned(std.testing.allocator, "Release Plan");
    defer std.testing.allocator.free(location);

    try std.testing.expectEqualStrings("/projects?project=Release%20Plan", location);
}
