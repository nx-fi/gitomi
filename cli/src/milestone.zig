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
