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
const stageProjectFieldCreatedEvent = project_mod.stageProjectFieldCreatedEvent;
const stageProjectFieldOptionAddedEvent = project_mod.stageProjectFieldOptionAddedEvent;
const stageProjectViewCreatedEvent = project_mod.stageProjectViewCreatedEvent;
const table_status_view_config = project_views.table_status_view_config;
const board_status_view_config = project_views.board_status_view_config;
const kanban_board_view_config = project_views.kanban_board_view_config;
const priority_table_view_config = project_views.priority_table_view_config;
const my_items_view_config = project_views.my_items_view_config;
const roadmap_view_config = project_views.roadmap_view_config;
const bugs_view_config = project_views.bugs_view_config;
const bugs_priority_view_config = project_views.bugs_priority_view_config;
const bug_triage_view_config = project_views.bug_triage_view_config;
const current_iteration_view_config = project_views.current_iteration_view_config;
const isProjectStatusValue = project_views.isProjectStatusValue;

const ProjectTemplate = struct {
    id: []const u8,
    title: []const u8,
    source: []const u8,
    description: []const u8,
    columns: []const u8,
    group: TemplateGroup,
    preview: []const u8,
};

const TemplateGroup = enum {
    featured,
    scratch,
};

const TemplateFieldOption = struct {
    name: []const u8,
    color: []const u8,
};

const default_project_template_id = "kanban";
const default_project_status_columns = "Draft, Todo, WIP, Review, Done, Failed";

const project_templates = [_]ProjectTemplate{
    .{
        .id = "team-planning",
        .title = "Team planning",
        .source = "Gitomi",
        .description = "Manage team work items, upcoming cycles, and capacity.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "kanban",
        .title = "Kanban",
        .source = "Gitomi",
        .description = "Visualize project status and limit work in progress.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "feature-release",
        .title = "Feature release",
        .source = "Gitomi",
        .description = "Prioritize, review, and ship a focused release.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "table",
    },
    .{
        .id = "bug-tracker",
        .title = "Bug tracker",
        .source = "Gitomi",
        .description = "Track, triage, and resolve reported bugs.",
        .columns = default_project_status_columns,
        .group = .featured,
        .preview = "board",
    },
    .{
        .id = "table",
        .title = "Table",
        .source = "Start from scratch",
        .description = "Start from a compact list of work items.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "table",
    },
    .{
        .id = "board",
        .title = "Board",
        .source = "Start from scratch",
        .description = "Start with a lightweight Kanban workflow.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "board",
    },
    .{
        .id = "roadmap",
        .title = "Roadmap",
        .source = "Start from scratch",
        .description = "Organize work by planning horizon.",
        .columns = default_project_status_columns,
        .group = .scratch,
        .preview = "roadmap",
    },
};

pub fn renderProjectForm(
    allocator: Allocator,
    repo: Repo,
    error_message: ?[]const u8,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
    template_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const project_id = try newUuidV7(allocator);
    defer allocator.free(project_id);
    const selected_template = projectTemplateById(template_id);

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
    try appendProjectTemplateSidebar(&buf, allocator, selected_template.id);
    try buf.appendSlice(allocator,
        \\<div class="project-template-workspace">
        \\  <div class="project-template-search">
        \\    <span class="project-template-search-icon" aria-hidden="true"></span>
        \\    <input type="search" placeholder="Search templates" aria-label="Search templates" data-project-template-search>
        \\  </div>
        \\  <div class="project-template-content">
        \\    <div class="project-template-list" data-project-template-list>
        \\      <h2>Featured</h2>
    );
    try appendProjectTemplateCards(&buf, allocator, selected_template.id, .featured);
    try buf.appendSlice(allocator,
        \\      <h2>Start from scratch</h2>
    );
    try appendProjectTemplateCards(&buf, allocator, selected_template.id, .scratch);
    try buf.appendSlice(allocator,
        \\    </div>
    );
    try appendProjectConfigForm(&buf, allocator, selected_template, project_id, name_value, description_value, columns_value);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</div>
        \\</div>
        \\</section>
    );
    try appendProjectTemplateSearchScript(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn renderProjectFormFromTarget(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const template_id = try queryValueOwned(allocator, target, "template");
    defer if (template_id) |value| allocator.free(value);
    const selected_template = projectTemplateById(template_id orelse default_project_template_id);

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
        description orelse selected_template.description,
        columns orelse selected_template.columns,
        selected_template.id,
    );
}

pub fn handleProjectPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const name_owned = (try formValueOwned(allocator, form_body, "name")) orelse try allocator.dupe(u8, "");
    defer allocator.free(name_owned);
    const description_owned = (try formValueOwned(allocator, form_body, "description")) orelse try allocator.dupe(u8, "");
    defer allocator.free(description_owned);
    const columns_owned = (try formValueOwned(allocator, form_body, "columns")) orelse try allocator.dupe(u8, "");
    defer allocator.free(columns_owned);
    const template_owned = (try formValueOwned(allocator, form_body, "template")) orelse try allocator.dupe(u8, default_project_template_id);
    defer allocator.free(template_owned);
    const project_id_owned = (try formValueOwned(allocator, form_body, "project_id")) orelse try newUuidV7(allocator);
    defer allocator.free(project_id_owned);
    const project_id = std.mem.trim(u8, project_id_owned, " \t\r\n");

    const name = std.mem.trim(u8, name_owned, " \t\r\n");
    if (name.len == 0) {
        const body = try renderProjectForm(allocator, repo, "Name is required.", name_owned, description_owned, columns_owned, template_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }
    if (!looksLikeUuid(project_id)) {
        const body = try renderProjectForm(allocator, repo, "Could not create the project. The create token was invalid; reload the form and try again.", name_owned, description_owned, columns_owned, template_owned);
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    const effective_columns = if (std.mem.trim(u8, columns_owned, " \t\r\n").len == 0) default_project_status_columns else columns_owned;
    var columns = try splitCommaFields(allocator, effective_columns);
    defer columns.deinit(allocator);
    for (columns.items) |column| {
        if (!isProjectStatusValue(column)) {
            const body = try renderProjectForm(allocator, repo, "Status values must be Draft, Todo, WIP, Review, Done, or Failed.", name_owned, description_owned, effective_columns, template_owned);
            defer allocator.free(body);
            try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
            return;
        }
    }

    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        createProjectFromTemplate(allocator, project_id, name, description_owned, columns.items, template_owned) catch {
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
                template_owned,
            );
            defer allocator.free(body);
            try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
            return;
        };

        try sendRedirect(allocator, stream, "/projects");
        return;
    }
}

fn createProjectFromTemplate(
    allocator: Allocator,
    project_id: []const u8,
    name: []const u8,
    description: []const u8,
    columns: []const []const u8,
    template_id: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt project create");
    defer writer.deinit();

    const commit_oid = try stageProjectCreatedEvent(allocator, &writer, project_id, name, description, columns);
    defer allocator.free(commit_oid);
    try seedProjectTemplateEvents(allocator, &writer, template_id, project_id);
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

fn seedProjectTemplateEvents(allocator: Allocator, writer: *EventWriter, template_id: []const u8, project_id: []const u8) !void {
    const template = projectTemplateById(template_id);
    if (std.mem.eql(u8, template.id, "table")) {
        try seedTemplateView(allocator, writer, project_id, "Table", "table", 1, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "board")) {
        try seedTemplateView(allocator, writer, project_id, "Board", "board", 1, board_status_view_config);
        try seedTemplateView(allocator, writer, project_id, "Table", "table", 2, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "roadmap")) {
        try seedRoadmapFields(allocator, writer, project_id, 1);
        try seedTemplateView(allocator, writer, project_id, "Roadmap", "roadmap", 1, roadmap_view_config);
        try seedTemplateView(allocator, writer, project_id, "Table", "table", 2, table_status_view_config);
    } else if (std.mem.eql(u8, template.id, "kanban")) {
        try seedTemplateView(allocator, writer, project_id, "Board", "board", 1, kanban_board_view_config);
        try seedTemplateView(allocator, writer, project_id, "Prioritized", "table", 2, priority_table_view_config);
        try seedTemplateView(allocator, writer, project_id, "My items", "table", 3, my_items_view_config);
    } else if (std.mem.eql(u8, template.id, "feature-release")) {
        try seedSizeField(allocator, writer, project_id, 1);
        try seedRoadmapFields(allocator, writer, project_id, 2);
        try seedTemplateView(allocator, writer, project_id, "Prioritized", "table", 1, priority_table_view_config);
        try seedTemplateView(allocator, writer, project_id, "Status", "board", 2, board_status_view_config);
        try seedTemplateView(allocator, writer, project_id, "Roadmap", "roadmap", 3, roadmap_view_config);
        try seedTemplateView(allocator, writer, project_id, "Bugs", "table", 4, bugs_view_config);
    } else if (std.mem.eql(u8, template.id, "bug-tracker")) {
        try seedTemplateView(allocator, writer, project_id, "Prioritized bugs", "table", 1, bugs_priority_view_config);
        try seedTemplateView(allocator, writer, project_id, "Triage", "board", 2, bug_triage_view_config);
        try seedTemplateView(allocator, writer, project_id, "My items", "table", 3, my_items_view_config);
    } else if (std.mem.eql(u8, template.id, "team-planning")) {
        try seedTemplateField(allocator, writer, project_id, "iteration", "Iteration", "text", 1);
        try seedTemplateField(allocator, writer, project_id, "estimate", "Estimate", "number", 2);
        try seedRoadmapFields(allocator, writer, project_id, 3);
        try seedTemplateView(allocator, writer, project_id, "Backlog", "table", 1, table_status_view_config);
        try seedTemplateView(allocator, writer, project_id, "Board", "board", 2, board_status_view_config);
        try seedTemplateView(allocator, writer, project_id, "Current iteration", "table", 3, current_iteration_view_config);
        try seedTemplateView(allocator, writer, project_id, "Roadmap", "roadmap", 4, roadmap_view_config);
        try seedTemplateView(allocator, writer, project_id, "My items", "table", 5, my_items_view_config);
    }
}

fn seedTemplateField(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    field_type: []const u8,
    position: i64,
) !void {
    const field_id = try stageProjectFieldCreatedEvent(allocator, writer, project_id, key, name, field_type, position, false, null);
    defer allocator.free(field_id);
}

fn seedTemplateSingleSelectField(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    position: i64,
    options: []const TemplateFieldOption,
) !void {
    const field_id = try stageProjectFieldCreatedEvent(allocator, writer, project_id, key, name, "single_select", position, false, null);
    defer allocator.free(field_id);
    for (options, 0..) |option, option_index| {
        const option_position: i64 = @intCast(option_index + 1);
        try stageProjectFieldOptionAddedEvent(allocator, writer, project_id, field_id, option.name, option.color, option_position);
    }
}

fn seedRoadmapFields(allocator: Allocator, writer: *EventWriter, project_id: []const u8, start_position: i64) !void {
    try seedTemplateField(allocator, writer, project_id, "start_at", "Start date", "date", start_position);
    try seedTemplateField(allocator, writer, project_id, "target_at", "Target date", "date", start_position + 1);
}

fn seedSizeField(allocator: Allocator, writer: *EventWriter, project_id: []const u8, position: i64) !void {
    const size_options = [_]TemplateFieldOption{
        .{ .name = "S", .color = "green" },
        .{ .name = "M", .color = "blue" },
        .{ .name = "L", .color = "orange" },
    };
    try seedTemplateSingleSelectField(allocator, writer, project_id, "size", "Size", position, size_options[0..]);
}

fn seedTemplateView(
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

fn appendProjectTemplateSidebar(buf: *std.ArrayList(u8), allocator: Allocator, selected_id: []const u8) !void {
    try buf.appendSlice(allocator,
        \\<aside class="project-template-sidebar">
        \\  <div class="project-template-sidebar-group">
        \\    <span>Project templates</span>
    );
    try appendProjectTemplateNavLink(buf, allocator, "Featured", "kanban", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "All templates", "team-planning", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "From this repository", "bug-tracker", selected_id);
    try buf.appendSlice(allocator,
        \\  </div>
        \\  <div class="project-template-sidebar-group">
        \\    <span>Start from scratch</span>
    );
    try appendProjectTemplateNavLink(buf, allocator, "Table", "table", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "Board", "board", selected_id);
    try appendProjectTemplateNavLink(buf, allocator, "Roadmap", "roadmap", selected_id);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</aside>
    );
}

fn appendProjectTemplateNavLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, template_id: []const u8, selected_id: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="/new-project?template={template_id}">{label}</a>
    , .{
        .class_attr = shared.classAttr("project-template-nav-link", &.{shared.class("active", std.mem.eql(u8, template_id, selected_id))}),
        .template_id = template_id,
        .label = label,
    });
}

fn appendProjectTemplateCards(buf: *std.ArrayList(u8), allocator: Allocator, selected_id: []const u8, group: TemplateGroup) !void {
    try buf.appendSlice(allocator, "<div class=\"project-template-grid\">");
    for (project_templates) |template| {
        if (template.group != group) continue;
        try appendProjectTemplateCard(buf, allocator, template, selected_id);
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectTemplateCard(buf: *std.ArrayList(u8), allocator: Allocator, template: ProjectTemplate, selected_id: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="/new-project?template={id}" data-project-template-card data-template-text="{title} {source} {description}">
    , .{
        .class_attr = shared.classAttr("project-template-card", &.{shared.class("selected", std.mem.eql(u8, template.id, selected_id))}),
        .id = template.id,
        .title = template.title,
        .source = template.source,
        .description = template.description,
    });
    try appendProjectTemplatePreview(buf, allocator, template.preview);
    try appendTemplate(buf, allocator,
        \\  <div class="project-template-card-body">
        \\    <h3>{title} <span>&middot; {source}</span></h3>
        \\    <p>{description}</p>
        \\  </div>
        \\</a>
    , .{
        .title = template.title,
        .source = template.source,
        .description = template.description,
    });
}

fn appendProjectTemplatePreview(buf: *std.ArrayList(u8), allocator: Allocator, preview: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="project-template-preview preview-{preview}" aria-hidden="true">
    , .{ .preview = preview });
    if (std.mem.eql(u8, preview, "board")) {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span><span></span><span></span>
        );
    } else if (std.mem.eql(u8, preview, "roadmap")) {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span>
        );
    } else {
        try buf.appendSlice(allocator,
            \\<span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span>
        );
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendProjectConfigForm(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    selected_template: *const ProjectTemplate,
    project_id: []const u8,
    name_value: []const u8,
    description_value: []const u8,
    columns_value: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<aside class="project-config-card">
        \\  <div class="project-config-head">
        \\    <span>Selected template</span>
        \\    <h2>{title}</h2>
        \\    <p>{description}</p>
        \\  </div>
        \\  <form method="post" action="/projects" class="issue-form project-form">
        \\    <input type="hidden" name="template" value="{template_id}">
        \\    <input type="hidden" name="project_id" value="{project_id}">
        \\    <label>Name<input name="name" value="{name_value}" autofocus required></label>
        \\    <label>Description<textarea name="description" rows="4">{description_value}</textarea></label>
        \\    <label>Status values<input name="columns" value="{columns_value}" placeholder="Draft, Todo, WIP, Review, Done, Failed"></label>
        \\    <div class="project-column-chips" aria-label="Template status values">
    , .{
        .title = selected_template.title,
        .description = selected_template.description,
        .template_id = selected_template.id,
        .project_id = project_id,
        .name_value = name_value,
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
        \\</aside>
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

fn appendProjectTemplateSearchScript(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<script>
        \\(function () {
        \\  var search = document.querySelector("[data-project-template-search]");
        \\  if (search) {
        \\    var cards = Array.prototype.slice.call(document.querySelectorAll("[data-project-template-card]"));
        \\    search.addEventListener("input", function () {
        \\      var query = search.value.trim().toLowerCase();
        \\      cards.forEach(function (card) {
        \\        var text = (card.getAttribute("data-template-text") || "").toLowerCase();
        \\        card.hidden = query.length !== 0 && text.indexOf(query) === -1;
        \\      });
        \\    });
        \\  }
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

fn projectTemplateById(id: []const u8) *const ProjectTemplate {
    for (project_templates[0..]) |*template| {
        if (std.mem.eql(u8, template.id, id)) return template;
    }
    for (project_templates[0..]) |*template| {
        if (std.mem.eql(u8, template.id, default_project_template_id)) return template;
    }
    return &project_templates[0];
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
