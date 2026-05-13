const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;
const EventWriter = event_writer_mod.EventWriter;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

pub fn createPullOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) !void {
    var writer = try EventWriter.init(allocator, "gt pull open");
    defer writer.deinit();

    const pull_id = try newUuidV7(allocator);
    defer allocator.free(pull_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullOpenedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        body,
        base_ref,
        head_ref,
        draft,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "pull.opened #{s} {s}", .{ pull_id[0..7], title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pull", subject, event_body);
    defer allocator.free(commit_oid);

    try out("opened pull #{s}\n", .{pull_id[0..7]});
    try out("  id:     {s}\n", .{pull_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullStringEvent(
    allocator: Allocator,
    pull_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt pull");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, pull_id[0..@min(pull_id.len, 7)], payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pull", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, pull_id[0..@min(pull_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullMergedEvent(
    allocator: Allocator,
    pull_id: []const u8,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt pull");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullMergedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        merge_oid,
        target_oid,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_id[0..@min(pull_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pull", subject, event_body);
    defer allocator.free(commit_oid);

    try out("pull.merged #{s}\n", .{pull_id[0..@min(pull_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createPullUpdatedEvent(
    allocator: Allocator,
    pull_id: []const u8,
    update: event_mod.PullUpdate,
) !void {
    if (!update.hasChanges()) {
        try eprint("gt pull edit: at least one update option is required\n", .{});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, "gt pull edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildPullUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "pull.updated #{s}", .{pull_id[0..@min(pull_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt pull", subject, event_body);
    defer allocator.free(commit_oid);

    try out("pull.updated #{s}\n", .{pull_id[0..@min(pull_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}
