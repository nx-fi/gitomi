const std = @import("std");
const errors = @import("errors.zig");
const event_builders = @import("event/builders.zig");
const event_writer_mod = @import("event_writer.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const out = io.out;
const eprint = io.eprint;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;

pub fn createReactionEvent(
    allocator: Allocator,
    object_kind: []const u8,
    object_id: []const u8,
    raw_emoji: []const u8,
    add: bool,
) !void {
    if (!isReactableKind(object_kind)) {
        try eprint("gt reaction: target kind must be issue, pr, pull, project, or comment\n", .{});
        return CliError.InvalidArgument;
    }
    const canonical_kind: []const u8 = if (std.mem.eql(u8, object_kind, "pr")) "pull" else object_kind;
    const emoji = normalizeEmoji(raw_emoji);
    if (std.mem.trim(u8, emoji, " \t\r\n").len == 0) {
        try eprint("gt reaction: emoji must not be empty\n", .{});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, "gt reaction");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_type = try std.fmt.allocPrint(allocator, "{s}.reaction_{s}", .{ canonical_kind, if (add) "added" else "removed" });
    defer allocator.free(event_type);
    const event_body = try event_builders.buildReactionJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        canonical_kind,
        object_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        event_type,
        emoji,
        &.{},
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ event_type, canonical_kind, emoji });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt reaction", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} {s}\n", .{ event_type, emoji });
    try out("  target: {s}:{s}\n", .{ canonical_kind, object_id });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

fn isReactableKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "issue") or
        std.mem.eql(u8, value, "pull") or
        std.mem.eql(u8, value, "pr") or
        std.mem.eql(u8, value, "project") or
        std.mem.eql(u8, value, "comment");
}

fn normalizeEmoji(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, value, "+1") or std.mem.eql(u8, value, "thumbs-up") or std.mem.eql(u8, value, "thumbsup")) return "\xF0\x9F\x91\x8D";
    if (std.mem.eql(u8, value, "-1") or std.mem.eql(u8, value, "thumbs-down")) return "\xF0\x9F\x91\x8E";
    if (std.mem.eql(u8, value, "heart")) return "\xE2\x9D\xA4\xEF\xB8\x8F";
    if (std.mem.eql(u8, value, "eyes")) return "\xF0\x9F\x91\x80";
    if (std.mem.eql(u8, value, "hooray") or std.mem.eql(u8, value, "tada")) return "\xF0\x9F\x8E\x89";
    if (std.mem.eql(u8, value, "laugh")) return "\xF0\x9F\x98\x84";
    if (std.mem.eql(u8, value, "confused")) return "\xF0\x9F\x98\x95";
    return value;
}
