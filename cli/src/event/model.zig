const std = @import("std");

const Allocator = std.mem.Allocator;

pub const event_schema = "urn:gitomi:event:v1";

pub const EventParents = struct {
    log: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    causal: []const []const u8 = &.{},
    related: []const []const u8 = &.{},
};

pub const LegacyInfo = struct {
    github_issue_number: ?u64 = null,
    github_issue_id: ?u64 = null,
    github_pull_number: ?u64 = null,
    github_pull_id: ?u64 = null,
    github_project_id: ?u64 = null,
    github_milestone_id: ?u64 = null,
    gitlab_issue_iid: ?u64 = null,
    gitlab_merge_request_iid: ?u64 = null,

    pub fn isEmpty(self: LegacyInfo) bool {
        return self.github_issue_number == null and
            self.github_issue_id == null and
            self.github_pull_number == null and
            self.github_pull_id == null and
            self.github_project_id == null and
            self.github_milestone_id == null and
            self.gitlab_issue_iid == null and
            self.gitlab_merge_request_iid == null;
    }
};

pub const ActionRunRequestedMetadata = struct {
    workflow_name: ?[]const u8 = null,
    workflow_dialect: ?[]const u8 = null,
    workflow_source_ref: ?[]const u8 = null,
    workflow_source_oid: ?[]const u8 = null,
    backend_kind: ?[]const u8 = null,
    pipeline: ?[]const u8 = null,
    schedule_slot: ?[]const u8 = null,
    source_workflow_from: ?[]const u8 = null,
    source_code_from: ?[]const u8 = null,
    permission_grant_json: ?[]const u8 = null,
};

pub const ActionRunCompletedMetadata = struct {
    attempt_id: ?[]const u8 = null,
    runner_id: ?[]const u8 = null,
    workflow_source_oid: ?[]const u8 = null,
    outputs_json: ?[]const u8 = null,
    published_events_json: ?[]const u8 = null,
};

pub const IssueProjectPlacement = struct {
    project: []const u8,
    column: []const u8,
};

pub const IssueOpenedMetadata = struct {
    source_author: ?[]const u8 = null,
    source_identity: ?[]const u8 = null,
    source_email: ?[]const u8 = null,
    source_avatar_url: ?[]const u8 = null,
    milestone: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    status: ?[]const u8 = null,
    projects: []const IssueProjectPlacement = &.{},
};

pub const PullOpenedMetadata = struct {
    source_author: ?[]const u8 = null,
    source_identity: ?[]const u8 = null,
    source_email: ?[]const u8 = null,
    source_avatar_url: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    assignees: []const []const u8 = &.{},
    reviewers: []const []const u8 = &.{},
    commit_count: ?u64 = null,
    changed_files: ?u64 = null,
    additions: ?u64 = null,
    deletions: ?u64 = null,
};

pub const PullMergedMetadata = struct {
    base_oid: ?[]const u8 = null,
    head_oid: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    remote_ref: ?[]const u8 = null,
};

pub const CommentAddedMetadata = struct {
    source_author: ?[]const u8 = null,
    source_identity: ?[]const u8 = null,
    source_email: ?[]const u8 = null,
    source_avatar_url: ?[]const u8 = null,
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
    milestone: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    status: ?[]const u8 = null,
    projects: []const IssueProjectPlacement = &.{},
    labels_added: []const []const u8 = &.{},
    labels_removed: []const []const u8 = &.{},
    assignees_added: []const []const u8 = &.{},
    assignees_removed: []const []const u8 = &.{},

    pub fn hasChanges(self: IssueUpdate) bool {
        return self.title != null or
            self.body != null or
            self.state != null or
            self.milestone != null or
            self.issue_type != null or
            self.priority != null or
            self.status != null or
            self.projects.len != 0 or
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
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    start_at: ?[]const u8 = null,
    end_at: ?[]const u8 = null,
    leads_added: []const []const u8 = &.{},
    leads_removed: []const []const u8 = &.{},
    members_added: []const []const u8 = &.{},
    members_removed: []const []const u8 = &.{},
    labels_added: []const []const u8 = &.{},
    labels_removed: []const []const u8 = &.{},
    milestones_added: []const []const u8 = &.{},
    milestones_removed: []const []const u8 = &.{},
    update_health: ?[]const u8 = null,
    update_body: ?[]const u8 = null,

    pub fn hasChanges(self: ProjectUpdate) bool {
        return self.name != null or
            self.description != null or
            self.state != null or
            self.status != null or
            self.priority != null or
            self.start_at != null or
            self.end_at != null or
            self.leads_added.len != 0 or
            self.leads_removed.len != 0 or
            self.members_added.len != 0 or
            self.members_removed.len != 0 or
            self.labels_added.len != 0 or
            self.labels_removed.len != 0 or
            self.milestones_added.len != 0 or
            self.milestones_removed.len != 0 or
            self.update_health != null or
            self.update_body != null;
    }
};

pub const ProjectFieldUpdate = struct {
    key: ?[]const u8 = null,
    name: ?[]const u8 = null,
    field_type: ?[]const u8 = null,
    position: ?i64 = null,
    required: ?bool = null,
    default_value_json: ?[]const u8 = null,
    state: ?[]const u8 = null,

    pub fn hasChanges(self: ProjectFieldUpdate) bool {
        return self.key != null or
            self.name != null or
            self.field_type != null or
            self.position != null or
            self.required != null or
            self.default_value_json != null or
            self.state != null;
    }
};

pub const ProjectFieldOptionUpdate = struct {
    name: ?[]const u8 = null,
    color: ?[]const u8 = null,
    position: ?i64 = null,
    state: ?[]const u8 = null,

    pub fn hasChanges(self: ProjectFieldOptionUpdate) bool {
        return self.name != null or self.color != null or self.position != null or self.state != null;
    }
};

pub const ProjectViewUpdate = struct {
    name: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    position: ?i64 = null,
    config_json: ?[]const u8 = null,
    state: ?[]const u8 = null,

    pub fn hasChanges(self: ProjectViewUpdate) bool {
        return self.name != null or self.layout != null or self.position != null or self.config_json != null or self.state != null;
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

pub const LabelUpdate = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    color: ?[]const u8 = null,
    position: ?i64 = null,

    pub fn hasChanges(self: LabelUpdate) bool {
        return self.name != null or self.description != null or self.color != null or self.position != null;
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
