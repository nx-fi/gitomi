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
const shortObjectRef = util.shortObjectRef;
const short_object_ref_len = util.short_object_ref_len;

pub fn createCommentAddedEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) !void {
    try createCommentAddedEventWithMetadata(allocator, parent_kind, parent_id, body, .{});
}

pub fn createCommentReplyEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
    body: []const u8,
) !void {
    try createCommentAddedEventWithMetadata(allocator, parent_kind, parent_id, body, .{
        .reply_parent_id = if (reply_parent_id.len == 0) null else reply_parent_id,
        .reply_parent_hash = if (reply_parent_hash.len == 0) null else reply_parent_hash,
    });
}

pub fn createCommentAddedEventWithMetadata(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
    metadata: event_mod.CommentAddedMetadata,
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
    var related: std.ArrayList([]const u8) = .empty;
    defer related.deinit(allocator);
    try related.appendSlice(allocator, writer.related_heads);
    if (metadata.reply_parent_hash) |hash| {
        if (hash.len != 0 and !containsString(related.items, hash)) try related.append(allocator, hash);
    }
    const event_parents = event_mod.EventParents{
        .log = writer.prepared_parents.old_head,
        .causal = writer.prepared_parents.causal_heads,
        .related = related.items,
    };

    const event_body = try event_mod.buildCommentAddedJsonWithMetadata(
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
        metadata,
    );
    defer allocator.free(event_body);

    var comment_ref_buf: [short_object_ref_len]u8 = undefined;
    const comment_ref = shortObjectRef(&comment_ref_buf, comment_id);
    const subject = try std.fmt.allocPrint(allocator, "comment.added comment:{s}", .{comment_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt comment", subject, event_body);
    defer allocator.free(commit_oid);

    try out("added comment comment:{s}\n", .{comment_ref});
    try out("  id:     {s}\n", .{comment_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
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
