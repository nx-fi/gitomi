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

pub fn createCommentAddedEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt comment");
    defer writer.deinit();

    const comment_id = try newUuidV7(allocator);
    defer allocator.free(comment_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try event_mod.buildCommentAddedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        comment_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        parent_kind,
        parent_id,
        body,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "comment.added #{s}", .{comment_id[0..7]});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt comment", subject, event_body);
    defer allocator.free(commit_oid);

    try out("added comment #{s}\n", .{comment_id[0..7]});
    try out("  id:     {s}\n", .{comment_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createCommentBodySetEvent(allocator: Allocator, comment_id: []const u8, body: []const u8) !void {
    try createCommentUpdateEvent(allocator, comment_id, body, null, .body_set);
}

pub fn createCommentRedactedEvent(allocator: Allocator, comment_id: []const u8, reason: ?[]const u8) !void {
    try createCommentUpdateEvent(allocator, comment_id, "", reason, .redacted);
}

const CommentUpdateKind = enum {
    body_set,
    redacted,
};

fn createCommentUpdateEvent(
    allocator: Allocator,
    comment_id: []const u8,
    body: []const u8,
    reason: ?[]const u8,
    kind: CommentUpdateKind,
) !void {
    var writer = try EventWriter.init(allocator, "gt comment");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = switch (kind) {
        .body_set => try event_mod.buildCommentBodySetJson(allocator, writer.cfg, writer.nextSeq(), comment_id, event_uuid, idem, occurred_at, event_parents, body),
        .redacted => try event_mod.buildCommentRedactedJson(allocator, writer.cfg, writer.nextSeq(), comment_id, event_uuid, idem, occurred_at, event_parents, reason),
    };
    defer allocator.free(event_body);

    const event_type: []const u8 = switch (kind) {
        .body_set => "comment.body_set",
        .redacted => "comment.redacted",
    };
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt comment", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}
