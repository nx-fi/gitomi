const std = @import("std");
const errors = @import("errors.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Config = repo_mod.Config;
const eprint = io.eprint;
const looksLikeUuid = util.looksLikeUuid;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonFieldBool = json_writer.appendJsonFieldBool;
const appendJsonString = json_writer.appendJsonString;

pub const event_schema = "urn:gitomi:event:v1";
pub const max_related_parents = 256;

pub const EventParents = struct {
    log: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    causal: []const []const u8 = &.{},
    related: []const []const u8 = &.{},
};

pub const LegacyInfo = struct {
    github_issue_number: ?u64 = null,
    github_pull_number: ?u64 = null,

    pub fn isEmpty(self: LegacyInfo) bool {
        return self.github_issue_number == null and self.github_pull_number == null;
    }
};

pub const IssueProjectPlacement = struct {
    project: []const u8,
    column: []const u8,
};

pub const IssueOpenedMetadata = struct {
    source_author: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    projects: []const IssueProjectPlacement = &.{},
};

pub const CommentAddedMetadata = struct {
    source_author: ?[]const u8 = null,
    reply_parent_id: ?[]const u8 = null,
    reply_parent_hash: ?[]const u8 = null,
};

pub const DelegationSigningKey = struct {
    scheme: []const u8,
    public_key: []const u8,
    fingerprint: []const u8,
};

pub const IssueUpdate = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    labels_added: []const []const u8 = &.{},
    labels_removed: []const []const u8 = &.{},
    assignees_added: []const []const u8 = &.{},
    assignees_removed: []const []const u8 = &.{},

    pub fn hasChanges(self: IssueUpdate) bool {
        return self.title != null or
            self.body != null or
            self.state != null or
            self.labels_added.len != 0 or
            self.labels_removed.len != 0 or
            self.assignees_added.len != 0 or
            self.assignees_removed.len != 0;
    }
};

pub const ProjectUpdate = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    state: ?[]const u8 = null,

    pub fn hasChanges(self: ProjectUpdate) bool {
        return self.name != null or self.description != null or self.state != null;
    }
};

pub const MilestoneUpdate = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    due_at: ?[]const u8 = null,
    state: ?[]const u8 = null,

    pub fn hasChanges(self: MilestoneUpdate) bool {
        return self.title != null or self.description != null or self.due_at != null or self.state != null;
    }
};

pub const PullUpdate = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    state: ?[]const u8 = null,
    base_ref: ?[]const u8 = null,
    head_ref: ?[]const u8 = null,
    labels_added: []const []const u8 = &.{},
    labels_removed: []const []const u8 = &.{},
    assignees_added: []const []const u8 = &.{},
    assignees_removed: []const []const u8 = &.{},
    reviewers_added: []const []const u8 = &.{},
    reviewers_removed: []const []const u8 = &.{},

    pub fn hasChanges(self: PullUpdate) bool {
        return self.title != null or
            self.body != null or
            self.state != null or
            self.base_ref != null or
            self.head_ref != null or
            self.labels_added.len != 0 or
            self.labels_removed.len != 0 or
            self.assignees_added.len != 0 or
            self.assignees_removed.len != 0 or
            self.reviewers_added.len != 0 or
            self.reviewers_removed.len != 0;
    }
};

pub const EventSummary = struct {
    allocator: Allocator,
    event_type: []u8,
    object_kind: []u8,
    object_id: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: ?i64 = null,
    occurred_at: []u8,

    pub fn deinit(self: EventSummary) void {
        self.allocator.free(self.event_type);
        self.allocator.free(self.object_kind);
        self.allocator.free(self.object_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
        self.allocator.free(self.occurred_at);
    }
};

pub const ValidatedEnvelope = struct {
    allocator: Allocator,
    repo_id: []u8,
    event_uuid: []u8,
    event_type: []u8,
    object_kind: []u8,
    object_id: []u8,
    idempotency_key: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: i64,
    occurred_at: []u8,

    pub fn deinit(self: ValidatedEnvelope) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.event_uuid);
        self.allocator.free(self.event_type);
        self.allocator.free(self.object_kind);
        self.allocator.free(self.object_id);
        self.allocator.free(self.idempotency_key);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
        self.allocator.free(self.occurred_at);
    }
};

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
    if (metadata.milestone) |value| {
        if (value.len != 0) try appendJsonFieldString(&buf, allocator, "milestone", value, true);
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
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, issue_id, event_uuid, idem, occurred_at, parents, event_type, "issue");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "project", project, true);
    try appendJsonFieldString(&buf, allocator, "column", column, false);
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
    columns: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, "project.created", "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "name", name, true);
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
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, project_id, event_uuid, idem, occurred_at, parents, event_type, "project");
    try buf.appendSlice(allocator, "\"payload\":{");
    try appendJsonFieldString(&buf, allocator, "column", column, false);
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
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendEnvelopePrefix(&buf, allocator, cfg, seq, pull_id, event_uuid, idem, occurred_at, parents, "pull.merged", "pull");
    try buf.appendSlice(allocator, "\"payload\":{");
    if (merge_oid) |value| try appendJsonFieldString(&buf, allocator, "merge_oid", value, true);
    if (target_oid) |value| try appendJsonFieldString(&buf, allocator, "target_oid", value, true);
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
    if (legacy.github_issue_number) |number| try appendJsonFieldUnsigned(buf, allocator, "github_issue_number", number, legacy.github_pull_number != null);
    if (legacy.github_pull_number) |number| try appendJsonFieldUnsigned(buf, allocator, "github_pull_number", number, false);
    try buf.appendSlice(allocator, "},");
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

pub fn validateEventEnvelope(allocator: Allocator, commit: []const u8, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try eprint("gt sync: rejecting {s}: event body is not valid JSON\n", .{commit});
        return CliError.UserError;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try eprint("gt sync: rejecting {s}: event body must be a JSON object\n", .{commit});
            return CliError.UserError;
        },
    };

    if (try validateEnvelopeObject(allocator, root)) |message| {
        defer allocator.free(message);
        try eprint("gt sync: rejecting {s}: {s}\n", .{ commit, message });
        return CliError.UserError;
    }
}

pub fn parseValidatedEnvelope(allocator: Allocator, body: []const u8) !ValidatedEnvelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidEventEnvelope;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventEnvelope,
    };

    return try parseValidatedEnvelopeObject(allocator, root);
}

pub fn parseValidatedEnvelopeObject(allocator: Allocator, root: std.json.ObjectMap) !ValidatedEnvelope {
    if (try validateEnvelopeObject(allocator, root)) |message| {
        allocator.free(message);
        return error.InvalidEventEnvelope;
    }

    const repo_id = requiredString(root, "repo_id").?;
    const event_uuid = requiredString(root, "event_uuid").?;
    const event_type = requiredString(root, "event_type").?;
    const idempotency_key = requiredString(root, "idempotency_key").?;
    const seq = root.get("seq").?.integer;
    const occurred_at = requiredString(root, "occurred_at").?;

    const object = requiredObject(root, "object").?;
    const object_kind = requiredString(object, "kind").?;
    const object_id = requiredString(object, "id").?;

    const actor = requiredObject(root, "actor").?;
    const actor_principal = requiredString(actor, "principal").?;
    const actor_device = requiredString(actor, "device").?;

    var repo_id_owned: ?[]u8 = try allocator.dupe(u8, repo_id);
    errdefer if (repo_id_owned) |value| allocator.free(value);
    var event_uuid_owned: ?[]u8 = try allocator.dupe(u8, event_uuid);
    errdefer if (event_uuid_owned) |value| allocator.free(value);
    var event_type_owned: ?[]u8 = try allocator.dupe(u8, event_type);
    errdefer if (event_type_owned) |value| allocator.free(value);
    var object_kind_owned: ?[]u8 = try allocator.dupe(u8, object_kind);
    errdefer if (object_kind_owned) |value| allocator.free(value);
    var object_id_owned: ?[]u8 = try allocator.dupe(u8, object_id);
    errdefer if (object_id_owned) |value| allocator.free(value);
    var idempotency_key_owned: ?[]u8 = try allocator.dupe(u8, idempotency_key);
    errdefer if (idempotency_key_owned) |value| allocator.free(value);
    var actor_principal_owned: ?[]u8 = try allocator.dupe(u8, actor_principal);
    errdefer if (actor_principal_owned) |value| allocator.free(value);
    var actor_device_owned: ?[]u8 = try allocator.dupe(u8, actor_device);
    errdefer if (actor_device_owned) |value| allocator.free(value);
    var occurred_at_owned: ?[]u8 = try allocator.dupe(u8, occurred_at);
    errdefer if (occurred_at_owned) |value| allocator.free(value);

    const envelope = ValidatedEnvelope{
        .allocator = allocator,
        .repo_id = repo_id_owned.?,
        .event_uuid = event_uuid_owned.?,
        .event_type = event_type_owned.?,
        .object_kind = object_kind_owned.?,
        .object_id = object_id_owned.?,
        .idempotency_key = idempotency_key_owned.?,
        .actor_principal = actor_principal_owned.?,
        .actor_device = actor_device_owned.?,
        .seq = seq,
        .occurred_at = occurred_at_owned.?,
    };
    repo_id_owned = null;
    event_uuid_owned = null;
    event_type_owned = null;
    object_kind_owned = null;
    object_id_owned = null;
    idempotency_key_owned = null;
    actor_principal_owned = null;
    actor_device_owned = null;
    occurred_at_owned = null;
    return envelope;
}

pub fn validateEnvelopeObject(allocator: Allocator, root: std.json.ObjectMap) !?[]u8 {
    const schema = switch (try requiredEnvelopeString(allocator, root, "$schema", "$schema", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (!std.mem.eql(u8, schema, event_schema)) {
        return try validationMessage(allocator, "$schema must be {s}", .{event_schema});
    }

    _ = switch (try requiredEnvelopeUuid(allocator, root, "repo_id", "repo_id")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeUuid(allocator, root, "event_uuid", "event_uuid")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const event_type = switch (try requiredEnvelopeString(allocator, root, "event_type", "event_type", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeUuid(allocator, root, "idempotency_key", "idempotency_key")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeObject(allocator, root, "legacy", "legacy")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const payload = switch (try requiredEnvelopeObject(allocator, root, "payload", "payload")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeSeq(allocator, root)) {
        .value => |value| value,
        .message => |message| return message,
    };

    const occurred_at = switch (try requiredEnvelopeString(allocator, root, "occurred_at", "occurred_at", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (occurred_at[occurred_at.len - 1] != 'Z') {
        return try validationMessage(allocator, "occurred_at must be a UTC RFC3339 timestamp", .{});
    }

    const parent_hashes = switch (try requiredEnvelopeObject(allocator, root, "parent_hashes", "parent_hashes")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, parent_hashes, "log", "parent_hashes.log", true)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, parent_hashes, "anchor", "parent_hashes.anchor", true)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (try validateEnvelopeStringArray(allocator, parent_hashes, "causal", "parent_hashes.causal")) |message| return message;
    if (try validateEnvelopeStringArray(allocator, parent_hashes, "related", "parent_hashes.related")) |message| return message;
    if (arrayLen(parent_hashes, "related") > max_related_parents) {
        return try validationMessage(allocator, "parent_hashes.related exceeds v1 related parent cap", .{});
    }

    const object = switch (try requiredEnvelopeObject(allocator, root, "object", "object")) {
        .value => |value| value,
        .message => |message| return message,
    };
    const kind = switch (try requiredEnvelopeString(allocator, object, "kind", "object.kind", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (!isKnownObjectKind(kind)) {
        return try validationMessage(allocator, "unknown object kind '{s}'", .{kind});
    }
    const object_id = switch (try requiredEnvelopeString(allocator, object, "id", "object.id", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    if (payloadRequirementError(event_type, kind, payload)) |message| {
        return try allocator.dupe(u8, message);
    }
    if (objectIdRequirementError(event_type, kind, object_id, payload)) |message| {
        return try allocator.dupe(u8, message);
    }

    const actor = switch (try requiredEnvelopeObject(allocator, root, "actor", "actor")) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, actor, "principal", "actor.principal", false)) {
        .value => |value| value,
        .message => |message| return message,
    };
    _ = switch (try requiredEnvelopeString(allocator, actor, "device", "actor.device", false)) {
        .value => |value| value,
        .message => |message| return message,
    };

    return null;
}

fn EnvelopeField(comptime T: type) type {
    return union(enum) {
        value: T,
        message: []u8,
    };
}

fn validationMessage(allocator: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

fn requiredEnvelopeObject(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !EnvelopeField(std.json.ObjectMap) {
    const value = object.get(key) orelse {
        return .{ .message = try validationMessage(allocator, "missing {s}", .{label}) };
    };
    return switch (value) {
        .object => |child| .{ .value = child },
        else => .{ .message = try validationMessage(allocator, "{s} must be an object", .{label}) },
    };
}

fn requiredEnvelopeString(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8, allow_empty: bool) !EnvelopeField([]const u8) {
    const value = object.get(key) orelse {
        return .{ .message = try validationMessage(allocator, "missing {s}", .{label}) };
    };
    const string = switch (value) {
        .string => |s| s,
        else => return .{ .message = try validationMessage(allocator, "{s} must be a string", .{label}) },
    };
    if (!allow_empty and string.len == 0) {
        return .{ .message = try validationMessage(allocator, "{s} must not be empty", .{label}) };
    }
    return .{ .value = string };
}

fn requiredEnvelopeUuid(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !EnvelopeField([]const u8) {
    const field = try requiredEnvelopeString(allocator, object, key, label, false);
    const value = switch (field) {
        .value => |string| string,
        .message => |message| return .{ .message = message },
    };
    if (!looksLikeUuid(value)) {
        return .{ .message = try validationMessage(allocator, "{s} must be a UUID", .{label}) };
    }
    return .{ .value = value };
}

fn requiredEnvelopeSeq(allocator: Allocator, object: std.json.ObjectMap) !EnvelopeField(i64) {
    const value = object.get("seq") orelse return .{ .message = try validationMessage(allocator, "missing seq", .{}) };
    return switch (value) {
        .integer => |seq| if (seq >= 0)
            .{ .value = seq }
        else
            .{ .message = try validationMessage(allocator, "seq must be a non-negative integer", .{}) },
        else => .{ .message = try validationMessage(allocator, "seq must be a non-negative integer", .{}) },
    };
}

fn validateEnvelopeStringArray(allocator: Allocator, object: std.json.ObjectMap, key: []const u8, label: []const u8) !?[]u8 {
    const value = object.get(key) orelse return try validationMessage(allocator, "missing {s}", .{label});
    const array = switch (value) {
        .array => |items| items,
        else => return try validationMessage(allocator, "{s} must be an array of strings", .{label}),
    };
    for (array.items) |item| {
        if (item != .string) return try validationMessage(allocator, "{s} must be an array of strings", .{label});
    }
    return null;
}

pub fn isKnownObjectKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "issue") or
        std.mem.eql(u8, kind, "pull") or
        std.mem.eql(u8, kind, "project") or
        std.mem.eql(u8, kind, "milestone") or
        std.mem.eql(u8, kind, "comment") or
        std.mem.eql(u8, kind, "acl") or
        std.mem.eql(u8, kind, "identity") or
        std.mem.eql(u8, kind, "action");
}

pub fn isKnownRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "reader") or
        std.mem.eql(u8, role, "reporter") or
        std.mem.eql(u8, role, "contributor") or
        std.mem.eql(u8, role, "maintainer") or
        std.mem.eql(u8, role, "owner");
}

pub fn payloadRequirementError(event_type: []const u8, object_kind: []const u8, payload: std.json.ObjectMap) ?[]const u8 {
    if (std.mem.startsWith(u8, event_type, "issue.") and !std.mem.eql(u8, object_kind, "issue")) {
        return "issue event object.kind must be issue";
    }
    if (std.mem.startsWith(u8, event_type, "pull.") and !std.mem.eql(u8, object_kind, "pull")) {
        return "pull event object.kind must be pull";
    }
    if (std.mem.startsWith(u8, event_type, "project.") and !std.mem.eql(u8, object_kind, "project")) {
        return "project event object.kind must be project";
    }
    if (std.mem.startsWith(u8, event_type, "milestone.") and !std.mem.eql(u8, object_kind, "milestone")) {
        return "milestone event object.kind must be milestone";
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and !std.mem.eql(u8, object_kind, "comment")) {
        return "comment event object.kind must be comment";
    }
    if (std.mem.startsWith(u8, event_type, "acl.") and !std.mem.eql(u8, object_kind, "acl")) {
        return "acl event object.kind must be acl";
    }
    if (std.mem.startsWith(u8, event_type, "identity.") and !std.mem.eql(u8, object_kind, "identity")) {
        return "identity event object.kind must be identity";
    }
    if (std.mem.startsWith(u8, event_type, "action.") and !std.mem.eql(u8, object_kind, "action")) {
        return "action event object.kind must be action";
    }

    if (isReactionEvent(event_type)) {
        const emoji = jsonString(payload.get("emoji")) orelse return "reaction payload.emoji must be a string";
        if (!validReactionEmoji(emoji)) return "reaction payload.emoji must be a non-empty emoji string";
        if (emoji.len > git.max_payload_atom_bytes) return "reaction payload.emoji exceeds v1 field size limit";
        if (std.mem.endsWith(u8, event_type, ".reaction_removed")) {
            if (!optionalStringArray(payload, "add_hashes")) return "reaction payload.add_hashes must be an array of strings";
            if (!optionalStringArrayWithin(payload, "add_hashes", git.max_payload_collection_items, git.max_payload_ref_bytes)) return "reaction payload.add_hashes exceeds v1 collection limits";
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "issue.opened")) {
        if (!hasString(payload, "title")) return "issue.opened payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_title_bytes)) return "issue.opened payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "issue.opened payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "issue.opened payload.body exceeds v1 text size limit";
        if (!optionalStringArray(payload, "labels")) return "issue.opened payload.labels must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.labels exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees")) return "issue.opened payload.assignees must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.assignees exceeds v1 collection limits";
        if (!optionalStringWithin(payload, "source_author", git.max_payload_atom_bytes)) return "issue.opened payload.source_author exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "milestone", git.max_payload_atom_bytes)) return "issue.opened payload.milestone exceeds v1 field size limit";
        if (!optionalIssueProjectsWithin(payload, "projects", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.opened payload.projects must be project objects within v1 collection limits";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        if (!optionalString(payload, "title")) return "issue.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_title_bytes)) return "issue.updated payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "issue.updated payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "issue.updated payload.body exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "issue.updated payload.state must be open or closed";
        if (!optionalStringArray(payload, "labels_added")) return "issue.updated payload.labels_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.labels_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_removed")) return "issue.updated payload.labels_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.labels_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_added")) return "issue.updated payload.assignees_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.assignees_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_removed")) return "issue.updated payload.assignees_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "issue.updated payload.assignees_removed exceeds v1 collection limits";
        if (!hasAnyKey(payload, &.{ "title", "body", "state", "labels_added", "labels_removed", "assignees_added", "assignees_removed" })) return "issue.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.title_set")) return requirePayloadStringWithin(payload, "issue.title_set", "title", git.max_payload_title_bytes);
    if (std.mem.eql(u8, event_type, "issue.body_set")) return requirePayloadStringWithin(payload, "issue.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "issue.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "issue.state_set payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "issue.label_added") or std.mem.eql(u8, event_type, "issue.label_removed")) return requirePayloadStringWithin(payload, event_type, "label", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.assignee_added") or std.mem.eql(u8, event_type, "issue.assignee_removed")) return requirePayloadStringWithin(payload, event_type, "assignee", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.milestone_set")) return requirePayloadStringWithin(payload, event_type, "milestone", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "issue.project_added") or std.mem.eql(u8, event_type, "issue.project_removed")) {
        if (!hasString(payload, "project")) return "issue project event payload.project must be a string";
        if (!stringWithin(payload, "project", git.max_payload_atom_bytes)) return "issue project event payload.project exceeds v1 field size limit";
        if (!hasString(payload, "column")) return "issue project event payload.column must be a string";
        if (!stringWithin(payload, "column", git.max_payload_atom_bytes)) return "issue project event payload.column exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "project.created")) {
        if (!hasString(payload, "name")) return "project.created payload.name must be a string";
        if (!stringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.created payload.name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "project.created payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "slug", git.max_payload_atom_bytes)) return "project.created payload.slug exceeds v1 field size limit";
        if (!optionalStringArray(payload, "columns")) return "project.created payload.columns must be an array of strings";
        if (!optionalStringArrayWithin(payload, "columns", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "project.created payload.columns exceeds v1 collection limits";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.updated")) {
        if (!optionalString(payload, "name")) return "project.updated payload.name must be a string";
        if (!optionalStringWithin(payload, "name", git.max_payload_atom_bytes)) return "project.updated payload.name exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "project.updated payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "project.updated payload.description exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "project.updated payload.state must be open or closed";
        if (!hasAnyKey(payload, &.{ "name", "description", "state" })) return "project.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "project.column_added") or std.mem.eql(u8, event_type, "project.column_removed")) {
        if (!hasString(payload, "column")) return "project column event payload.column must be a string";
        if (!stringWithin(payload, "column", git.max_payload_atom_bytes)) return "project column event payload.column exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "column_ref", git.max_payload_atom_bytes)) return "project column event payload.column_ref exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "milestone.created")) {
        if (!hasString(payload, "title")) return "milestone.created payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_atom_bytes)) return "milestone.created payload.title exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "milestone.created payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "milestone.created payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "slug", git.max_payload_atom_bytes)) return "milestone.created payload.slug exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "due_at", git.max_payload_atom_bytes)) return "milestone.created payload.due_at exceeds v1 field size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "milestone.created payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "milestone.updated")) {
        if (!optionalString(payload, "title")) return "milestone.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_atom_bytes)) return "milestone.updated payload.title exceeds v1 field size limit";
        if (!optionalString(payload, "description")) return "milestone.updated payload.description must be a string";
        if (!optionalStringWithin(payload, "description", git.max_payload_text_bytes)) return "milestone.updated payload.description exceeds v1 text size limit";
        if (!optionalStringWithin(payload, "due_at", git.max_payload_atom_bytes)) return "milestone.updated payload.due_at exceeds v1 field size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "milestone.updated payload.state must be open or closed";
        if (!hasAnyKey(payload, &.{ "title", "description", "due_at", "state" })) return "milestone.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "milestone.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "milestone.state_set payload.state must be open or closed";
        return null;
    }

    if (std.mem.eql(u8, event_type, "pull.opened")) {
        if (!hasString(payload, "title")) return "pull.opened payload.title must be a string";
        if (!stringWithin(payload, "title", git.max_payload_title_bytes)) return "pull.opened payload.title exceeds v1 title size limit";
        if (!hasString(payload, "base_ref")) return "pull.opened payload.base_ref must be a string";
        if (!stringWithin(payload, "base_ref", git.max_payload_ref_bytes)) return "pull.opened payload.base_ref exceeds v1 ref size limit";
        if (!hasString(payload, "head_ref")) return "pull.opened payload.head_ref must be a string";
        if (!stringWithin(payload, "head_ref", git.max_payload_ref_bytes)) return "pull.opened payload.head_ref exceeds v1 ref size limit";
        if (!optionalString(payload, "body")) return "pull.opened payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "pull.opened payload.body exceeds v1 text size limit";
        if (!optionalBool(payload, "draft")) return "pull.opened payload.draft must be a boolean";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.updated")) {
        if (!optionalString(payload, "title")) return "pull.updated payload.title must be a string";
        if (!optionalStringWithin(payload, "title", git.max_payload_title_bytes)) return "pull.updated payload.title exceeds v1 title size limit";
        if (!optionalString(payload, "body")) return "pull.updated payload.body must be a string";
        if (!optionalStringWithin(payload, "body", git.max_payload_text_bytes)) return "pull.updated payload.body exceeds v1 text size limit";
        if (!optionalState(payload, "state", &.{ "open", "closed" })) return "pull.updated payload.state must be open or closed";
        if (!optionalString(payload, "base_ref")) return "pull.updated payload.base_ref must be a string";
        if (!optionalStringWithin(payload, "base_ref", git.max_payload_ref_bytes)) return "pull.updated payload.base_ref exceeds v1 ref size limit";
        if (!optionalString(payload, "head_ref")) return "pull.updated payload.head_ref must be a string";
        if (!optionalStringWithin(payload, "head_ref", git.max_payload_ref_bytes)) return "pull.updated payload.head_ref exceeds v1 ref size limit";
        if (!optionalStringArray(payload, "labels_added")) return "pull.updated payload.labels_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.labels_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "labels_removed")) return "pull.updated payload.labels_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "labels_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.labels_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_added")) return "pull.updated payload.assignees_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.assignees_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "assignees_removed")) return "pull.updated payload.assignees_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "assignees_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.assignees_removed exceeds v1 collection limits";
        if (!optionalStringArray(payload, "reviewers_added")) return "pull.updated payload.reviewers_added must be an array of strings";
        if (!optionalStringArrayWithin(payload, "reviewers_added", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.reviewers_added exceeds v1 collection limits";
        if (!optionalStringArray(payload, "reviewers_removed")) return "pull.updated payload.reviewers_removed must be an array of strings";
        if (!optionalStringArrayWithin(payload, "reviewers_removed", git.max_payload_collection_items, git.max_payload_atom_bytes)) return "pull.updated payload.reviewers_removed exceeds v1 collection limits";
        if (!hasAnyKey(payload, &.{ "title", "body", "state", "base_ref", "head_ref", "labels_added", "labels_removed", "assignees_added", "assignees_removed", "reviewers_added", "reviewers_removed" })) return "pull.updated payload must contain at least one update field";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.title_set")) return requirePayloadStringWithin(payload, "pull.title_set", "title", git.max_payload_title_bytes);
    if (std.mem.eql(u8, event_type, "pull.body_set")) return requirePayloadStringWithin(payload, "pull.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "pull.state_set")) {
        if (!hasState(payload, "state", &.{ "open", "closed" })) return "pull.state_set payload.state must be open or closed";
        return null;
    }
    if (std.mem.eql(u8, event_type, "pull.base_set")) return requirePayloadStringWithin(payload, "pull.base_set", "base_ref", git.max_payload_ref_bytes);
    if (std.mem.eql(u8, event_type, "pull.head_set")) return requirePayloadStringWithin(payload, "pull.head_set", "head_ref", git.max_payload_ref_bytes);
    if (std.mem.eql(u8, event_type, "pull.label_added") or std.mem.eql(u8, event_type, "pull.label_removed")) return requirePayloadStringWithin(payload, event_type, "label", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.assignee_added") or std.mem.eql(u8, event_type, "pull.assignee_removed")) return requirePayloadStringWithin(payload, event_type, "assignee", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.reviewer_added") or std.mem.eql(u8, event_type, "pull.reviewer_removed")) return requirePayloadStringWithin(payload, event_type, "reviewer", git.max_payload_atom_bytes);
    if (std.mem.eql(u8, event_type, "pull.merged")) {
        if (!hasString(payload, "merge_oid") and !hasString(payload, "target_oid")) return "pull.merged payload.merge_oid or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "merge_oid", git.max_payload_ref_bytes)) return "pull.merged payload.merge_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "pull.merged payload.target_oid exceeds v1 ref size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "comment.added")) {
        if (!hasString(payload, "parent_kind")) return "comment.added payload.parent_kind must be a string";
        if (!stringWithin(payload, "parent_kind", git.max_payload_atom_bytes)) return "comment.added payload.parent_kind exceeds v1 field size limit";
        if (!hasString(payload, "parent_id")) return "comment.added payload.parent_id must be a string";
        if (!stringWithin(payload, "parent_id", git.max_payload_ref_bytes)) return "comment.added payload.parent_id exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "source_author", git.max_payload_atom_bytes)) return "comment.added payload.source_author exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "reply_parent_id", git.max_payload_ref_bytes)) return "comment.added payload.reply_parent_id exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "reply_parent_hash", git.max_payload_ref_bytes)) return "comment.added payload.reply_parent_hash exceeds v1 field size limit";
        if (!hasString(payload, "body")) return "comment.added payload.body must be a string";
        if (!stringWithin(payload, "body", git.max_payload_text_bytes)) return "comment.added payload.body exceeds v1 text size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "comment.body_set")) return requirePayloadStringWithin(payload, "comment.body_set", "body", git.max_payload_text_bytes);
    if (std.mem.eql(u8, event_type, "comment.redacted")) {
        if (!optionalString(payload, "reason")) return "comment.redacted payload.reason must be a string";
        if (!optionalStringWithin(payload, "reason", git.max_payload_text_bytes)) return "comment.redacted payload.reason exceeds v1 text size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "acl.role_granted") or std.mem.eql(u8, event_type, "acl.role_revoked")) {
        if (!hasString(payload, "principal")) return "acl role event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "acl role event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "role")) return "acl role event payload.role must be a string";
        if (!stringWithin(payload, "role", git.max_payload_atom_bytes)) return "acl role event payload.role exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "acl.delegation_granted") or std.mem.eql(u8, event_type, "acl.delegation_revoked")) {
        if (!hasString(payload, "principal")) return "acl delegation event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "acl delegation event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "acl delegation event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "acl delegation event payload.device exceeds v1 field size limit";
        if (!hasString(payload, "capability")) return "acl delegation event payload.capability must be a string";
        if (!stringWithin(payload, "capability", git.max_payload_atom_bytes)) return "acl delegation event payload.capability exceeds v1 field size limit";
        if (!hasString(payload, "scope")) return "acl delegation event payload.scope must be a string";
        if (!stringWithin(payload, "scope", git.max_payload_ref_bytes)) return "acl delegation event payload.scope exceeds v1 field size limit";
        if (std.mem.eql(u8, event_type, "acl.delegation_granted")) {
            const signing_key = objectValue(payload, "signing_key") orelse return "acl.delegation_granted payload.signing_key must be an object";
            if (!hasString(signing_key, "public_key")) return "acl.delegation_granted payload.signing_key.public_key must be a string";
            if (!stringWithin(signing_key, "public_key", git.max_payload_key_bytes)) return "acl.delegation_granted payload.signing_key.public_key exceeds v1 key size limit";
            if (!hasString(signing_key, "fingerprint")) return "acl.delegation_granted payload.signing_key.fingerprint must be a string";
            if (!stringWithin(signing_key, "fingerprint", git.max_payload_atom_bytes)) return "acl.delegation_granted payload.signing_key.fingerprint exceeds v1 field size limit";
            if (!optionalString(signing_key, "scheme")) return "acl.delegation_granted payload.signing_key.scheme must be a string";
            if (!optionalStringWithin(signing_key, "scheme", git.max_payload_atom_bytes)) return "acl.delegation_granted payload.signing_key.scheme exceeds v1 field size limit";
        }
        return null;
    }

    if (std.mem.eql(u8, event_type, "identity.device_added")) {
        if (!hasString(payload, "principal")) return "identity device event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "identity device event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "identity device event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "identity device event payload.device exceeds v1 field size limit";
        const signing_key = objectValue(payload, "signing_key") orelse return "identity.device_added payload.signing_key must be an object";
        if (!hasString(signing_key, "public_key")) return "identity.device_added payload.signing_key.public_key must be a string";
        if (!stringWithin(signing_key, "public_key", git.max_payload_key_bytes)) return "identity.device_added payload.signing_key.public_key exceeds v1 key size limit";
        if (!hasString(signing_key, "fingerprint")) return "identity.device_added payload.signing_key.fingerprint must be a string";
        if (!stringWithin(signing_key, "fingerprint", git.max_payload_atom_bytes)) return "identity.device_added payload.signing_key.fingerprint exceeds v1 field size limit";
        if (!optionalString(signing_key, "scheme")) return "identity.device_added payload.signing_key.scheme must be a string";
        if (!optionalStringWithin(signing_key, "scheme", git.max_payload_atom_bytes)) return "identity.device_added payload.signing_key.scheme exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "identity.device_revoked")) {
        if (!hasString(payload, "principal")) return "identity device event payload.principal must be a string";
        if (!stringWithin(payload, "principal", git.max_payload_atom_bytes)) return "identity device event payload.principal exceeds v1 field size limit";
        if (!hasString(payload, "device")) return "identity device event payload.device must be a string";
        if (!stringWithin(payload, "device", git.max_payload_atom_bytes)) return "identity device event payload.device exceeds v1 field size limit";
        return null;
    }

    if (std.mem.eql(u8, event_type, "action.run_requested")) {
        if (!hasString(payload, "workflow")) return "action.run_requested payload.workflow must be a string";
        if (!stringWithin(payload, "workflow", git.max_payload_atom_bytes)) return "action.run_requested payload.workflow exceeds v1 field size limit";
        if (!hasString(payload, "target_ref") and !hasString(payload, "target_oid")) return "action.run_requested payload.target_ref or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "target_ref", git.max_payload_ref_bytes)) return "action.run_requested payload.target_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "action.run_requested payload.target_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "event_name", git.max_payload_atom_bytes)) return "action.run_requested payload.event_name exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "gitomi_event_type", git.max_payload_atom_bytes)) return "action.run_requested payload.gitomi_event_type exceeds v1 field size limit";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_completed")) {
        if (!hasString(payload, "run_id")) return "action.run_completed payload.run_id must be a string";
        if (!stringWithin(payload, "run_id", git.max_payload_ref_bytes)) return "action.run_completed payload.run_id exceeds v1 field size limit";
        if (!hasString(payload, "conclusion")) return "action.run_completed payload.conclusion must be a string";
        if (!stringWithin(payload, "conclusion", git.max_payload_atom_bytes)) return "action.run_completed payload.conclusion exceeds v1 field size limit";
        const conclusion = jsonString(payload.get("conclusion")) orelse return "action.run_completed payload.conclusion must be a string";
        if (!isActionConclusion(conclusion)) return "action.run_completed payload.conclusion is not a recognized conclusion";
        if (!hasString(payload, "target_ref") and !hasString(payload, "target_oid")) return "action.run_completed payload.target_ref or payload.target_oid must be a string";
        if (!optionalStringWithin(payload, "target_ref", git.max_payload_ref_bytes)) return "action.run_completed payload.target_ref exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "target_oid", git.max_payload_ref_bytes)) return "action.run_completed payload.target_oid exceeds v1 ref size limit";
        if (!optionalStringWithin(payload, "workflow", git.max_payload_atom_bytes)) return "action.run_completed payload.workflow exceeds v1 field size limit";
        if (!optionalStringWithin(payload, "event_name", git.max_payload_atom_bytes)) return "action.run_completed payload.event_name exceeds v1 field size limit";
        return null;
    }

    return null;
}

fn isReactionEvent(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "issue.reaction_added") or
        std.mem.eql(u8, event_type, "issue.reaction_removed") or
        std.mem.eql(u8, event_type, "pull.reaction_added") or
        std.mem.eql(u8, event_type, "pull.reaction_removed") or
        std.mem.eql(u8, event_type, "comment.reaction_added") or
        std.mem.eql(u8, event_type, "comment.reaction_removed");
}

fn validReactionEmoji(value: []const u8) bool {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return false;
    for (value) |c| {
        if (c < 0x20) return false;
    }
    return true;
}

pub fn objectIdRequirementError(event_type: []const u8, object_kind: []const u8, object_id: []const u8, payload: std.json.ObjectMap) ?[]const u8 {
    if (std.mem.startsWith(u8, event_type, "issue.") and std.mem.eql(u8, object_kind, "issue")) {
        if (!looksLikeUuid(object_id)) return "issue event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "pull.") and std.mem.eql(u8, object_kind, "pull")) {
        if (!looksLikeUuid(object_id)) return "pull event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "project.") and std.mem.eql(u8, object_kind, "project")) {
        if (!looksLikeUuid(object_id)) return "project event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "milestone.") and std.mem.eql(u8, object_kind, "milestone")) {
        if (!looksLikeUuid(object_id)) return "milestone event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "comment.") and std.mem.eql(u8, object_kind, "comment")) {
        if (!looksLikeUuid(object_id)) return "comment event object.id must be a UUID";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "acl.") and std.mem.eql(u8, object_kind, "acl")) {
        const principal = jsonString(payload.get("principal")) orelse return "acl event payload.principal must be a string";
        if (!std.mem.startsWith(u8, object_id, "acl:")) return "acl event object.id must be acl:<principal>";
        if (!std.mem.eql(u8, object_id["acl:".len..], principal)) return "acl event object.id must match payload.principal";
        return null;
    }
    if (std.mem.startsWith(u8, event_type, "identity.") and std.mem.eql(u8, object_kind, "identity")) {
        const principal = jsonString(payload.get("principal")) orelse return "identity event payload.principal must be a string";
        const device = jsonString(payload.get("device")) orelse return "identity event payload.device must be a string";
        if (!std.mem.startsWith(u8, object_id, "identity:")) return "identity event object.id must be identity:<principal>:<device>";
        const rest = object_id["identity:".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return "identity event object.id must be identity:<principal>:<device>";
        if (!std.mem.eql(u8, rest[0..colon], principal)) return "identity event object.id must match payload.principal";
        if (!std.mem.eql(u8, rest[colon + 1 ..], device)) return "identity event object.id must match payload.device";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_requested") and std.mem.eql(u8, object_kind, "action")) {
        if (!looksLikeUuid(object_id)) return "action.run_requested object.id must be a run UUID";
        return null;
    }
    if (std.mem.eql(u8, event_type, "action.run_completed") and std.mem.eql(u8, object_kind, "action")) {
        if (!looksLikeUuid(object_id)) return "action.run_completed object.id must be a run UUID";
        const run_id = jsonString(payload.get("run_id")) orelse return "action.run_completed payload.run_id must be a string";
        if (!std.mem.eql(u8, object_id, run_id)) return "action.run_completed object.id must equal payload.run_id";
        return null;
    }
    return null;
}

fn requiredObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    const string = switch (value) {
        .string => |s| s,
        else => return null,
    };
    if (string.len == 0) return null;
    return string;
}

fn requirePayloadString(payload: std.json.ObjectMap, event_type: []const u8, key: []const u8) ?[]const u8 {
    if (hasString(payload, key)) return null;
    if (std.mem.eql(u8, key, "title")) {
        if (std.mem.startsWith(u8, event_type, "issue.")) return "issue payload.title must be a string";
        if (std.mem.startsWith(u8, event_type, "pull.")) return "pull payload.title must be a string";
    }
    if (std.mem.eql(u8, key, "body")) {
        if (std.mem.startsWith(u8, event_type, "issue.")) return "issue payload.body must be a string";
        if (std.mem.startsWith(u8, event_type, "pull.")) return "pull payload.body must be a string";
        if (std.mem.startsWith(u8, event_type, "comment.")) return "comment payload.body must be a string";
    }
    return "event payload is missing a required string field";
}

fn requirePayloadStringWithin(payload: std.json.ObjectMap, event_type: []const u8, key: []const u8, max_bytes: usize) ?[]const u8 {
    if (requirePayloadString(payload, event_type, key)) |message| return message;
    if (!stringWithin(payload, key, max_bytes)) return "event payload string exceeds v1 field size limit";
    return null;
}

fn hasString(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .string;
}

fn stringWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = jsonString(object.get(key)) orelse return false;
    return value.len <= max_bytes;
}

fn objectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    return value == .string;
}

fn optionalStringWithin(object: std.json.ObjectMap, key: []const u8, max_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const string = switch (value) {
        .string => |s| s,
        else => return false,
    };
    return string.len <= max_bytes;
}

fn isActionConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or
        std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "skipped") or
        std.mem.eql(u8, value, "neutral") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "action_required");
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    return value == .bool;
}

fn optionalStringArray(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    for (array.items) |item| {
        if (item != .string) return false;
    }
    return true;
}

fn optionalStringArrayWithin(object: std.json.ObjectMap, key: []const u8, max_items: usize, max_item_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    if (array.items.len > max_items) return false;
    for (array.items) |item| {
        if (item != .string or item.string.len > max_item_bytes) return false;
    }
    return true;
}

fn optionalIssueProjectsWithin(object: std.json.ObjectMap, key: []const u8, max_items: usize, max_item_bytes: usize) bool {
    const value = object.get(key) orelse return true;
    const array = switch (value) {
        .array => |items| items,
        else => return false,
    };
    if (array.items.len > max_items) return false;
    for (array.items) |item| {
        const project = switch (item) {
            .object => |map| map,
            else => return false,
        };
        const name = jsonString(project.get("project")) orelse return false;
        const column = jsonString(project.get("column")) orelse return false;
        if (name.len == 0 or name.len > max_item_bytes or column.len > max_item_bytes) return false;
    }
    return true;
}

fn optionalState(object: std.json.ObjectMap, key: []const u8, allowed: []const []const u8) bool {
    if (object.get(key) == null) return true;
    return hasState(object, key, allowed);
}

fn hasAnyKey(object: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (object.get(key) != null) return true;
    }
    return false;
}

fn arrayLen(object: std.json.ObjectMap, key: []const u8) usize {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .array => |items| items.items.len,
        else => 0,
    };
}

fn hasState(object: std.json.ObjectMap, key: []const u8, allowed: []const []const u8) bool {
    const value = jsonString(object.get(key)) orelse return false;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

pub fn parseEventSummary(allocator: Allocator, body: []const u8) ?EventSummary {
    return parseEventSummaryInner(allocator, body) catch null;
}

pub fn parseEventSummaryInner(allocator: Allocator, body: []const u8) !EventSummary {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventJson,
    };

    var event_type: ?[]u8 = try dupeJsonString(allocator, object.get("event_type"));
    errdefer if (event_type) |value| allocator.free(value);
    var object_kind: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_kind) |value| allocator.free(value);
    var object_id: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (object_id) |value| allocator.free(value);
    var actor_principal: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_principal) |value| allocator.free(value);
    var actor_device: ?[]u8 = try allocator.dupe(u8, "");
    errdefer if (actor_device) |value| allocator.free(value);
    var occurred_at: ?[]u8 = try dupeJsonString(allocator, object.get("occurred_at"));
    errdefer if (occurred_at) |value| allocator.free(value);

    var summary = EventSummary{
        .allocator = allocator,
        .event_type = event_type.?,
        .object_kind = object_kind.?,
        .object_id = object_id.?,
        .actor_principal = actor_principal.?,
        .actor_device = actor_device.?,
        .seq = jsonInteger(object.get("seq")),
        .occurred_at = occurred_at.?,
    };
    event_type = null;
    object_kind = null;
    object_id = null;
    actor_principal = null;
    actor_device = null;
    occurred_at = null;
    errdefer summary.deinit();

    if (object.get("object")) |obj_value| {
        if (obj_value == .object) {
            var next_object_kind: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("kind"));
            errdefer if (next_object_kind) |value| allocator.free(value);
            var next_object_id: ?[]u8 = try dupeJsonString(allocator, obj_value.object.get("id"));
            errdefer if (next_object_id) |value| allocator.free(value);
            allocator.free(summary.object_kind);
            summary.object_kind = next_object_kind.?;
            next_object_kind = null;
            allocator.free(summary.object_id);
            summary.object_id = next_object_id.?;
            next_object_id = null;
        }
    }

    if (object.get("actor")) |actor_value| {
        if (actor_value == .object) {
            var next_actor_principal: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("principal"));
            errdefer if (next_actor_principal) |value| allocator.free(value);
            var next_actor_device: ?[]u8 = try dupeJsonString(allocator, actor_value.object.get("device"));
            errdefer if (next_actor_device) |value| allocator.free(value);
            allocator.free(summary.actor_principal);
            summary.actor_principal = next_actor_principal.?;
            next_actor_principal = null;
            allocator.free(summary.actor_device);
            summary.actor_device = next_actor_device.?;
            next_actor_device = null;
        }
    }

    return summary;
}

pub fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

pub fn jsonBool(value: ?std.json.Value) ?bool {
    if (value) |v| {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }
    return null;
}

pub fn dupeJsonString(allocator: Allocator, value: ?std.json.Value) ![]u8 {
    return allocator.dupe(u8, jsonString(value) orelse "");
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }
    return null;
}

test "issue opened event json contains required envelope fields" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const labels = [_][]const u8{"bug"};
    const assignees = [_][]const u8{"alice"};
    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "Body",
        &labels,
        &assignees,
    );
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(event_schema, root.get("$schema").?.string);
    try std.testing.expectEqualStrings("issue.opened", root.get("event_type").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("seq").?.integer);
    try std.testing.expectEqualStrings("issue", root.get("object").?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("Smoke", root.get("payload").?.object.get("title").?.string);
}

test "issue opened event json passes envelope validation" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(body);

    try validateEventEnvelope(std.testing.allocator, "test-commit", body);
}

test "validated envelope rejects oversized payload fields and arrays" {
    var cfg = Config{
        .allocator = std.testing.allocator,
        .repo_id = try std.testing.allocator.dupe(u8, "018f0000-0000-7000-8000-000000000001"),
        .principal = try std.testing.allocator.dupe(u8, "alice"),
        .device = try std.testing.allocator.dupe(u8, "laptop"),
        .seq = 0,
    };
    defer cfg.deinit();

    const oversized_title = try std.testing.allocator.alloc(u8, git.max_payload_title_bytes + 1);
    defer std.testing.allocator.free(oversized_title);
    @memset(oversized_title, 'a');

    const oversized_body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        oversized_title,
        "",
        &.{},
        &.{},
    );
    defer std.testing.allocator.free(oversized_body);
    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, oversized_body));

    const labels = try std.testing.allocator.alloc([]const u8, git.max_payload_collection_items + 1);
    defer std.testing.allocator.free(labels);
    for (labels) |*label| label.* = "bug";

    const oversized_array_body = try buildIssueOpenedJson(
        std.testing.allocator,
        cfg,
        1,
        "018f0000-0000-7000-8000-000000000002",
        "018f0000-0000-7000-8000-000000000003",
        "018f0000-0000-7000-8000-000000000004",
        "2026-05-13T18:30:59Z",
        .{},
        "Smoke",
        "",
        labels,
        &.{},
    );
    defer std.testing.allocator.free(oversized_array_body);
    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, oversized_array_body));
}

test "validated envelope rejects known event with missing required payload" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "issue.opened",
        \\  "object": {
        \\    "kind": "issue",
        \\    "id": "018f0000-0000-7000-8000-000000000003"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {}
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}

test "acl object id targets principal instead of uuid" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "acl.role_granted",
        \\  "object": {
        \\    "kind": "acl",
        \\    "id": "acl:bob"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "principal": "bob",
        \\    "role": "maintainer"
        \\  }
        \\}
    ;

    var envelope = try parseValidatedEnvelope(std.testing.allocator, body);
    defer envelope.deinit();
    try std.testing.expectEqualStrings("acl:bob", envelope.object_id);
}

test "identity object id must match principal and device payload" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "identity.device_revoked",
        \\  "object": {
        \\    "kind": "identity",
        \\    "id": "identity:bob:phone"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "principal": "bob",
        \\    "device": "laptop"
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}

test "validated envelope rejects pull state_set merged" {
    const body =
        \\{
        \\  "$schema": "urn:gitomi:event:v1",
        \\  "repo_id": "018f0000-0000-7000-8000-000000000001",
        \\  "event_uuid": "018f0000-0000-7000-8000-000000000002",
        \\  "event_type": "pull.state_set",
        \\  "object": {
        \\    "kind": "pull",
        \\    "id": "018f0000-0000-7000-8000-000000000003"
        \\  },
        \\  "idempotency_key": "018f0000-0000-7000-8000-000000000004",
        \\  "actor": {
        \\    "principal": "alice",
        \\    "device": "laptop"
        \\  },
        \\  "parent_hashes": {
        \\    "log": "",
        \\    "anchor": "",
        \\    "causal": [],
        \\    "related": []
        \\  },
        \\  "seq": 1,
        \\  "occurred_at": "2026-05-13T18:30:59Z",
        \\  "legacy": {},
        \\  "payload": {
        \\    "state": "merged"
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidEventEnvelope, parseValidatedEnvelope(std.testing.allocator, body));
}
