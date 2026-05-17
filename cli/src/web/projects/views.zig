const std = @import("std");
const event_mod = @import("../../event.zig");

const Allocator = std.mem.Allocator;

pub const ProjectView = enum {
    table,
    board,
    roadmap,
};

pub const ProjectGroupField = enum {
    status,
    priority,
};

pub const ActiveProjectView = struct {
    layout: ProjectView,
    title: []u8,
    ref: []u8,
    config_json: []u8,
    saved: bool,

    pub fn deinit(self: *ActiveProjectView, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.ref);
        allocator.free(self.config_json);
    }
};

pub const ProjectIssueFilter = struct {
    require_assignee: bool = false,
    assignee: []const u8 = "",
    bug_label: bool = false,
    current_iteration: bool = false,
};

pub const ProjectViewDefaults = struct {
    status: []const u8 = default_project_status,
    status_explicit: bool = false,
    priority: []const u8 = default_project_priority,
    priority_explicit: bool = false,
};

pub const max_project_table_fields = 6;

pub const ProjectTableField = struct {
    key: []u8,
    name: []u8,
    field_type: []u8,

    pub fn deinit(self: *ProjectTableField, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.name);
        allocator.free(self.field_type);
    }
};

pub const ProjectTableFields = struct {
    items: [max_project_table_fields]ProjectTableField = undefined,
    len: usize = 0,

    pub fn deinit(self: *ProjectTableFields, allocator: Allocator) void {
        for (self.items[0..self.len]) |*field| field.deinit(allocator);
    }
};

pub const ProjectRenderContext = struct {
    filter: ProjectIssueFilter,
    defaults: ProjectViewDefaults,
    table_fields: ?*const ProjectTableFields = null,
    view_ref: []const u8,

    pub fn tableFieldCount(self: ProjectRenderContext) usize {
        return if (self.table_fields) |fields| fields.len else 0;
    }

    pub fn tableColspan(self: ProjectRenderContext) usize {
        return 9 + self.tableFieldCount();
    }
};

pub const default_project_priority = "P3";
pub const default_project_status = "Draft";
pub const project_status_values = [_][]const u8{ "Draft", "Todo", "WIP", "Review", "Done", "Failed" };
pub const project_priority_values = [_][]const u8{ "P0", "P1", "P2", "P3" };

pub const table_status_view_config =
    \\{"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels","issue.milestone"]}
;
pub const board_status_view_config =
    \\{"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
pub const kanban_board_view_config =
    \\{"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"defaults":{"issue.status":"Draft","issue.priority":"P3"},"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
pub const priority_table_view_config =
    \\{"group_by":"issue.priority","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels","issue.milestone"],"defaults":{"issue.priority":"P3","issue.status":"Draft"}}
;
pub const my_items_view_config =
    \\{"filter":{"assignee":"@me"},"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"]}
;
pub const roadmap_view_config =
    \\{"start":"project.start_at","target":"project.end_at","group_by":"issue.priority","status":"issue.status","fields":["issue.priority","issue.status","project.start_at","project.end_at"]}
;
pub const bugs_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.status","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"]}
;
pub const bugs_priority_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.priority","fields":["issue.priority","issue.status","issue.state","issue.assignees","issue.labels"],"defaults":{"issue.priority":"P3","issue.status":"Draft"}}
;
pub const bug_triage_view_config =
    \\{"filter":{"any":[{"issue.type":"bug"},{"label":"bug"}]},"group_by":"issue.status","columns":["Draft","Todo","WIP","Review","Done","Failed"],"defaults":{"issue.status":"Todo","issue.priority":"P3"},"card_fields":["issue.priority","issue.state","issue.assignees","issue.labels"]}
;
pub const current_iteration_view_config =
    \\{"filter":{"project.iteration":"current"},"group_by":"issue.status","fields":["project.iteration","project.estimate","issue.priority","issue.status","issue.assignees"]}
;

pub fn projectViewFromValue(value: []const u8) ProjectView {
    if (std.mem.eql(u8, value, "table")) return .table;
    if (std.mem.eql(u8, value, "roadmap")) return .roadmap;
    return .board;
}

pub fn isProjectViewValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or std.mem.eql(u8, value, "board") or std.mem.eql(u8, value, "roadmap");
}

pub fn projectViewValue(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "table",
        .board => "board",
        .roadmap => "roadmap",
    };
}

pub fn projectViewTitle(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "Table",
        .board => "Board",
        .roadmap => "Roadmap",
    };
}

pub fn projectViewIconClass(view: ProjectView) []const u8 {
    return switch (view) {
        .table => "project-view-table-icon",
        .board => "project-view-board-icon",
        .roadmap => "project-view-roadmap-icon",
    };
}

pub fn projectGroupFieldFromConfig(allocator: Allocator, config_json: []const u8) ProjectGroupField {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .status;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .status,
    };
    const group_by = event_mod.jsonString(root.get("group_by")) orelse return .status;
    if (std.mem.eql(u8, group_by, "issue.priority") or std.mem.eql(u8, group_by, "priority")) return .priority;
    return .status;
}

pub fn projectRenderContextFromView(allocator: Allocator, active_view: *const ActiveProjectView, current_principal: []const u8) ProjectRenderContext {
    return .{
        .filter = projectIssueFilterFromConfig(allocator, active_view.config_json, current_principal),
        .defaults = projectViewDefaultsFromConfig(allocator, active_view.config_json),
        .view_ref = active_view.ref,
    };
}

pub fn projectTableFieldsContains(fields: *const ProjectTableFields, key: []const u8) bool {
    for (fields.items[0..fields.len]) |field| {
        if (std.mem.eql(u8, field.key, key)) return true;
    }
    return false;
}

pub fn projectFieldKeyFromViewRef(field_ref: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, field_ref, "project.")) {
        const key = field_ref["project.".len..];
        return if (key.len == 0) null else key;
    }
    if (std.mem.startsWith(u8, field_ref, "issue.")) return null;
    if (isBuiltInIssueFieldRef(field_ref)) return null;
    return if (field_ref.len == 0) null else field_ref;
}

pub fn isBuiltInIssueFieldRef(field_ref: []const u8) bool {
    return std.mem.eql(u8, field_ref, "state") or
        std.mem.eql(u8, field_ref, "status") or
        std.mem.eql(u8, field_ref, "priority") or
        std.mem.eql(u8, field_ref, "type") or
        std.mem.eql(u8, field_ref, "milestone") or
        std.mem.eql(u8, field_ref, "labels") or
        std.mem.eql(u8, field_ref, "assignees") or
        std.mem.eql(u8, field_ref, "projects");
}

pub fn projectViewDefaultsFromConfig(allocator: Allocator, config_json: []const u8) ProjectViewDefaults {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    const defaults_value = root.get("defaults") orelse return .{};
    const defaults_object = switch (defaults_value) {
        .object => |object| object,
        else => return .{},
    };

    var defaults: ProjectViewDefaults = .{};
    if (event_mod.jsonString(defaults_object.get("issue.status")) orelse event_mod.jsonString(defaults_object.get("status"))) |status| {
        if (canonicalProjectStatus(status)) |canonical| {
            defaults.status = canonical;
            defaults.status_explicit = true;
        }
    }
    if (event_mod.jsonString(defaults_object.get("issue.priority")) orelse event_mod.jsonString(defaults_object.get("priority"))) |priority| {
        if (canonicalProjectPriority(priority)) |canonical| {
            defaults.priority = canonical;
            defaults.priority_explicit = true;
        }
    }
    return defaults;
}

pub fn projectIssueFilterFromConfig(allocator: Allocator, config_json: []const u8, current_principal: []const u8) ProjectIssueFilter {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return .{};
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{},
    };
    const filter_value = root.get("filter") orelse return .{};
    var filter: ProjectIssueFilter = .{};
    applyProjectIssueFilterValue(&filter, filter_value, current_principal);
    return filter;
}

fn applyProjectIssueFilterValue(filter: *ProjectIssueFilter, value: std.json.Value, current_principal: []const u8) void {
    switch (value) {
        .object => |object| {
            if (event_mod.jsonString(object.get("assignee"))) |assignee| {
                if (asciiEqlIgnoreCase(assignee, "@me")) {
                    filter.require_assignee = true;
                    filter.assignee = current_principal;
                }
            }
            if (event_mod.jsonString(object.get("label"))) |label| {
                if (asciiEqlIgnoreCase(label, "bug")) filter.bug_label = true;
            }
            if (event_mod.jsonString(object.get("issue.type"))) |issue_type| {
                if (asciiEqlIgnoreCase(issue_type, "bug")) filter.bug_label = true;
            }
            if (event_mod.jsonString(object.get("project.iteration"))) |iteration| {
                if (asciiEqlIgnoreCase(iteration, "current")) filter.current_iteration = true;
            }
            if (object.get("any")) |any_value| {
                switch (any_value) {
                    .array => |items| for (items.items) |item| applyProjectIssueFilterValue(filter, item, current_principal),
                    else => {},
                }
            }
        },
        else => {},
    }
}

pub fn isProjectPriorityValue(value: []const u8) bool {
    for (project_priority_values) |priority| {
        if (std.mem.eql(u8, value, priority)) return true;
    }
    return false;
}

pub fn isProjectStatusValue(value: []const u8) bool {
    for (project_status_values) |status| {
        if (std.mem.eql(u8, value, status)) return true;
    }
    return false;
}

fn canonicalProjectStatus(value: []const u8) ?[]const u8 {
    for (project_status_values) |status| {
        if (std.mem.eql(u8, value, status)) return status;
    }
    return null;
}

fn canonicalProjectPriority(value: []const u8) ?[]const u8 {
    for (project_priority_values) |priority| {
        if (std.mem.eql(u8, value, priority)) return priority;
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
