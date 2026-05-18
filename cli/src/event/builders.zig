const std = @import("std");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Config = repo_mod.Config;
const event_schema = model.event_schema;
const EventParents = model.EventParents;
const LegacyInfo = model.LegacyInfo;
const ActionRunRequestedMetadata = model.ActionRunRequestedMetadata;
const ActionRunCompletedMetadata = model.ActionRunCompletedMetadata;
const IssueProjectPlacement = model.IssueProjectPlacement;
const IssueOpenedMetadata = model.IssueOpenedMetadata;
const PullOpenedMetadata = model.PullOpenedMetadata;
const PullMergedMetadata = model.PullMergedMetadata;
const CommentAddedMetadata = model.CommentAddedMetadata;
const DelegationSigningKey = model.DelegationSigningKey;
const IssueUpdate = model.IssueUpdate;
const ProjectUpdate = model.ProjectUpdate;
const ProjectFieldUpdate = model.ProjectFieldUpdate;
const ProjectFieldOptionUpdate = model.ProjectFieldOptionUpdate;
const ProjectViewUpdate = model.ProjectViewUpdate;
const MilestoneUpdate = model.MilestoneUpdate;
const LabelUpdate = model.LabelUpdate;
const PullUpdate = model.PullUpdate;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonFieldInteger = json_writer.appendJsonFieldInteger;
const appendJsonString = json_writer.appendJsonString;
const JsonRootKind = json_writer.JsonRootKind;

fn appendSourceIdentityFields(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    source_identity: ?[]const u8,
    source_email: ?[]const u8,
    source_avatar_url: ?[]const u8,
) !void {
    if (source_identity) |value| {
        if (value.len != 0) try appendJsonFieldString(buf, allocator, "source_identity", value, true);
    }
    if (source_email) |value| {
        if (value.len != 0) try appendJsonFieldString(buf, allocator, "source_email", value, true);
    }
    if (source_avatar_url) |value| {
        if (value.len != 0) try appendJsonFieldString(buf, allocator, "source_avatar_url", value, true);
    }
}

pub fn buildIssueOpenedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
) ![]u8 {
    return buildIssueOpenedJsonWithLegacy(
        allocator,
        cfg,
        seq,
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        title,
        body,
        labels,
        assignees,
        .{},
    );
}

pub fn buildIssueOpenedJsonWithLegacy(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
    legacy: LegacyInfo,
) ![]u8 {
    return buildIssueOpenedJsonWithLegacyAndMetadata(
        allocator,
        cfg,
        seq,
        issue_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        title,
        body,
        labels,
        assignees,
        legacy,
        .{},
    );
}

pub fn buildIssueOpenedJsonWithLegacyAndMetadata(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    labels: []const []const u8,
    assignees: []const []const u8,
    legacy: LegacyInfo,
    metadata: IssueOpenedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefixWithLegacy(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, "issue.opened", "issue", legacy);
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "title", title, true);
    if (body.len != 0) {
        try appendJsonFieldString(&buf, allocator, "body", body, true);
    }
    if (labels.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "labels", labels, true);
    }
    if (assignees.len != 0) {
        try appendJsonFieldStringArray(&buf, allocator, "assignees", assignees, true);
    }
    if (metadata.source_author) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "source_author", value, true);
    }
    try appendSourceIdentityFields(&buf, allocator, metadata.source_identity, metadata.source_email, metadata.source_avatar_url);
    if (metadata.milestone) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "milestone", value, true);
    }
    if (metadata.issue_type) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "type", value, true);
    }
    if (metadata.priority) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "priority", value, true);
    }
    if (metadata.status) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "status", value, true);
    }
    if (metadata.projects.len != 0) {
        try appendIssueProjectsField(&buf, allocator, "projects", metadata.projects, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueProjectEventJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    project: []const u8,
    column: []const u8,
    project_ref: ?[]const u8,
    column_ref: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, event_type, "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "project", project, true);
    try appendJsonFieldString(&buf, allocator, "column", column, project_ref != null or column_ref != null);
    if (project_ref) |value| try appendJsonFieldString(&buf, allocator, "project_ref", value, column_ref != null);
    if (column_ref) |value| try appendJsonFieldString(&buf, allocator, "column_ref", value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueRelationshipEventJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    kind: []const u8,
    target_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, event_type, "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "kind", kind, true);
    try appendJsonFieldString(&buf, allocator, "target_id", target_id, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueConcurrentGroupEventJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    group: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, event_type, "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "group", group, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueProjectFieldSetJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    project_id: []const u8,
    project_ref: ?[]const u8,
    field_id: ?[]const u8,
    field_key: ?[]const u8,
    value_json: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, "issue.project_field_set", "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "project_id", project_id, true);
    if (project_ref) |value| try appendJsonFieldString(&buf, allocator, "project_ref", value, true);
    if (field_id) |value| try appendJsonFieldString(&buf, allocator, "field_id", value, true);
    if (field_key) |value| try appendJsonFieldString(&buf, allocator, "field_key", value, true);
    try appendJsonFieldRaw(&buf, allocator, "value", value_json, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueProjectFieldClearedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    project_id: []const u8,
    project_ref: ?[]const u8,
    field_id: ?[]const u8,
    field_key: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, "issue.project_field_cleared", "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "project_id", project_id, true);
    if (project_ref) |value| try appendJsonFieldString(&buf, allocator, "project_ref", value, true);
    if (field_id) |value| try appendJsonFieldString(&buf, allocator, "field_id", value, field_key != null);
    if (field_key) |value| try appendJsonFieldString(&buf, allocator, "field_key", value, false);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueStringPayloadJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, event_type, "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, payload_key, payload_value, false);
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    update: IssueUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, "issue.updated", "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (update.title) |value| try appendJsonFieldString(&buf, allocator, "title", value, true);
    if (update.body) |value| try appendJsonFieldString(&buf, allocator, "body", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (update.milestone) |value| try appendJsonFieldString(&buf, allocator, "milestone", value, true);
    if (update.issue_type) |value| try appendJsonFieldString(&buf, allocator, "type", value, true);
    if (update.priority) |value| try appendJsonFieldString(&buf, allocator, "priority", value, true);
    if (update.status) |value| try appendJsonFieldString(&buf, allocator, "status", value, true);
    if (update.projects.len != 0) try appendIssueProjectsField(&buf, allocator, "projects", update.projects, true);
    if (update.labels_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_added", update.labels_added, true);
    if (update.labels_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_removed", update.labels_removed, true);
    if (update.assignees_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "assignees_added", update.assignees_added, true);
    if (update.assignees_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "assignees_removed", update.assignees_removed, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIssueLegacyAliasJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    issue_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    legacy: LegacyInfo,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefixWithLegacy(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, "issue.updated", "issue", legacy);
    try buf.appendSlice(allocator, "\"payload\":{}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectCreatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    name: []const u8,
    description: []const u8,
    slug: ?[]const u8,
    columns: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.created", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "name", name, true);
    if (slug) |value| if (value.len != 0) try appendJsonFieldString(&buf, allocator, "slug", value, true);
    if (description.len != 0) try appendJsonFieldString(&buf, allocator, "description", description, true);
    if (columns.len != 0) try appendJsonFieldStringArray(&buf, allocator, "columns", columns, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    update: ProjectUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.updated", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (update.name) |value| try appendJsonFieldString(&buf, allocator, "name", value, true);
    if (update.description) |value| try appendJsonFieldString(&buf, allocator, "description", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (update.status) |value| try appendJsonFieldString(&buf, allocator, "status", value, true);
    if (update.priority) |value| try appendJsonFieldString(&buf, allocator, "priority", value, true);
    if (update.start_at) |value| try appendJsonFieldString(&buf, allocator, "start_at", value, true);
    if (update.end_at) |value| try appendJsonFieldString(&buf, allocator, "end_at", value, true);
    if (update.leads_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "leads_added", update.leads_added, true);
    if (update.leads_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "leads_removed", update.leads_removed, true);
    if (update.members_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "members_added", update.members_added, true);
    if (update.members_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "members_removed", update.members_removed, true);
    if (update.labels_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_added", update.labels_added, true);
    if (update.labels_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_removed", update.labels_removed, true);
    if (update.milestones_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "milestones_added", update.milestones_added, true);
    if (update.milestones_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "milestones_removed", update.milestones_removed, true);
    if (update.update_health) |value| try appendJsonFieldString(&buf, allocator, "update_health", value, true);
    if (update.update_body) |value| try appendJsonFieldString(&buf, allocator, "update_body", value, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectColumnEventJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    column: []const u8,
    column_ref: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, event_type, "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "column", column, column_ref != null);
    if (column_ref) |value| try appendJsonFieldString(&buf, allocator, "column_ref", value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectFieldCreatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
    key: []const u8,
    name: []const u8,
    field_type: []const u8,
    position: ?i64,
    required: ?bool,
    default_value_json: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_created", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "field_id", field_id, true);
    try appendJsonFieldString(&buf, allocator, "key", key, true);
    try appendJsonFieldString(&buf, allocator, "name", name, true);
    try appendJsonFieldString(&buf, allocator, "type", field_type, true);
    if (position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (required) |value| try appendJsonFieldBool(&buf, allocator, "required", value, true);
    if (default_value_json) |value| try appendJsonFieldRaw(&buf, allocator, "default_value", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectFieldUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
    update: ProjectFieldUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_updated", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "field_id", field_id, true);
    if (update.key) |value| try appendJsonFieldString(&buf, allocator, "key", value, true);
    if (update.name) |value| try appendJsonFieldString(&buf, allocator, "name", value, true);
    if (update.field_type) |value| try appendJsonFieldString(&buf, allocator, "type", value, true);
    if (update.position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (update.required) |value| try appendJsonFieldBool(&buf, allocator, "required", value, true);
    if (update.default_value_json) |value| try appendJsonFieldRaw(&buf, allocator, "default_value", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectFieldRemovedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
) ![]u8 {
    return try buildProjectSingleStringPayloadJson(allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_removed", "field_id", field_id);
}

pub fn buildProjectFieldOptionAddedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
    option_id: []const u8,
    name: []const u8,
    color: ?[]const u8,
    position: ?i64,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_option_added", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "field_id", field_id, true);
    try appendJsonFieldString(&buf, allocator, "option_id", option_id, true);
    try appendJsonFieldString(&buf, allocator, "name", name, true);
    if (color) |value| try appendJsonFieldString(&buf, allocator, "color", value, true);
    if (position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectFieldOptionUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
    option_id: []const u8,
    update: ProjectFieldOptionUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_option_updated", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "field_id", field_id, true);
    try appendJsonFieldString(&buf, allocator, "option_id", option_id, true);
    if (update.name) |value| try appendJsonFieldString(&buf, allocator, "name", value, true);
    if (update.color) |value| try appendJsonFieldString(&buf, allocator, "color", value, true);
    if (update.position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectFieldOptionRemovedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    field_id: []const u8,
    option_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.field_option_removed", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "field_id", field_id, true);
    try appendJsonFieldString(&buf, allocator, "option_id", option_id, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectViewCreatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    view_id: []const u8,
    name: []const u8,
    layout: []const u8,
    position: ?i64,
    config_json: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.view_created", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "view_id", view_id, true);
    try appendJsonFieldString(&buf, allocator, "name", name, true);
    try appendJsonFieldString(&buf, allocator, "layout", layout, true);
    if (position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (config_json) |value| try appendJsonFieldRaw(&buf, allocator, "config", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectViewUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    view_id: []const u8,
    update: ProjectViewUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.view_updated", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "view_id", view_id, true);
    if (update.name) |value| try appendJsonFieldString(&buf, allocator, "name", value, true);
    if (update.layout) |value| try appendJsonFieldString(&buf, allocator, "layout", value, true);
    if (update.position) |value| try appendJsonFieldInteger(&buf, allocator, "position", value, true);
    if (update.config_json) |value| try appendJsonFieldRaw(&buf, allocator, "config", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProjectViewRemovedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    view_id: []const u8,
) ![]u8 {
    return try buildProjectSingleStringPayloadJson(allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.view_removed", "view_id", view_id);
}

fn buildProjectSingleStringPayloadJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    project_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, event_type, "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, key, value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildMilestoneCreatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    milestone_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    description: []const u8,
    due_at: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, milestone_id, event_uuid, idem, occurred_at, parents, "milestone.created", "milestone");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "title", title, true);
    if (description.len != 0) try appendJsonFieldString(&buf, allocator, "description", description, true);
    if (due_at.len != 0) try appendJsonFieldString(&buf, allocator, "due_at", due_at, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildMilestoneUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    milestone_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    update: MilestoneUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, milestone_id, event_uuid, idem, occurred_at, parents, "milestone.updated", "milestone");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (update.title) |value| try appendJsonFieldString(&buf, allocator, "title", value, true);
    if (update.description) |value| try appendJsonFieldString(&buf, allocator, "description", value, true);
    if (update.due_at) |value| try appendJsonFieldString(&buf, allocator, "due_at", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildMilestoneStringPayloadJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    milestone_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, milestone_id, event_uuid, idem, occurred_at, parents, event_type, "milestone");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, payload_key, payload_value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildMilestoneDeletedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    milestone_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, milestone_id, event_uuid, idem, occurred_at, parents, "milestone.deleted", "milestone");
    try buf.appendSlice(allocator, "\"payload\":{}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildLabelCreatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    label_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    name: []const u8,
    description: []const u8,
    color: []const u8,
    priority: ?i64,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, label_id, event_uuid, idem, occurred_at, parents, "label.created", "label");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "name", name, true);
    try appendJsonFieldString(&buf, allocator, "description", description, true);
    try appendJsonFieldString(&buf, allocator, "color", color, priority != null);
    if (priority) |value| try appendJsonFieldInteger(&buf, allocator, "priority", value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildLabelUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    label_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    update: LabelUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, label_id, event_uuid, idem, occurred_at, parents, "label.updated", "label");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (update.name) |value| try appendJsonFieldString(&buf, allocator, "name", value, true);
    if (update.description) |value| try appendJsonFieldString(&buf, allocator, "description", value, true);
    if (update.color) |value| try appendJsonFieldString(&buf, allocator, "color", value, true);
    if (update.priority) |value| try appendJsonFieldInteger(&buf, allocator, "priority", value, true);
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildLabelDeletedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    label_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, label_id, event_uuid, idem, occurred_at, parents, "label.deleted", "label");
    try buf.appendSlice(allocator, "\"payload\":{}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildCommentAddedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    comment_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) ![]u8 {
    return buildCommentAddedJsonWithMetadata(
        allocator,
        cfg,
        seq,
        comment_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        parent_kind,
        parent_id,
        body,
        .{},
    );
}

pub fn buildCommentAddedJsonWithMetadata(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    comment_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
    metadata: CommentAddedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, comment_id, event_uuid, idem, occurred_at, parents, "comment.added", "comment");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "parent_kind", parent_kind, true);
    try appendJsonFieldString(&buf, allocator, "parent_id", parent_id, true);
    if (metadata.source_author) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "source_author", value, true);
    }
    try appendSourceIdentityFields(&buf, allocator, metadata.source_identity, metadata.source_email, metadata.source_avatar_url);
    if (metadata.reply_parent_id) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "reply_parent_id", value, true);
    }
    if (metadata.reply_parent_hash) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "reply_parent_hash", value, true);
    }
    try appendJsonFieldString(&buf, allocator, "body", body, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildCommentBodySetJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    comment_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    body: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, comment_id, event_uuid, idem, occurred_at, parents, "comment.body_set", "comment");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "body", body, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildCommentRedactedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    comment_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    reason: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, comment_id, event_uuid, idem, occurred_at, parents, "comment.redacted", "comment");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (reason) |value| try appendJsonFieldString(&buf, allocator, "reason", value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildReactionJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    object_kind: []const u8,
    object_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    emoji: []const u8,
    add_hashes: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, event_type, object_kind);
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "emoji", emoji, add_hashes.len != 0);
    if (add_hashes.len != 0) try appendJsonFieldStringArray(&buf, allocator, "add_hashes", add_hashes, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildNotificationSubscriptionJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    notification_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    principal: []const u8,
    target_kind: []const u8,
    target_id: []const u8,
    reason: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, notification_id, event_uuid, idem, occurred_at, parents, event_type, "notification");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "target_kind", target_kind, true);
    try appendJsonFieldString(&buf, allocator, "target_id", target_id, reason.len != 0);
    if (reason.len != 0) try appendJsonFieldString(&buf, allocator, "reason", reason, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildNotificationReadJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    notification_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    principal: []const u8,
    event_hash: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, notification_id, event_uuid, idem, occurred_at, parents, "notification.read", "notification");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "event_hash", event_hash, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildNotificationReadAllJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    notification_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    principal: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, notification_id, event_uuid, idem, occurred_at, parents, "notification.read_all", "notification");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPullOpenedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) ![]u8 {
    return buildPullOpenedJsonWithLegacy(
        allocator,
        cfg,
        seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        title,
        body,
        base_ref,
        head_ref,
        draft,
        .{},
    );
}

pub fn buildPullOpenedJsonWithLegacy(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    legacy: LegacyInfo,
) ![]u8 {
    return buildPullOpenedJsonWithLegacyAndMetadata(
        allocator,
        cfg,
        seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        title,
        body,
        base_ref,
        head_ref,
        draft,
        legacy,
        .{},
    );
}

pub fn buildPullOpenedJsonWithLegacyAndMetadata(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
    legacy: LegacyInfo,
    metadata: PullOpenedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefixWithLegacy(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, "pull.opened", "pull", legacy);
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "title", title, true);
    if (body.len != 0) {
        try appendJsonFieldString(&buf, allocator, "body", body, true);
    }
    try appendJsonFieldString(&buf, allocator, "base_ref", base_ref, true);
    try appendJsonFieldString(&buf, allocator, "head_ref", head_ref, true);
    if (draft) {
        try appendJsonFieldBool(&buf, allocator, "draft", true, true);
    }
    if (metadata.source_author) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "source_author", value, true);
    }
    try appendSourceIdentityFields(&buf, allocator, metadata.source_identity, metadata.source_email, metadata.source_avatar_url);
    if (metadata.labels.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels", metadata.labels, true);
    if (metadata.assignees.len != 0) try appendJsonFieldStringArray(&buf, allocator, "assignees", metadata.assignees, true);
    if (metadata.reviewers.len != 0) try appendJsonFieldStringArray(&buf, allocator, "reviewers", metadata.reviewers, true);
    if (metadata.commit_count) |value| try appendJsonFieldUnsigned(&buf, allocator, "commits", value, true);
    if (metadata.changed_files) |value| try appendJsonFieldUnsigned(&buf, allocator, "changed_files", value, true);
    if (metadata.additions) |value| try appendJsonFieldUnsigned(&buf, allocator, "additions", value, true);
    if (metadata.deletions) |value| try appendJsonFieldUnsigned(&buf, allocator, "deletions", value, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPullStringPayloadJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, event_type, "pull");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, payload_key, payload_value, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPullUpdatedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    update: PullUpdate,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, "pull.updated", "pull");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (update.title) |value| try appendJsonFieldString(&buf, allocator, "title", value, true);
    if (update.body) |value| try appendJsonFieldString(&buf, allocator, "body", value, true);
    if (update.state) |value| try appendJsonFieldString(&buf, allocator, "state", value, true);
    if (update.base_ref) |value| try appendJsonFieldString(&buf, allocator, "base_ref", value, true);
    if (update.head_ref) |value| try appendJsonFieldString(&buf, allocator, "head_ref", value, true);
    if (update.labels_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_added", update.labels_added, true);
    if (update.labels_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "labels_removed", update.labels_removed, true);
    if (update.assignees_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "assignees_added", update.assignees_added, true);
    if (update.assignees_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "assignees_removed", update.assignees_removed, true);
    if (update.reviewers_added.len != 0) try appendJsonFieldStringArray(&buf, allocator, "reviewers_added", update.reviewers_added, true);
    if (update.reviewers_removed.len != 0) try appendJsonFieldStringArray(&buf, allocator, "reviewers_removed", update.reviewers_removed, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPullLegacyAliasJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    legacy: LegacyInfo,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefixWithLegacy(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, "pull.updated", "pull", legacy);
    try buf.appendSlice(allocator, "\"payload\":{}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPullMergedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
) ![]u8 {
    return buildPullMergedJsonWithMetadata(
        allocator,
        cfg,
        seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        parents,
        merge_oid,
        target_oid,
        .{},
    );
}

pub fn buildPullMergedJsonWithMetadata(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    pull_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
    metadata: PullMergedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, "pull.merged", "pull");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (merge_oid) |value| try appendJsonFieldString(&buf, allocator, "merge_oid", value, true);
    if (target_oid) |value| try appendJsonFieldString(&buf, allocator, "target_oid", value, true);
    if (metadata.base_oid) |value| try appendJsonFieldString(&buf, allocator, "base_oid", value, true);
    if (metadata.head_oid) |value| try appendJsonFieldString(&buf, allocator, "head_oid", value, true);
    if (metadata.remote) |value| try appendJsonFieldString(&buf, allocator, "remote", value, true);
    if (metadata.remote_ref) |value| try appendJsonFieldString(&buf, allocator, "remote_ref", value, true);
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildAclRoleJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    principal: []const u8,
    role: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    grant: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const object_id = try std.fmt.allocPrint(allocator, "acl:{s}", .{principal});
    defer allocator.free(object_id);
    try appendEnvelopePrefix(&buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, if (grant) "acl.role_granted" else "acl.role_revoked", "acl");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "role", role, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildAclDelegationJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    principal: []const u8,
    device: []const u8,
    capability: []const u8,
    scope: []const u8,
    signing_key: DelegationSigningKey,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    grant: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const object_id = try std.fmt.allocPrint(allocator, "acl:{s}", .{principal});
    defer allocator.free(object_id);
    try appendEnvelopePrefix(&buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, if (grant) "acl.delegation_granted" else "acl.delegation_revoked", "acl");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "device", device, true);
    try appendJsonFieldString(&buf, allocator, "capability", capability, true);
    try appendJsonFieldString(&buf, allocator, "scope", scope, true);
    if (grant) {
        try buf.appendSlice(allocator, "\"signing_key\":{");
        try appendJsonFieldString(&buf, allocator, "scheme", signing_key.scheme, true);
        try appendJsonFieldString(&buf, allocator, "public_key", signing_key.public_key, true);
        try appendJsonFieldString(&buf, allocator, "fingerprint", signing_key.fingerprint, false);
        try buf.appendSlice(allocator, "}");
    } else if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIdentityDeviceAddedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    principal: []const u8,
    device: []const u8,
    public_key: []const u8,
    fingerprint: []const u8,
    scheme: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const object_id = try std.fmt.allocPrint(allocator, "identity:{s}:{s}", .{ principal, device });
    defer allocator.free(object_id);
    try appendEnvelopePrefix(&buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, "identity.device_added", "identity");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "device", device, true);
    try buf.appendSlice(allocator, "\"signing_key\":{");
    try appendJsonFieldString(&buf, allocator, "scheme", scheme, true);
    try appendJsonFieldString(&buf, allocator, "public_key", public_key, true);
    try appendJsonFieldString(&buf, allocator, "fingerprint", fingerprint, false);
    try buf.appendSlice(allocator, "}}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildIdentityDeviceRevokedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    principal: []const u8,
    device: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const object_id = try std.fmt.allocPrint(allocator, "identity:{s}:{s}", .{ principal, device });
    defer allocator.free(object_id);
    try appendEnvelopePrefix(&buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, "identity.device_revoked", "identity");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "principal", principal, true);
    try appendJsonFieldString(&buf, allocator, "device", device, false);
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildActionRunRequestedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    run_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    workflow: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    event_name: ?[]const u8,
    gitomi_event_type: ?[]const u8,
    metadata: ActionRunRequestedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, run_id, event_uuid, idem, occurred_at, parents, "action.run_requested", "action");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "workflow", workflow, true);
    if (target_ref) |value| try appendJsonFieldString(&buf, allocator, "target_ref", value, true);
    if (target_oid) |value| try appendJsonFieldString(&buf, allocator, "target_oid", value, true);
    if (event_name) |value| try appendJsonFieldString(&buf, allocator, "event_name", value, true);
    if (gitomi_event_type) |value| try appendJsonFieldString(&buf, allocator, "gitomi_event_type", value, true);
    if (metadata.workflow_name) |value| try appendJsonFieldString(&buf, allocator, "workflow_name", value, true);
    if (metadata.workflow_dialect) |value| try appendJsonFieldString(&buf, allocator, "workflow_dialect", value, true);
    if (metadata.workflow_source_ref) |value| try appendJsonFieldString(&buf, allocator, "workflow_source_ref", value, true);
    if (metadata.workflow_source_oid) |value| try appendJsonFieldString(&buf, allocator, "workflow_source_oid", value, true);
    if (metadata.backend_kind) |value| try appendJsonFieldString(&buf, allocator, "backend_kind", value, true);
    if (metadata.pipeline) |value| try appendJsonFieldString(&buf, allocator, "pipeline", value, true);
    if (metadata.schedule_slot) |value| try appendJsonFieldString(&buf, allocator, "schedule_slot", value, true);
    if (metadata.source_workflow_from) |value| try appendJsonFieldString(&buf, allocator, "source_workflow_from", value, true);
    if (metadata.source_code_from) |value| try appendJsonFieldString(&buf, allocator, "source_code_from", value, true);
    if (metadata.permission_grant_json) |value| {
        try appendJsonFieldCanonicalRaw(&buf, allocator, "permission_grant", value, .object, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildActionRunCompletedJson(
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    run_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    conclusion: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    workflow: ?[]const u8,
    event_name: ?[]const u8,
    diagnostics_ref: ?[]const u8,
    diagnostics_oid: ?[]const u8,
    metadata: ActionRunCompletedMetadata,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, run_id, event_uuid, idem, occurred_at, parents, "action.run_completed", "action");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, true);
    if (target_ref) |value| try appendJsonFieldString(&buf, allocator, "target_ref", value, true);
    if (target_oid) |value| try appendJsonFieldString(&buf, allocator, "target_oid", value, true);
    if (workflow) |value| try appendJsonFieldString(&buf, allocator, "workflow", value, true);
    if (event_name) |value| try appendJsonFieldString(&buf, allocator, "event_name", value, true);
    if (diagnostics_ref) |value| try appendJsonFieldString(&buf, allocator, "diagnostics_ref", value, true);
    if (diagnostics_oid) |value| try appendJsonFieldString(&buf, allocator, "diagnostics_oid", value, true);
    if (metadata.attempt_id) |value| try appendJsonFieldString(&buf, allocator, "attempt_id", value, true);
    if (metadata.runner_id) |value| try appendJsonFieldString(&buf, allocator, "runner_id", value, true);
    if (metadata.workflow_source_oid) |value| try appendJsonFieldString(&buf, allocator, "workflow_source_oid", value, true);
    if (metadata.outputs_json) |value| {
        try appendJsonFieldCanonicalRaw(&buf, allocator, "outputs", value, .object, true);
    }
    if (metadata.published_events_json) |value| {
        try appendJsonFieldCanonicalRaw(&buf, allocator, "published_events", value, .array, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "}}");
    return try buf.toOwnedSlice(allocator);
}

fn appendEnvelopePrefix(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    object_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    object_kind: []const u8,
) !void {
    try appendEnvelopePrefixWithLegacy(buf, allocator, cfg, seq, object_id, event_uuid, idem, occurred_at, parents, event_type, object_kind, .{});
}

fn appendEnvelopePrefixWithLegacy(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    cfg: Config,
    seq: u64,
    object_id: []const u8,
    event_uuid: []const u8,
    idem: []const u8,
    occurred_at: []const u8,
    parents: EventParents,
    event_type: []const u8,
    object_kind: []const u8,
    legacy: LegacyInfo,
) !void {
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "$schema", event_schema, true);
    try appendJsonFieldString(buf, allocator, "repo_id", cfg.repo_id, true);
    try appendJsonFieldString(buf, allocator, "event_uuid", event_uuid, true);
    try appendJsonFieldString(buf, allocator, "event_type", event_type, true);
    try buf.appendSlice(allocator, "\"object\":{");
    try appendJsonFieldString(buf, allocator, "kind", object_kind, true);
    try appendJsonFieldString(buf, allocator, "id", object_id, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonFieldString(buf, allocator, "idempotency_key", idem, true);
    try buf.appendSlice(allocator, "\"actor\":{");
    try appendJsonFieldString(buf, allocator, "principal", cfg.principal, true);
    try appendJsonFieldString(buf, allocator, "device", cfg.device, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonFieldUnsigned(buf, allocator, "seq", seq, true);
    try appendJsonFieldString(buf, allocator, "occurred_at", occurred_at, true);
    try appendParentHashes(buf, allocator, parents);
    try appendLegacyInfo(buf, allocator, legacy);
}

fn appendLegacyInfo(buf: *std.ArrayList(u8), allocator: Allocator, legacy: LegacyInfo) !void {
    if (legacy.isEmpty()) {
        try buf.appendSlice(allocator, "\"legacy\":{},");
        return;
    }

    try buf.appendSlice(allocator, "\"legacy\":{");
    if (legacy.github_issue_number) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_issue_number", number, true);
    }
    if (legacy.github_issue_id) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_issue_id", number, true);
    }
    if (legacy.github_pull_number) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_pull_number", number, true);
    }
    if (legacy.github_pull_id) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_pull_id", number, true);
    }
    if (legacy.github_project_id) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_project_id", number, true);
    }
    if (legacy.github_milestone_id) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "github_milestone_id", number, true);
    }
    if (legacy.gitlab_issue_iid) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "gitlab_issue_iid", number, true);
    }
    if (legacy.gitlab_merge_request_iid) |number| {
        try appendJsonFieldUnsigned(buf, allocator, "gitlab_merge_request_iid", number, true);
    }
    if (buf.items[buf.items.len - 1] == ',') {
        buf.items.len -= 1;
    }
    try buf.appendSlice(allocator, "},");
}

fn appendJsonFieldRaw(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    raw_json: []const u8,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, raw_json);
    if (comma) try buf.append(allocator, ',');
}

fn appendJsonFieldCanonicalRaw(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    raw_json: []const u8,
    root_kind: JsonRootKind,
    comma: bool,
) !void {
    const canonical = try json_writer.requireCanonicalJsonValue(allocator, raw_json, root_kind);
    defer allocator.free(canonical);
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, canonical);
    if (comma) try buf.append(allocator, ',');
}

test "action run completed rejects structurally invalid output metadata" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try allocator.dupe(u8, "alice"),
        .device = try allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    try std.testing.expectError(error.InvalidJsonValue, buildActionRunCompletedJson(
        allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-17T12:00:00Z",
        .{},
        "failure",
        "refs/heads/main",
        null,
        ".gitomi/workflows/build.yml",
        "push",
        null,
        null,
        .{ .outputs_json = "{}},\"conclusion\":\"success\",\"pad\":{" },
    ));
}

fn appendIssueProjectsField(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    key: []const u8,
    projects: []const IssueProjectPlacement,
    comma: bool,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.appendSlice(allocator, ":[");
    for (projects, 0..) |project, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "project", project.project, true);
        try appendJsonFieldString(buf, allocator, "column", project.column, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    if (comma) try buf.append(allocator, ',');
}

fn appendParentHashes(buf: *std.ArrayList(u8), allocator: Allocator, parents: EventParents) !void {
    try buf.appendSlice(allocator, "\"parent_hashes\":{");
    try appendJsonFieldString(buf, allocator, "log", parents.log orelse "", true);
    try appendJsonFieldString(buf, allocator, "anchor", parents.anchor orelse "", true);
    try appendJsonFieldStringArray(buf, allocator, "causal", parents.causal, true);
    try appendJsonFieldStringArray(buf, allocator, "related", parents.related, false);
    try buf.appendSlice(allocator, "},");
}
