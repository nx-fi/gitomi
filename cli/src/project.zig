const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const issue = @import("issue.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const project = @This();
const out = io.out;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const isProjectFieldType = cmd_common.isProjectFieldType;
const isProjectItemState = cmd_common.isProjectItemState;
const isProjectState = cmd_common.isProjectState;
const isProjectViewLayout = cmd_common.isProjectViewLayout;
const parseBoolOption = cmd_common.parseBoolOption;
const parseNonNegativeIntegerOption = cmd_common.parseNonNegativeIntegerOption;
const requireNonEmptyOption = cmd_common.requireNonEmptyOption;
const validateJsonArgument = cmd_common.validateJsonArgument;

const default_columns = [_][]const u8{ "Draft", "Todo", "WIP", "Review", "Done", "Failed" };

pub fn createProjectCreatedEvent(
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    columns: []const []const u8,
) ![]u8 {
    var writer = try EventWriter.init(allocator, "gt project create");
    defer writer.deinit();

    const project_id = try newUuidV7(allocator);
    errdefer allocator.free(project_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();
    const effective_columns = if (columns.len == 0) default_columns[0..] else columns;
    const slug = try optionalSanitizedRef(allocator, name);
    defer if (slug) |value| allocator.free(value);

    const event_body = try event_mod.buildProjectCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        name,
        description,
        slug,
        effective_columns,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.created @{s} {s}", .{ project_id[0..7], name });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("created project @{s}\n", .{project_id[0..7]});
    try out("  id:     {s}\n", .{project_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
    return project_id;
}

pub fn stageProjectCreatedEvent(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    name: []const u8,
    description: []const u8,
    columns: []const []const u8,
) ![]u8 {
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.stagedEventParents();
    const effective_columns = if (columns.len == 0) default_columns[0..] else columns;
    const slug = try optionalSanitizedRef(allocator, name);
    defer if (slug) |value| allocator.free(value);

    const event_body = try event_mod.buildProjectCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        name,
        description,
        slug,
        effective_columns,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.created @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], name });
    defer allocator.free(subject);
    return try writer.stage("gt project", subject, event_body);
}

pub fn createProjectColumnEvent(
    allocator: Allocator,
    project_id: []const u8,
    column: []const u8,
    column_ref: ?[]const u8,
    add: bool,
) !void {
    var writer = try EventWriter.init(allocator, "gt project column");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();
    const event_type: []const u8 = if (add) "project.column_added" else "project.column_removed";
    const generated_ref = if (add and column_ref == null) try optionalSanitizedRef(allocator, column) else null;
    defer if (generated_ref) |value| allocator.free(value);
    const effective_ref = column_ref orelse generated_ref;

    const event_body = try event_mod.buildProjectColumnEventJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        column,
        effective_ref,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "{s} @{s} {s}", .{ event_type, project_id[0..@min(project_id.len, 7)], column });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} @{s}\n", .{ event_type, project_id[0..@min(project_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectUpdatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    update: event_mod.ProjectUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt project edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.updated @{s}", .{project_id[0..@min(project_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.updated @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectFieldCreatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    field_type: []const u8,
    position: ?i64,
    required: ?bool,
    default_value_json: ?[]const u8,
) ![]u8 {
    var writer = try EventWriter.init(allocator, "gt project field create");
    defer writer.deinit();

    const field_id = try newUuidV7(allocator);
    errdefer allocator.free(field_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
        key,
        name,
        field_type,
        position,
        required,
        default_value_json,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_created @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], key });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_created @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  field:  {s}\n", .{field_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
    return field_id;
}

pub fn stageProjectFieldCreatedEvent(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    key: []const u8,
    name: []const u8,
    field_type: []const u8,
    position: ?i64,
    required: ?bool,
    default_value_json: ?[]const u8,
) ![]u8 {
    const field_id = try newUuidV7(allocator);
    errdefer allocator.free(field_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.stagedEventParents(),
        field_id,
        key,
        name,
        field_type,
        position,
        required,
        default_value_json,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_created @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], key });
    defer allocator.free(subject);
    const commit_oid = try writer.stage("gt project", subject, event_body);
    defer allocator.free(commit_oid);
    return field_id;
}

pub fn createProjectFieldUpdatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    field_id: []const u8,
    update: event_mod.ProjectFieldUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt project field update");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_updated @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], field_id[0..@min(field_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_updated @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectFieldRemovedEvent(allocator: Allocator, project_id: []const u8, field_id: []const u8) !void {
    var writer = try EventWriter.init(allocator, "gt project field remove");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldRemovedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_removed @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], field_id[0..@min(field_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_removed @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectFieldOptionAddedEvent(
    allocator: Allocator,
    project_id: []const u8,
    field_id: []const u8,
    name: []const u8,
    color: ?[]const u8,
    position: ?i64,
) !void {
    var writer = try EventWriter.init(allocator, "gt project field-option add");
    defer writer.deinit();

    const option_id = try newUuidV7(allocator);
    defer allocator.free(option_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldOptionAddedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
        option_id,
        name,
        color,
        position,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_option_added @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], name });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_option_added @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  option: {s}\n", .{option_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn stageProjectFieldOptionAddedEvent(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    field_id: []const u8,
    name: []const u8,
    color: ?[]const u8,
    position: ?i64,
) !void {
    const option_id = try newUuidV7(allocator);
    defer allocator.free(option_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldOptionAddedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.stagedEventParents(),
        field_id,
        option_id,
        name,
        color,
        position,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_option_added @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], name });
    defer allocator.free(subject);
    const commit_oid = try writer.stage("gt project", subject, event_body);
    defer allocator.free(commit_oid);
}

pub fn createProjectFieldOptionUpdatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    field_id: []const u8,
    option_id: []const u8,
    update: event_mod.ProjectFieldOptionUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt project field-option update");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldOptionUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
        option_id,
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_option_updated @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], option_id[0..@min(option_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_option_updated @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectFieldOptionRemovedEvent(allocator: Allocator, project_id: []const u8, field_id: []const u8, option_id: []const u8) !void {
    var writer = try EventWriter.init(allocator, "gt project field-option remove");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectFieldOptionRemovedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        field_id,
        option_id,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.field_option_removed @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], option_id[0..@min(option_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.field_option_removed @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectViewCreatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    name: []const u8,
    layout: []const u8,
    position: ?i64,
    config_json: ?[]const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt project view create");
    defer writer.deinit();

    const view_id = try newUuidV7(allocator);
    defer allocator.free(view_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectViewCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        view_id,
        name,
        layout,
        position,
        config_json,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.view_created @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], name });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.view_created @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  view:   {s}\n", .{view_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn stageProjectViewCreatedEvent(
    allocator: Allocator,
    writer: *EventWriter,
    project_id: []const u8,
    name: []const u8,
    layout: []const u8,
    position: ?i64,
    config_json: ?[]const u8,
) !void {
    const view_id = try newUuidV7(allocator);
    defer allocator.free(view_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectViewCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.stagedEventParents(),
        view_id,
        name,
        layout,
        position,
        config_json,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.view_created @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], name });
    defer allocator.free(subject);
    const commit_oid = try writer.stage("gt project", subject, event_body);
    defer allocator.free(commit_oid);
}

pub fn createProjectViewUpdatedEvent(
    allocator: Allocator,
    project_id: []const u8,
    view_id: []const u8,
    update: event_mod.ProjectViewUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt project view update");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectViewUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        view_id,
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.view_updated @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], view_id[0..@min(view_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.view_updated @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createProjectViewRemovedEvent(allocator: Allocator, project_id: []const u8, view_id: []const u8) !void {
    var writer = try EventWriter.init(allocator, "gt project view remove");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildProjectViewRemovedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        project_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        view_id,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "project.view_removed @{s} {s}", .{ project_id[0..@min(project_id.len, 7)], view_id[0..@min(view_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt project", subject, event_body);
    defer allocator.free(commit_oid);

    try out("project.view_removed @{s}\n", .{project_id[0..@min(project_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

fn optionalSanitizedRef(allocator: Allocator, value: []const u8) !?[]u8 {
    const sanitized = try util.sanitizeRefSegment(allocator, value);
    if (sanitized.len != 0) return sanitized;
    allocator.free(sanitized);
    return null;
}

pub fn cmdProject(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt project: expected subcommand 'list', 'create', 'edit', 'column', 'field', 'field-option', 'view', 'add', or 'remove'\n", .{});
        return CliError.UserError;
    }

    var command_repo = cmd_common.CommandRepo.init(allocator);
    defer command_repo.deinit();

    if (std.mem.eql(u8, args[0], "list")) {
        var json = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt project list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const repo = try command_repo.indexedRepo();
        try index.listProjectsFromIndex(allocator, repo, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "create")) {
        var name: ?[]const u8 = null;
        var description: []const u8 = "";
        var columns: std.ArrayList([]const u8) = .empty;
        defer columns.deinit(allocator);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--name") or std.mem.eql(u8, args[i], "-n")) {
                name = try util.requireValue(args, &i, "--name");
            } else if (std.mem.eql(u8, args[i], "--description") or std.mem.eql(u8, args[i], "-d")) {
                description = try util.requireValue(args, &i, "--description");
            } else if (std.mem.eql(u8, args[i], "--column") or std.mem.eql(u8, args[i], "-c")) {
                const value = try util.requireValue(args, &i, "--column");
                try requireNonEmptyOption("gt project create", "--column", value);
                try columns.append(allocator, value);
            } else {
                try io.eprint("gt project create: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (name == null or std.mem.trim(u8, name.?, " \t\r\n").len == 0) {
            try io.eprint("gt project create: --name is required\n", .{});
            return CliError.UserError;
        }
        const project_id = try project.createProjectCreatedEvent(allocator, name.?, description, columns.items);
        defer allocator.free(project_id);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt project edit: PROJECT is required\n", .{});
            return CliError.UserError;
        }
        var update = event_mod.ProjectUpdate{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--name")) {
                update.name = try util.requireValue(args, &i, "--name");
            } else if (std.mem.eql(u8, arg, "--description")) {
                update.description = try util.requireValue(args, &i, "--description");
            } else if (std.mem.eql(u8, arg, "--state")) {
                const state = try util.requireValue(args, &i, "--state");
                if (!isProjectState(state)) {
                    try io.eprint("gt project edit: --state must be open or closed\n", .{});
                    return CliError.UserError;
                }
                update.state = state;
            } else {
                try io.eprint("gt project edit: unknown option '{s}'\n", .{arg});
                return CliError.UserError;
            }
        }
        if (!update.hasChanges()) {
            try io.eprint("gt project edit: at least one update option is required\n", .{});
            return CliError.UserError;
        }
        if (update.name) |name| try requireNonEmptyOption("gt project edit", "--name", name);
        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        try project.createProjectUpdatedEvent(allocator, project_id, update);
        return;
    }

    if (std.mem.eql(u8, args[0], "column")) {
        if (args.len != 4) {
            try io.eprint("gt project column: expected PROJECT add|remove COLUMN\n", .{});
            return CliError.UserError;
        }
        const op = args[2];
        if (!std.mem.eql(u8, op, "add") and !std.mem.eql(u8, op, "remove")) {
            try io.eprint("gt project column: expected add or remove\n", .{});
            return CliError.UserError;
        }
        try requireNonEmptyOption("gt project column", "COLUMN", args[3]);
        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        if (std.mem.eql(u8, op, "remove")) {
            var resolved_column = try command_repo.resolveProjectColumn(project_id, args[3]);
            defer resolved_column.deinit(allocator);
            try project.createProjectColumnEvent(allocator, project_id, resolved_column.column, resolved_column.column_ref, false);
        } else {
            try project.createProjectColumnEvent(allocator, project_id, args[3], null, true);
        }
        return;
    }

    if (std.mem.eql(u8, args[0], "field")) {
        if (args.len < 3) {
            try io.eprint("gt project field: expected PROJECT create|update|remove\n", .{});
            return CliError.UserError;
        }
        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        const op = args[2];
        if (std.mem.eql(u8, op, "create")) {
            var key: ?[]const u8 = null;
            var name: ?[]const u8 = null;
            var field_type: ?[]const u8 = null;
            var position: ?i64 = null;
            var required: ?bool = null;
            var default_value_json: ?[]u8 = null;
            defer if (default_value_json) |value| allocator.free(value);
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--key")) {
                    key = try util.requireValue(args, &i, "--key");
                } else if (std.mem.eql(u8, arg, "--name")) {
                    name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--type")) {
                    field_type = try util.requireValue(args, &i, "--type");
                } else if (std.mem.eql(u8, arg, "--position")) {
                    position = try parseNonNegativeIntegerOption("gt project field create", "--position", try util.requireValue(args, &i, "--position"));
                } else if (std.mem.eql(u8, arg, "--required")) {
                    required = try parseBoolOption("gt project field create", "--required", try util.requireValue(args, &i, "--required"));
                } else if (std.mem.eql(u8, arg, "--default-json")) {
                    const raw_json = try util.requireValue(args, &i, "--default-json");
                    try validateJsonArgument(allocator, "gt project field create", "--default-json", raw_json);
                    if (default_value_json) |old| allocator.free(old);
                    default_value_json = try allocator.dupe(u8, raw_json);
                } else {
                    try io.eprint("gt project field create: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (key == null or name == null or field_type == null) {
                try io.eprint("gt project field create: --key, --name, and --type are required\n", .{});
                return CliError.UserError;
            }
            try requireNonEmptyOption("gt project field create", "--key", key.?);
            try requireNonEmptyOption("gt project field create", "--name", name.?);
            if (!isProjectFieldType(field_type.?)) {
                try io.eprint("gt project field create: --type must be text, number, date, boolean, single_select, multi_select, user, or issue_ref\n", .{});
                return CliError.UserError;
            }
            const field_id = try project.createProjectFieldCreatedEvent(allocator, project_id, key.?, name.?, field_type.?, position, required, default_value_json);
            defer allocator.free(field_id);
            return;
        }

        if (std.mem.eql(u8, op, "update")) {
            if (args.len < 4) {
                try io.eprint("gt project field update: FIELD is required\n", .{});
                return CliError.UserError;
            }
            const field_id = try command_repo.resolveProjectFieldId(project_id, args[3]);
            defer allocator.free(field_id);
            var update = event_mod.ProjectFieldUpdate{};
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--key")) {
                    update.key = try util.requireValue(args, &i, "--key");
                } else if (std.mem.eql(u8, arg, "--name")) {
                    update.name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--type")) {
                    const field_type = try util.requireValue(args, &i, "--type");
                    if (!isProjectFieldType(field_type)) {
                        try io.eprint("gt project field update: --type must be text, number, date, boolean, single_select, multi_select, user, or issue_ref\n", .{});
                        return CliError.UserError;
                    }
                    update.field_type = field_type;
                } else if (std.mem.eql(u8, arg, "--position")) {
                    update.position = try parseNonNegativeIntegerOption("gt project field update", "--position", try util.requireValue(args, &i, "--position"));
                } else if (std.mem.eql(u8, arg, "--required")) {
                    update.required = try parseBoolOption("gt project field update", "--required", try util.requireValue(args, &i, "--required"));
                } else if (std.mem.eql(u8, arg, "--default-json")) {
                    const raw_json = try util.requireValue(args, &i, "--default-json");
                    try validateJsonArgument(allocator, "gt project field update", "--default-json", raw_json);
                    update.default_value_json = raw_json;
                } else if (std.mem.eql(u8, arg, "--state")) {
                    const state = try util.requireValue(args, &i, "--state");
                    if (!isProjectItemState(state)) {
                        try io.eprint("gt project field update: --state must be active or removed\n", .{});
                        return CliError.UserError;
                    }
                    update.state = state;
                } else {
                    try io.eprint("gt project field update: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (!update.hasChanges()) {
                try io.eprint("gt project field update: at least one update option is required\n", .{});
                return CliError.UserError;
            }
            if (update.key) |key| try requireNonEmptyOption("gt project field update", "--key", key);
            if (update.name) |name| try requireNonEmptyOption("gt project field update", "--name", name);
            try project.createProjectFieldUpdatedEvent(allocator, project_id, field_id, update);
            return;
        }

        if (std.mem.eql(u8, op, "remove")) {
            if (args.len != 4) {
                try io.eprint("gt project field remove: expected FIELD\n", .{});
                return CliError.UserError;
            }
            const field_id = try command_repo.resolveProjectFieldId(project_id, args[3]);
            defer allocator.free(field_id);
            try project.createProjectFieldRemovedEvent(allocator, project_id, field_id);
            return;
        }

        try io.eprint("gt project field: expected create, update, or remove\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "field-option")) {
        if (args.len < 4) {
            try io.eprint("gt project field-option: expected PROJECT FIELD add|update|remove\n", .{});
            return CliError.UserError;
        }
        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        const field_id = try command_repo.resolveProjectFieldId(project_id, args[2]);
        defer allocator.free(field_id);
        const op = args[3];
        if (std.mem.eql(u8, op, "add")) {
            var name: ?[]const u8 = null;
            var color: ?[]const u8 = null;
            var position: ?i64 = null;
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--name")) {
                    name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--color")) {
                    color = try util.requireValue(args, &i, "--color");
                } else if (std.mem.eql(u8, arg, "--position")) {
                    position = try parseNonNegativeIntegerOption("gt project field-option add", "--position", try util.requireValue(args, &i, "--position"));
                } else {
                    try io.eprint("gt project field-option add: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (name == null) {
                try io.eprint("gt project field-option add: --name is required\n", .{});
                return CliError.UserError;
            }
            try requireNonEmptyOption("gt project field-option add", "--name", name.?);
            try project.createProjectFieldOptionAddedEvent(allocator, project_id, field_id, name.?, color, position);
            return;
        }

        if (std.mem.eql(u8, op, "update")) {
            if (args.len < 5) {
                try io.eprint("gt project field-option update: OPTION is required\n", .{});
                return CliError.UserError;
            }
            const option_id = try command_repo.resolveProjectFieldOptionId(project_id, field_id, args[4]);
            defer allocator.free(option_id);
            var update = event_mod.ProjectFieldOptionUpdate{};
            var i: usize = 5;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--name")) {
                    update.name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--color")) {
                    update.color = try util.requireValue(args, &i, "--color");
                } else if (std.mem.eql(u8, arg, "--position")) {
                    update.position = try parseNonNegativeIntegerOption("gt project field-option update", "--position", try util.requireValue(args, &i, "--position"));
                } else if (std.mem.eql(u8, arg, "--state")) {
                    const state = try util.requireValue(args, &i, "--state");
                    if (!isProjectItemState(state)) {
                        try io.eprint("gt project field-option update: --state must be active or removed\n", .{});
                        return CliError.UserError;
                    }
                    update.state = state;
                } else {
                    try io.eprint("gt project field-option update: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (!update.hasChanges()) {
                try io.eprint("gt project field-option update: at least one update option is required\n", .{});
                return CliError.UserError;
            }
            if (update.name) |name| try requireNonEmptyOption("gt project field-option update", "--name", name);
            try project.createProjectFieldOptionUpdatedEvent(allocator, project_id, field_id, option_id, update);
            return;
        }

        if (std.mem.eql(u8, op, "remove")) {
            if (args.len != 5) {
                try io.eprint("gt project field-option remove: expected OPTION\n", .{});
                return CliError.UserError;
            }
            const option_id = try command_repo.resolveProjectFieldOptionId(project_id, field_id, args[4]);
            defer allocator.free(option_id);
            try project.createProjectFieldOptionRemovedEvent(allocator, project_id, field_id, option_id);
            return;
        }

        try io.eprint("gt project field-option: expected add, update, or remove\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "view")) {
        if (args.len < 3) {
            try io.eprint("gt project view: expected PROJECT create|update|remove\n", .{});
            return CliError.UserError;
        }
        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        const op = args[2];
        if (std.mem.eql(u8, op, "create")) {
            var name: ?[]const u8 = null;
            var layout: ?[]const u8 = null;
            var position: ?i64 = null;
            var config_json: ?[]u8 = null;
            defer if (config_json) |value| allocator.free(value);
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--name")) {
                    name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--layout")) {
                    layout = try util.requireValue(args, &i, "--layout");
                } else if (std.mem.eql(u8, arg, "--position")) {
                    position = try parseNonNegativeIntegerOption("gt project view create", "--position", try util.requireValue(args, &i, "--position"));
                } else if (std.mem.eql(u8, arg, "--config-json")) {
                    const raw_json = try util.requireValue(args, &i, "--config-json");
                    try validateJsonArgument(allocator, "gt project view create", "--config-json", raw_json);
                    if (config_json) |old| allocator.free(old);
                    config_json = try allocator.dupe(u8, raw_json);
                } else {
                    try io.eprint("gt project view create: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (name == null or layout == null) {
                try io.eprint("gt project view create: --name and --layout are required\n", .{});
                return CliError.UserError;
            }
            try requireNonEmptyOption("gt project view create", "--name", name.?);
            if (!isProjectViewLayout(layout.?)) {
                try io.eprint("gt project view create: --layout must be table, board, or roadmap\n", .{});
                return CliError.UserError;
            }
            try project.createProjectViewCreatedEvent(allocator, project_id, name.?, layout.?, position, config_json);
            return;
        }

        if (std.mem.eql(u8, op, "update")) {
            if (args.len < 4) {
                try io.eprint("gt project view update: VIEW is required\n", .{});
                return CliError.UserError;
            }
            const view_id = try command_repo.resolveProjectViewId(project_id, args[3]);
            defer allocator.free(view_id);
            var update = event_mod.ProjectViewUpdate{};
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--name")) {
                    update.name = try util.requireValue(args, &i, "--name");
                } else if (std.mem.eql(u8, arg, "--layout")) {
                    const layout = try util.requireValue(args, &i, "--layout");
                    if (!isProjectViewLayout(layout)) {
                        try io.eprint("gt project view update: --layout must be table, board, or roadmap\n", .{});
                        return CliError.UserError;
                    }
                    update.layout = layout;
                } else if (std.mem.eql(u8, arg, "--position")) {
                    update.position = try parseNonNegativeIntegerOption("gt project view update", "--position", try util.requireValue(args, &i, "--position"));
                } else if (std.mem.eql(u8, arg, "--config-json")) {
                    const raw_json = try util.requireValue(args, &i, "--config-json");
                    try validateJsonArgument(allocator, "gt project view update", "--config-json", raw_json);
                    update.config_json = raw_json;
                } else if (std.mem.eql(u8, arg, "--state")) {
                    const state = try util.requireValue(args, &i, "--state");
                    if (!isProjectItemState(state)) {
                        try io.eprint("gt project view update: --state must be active or removed\n", .{});
                        return CliError.UserError;
                    }
                    update.state = state;
                } else {
                    try io.eprint("gt project view update: unknown option '{s}'\n", .{arg});
                    return CliError.UserError;
                }
            }
            if (!update.hasChanges()) {
                try io.eprint("gt project view update: at least one update option is required\n", .{});
                return CliError.UserError;
            }
            if (update.name) |name| try requireNonEmptyOption("gt project view update", "--name", name);
            try project.createProjectViewUpdatedEvent(allocator, project_id, view_id, update);
            return;
        }

        if (std.mem.eql(u8, op, "remove")) {
            if (args.len != 4) {
                try io.eprint("gt project view remove: expected VIEW\n", .{});
                return CliError.UserError;
            }
            const view_id = try command_repo.resolveProjectViewId(project_id, args[3]);
            defer allocator.free(view_id);
            try project.createProjectViewRemovedEvent(allocator, project_id, view_id);
            return;
        }

        try io.eprint("gt project view: expected create, update, or remove\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "remove")) {
        if (args.len < 3) {
            try io.eprint("gt project {s}: expected PROJECT ISSUE --column COLUMN\n", .{args[0]});
            return CliError.UserError;
        }
        var column: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--column") or std.mem.eql(u8, args[i], "-c")) {
                column = try util.requireValue(args, &i, "--column");
            } else {
                try io.eprint("gt project {s}: unknown option '{s}'\n", .{ args[0], args[i] });
                return CliError.UserError;
            }
        }
        if (column == null or std.mem.trim(u8, column.?, " \t\r\n").len == 0) {
            try io.eprint("gt project {s}: --column is required\n", .{args[0]});
            return CliError.UserError;
        }

        const project_id = try command_repo.resolveProjectId(args[1]);
        defer allocator.free(project_id);
        const project_name = try command_repo.projectName(project_id);
        defer allocator.free(project_name);
        const issue_id = try command_repo.resolveIssueId(args[2]);
        defer allocator.free(issue_id);
        var resolved_column = try command_repo.resolveProjectColumn(project_id, column.?);
        defer resolved_column.deinit(allocator);
        try issue.createIssueProjectEvent(allocator, issue_id, project_name, resolved_column.column, project_id, resolved_column.column_ref, std.mem.eql(u8, args[0], "add"));
        return;
    }

    try io.eprint("gt project: expected subcommand 'list', 'create', 'edit', 'column', 'field', 'field-option', 'view', 'add', or 'remove'\n", .{});
    return CliError.UserError;
}
