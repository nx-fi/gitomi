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

pub fn createMilestoneCreatedEvent(
    allocator: Allocator,
    title: []const u8,
    description: []const u8,
    due_at: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone create");
    defer writer.deinit();

    const milestone_id = try newUuidV7(allocator);
    defer allocator.free(milestone_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneCreatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        description,
        due_at,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "milestone.created ^{s} {s}", .{ milestone_id[0..7], title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("created milestone ^{s}\n", .{milestone_id[0..7]});
    try out("  id:     {s}\n", .{milestone_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createMilestoneUpdatedEvent(
    allocator: Allocator,
    milestone_id: []const u8,
    update: event_mod.MilestoneUpdate,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    const short_id = milestone_id[0..@min(milestone_id.len, 7)];
    const subject = try std.fmt.allocPrint(allocator, "milestone.updated ^{s}", .{short_id});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("milestone.updated ^{s}\n", .{short_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createMilestoneStringEvent(
    allocator: Allocator,
    milestone_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt milestone");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildMilestoneStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        milestone_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    const short_id = milestone_id[0..@min(milestone_id.len, 7)];
    const subject = try std.fmt.allocPrint(allocator, "{s} ^{s} {s}", .{ event_type, short_id, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt milestone", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} ^{s}\n", .{ event_type, short_id });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}
