const std = @import("std");
const event_model = @import("../event/model.zig");
const event_builders = @import("../event/builders.zig");
const event_writer_mod = @import("../event_writer.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const EventWriter = event_writer_mod.EventWriter;

pub const ObjectKind = enum {
    issue,
    pull,

    fn name(self: ObjectKind) []const u8 {
        return switch (self) {
            .issue => "issue",
            .pull => "pull",
        };
    }
};

pub const IssueOpenedOptions = struct {
    issue_id: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
    legacy: event_model.LegacyInfo,
    metadata: event_model.IssueOpenedMetadata = .{},
    command_context: []const u8,
    subject: []const u8,
};

pub const PullOpenedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    title: []const u8,
    body_text: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    legacy: event_model.LegacyInfo,
    metadata: event_model.PullOpenedMetadata = .{},
    command_context: []const u8,
    subject: []const u8,
};

pub const StringEventOptions = struct {
    object_kind: ObjectKind,
    object_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
    occurred_at: []const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const IssueUpdatedOptions = struct {
    issue_id: []const u8,
    occurred_at: []const u8,
    update: event_model.IssueUpdate,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const PullUpdatedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    update: event_model.PullUpdate,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub const PullMergedOptions = struct {
    pull_id: []const u8,
    occurred_at: []const u8,
    merge_oid: []const u8,
    target_oid: ?[]const u8,
    command_context: []const u8,
    subject_suffix: []const u8 = "",
};

pub fn constStringList(values: [][]u8) []const []const u8 {
    return @ptrCast(values);
}

pub fn openedSubjectPrefix(
    allocator: Allocator,
    object_kind: ObjectKind,
    object_id: []const u8,
    provider_name: []const u8,
    remote_number_prefix: []const u8,
    remote_number: u64,
) ![]u8 {
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, object_id);
    return std.fmt.allocPrint(
        allocator,
        "{s}.opened #{s} {s} {s}{d} ",
        .{ object_kind.name(), object_ref, provider_name, remote_number_prefix, remote_number },
    );
}

pub fn writeImportedIssueOpened(allocator: Allocator, writer: *EventWriter, options: IssueOpenedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildIssueOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.issue_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.title,
        options.body_text,
        options.labels,
        options.assignees,
        options.legacy,
        options.metadata,
    );
    defer allocator.free(body);
    try stageAndFreeCommit(allocator, writer, options.command_context, options.subject, body);
}

pub fn writeImportedPullOpened(allocator: Allocator, writer: *EventWriter, options: PullOpenedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullOpenedJsonWithLegacyAndMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.pull_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        options.title,
        options.body_text,
        options.base_ref,
        options.head_ref,
        options.draft,
        options.legacy,
        options.metadata,
    );
    defer allocator.free(body);
    try stageAndFreeCommit(allocator, writer, options.command_context, options.subject, body);
}

pub fn writeImportedStringEvent(allocator: Allocator, writer: *EventWriter, options: StringEventOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = switch (options.object_kind) {
        .issue => try event_builders.buildIssueStringPayloadJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            options.object_id,
            event_uuid,
            idem,
            options.occurred_at,
            writer.stagedEventParents(),
            options.event_type,
            options.payload_key,
            options.payload_value,
        ),
        .pull => try event_builders.buildPullStringPayloadJson(
            allocator,
            writer.cfg,
            writer.nextSeq(),
            options.object_id,
            event_uuid,
            idem,
            options.occurred_at,
            writer.stagedEventParents(),
            options.event_type,
            options.payload_key,
            options.payload_value,
        ),
    };
    defer allocator.free(body);
    var object_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const object_ref = util.shortObjectRef(&object_ref_buf, options.object_id);
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}{s}", .{ options.event_type, object_ref, options.subject_suffix });
    defer allocator.free(subject);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject, body);
}

pub fn writeImportedIssueUpdated(allocator: Allocator, writer: *EventWriter, options: IssueUpdatedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildIssueUpdatedJson(allocator, writer.cfg, writer.nextSeq(), options.issue_id, event_uuid, idem, options.occurred_at, writer.stagedEventParents(), options.update);
    defer allocator.free(body);
    var issue_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const issue_ref = util.shortObjectRef(&issue_ref_buf, options.issue_id);
    const subject = try std.fmt.allocPrint(allocator, "issue.updated #{s}{s}", .{ issue_ref, options.subject_suffix });
    defer allocator.free(subject);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject, body);
}

pub fn writeImportedPullUpdated(allocator: Allocator, writer: *EventWriter, options: PullUpdatedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullUpdatedJson(allocator, writer.cfg, writer.nextSeq(), options.pull_id, event_uuid, idem, options.occurred_at, writer.stagedEventParents(), options.update);
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, options.pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.updated #{s}{s}", .{ pull_ref, options.subject_suffix });
    defer allocator.free(subject);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject, body);
}

pub fn writeImportedPullMerged(allocator: Allocator, writer: *EventWriter, options: PullMergedOptions) !void {
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const body = try event_builders.buildPullMergedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        options.pull_id,
        event_uuid,
        idem,
        options.occurred_at,
        writer.stagedEventParents(),
        if (options.merge_oid.len == 0) null else options.merge_oid,
        options.target_oid,
    );
    defer allocator.free(body);
    var pull_ref_buf: [util.short_object_ref_len]u8 = undefined;
    const pull_ref = util.shortObjectRef(&pull_ref_buf, options.pull_id);
    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}{s}", .{ pull_ref, options.subject_suffix });
    defer allocator.free(subject);
    try stageAndFreeCommit(allocator, writer, options.command_context, subject, body);
}

fn stageAndFreeCommit(allocator: Allocator, writer: *EventWriter, command_context: []const u8, subject: []const u8, body: []const u8) !void {
    const commit = try writer.stage(command_context, subject, body);
    allocator.free(commit);
}
