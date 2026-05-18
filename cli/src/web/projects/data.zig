const std = @import("std");
const event_mod = @import("../../event.zig");
const index = @import("../../index.zig");
const project_views = @import("views.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;

const ProjectView = project_views.ProjectView;
const ActiveProjectView = project_views.ActiveProjectView;
const ProjectIssueFilter = project_views.ProjectIssueFilter;
const ProjectTableField = project_views.ProjectTableField;
const ProjectTableFields = project_views.ProjectTableFields;
const max_project_table_fields = project_views.max_project_table_fields;
const isProjectViewValue = project_views.isProjectViewValue;
const projectViewFromValue = project_views.projectViewFromValue;
const projectViewTitle = project_views.projectViewTitle;
const projectViewValue = project_views.projectViewValue;
const projectTableFieldsContains = project_views.projectTableFieldsContains;
const projectFieldKeyFromViewRef = project_views.projectFieldKeyFromViewRef;

pub const project_issue_filter_sql =
    \\
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM issue_assignees ia
    \\    WHERE ia.issue_id = i.id AND ia.assignee = ?
    \\  ))
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM issue_metadata im
    \\    WHERE im.issue_id = i.id AND lower(im.issue_type) = 'bug'
    \\  ) OR EXISTS (
    \\    SELECT 1
    \\    FROM issue_labels il
    \\    WHERE il.issue_id = i.id AND lower(il.label) = 'bug'
    \\  ))
    \\  AND (? = 0 OR EXISTS (
    \\    SELECT 1
    \\    FROM projects filter_project
    \\    JOIN project_fields filter_field
    \\      ON filter_field.project_id = filter_project.id
    \\     AND filter_field.key = 'iteration'
    \\     AND filter_field.state != 'removed'
    \\    JOIN project_field_values filter_value
    \\      ON filter_value.project_id = filter_project.id
    \\     AND filter_value.issue_id = i.id
    \\     AND filter_value.field_id = filter_field.id
    \\    WHERE filter_project.name = ?
    \\      AND COALESCE(json_extract(filter_value.value_json, '$'), '') = 'current'
    \\  ))
;

pub fn projectIssueCount(db: *SqliteDb, project: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT issue_id
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
        \\SELECT COUNT(DISTINCT i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\WHERE 1 = 1
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try bindProjectIssueFilter(&stmt, 3, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

pub fn projectColumnIssueCount(db: *SqliteDb, project: []const u8, column: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT pi.issue_id,
        \\         CASE
        \\           WHEN COALESCE(m.status, '') <> '' THEN m.status
        \\           ELSE pi.legacy_column
        \\         END AS effective_status
        \\  FROM (
        \\    SELECT issue_id, column_name AS legacy_column
        \\    FROM issue_projects
        \\    WHERE project = ?
        \\    UNION
        \\    SELECT pm.issue_id, ''
        \\    FROM project_memberships pm
        \\    JOIN projects p ON p.id = pm.project_id
        \\    WHERE p.name = ?
        \\  ) pi
        \\  LEFT JOIN issue_metadata m ON m.issue_id = pi.issue_id
        \\)
        \\SELECT COUNT(DISTINCT i.id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\WHERE p.effective_status = ?
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try stmt.bindText(3, column);
    try bindProjectIssueFilter(&stmt, 4, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

pub fn projectPriorityIssueCount(db: *SqliteDb, project: []const u8, priority: []const u8, filter: ProjectIssueFilter) !usize {
    var stmt = try db.prepare(
        \\WITH project_items AS (
        \\  SELECT issue_id
        \\  FROM issue_projects
        \\  WHERE project = ?
        \\  UNION
        \\  SELECT pm.issue_id
        \\  FROM project_memberships pm
        \\  JOIN projects p ON p.id = pm.project_id
        \\  WHERE p.name = ?
        \\)
        \\SELECT COUNT(DISTINCT p.issue_id)
        \\FROM project_items p
        \\JOIN issues i ON i.id = p.issue_id
        \\LEFT JOIN issue_metadata m ON m.issue_id = p.issue_id
        \\WHERE COALESCE(m.priority, '') = ?
    ++ project_issue_filter_sql);
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    try stmt.bindText(3, priority);
    try bindProjectIssueFilter(&stmt, 4, project, filter);
    if (!(try stmt.step())) return 0;
    return @intCast(stmt.columnInt64(0));
}

pub fn projectFieldKeyExists(db: *SqliteDb, project: []const u8, field_key: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1
        \\FROM project_fields pf
        \\JOIN projects p ON p.id = pf.project_id
        \\WHERE p.name = ? AND pf.key = ? AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, field_key);
    return try stmt.step();
}

pub fn projectFieldStringValue(allocator: Allocator, db: *SqliteDb, project: []const u8, issue_id: []const u8, field_key: []const u8) ![]u8 {
    var stmt = try db.prepare(
        \\SELECT COALESCE(json_extract(pfv.value_json, '$'), '')
        \\FROM project_field_values pfv
        \\JOIN project_fields pf ON pf.id = pfv.field_id AND pf.project_id = pfv.project_id
        \\JOIN projects p ON p.id = pfv.project_id
        \\WHERE p.name = ?
        \\  AND pfv.issue_id = ?
        \\  AND pf.key = ?
        \\  AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, issue_id);
    try stmt.bindText(3, field_key);
    if (!(try stmt.step())) return try allocator.dupe(u8, "");
    return try stmt.columnTextDup(allocator, 0);
}

pub fn resolveActiveProjectView(allocator: Allocator, db: *SqliteDb, project: []const u8, view_ref: []const u8) !ActiveProjectView {
    if (view_ref.len != 0) {
        if (std.mem.eql(u8, view_ref, projectViewValue(.issues))) return activeBuiltinProjectView(allocator, .issues);
        if (try loadSavedProjectViewByRef(allocator, db, project, view_ref)) |saved| return saved;
        if (isProjectViewValue(view_ref)) {
            const requested = projectViewFromValue(view_ref);
            if (try loadFirstSavedProjectView(allocator, db, project, requested)) |saved| return saved;
            return activeBuiltinProjectView(allocator, requested);
        }
    } else if (try loadFirstSavedProjectView(allocator, db, project, null)) |saved| {
        return saved;
    }
    return activeBuiltinProjectView(allocator, .board);
}

pub fn activeBuiltinProjectView(allocator: Allocator, view: ProjectView) !ActiveProjectView {
    const title = try allocator.dupe(u8, projectViewTitle(view));
    errdefer allocator.free(title);
    const ref = try allocator.dupe(u8, projectViewValue(view));
    errdefer allocator.free(ref);
    const config_json = try allocator.dupe(u8, "{}");
    errdefer allocator.free(config_json);
    return .{
        .layout = view,
        .title = title,
        .ref = ref,
        .config_json = config_json,
        .saved = false,
    };
}

fn loadSavedProjectViewByRef(allocator: Allocator, db: *SqliteDb, project: []const u8, view_ref: []const u8) !?ActiveProjectView {
    const prefix = try std.fmt.allocPrint(allocator, "{s}%", .{view_ref});
    defer allocator.free(prefix);
    var stmt = try db.prepare(
        \\SELECT pv.id, pv.name, pv.layout, pv.config_json
        \\FROM project_views pv
        \\JOIN projects p ON p.id = pv.project_id
        \\WHERE p.name = ?
        \\  AND pv.state != 'removed'
        \\  AND (pv.id = ? OR pv.name = ? OR pv.id LIKE ?)
        \\ORDER BY
        \\  CASE
        \\    WHEN pv.id = ? THEN 0
        \\    WHEN pv.name = ? THEN 1
        \\    ELSE 2
        \\  END,
        \\  pv.position, pv.name, pv.id
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, view_ref);
    try stmt.bindText(3, view_ref);
    try stmt.bindText(4, prefix);
    try stmt.bindText(5, view_ref);
    try stmt.bindText(6, view_ref);
    if (!(try stmt.step())) return null;
    return try activeSavedProjectViewFromStmt(allocator, &stmt);
}

fn loadFirstSavedProjectView(allocator: Allocator, db: *SqliteDb, project: []const u8, layout: ?ProjectView) !?ActiveProjectView {
    const layout_value = if (layout) |view| projectViewValue(view) else "";
    var stmt = try db.prepare(
        \\SELECT pv.id, pv.name, pv.layout, pv.config_json
        \\FROM project_views pv
        \\JOIN projects p ON p.id = pv.project_id
        \\WHERE p.name = ?
        \\  AND pv.state != 'removed'
        \\  AND (? = '' OR pv.layout = ?)
        \\ORDER BY pv.position, pv.name, pv.id
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, layout_value);
    try stmt.bindText(3, layout_value);
    if (!(try stmt.step())) return null;
    return try activeSavedProjectViewFromStmt(allocator, &stmt);
}

fn activeSavedProjectViewFromStmt(allocator: Allocator, stmt: *index.SqliteStmt) !ActiveProjectView {
    const view_id = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(view_id);
    const name = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(name);
    const layout = try stmt.columnTextDup(allocator, 2);
    defer allocator.free(layout);
    const config_json = try stmt.columnTextDup(allocator, 3);
    errdefer allocator.free(config_json);
    return .{
        .layout = projectViewFromValue(layout),
        .title = name,
        .ref = view_id,
        .config_json = config_json,
        .saved = true,
    };
}

pub fn projectTableFieldsFromConfig(allocator: Allocator, db: *SqliteDb, project: []const u8, config_json: []const u8) !ProjectTableFields {
    var result: ProjectTableFields = .{};
    errdefer result.deinit(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch return result;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return result,
    };
    const fields_value = root.get("fields") orelse return result;
    const fields_array = switch (fields_value) {
        .array => |array| array,
        else => return result,
    };
    for (fields_array.items) |field_value| {
        if (result.len == max_project_table_fields) break;
        const field_ref = event_mod.jsonString(field_value) orelse continue;
        const field_key = projectFieldKeyFromViewRef(field_ref) orelse continue;
        if (projectTableFieldsContains(&result, field_key)) continue;
        if (try loadProjectTableField(allocator, db, project, field_key)) |field| {
            result.items[result.len] = field;
            result.len += 1;
        }
    }
    return result;
}

fn loadProjectTableField(allocator: Allocator, db: *SqliteDb, project: []const u8, field_key: []const u8) !?ProjectTableField {
    var stmt = try db.prepare(
        \\SELECT pf.key, pf.name, pf.field_type
        \\FROM project_fields pf
        \\JOIN projects p ON p.id = pf.project_id
        \\WHERE p.name = ?
        \\  AND pf.key = ?
        \\  AND pf.state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, field_key);
    if (!(try stmt.step())) return null;
    const key = try stmt.columnTextDup(allocator, 0);
    errdefer allocator.free(key);
    const name = try stmt.columnTextDup(allocator, 1);
    errdefer allocator.free(name);
    const field_type = try stmt.columnTextDup(allocator, 2);
    errdefer allocator.free(field_type);
    return .{
        .key = key,
        .name = name,
        .field_type = field_type,
    };
}

pub fn bindProjectIssueFilter(stmt: *index.SqliteStmt, start_index: c_int, project: []const u8, filter: ProjectIssueFilter) !void {
    var idx = start_index;
    try stmt.bindInt(idx, if (filter.require_assignee) 1 else 0);
    idx += 1;
    try stmt.bindText(idx, filter.assignee);
    idx += 1;
    try stmt.bindInt(idx, if (filter.bug_label) 1 else 0);
    idx += 1;
    try stmt.bindInt(idx, if (filter.current_iteration) 1 else 0);
    idx += 1;
    try stmt.bindText(idx, project);
}

pub fn projectExists(db: *SqliteDb, project: []const u8) !bool {
    var stmt = try db.prepare(
        \\SELECT 1 FROM projects WHERE name = ?
        \\UNION
        \\SELECT 1 FROM issue_projects WHERE project = ?
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project);
    try stmt.bindText(2, project);
    return try stmt.step();
}

test "project view config loads project table fields" {
    var db = try SqliteDb.openWithOptions(
        std.testing.allocator,
        ":memory:",
        index.sqlite.SQLITE_OPEN_READWRITE | index.sqlite.SQLITE_OPEN_CREATE,
        true,
        .{ .enable_wal = false },
    );
    defer db.deinit();
    try db.exec("CREATE TABLE projects (id TEXT, name TEXT)");
    try db.exec("CREATE TABLE project_fields (id TEXT, project_id TEXT, key TEXT, name TEXT, field_type TEXT, state TEXT)");
    try db.exec("INSERT INTO projects (id, name) VALUES ('p1', 'Plan')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f1', 'p1', 'iteration', 'Iteration', 'text', 'active')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f2', 'p1', 'estimate', 'Estimate', 'number', 'active')");
    try db.exec("INSERT INTO project_fields (id, project_id, key, name, field_type, state) VALUES ('f3', 'p1', 'track', 'Track', 'text', 'removed')");

    var fields = try projectTableFieldsFromConfig(std.testing.allocator, &db, "Plan", project_views.current_iteration_view_config);
    defer fields.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("iteration", fields.items[0].key);
    try std.testing.expectEqualStrings("Iteration", fields.items[0].name);
    try std.testing.expectEqualStrings("text", fields.items[0].field_type);
    try std.testing.expectEqualStrings("estimate", fields.items[1].key);
    try std.testing.expectEqualStrings("number", fields.items[1].field_type);
}
