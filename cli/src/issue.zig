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
const buildIssueOpenedJson = event_mod.buildIssueOpenedJson;
const buildIssueProjectEventJson = event_mod.buildIssueProjectEventJson;
const buildIssueStringPayloadJson = event_mod.buildIssueStringPayloadJson;
const buildIssueUpdatedJson = event_mod.buildIssueUpdatedJson;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const shortObjectRef = util.shortObjectRef;
const short_object_ref_len = util.short_object_ref_len;

pub fn createIssueOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue open");
    defer writer.deinit();

    const issue_id = try newUuidV7(allocator);
    defer allocator.free(issue_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueOpenedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        title,
        body,
        labels,
        assignees,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.opened #{s} {s}", .{ issue_ref, title });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("opened issue #{s}\n", .{issue_ref});
    try out("  id:     {s}\n", .{issue_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueStringEvent(
    allocator: Allocator,
    issue_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueStringPayloadJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, issue_ref, payload_value });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, issue_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueUpdatedEvent(
    allocator: Allocator,
    issue_id: []const u8,
    update: event_mod.IssueUpdate,
) !void {
    if (!update.hasChanges()) {
        try eprint("gt issue edit: at least one update option is required\n", .{});
        return CliError.InvalidArgument;
    }

    var writer = try EventWriter.init(allocator, "gt issue edit");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = try buildIssueUpdatedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        update,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.updated #{s}", .{issue_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("issue.updated #{s}\n", .{issue_ref});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createIssueProjectEvent(
    allocator: Allocator,
    issue_id: []const u8,
    project: []const u8,
    column: []const u8,
    add: bool,
) !void {
    var writer = try EventWriter.init(allocator, "gt issue project");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();
    const event_type: []const u8 = if (add) "issue.project_added" else "issue.project_removed";

    const event_body = try buildIssueProjectEventJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        event_type,
        project,
        column,
    );
    defer allocator.free(event_body);

    var issue_ref_buf: [short_object_ref_len]u8 = undefined;
    const issue_ref = shortObjectRef(&issue_ref_buf, issue_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, issue_ref, project });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt issue", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, issue_ref });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}
