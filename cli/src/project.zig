const std = @import("std");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

const default_columns = [_][]const u8{ "Todo", "In Progress", "Done" };

pub fn createProjectCreatedEvent(
    allocator: Allocator,
    name: []const u8,
    description: []const u8,
    columns: []const []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt project create");
    defer writer.deinit();

    const project_id = try newUuidV7(allocator);
    defer allocator.free(project_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();
    const effective_columns = if (columns.len == 0) default_columns[0..] else columns;

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
}

pub fn createProjectColumnEvent(
    allocator: Allocator,
    project_id: []const u8,
    column: []const u8,
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
