const std = @import("std");
const cmd_common = @import("../../cmd_common.zig");
const event_model = @import("../../event/model.zig");
const index = @import("../../index.zig");
const issue_mod = @import("../../issue.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const project_views = @import("views.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const createIssueOpenedWithMetadataEvent = issue_mod.createIssueOpenedWithMetadataEvent;
const createIssueProjectFieldClearedEvent = issue_mod.createIssueProjectFieldClearedEvent;
const createIssueProjectFieldSetEvent = issue_mod.createIssueProjectFieldSetEvent;
const createIssueProjectEvent = issue_mod.createIssueProjectEvent;
const createIssueStringEvent = issue_mod.createIssueStringEvent;
const formValueOwned = shared.formValueOwned;
const percentDecodeForm = shared.percentDecodeForm;
const jsonStringArgument = cmd_common.jsonStringArgument;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const splitCommaFields = util.splitCommaFields;
const sqlite = index.sqlite;
const default_project_priority = project_views.default_project_priority;
const default_project_status = project_views.default_project_status;
const isProjectPriorityValue = project_views.isProjectPriorityValue;
const isProjectStatusValue = project_views.isProjectStatusValue;

pub fn handleProjectItemPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, form_body: []const u8) !void {
    const action_owned = try formTrimmedOwned(allocator, form_body, "action");
    defer allocator.free(action_owned);
    const project_owned = try formTrimmedOwned(allocator, form_body, "project");
    defer allocator.free(project_owned);
    var column_owned = try formTrimmedOwned(allocator, form_body, "column");
    defer allocator.free(column_owned);
    const priority_owned = try formTrimmedOwned(allocator, form_body, "priority");
    defer allocator.free(priority_owned);
    const view_owned = try formTrimmedOwned(allocator, form_body, "view");
    defer allocator.free(view_owned);
    const request_mode_owned = try formTrimmedOwned(allocator, form_body, "request_mode");
    defer allocator.free(request_mode_owned);

    const wants_async = std.mem.eql(u8, request_mode_owned, "async");
    if (project_owned.len == 0) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project is required\n");
        return;
    }
    if (column_owned.len == 0) {
        allocator.free(column_owned);
        column_owned = try allocator.dupe(u8, default_project_status);
    }
    if (!isProjectStatusValue(column_owned)) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Status must be Draft, Todo, WIP, Review, Done, or Failed\n");
        return;
    }
    if (priority_owned.len != 0 and !isProjectPriorityValue(priority_owned)) {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Priority must be P0, P1, P2, or P3\n");
        return;
    }

    if (std.mem.eql(u8, action_owned, "create-issue")) {
        const title_owned = try formTrimmedOwned(allocator, form_body, "title");
        defer allocator.free(title_owned);
        if (title_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Title is required\n");
            return;
        }
        const body_owned = (try formValueOwned(allocator, form_body, "body")) orelse try allocator.dupe(u8, "");
        defer allocator.free(body_owned);
        const labels_owned = (try formValueOwned(allocator, form_body, "labels")) orelse try allocator.dupe(u8, "");
        defer allocator.free(labels_owned);
        const assignees_owned = (try formValueOwned(allocator, form_body, "assignees")) orelse try allocator.dupe(u8, "");
        defer allocator.free(assignees_owned);
        var labels = try splitCommaFields(allocator, labels_owned);
        defer labels.deinit(allocator);
        var assignees = try splitCommaFields(allocator, assignees_owned);
        defer assignees.deinit(allocator);
        const placements = [_]event_model.IssueProjectPlacement{.{
            .project = project_owned,
            .column = column_owned,
        }};
        createIssueOpenedWithMetadataEvent(
            allocator,
            title_owned,
            body_owned,
            labels.items,
            assignees.items,
            .{
                .priority = if (priority_owned.len == 0) default_project_priority else priority_owned,
                .status = column_owned,
                .projects = placements[0..],
            },
        ) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not create issue\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "set-roadmap-dates")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        const start_at_owned = try formTrimmedOwned(allocator, form_body, "start_at");
        defer allocator.free(start_at_owned);
        const raw_end_at_owned = try formValueOwned(allocator, form_body, "end_at");
        defer if (raw_end_at_owned) |value| allocator.free(value);
        const end_at_owned = if (raw_end_at_owned) |value| blk: {
            break :blk try allocator.dupe(u8, std.mem.trim(u8, value, " \t\r\n"));
        } else try formTrimmedOwned(allocator, form_body, "target_at");
        defer allocator.free(end_at_owned);
        if (!isProjectDateValue(start_at_owned) or !isProjectDateValue(end_at_owned)) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Dates must use YYYY-MM-DD\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        const project_id = index.resolveProjectId(allocator, repo, project_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Project not found\n");
            return;
        };
        defer allocator.free(project_id);
        setProjectDateFieldByKey(allocator, repo, issue_id, project_id, project_owned, "start_at", start_at_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update roadmap start date\n");
            return;
        };
        setProjectEndDateField(allocator, repo, issue_id, project_id, project_owned, end_at_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update roadmap end date\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "set-project-field")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        const field_key_owned = try formTrimmedOwned(allocator, form_body, "field");
        defer allocator.free(field_key_owned);
        if (field_key_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project field is required\n");
            return;
        }
        const value_owned = try formTrimmedOwned(allocator, form_body, "value");
        defer allocator.free(value_owned);
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        const project_id = index.resolveProjectId(allocator, repo, project_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Project not found\n");
            return;
        };
        defer allocator.free(project_id);
        setProjectFieldValue(allocator, repo, issue_id, project_id, project_owned, field_key_owned, value_owned) catch |err| {
            switch (err) {
                error.InvalidProjectFieldValue => try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Project field value is invalid\n"),
                else => try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update project field\n"),
            }
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "add-existing")) {
        var issue_refs: std.ArrayList([]u8) = .empty;
        defer freeStringList(allocator, &issue_refs);
        try formTrimmedValuesOwned(allocator, form_body, "issue", &issue_refs);
        if (issue_refs.items.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        var issue_ids: std.ArrayList([]u8) = .empty;
        defer freeStringList(allocator, &issue_ids);
        for (issue_refs.items, 0..) |issue_ref, issue_index| {
            if (containsString(issue_refs.items[0..issue_index], issue_ref)) continue;
            const issue_id = index.resolveIssueId(allocator, repo, issue_ref) catch {
                try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
                return;
            };
            errdefer allocator.free(issue_id);
            try issue_ids.append(allocator, issue_id);
        }
        for (issue_ids.items) |issue_id| {
            addIssueToProjectWithMetadata(allocator, repo, issue_id, project_owned, column_owned, "") catch {
                try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update issue project metadata\n");
                return;
            };
        }
    } else if (std.mem.eql(u8, action_owned, "move")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        moveIssueOnStatusBoard(allocator, issue_id, column_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not update issue project metadata\n");
            return;
        };
    } else if (std.mem.eql(u8, action_owned, "remove")) {
        const issue_ref_owned = try formTrimmedOwned(allocator, form_body, "issue");
        defer allocator.free(issue_ref_owned);
        if (issue_ref_owned.len == 0) {
            try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Issue is required\n");
            return;
        }
        try index.ensureIndex(allocator, repo);
        const issue_id = index.resolveIssueId(allocator, repo, issue_ref_owned) catch {
            try sendProjectItemError(allocator, stream, wants_async, 404, "Not Found", "Issue not found\n");
            return;
        };
        defer allocator.free(issue_id);
        removeIssueProjectPlacements(allocator, repo, issue_id, project_owned, null) catch {
            try sendProjectItemError(allocator, stream, wants_async, 500, "Internal Server Error", "Could not remove issue from project\n");
            return;
        };
    } else {
        try sendProjectItemError(allocator, stream, wants_async, 422, "Unprocessable Entity", "Unknown project item action\n");
        return;
    }

    if (wants_async) {
        try sendResponse(allocator, stream, 204, "No Content", "text/plain", "", null);
        return;
    }
    const location = try projectWorkspaceLocationOwned(allocator, project_owned, view_owned);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn setProjectDateFieldByKey(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    field_key: []const u8,
    value: []const u8,
) !void {
    const field_id = (try projectFieldIdByKeyOwned(allocator, repo, project_id, field_key)) orelse {
        if (value.len == 0) return;
        return error.ProjectFieldNotFound;
    };
    defer allocator.free(field_id);
    try setProjectDateFieldById(allocator, issue_id, project_id, project_ref, field_id, value);
}

fn setProjectEndDateField(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    value: []const u8,
) !void {
    if (try projectFieldIdByKeyOwned(allocator, repo, project_id, "end_at")) |field_id| {
        defer allocator.free(field_id);
        try setProjectDateFieldById(allocator, issue_id, project_id, project_ref, field_id, value);
        if (try projectFieldIdByKeyOwned(allocator, repo, project_id, "target_at")) |legacy_field_id| {
            defer allocator.free(legacy_field_id);
            try setProjectDateFieldById(allocator, issue_id, project_id, project_ref, legacy_field_id, "");
        }
        return;
    }
    if (try projectFieldIdByKeyOwned(allocator, repo, project_id, "target_at")) |legacy_field_id| {
        defer allocator.free(legacy_field_id);
        try setProjectDateFieldById(allocator, issue_id, project_id, project_ref, legacy_field_id, value);
        return;
    }
    if (value.len == 0) return;
    return error.ProjectFieldNotFound;
}

fn setProjectDateFieldById(
    allocator: Allocator,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    field_id: []const u8,
    value: []const u8,
) !void {
    if (value.len == 0) {
        try createIssueProjectFieldClearedEvent(allocator, issue_id, project_id, project_ref, field_id, null);
        return;
    }
    const value_json = try jsonStringArgument(allocator, value);
    defer allocator.free(value_json);
    try createIssueProjectFieldSetEvent(allocator, issue_id, project_id, project_ref, field_id, null, value_json);
}

fn projectFieldIdByKeyOwned(allocator: Allocator, repo: Repo, project_id: []const u8, field_key: []const u8) !?[]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT id
        \\FROM project_fields
        \\WHERE project_id = ? AND key = ? AND state != 'removed'
        \\ORDER BY position, id
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_key);
    if (!(try stmt.step())) return null;
    return try stmt.columnTextDup(allocator, 0);
}

fn setProjectFieldValue(
    allocator: Allocator,
    repo: Repo,
    issue_id: []const u8,
    project_id: []const u8,
    project_ref: []const u8,
    field_key: []const u8,
    value: []const u8,
) !void {
    const field_id = try index.resolveProjectFieldId(allocator, repo, project_id, field_key);
    defer allocator.free(field_id);
    if (value.len == 0) {
        try createIssueProjectFieldClearedEvent(allocator, issue_id, project_id, project_ref, field_id, null);
        return;
    }
    const field_type = try projectFieldTypeOwned(allocator, repo, project_id, field_id);
    defer allocator.free(field_type);
    const value_json = try projectFieldValueJson(allocator, field_type, value);
    defer allocator.free(value_json);
    try createIssueProjectFieldSetEvent(allocator, issue_id, project_id, project_ref, field_id, null, value_json);
}

fn projectFieldTypeOwned(allocator: Allocator, repo: Repo, project_id: []const u8, field_id: []const u8) ![]u8 {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT field_type
        \\FROM project_fields
        \\WHERE project_id = ? AND id = ? AND state != 'removed'
        \\LIMIT 1
    );
    defer stmt.deinit();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, field_id);
    if (!(try stmt.step())) return error.ProjectFieldNotFound;
    return try stmt.columnTextDup(allocator, 0);
}

fn projectFieldValueJson(allocator: Allocator, field_type: []const u8, value: []const u8) ![]u8 {
    if (std.mem.eql(u8, field_type, "number")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch return error.InvalidProjectFieldValue;
        defer parsed.deinit();
        switch (parsed.value) {
            .integer, .float => {},
            else => return error.InvalidProjectFieldValue,
        }
        return try allocator.dupe(u8, value);
    }
    if (std.mem.eql(u8, field_type, "boolean")) {
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidProjectFieldValue;
        return try allocator.dupe(u8, value);
    }
    if (std.mem.eql(u8, field_type, "date") and !isProjectDateValue(value)) return error.InvalidProjectFieldValue;
    return try jsonStringArgument(allocator, value);
}

fn isProjectDateValue(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len != 10) return false;
    for (value, 0..) |char, index_value| {
        if (index_value == 4 or index_value == 7) {
            if (char != '-') return false;
        } else if (!std.ascii.isDigit(char)) {
            return false;
        }
    }
    return true;
}

fn formTrimmedOwned(allocator: Allocator, form_body: []const u8, wanted_key: []const u8) ![]u8 {
    const owned = (try formValueOwned(allocator, form_body, wanted_key)) orelse try allocator.dupe(u8, "");
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

fn formTrimmedValuesOwned(allocator: Allocator, form_body: []const u8, wanted_key: []const u8, values: *std.ArrayList([]u8)) !void {
    var pairs = std.mem.splitScalar(u8, form_body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;

        const value = try percentDecodeForm(allocator, raw_value);
        defer allocator.free(value);
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or containsString(values.items, trimmed)) continue;
        const owned = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(owned);
        try values.append(allocator, owned);
    }
}

fn containsString(values: []const []u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn freeStringList(allocator: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn projectWorkspaceLocationOwned(allocator: Allocator, project: []const u8, view_ref: []const u8) ![]u8 {
    var location: std.ArrayList(u8) = .empty;
    errdefer location.deinit(allocator);
    try location.appendSlice(allocator, "/projects?project=");
    try shared.appendUrlEncoded(&location, allocator, project);
    if (view_ref.len != 0) {
        try location.appendSlice(allocator, "&view=");
        try shared.appendUrlEncoded(&location, allocator, view_ref);
    }
    return location.toOwnedSlice(allocator);
}

fn sendProjectItemError(
    allocator: Allocator,
    stream: @import("compat").net.Stream,
    wants_async: bool,
    status: u16,
    reason: []const u8,
    message: []const u8,
) !void {
    if (wants_async) {
        try sendPlainResponse(allocator, stream, status, reason, message);
        return;
    }
    try sendPlainResponse(allocator, stream, status, reason, message);
}

fn replaceIssueProjectPlacement(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8, column: []const u8, column_filter: ?[]const u8) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project, null);
    defer freeColumnList(allocator, &existing);
    for (existing.items) |existing_column| {
        if (column_filter) |filter| {
            if (!std.mem.eql(u8, existing_column, filter)) continue;
        }
        if (std.mem.eql(u8, existing_column, column)) continue;
        try createIssueProjectEvent(allocator, issue_id, project, existing_column, null, null, false);
    }
    try createIssueProjectEvent(allocator, issue_id, project, column, null, null, true);
}

fn addIssueToProjectWithMetadata(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8, column: []const u8, priority: []const u8) !void {
    try setIssueStatusAndPriority(allocator, issue_id, column, priority);
    try replaceIssueProjectPlacement(allocator, repo, issue_id, project, column, null);
}

fn moveIssueOnStatusBoard(allocator: Allocator, issue_id: []const u8, column: []const u8) !void {
    try createIssueStringEvent(allocator, issue_id, "issue.status_set", "status", column);
}

fn setIssueStatusAndPriority(allocator: Allocator, issue_id: []const u8, column: []const u8, priority: []const u8) !void {
    try createIssueStringEvent(allocator, issue_id, "issue.status_set", "status", column);
    if (priority.len != 0) {
        try createIssueStringEvent(allocator, issue_id, "issue.priority_set", "priority", priority);
    }
}

fn removeIssueProjectPlacements(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8, column_filter: ?[]const u8) !void {
    var existing = try loadIssueProjectColumns(allocator, repo, issue_id, project, column_filter);
    defer freeColumnList(allocator, &existing);
    for (existing.items) |existing_column| {
        try createIssueProjectEvent(allocator, issue_id, project, existing_column, null, null, false);
    }
}

fn loadIssueProjectColumns(allocator: Allocator, repo: Repo, issue_id: []const u8, project: []const u8, column_filter: ?[]const u8) !std.ArrayList([]u8) {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT DISTINCT column_name
        \\FROM issue_projects
        \\WHERE issue_id = ? AND project = ?
        \\  AND (? IS NULL OR column_name = ?)
        \\ORDER BY column_name
    );
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    try stmt.bindText(2, project);
    if (column_filter) |column| {
        try stmt.bindText(3, column);
        try stmt.bindText(4, column);
    } else {
        try stmt.bindNull(3);
        try stmt.bindNull(4);
    }
    var columns: std.ArrayList([]u8) = .empty;
    errdefer freeColumnList(allocator, &columns);
    while (try stmt.step()) {
        const column = try stmt.columnTextDup(allocator, 0);
        try columns.append(allocator, column);
    }
    return columns;
}

fn freeColumnList(allocator: Allocator, columns: *std.ArrayList([]u8)) void {
    for (columns.items) |column| allocator.free(column);
    columns.deinit(allocator);
}

test "project field value json validates typed values" {
    const number_json = try projectFieldValueJson(std.testing.allocator, "number", "3.5");
    defer std.testing.allocator.free(number_json);
    try std.testing.expectEqualStrings("3.5", number_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "number", "soon"));

    const bool_json = try projectFieldValueJson(std.testing.allocator, "boolean", "true");
    defer std.testing.allocator.free(bool_json);
    try std.testing.expectEqualStrings("true", bool_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "boolean", "yes"));

    const date_json = try projectFieldValueJson(std.testing.allocator, "date", "2026-05-16");
    defer std.testing.allocator.free(date_json);
    try std.testing.expectEqualStrings("\"2026-05-16\"", date_json);
    try std.testing.expectError(error.InvalidProjectFieldValue, projectFieldValueJson(std.testing.allocator, "date", "2026/05/16"));
}
