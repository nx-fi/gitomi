const std = @import("std");
const index = @import("../../index.zig");
const project_views = @import("views.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const ProjectRenderContext = project_views.ProjectRenderContext;
const project_status_values = project_views.project_status_values;
const project_priority_values = project_views.project_priority_values;
const isProjectStatusValue = project_views.isProjectStatusValue;

pub fn appendProjectColumns(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
    comptime appendColumnFn: fn (*std.ArrayList(u8), Allocator, *SqliteDb, []const u8, []const u8, *const ProjectRenderContext) anyerror!void,
) !void {
    for (project_status_values) |status| {
        try appendColumnFn(buf, allocator, db, project, status, context);
    }

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
        \\ORDER BY
        \\  CASE lower(column_name)
        \\    WHEN 'triage' THEN 5
        \\    WHEN 'backlog' THEN 10
        \\    WHEN 'todo' THEN 20
        \\    WHEN 'to do' THEN 20
        \\    WHEN 'ready' THEN 30
        \\    WHEN 'in progress' THEN 40
        \\    WHEN 'doing' THEN 40
        \\    WHEN 'in review' THEN 50
        \\    WHEN 'review' THEN 50
        \\    WHEN 'done' THEN 60
        \\    WHEN 'completed' THEN 60
        \\    WHEN 'closed' THEN 60
        \\    ELSE 70
        \\  END,
        \\  lower(column_name),
        \\  column_name
    );
    defer columns.deinit();
    try columns.bindText(1, project);
    try columns.bindText(2, project);
    while (try columns.step()) {
        const column = try columns.columnTextDup(allocator, 0);
        defer allocator.free(column);
        if (isProjectStatusValue(column)) continue;
        try appendColumnFn(buf, allocator, db, project, column, context);
    }
}

pub fn appendProjectPriorityGroups(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    project: []const u8,
    context: *const ProjectRenderContext,
    comptime appendGroupFn: fn (*std.ArrayList(u8), Allocator, *SqliteDb, []const u8, []const u8, *const ProjectRenderContext) anyerror!void,
) !void {
    for (project_priority_values) |priority| {
        try appendGroupFn(buf, allocator, db, project, priority, context);
    }
    try appendGroupFn(buf, allocator, db, project, "", context);
}
