const std = @import("std");
const event_model = @import("event/model.zig");
const event_builders = @import("event/builders.zig");
const event_writer_mod = @import("event_writer.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Config = repo_mod.Config;
const EventParents = event_model.EventParents;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;

pub const ObjectKind = enum {
    issue,
    pull,

    fn commandContext(self: ObjectKind) []const u8 {
        return switch (self) {
            .issue => "gt issue",
            .pull => "gt pr",
        };
    }

    fn buildStringPayloadJson(
        self: ObjectKind,
        allocator: Allocator,
        cfg: Config,
        seq: u64,
        object_id: []const u8,
        event_uuid: []const u8,
        idem: []const u8,
        occurred_at: []const u8,
        parents: EventParents,
        event_type: []const u8,
        payload_key: []const u8,
        payload_value: []const u8,
    ) ![]u8 {
        return switch (self) {
            .issue => try event_builders.buildIssueStringPayloadJson(
                allocator,
                cfg,
                seq,
                object_id,
                event_uuid,
                idem,
                occurred_at,
                parents,
                event_type,
                payload_key,
                payload_value,
            ),
            .pull => try event_builders.buildPullStringPayloadJson(
                allocator,
                cfg,
                seq,
                object_id,
                event_uuid,
                idem,
                occurred_at,
                parents,
                event_type,
                payload_key,
                payload_value,
            ),
        };
    }
};

pub fn createStringEvent(
    allocator: Allocator,
    object_kind: ObjectKind,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    const command_context = object_kind.commandContext();
    var writer = try EventWriter.init(allocator, command_context);
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try object_kind.buildStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        object_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, object_ref, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write(command_context, subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, object_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}
