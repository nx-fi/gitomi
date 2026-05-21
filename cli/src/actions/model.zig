const std = @import("std");
const git = @import("../git.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    act_path: []const u8 = "act",
    agent_runner_path: ?[]const u8 = null,
    dry_run: bool = false,
    allow_untrusted_local_execution: bool = false,
    extra_args: []const []const u8 = &.{},
};

pub const DaemonOptions = struct {
    act_path: []const u8 = "act",
    agent_runner_path: ?[]const u8 = null,
    dry_run: bool = false,
    allow_untrusted_local_execution: bool = false,
    extra_args: []const []const u8 = &.{},
    once: bool = false,
    replay: bool = false,
    interval_ms: u64 = 5000,
};

pub const ResolvedTarget = struct {
    allocator: Allocator,
    target_ref: ?[]u8,
    target_oid: []u8,

    pub fn deinit(self: *ResolvedTarget) void {
        if (self.target_ref) |value| self.allocator.free(value);
        self.allocator.free(self.target_oid);
    }
};

pub const Workflow = struct {
    allocator: Allocator,
    path: []u8,
    name: []u8,
    source_oid: []u8,
    triggers: [][]u8,
    trigger_defs: []WorkflowTrigger,
    dialect: WorkflowDialect,
    source: WorkflowSourcePolicy,
    permissions: []KeyValuePair,
    jobs: []WorkflowJob,
    schedules: []WorkflowSchedule,

    pub fn deinit(self: *Workflow) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        self.allocator.free(self.source_oid);
        for (self.triggers) |trigger| self.allocator.free(trigger);
        self.allocator.free(self.triggers);
        for (self.trigger_defs) |*trigger| trigger.deinit();
        self.allocator.free(self.trigger_defs);
        self.source.deinit(self.allocator);
        freeKeyValuePairs(self.allocator, self.permissions);
        for (self.jobs) |*job| job.deinit();
        self.allocator.free(self.jobs);
        for (self.schedules) |*schedule| schedule.deinit();
        self.allocator.free(self.schedules);
    }
};

pub const WorkflowDialect = enum {
    github_actions,
    gitomi,

    pub fn label(self: WorkflowDialect) []const u8 {
        return switch (self) {
            .github_actions => "github-actions",
            .gitomi => "gitomi",
        };
    }
};

pub const WorkflowSourcePolicy = struct {
    workflow_from: []u8,
    code_from: []u8,
    workflow_from_explicit: bool = false,
    code_from_explicit: bool = false,

    pub fn initDefaults(allocator: Allocator) !WorkflowSourcePolicy {
        return .{
            .workflow_from = try allocator.dupe(u8, "target"),
            .code_from = try allocator.dupe(u8, "target"),
        };
    }

    pub fn deinit(self: *WorkflowSourcePolicy, allocator: Allocator) void {
        allocator.free(self.workflow_from);
        allocator.free(self.code_from);
    }

    pub fn setWorkflowFrom(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
        const owned = try allocator.dupe(u8, value);
        allocator.free(self.workflow_from);
        self.workflow_from = owned;
        self.workflow_from_explicit = true;
    }

    pub fn setCodeFrom(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
        const owned = try allocator.dupe(u8, value);
        allocator.free(self.code_from);
        self.code_from = owned;
        self.code_from_explicit = true;
    }

    pub fn setWorkflowFromDefault(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
        if (self.workflow_from_explicit) return;
        const owned = try allocator.dupe(u8, value);
        allocator.free(self.workflow_from);
        self.workflow_from = owned;
    }

    pub fn setCodeFromDefault(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
        if (self.code_from_explicit) return;
        const owned = try allocator.dupe(u8, value);
        allocator.free(self.code_from);
        self.code_from = owned;
    }
};

pub const WorkflowTrigger = struct {
    allocator: Allocator,
    name: []u8,
    branches: [][]u8 = &.{},
    branches_ignore: [][]u8 = &.{},
    paths: [][]u8 = &.{},
    paths_ignore: [][]u8 = &.{},
    types: [][]u8 = &.{},
    actors: [][]u8 = &.{},
    labels: [][]u8 = &.{},

    pub fn deinit(self: *WorkflowTrigger) void {
        self.allocator.free(self.name);
        git.freeStringList(self.allocator, self.branches);
        git.freeStringList(self.allocator, self.branches_ignore);
        git.freeStringList(self.allocator, self.paths);
        git.freeStringList(self.allocator, self.paths_ignore);
        git.freeStringList(self.allocator, self.types);
        git.freeStringList(self.allocator, self.actors);
        git.freeStringList(self.allocator, self.labels);
    }
};

pub const WorkflowSchedule = struct {
    allocator: Allocator,
    cron: []u8,
    timezone: []u8,

    pub fn deinit(self: *WorkflowSchedule) void {
        self.allocator.free(self.cron);
        self.allocator.free(self.timezone);
    }
};

pub const KeyValuePair = struct {
    key: []u8,
    value: []u8,
};

pub const WorkflowJob = struct {
    allocator: Allocator,
    id: []u8,
    backend: []u8,
    uses: ?[]u8 = null,
    image: ?[]u8 = null,
    needs: [][]u8 = &.{},
    condition: ?[]u8 = null,
    with: []KeyValuePair = &.{},
    env: []KeyValuePair = &.{},
    permissions: []KeyValuePair = &.{},
    timeout_minutes: ?u64 = null,
    steps: []WorkflowStep = &.{},

    pub fn deinit(self: *WorkflowJob) void {
        self.allocator.free(self.id);
        self.allocator.free(self.backend);
        if (self.uses) |value| self.allocator.free(value);
        if (self.image) |value| self.allocator.free(value);
        git.freeStringList(self.allocator, self.needs);
        if (self.condition) |value| self.allocator.free(value);
        freeKeyValuePairs(self.allocator, self.with);
        freeKeyValuePairs(self.allocator, self.env);
        freeKeyValuePairs(self.allocator, self.permissions);
        for (self.steps) |*step| step.deinit();
        self.allocator.free(self.steps);
    }
};

pub const WorkflowStep = struct {
    allocator: Allocator,
    name: ?[]u8 = null,
    run: ?[]u8 = null,

    pub fn deinit(self: *WorkflowStep) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.run) |value| self.allocator.free(value);
    }
};

pub const RunRequest = struct {
    allocator: Allocator,
    run_id: []u8,
    workflow: []u8,
    workflow_source_ref: ?[]u8 = null,
    workflow_source_oid: ?[]u8 = null,
    target_ref: ?[]u8,
    target_oid: ?[]u8,
    event_name: []u8,
    gitomi_event_type: []u8,
    schedule_slot: ?[]u8 = null,
    source_workflow_from: ?[]u8 = null,
    source_code_from: ?[]u8 = null,

    pub fn deinit(self: *RunRequest) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.workflow);
        if (self.workflow_source_ref) |value| self.allocator.free(value);
        if (self.workflow_source_oid) |value| self.allocator.free(value);
        if (self.target_ref) |value| self.allocator.free(value);
        if (self.target_oid) |value| self.allocator.free(value);
        self.allocator.free(self.event_name);
        self.allocator.free(self.gitomi_event_type);
        if (self.schedule_slot) |value| self.allocator.free(value);
        if (self.source_workflow_from) |value| self.allocator.free(value);
        if (self.source_code_from) |value| self.allocator.free(value);
    }
};

pub const RequestResult = struct {
    allocator: Allocator,
    run_id: []u8,
    commit_oid: []u8,

    pub fn deinit(self: *RequestResult) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.commit_oid);
    }
};

pub const CompleteResult = struct {
    allocator: Allocator,
    commit_oid: []u8,

    pub fn deinit(self: *CompleteResult) void {
        self.allocator.free(self.commit_oid);
    }
};

pub const SchedulerState = struct {
    allocator: Allocator,
    exists: bool = false,
    last_event_ordinal: i64 = 0,
    last_schedule_minute: i64 = 0,
    last_head_oid: []u8,

    pub fn init(allocator: Allocator) !SchedulerState {
        return .{
            .allocator = allocator,
            .last_head_oid = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *SchedulerState) void {
        self.allocator.free(self.last_head_oid);
    }

    pub fn setHead(self: *SchedulerState, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.last_head_oid);
        self.last_head_oid = owned;
    }
};

pub const ExecuteResult = struct {
    allocator: Allocator,
    conclusion: []const u8,
    diagnostics_ref: ?[]u8 = null,
    diagnostics_oid: ?[]u8 = null,
    attempt_id: ?[]u8 = null,
    runner_id: ?[]u8 = null,
    workflow_source_oid: ?[]u8 = null,
    outputs_json: ?[]u8 = null,
    published_events_json: ?[]u8 = null,

    pub fn deinit(self: *ExecuteResult) void {
        if (self.diagnostics_ref) |value| self.allocator.free(value);
        if (self.diagnostics_oid) |value| self.allocator.free(value);
        if (self.attempt_id) |value| self.allocator.free(value);
        if (self.runner_id) |value| self.allocator.free(value);
        if (self.workflow_source_oid) |value| self.allocator.free(value);
        if (self.outputs_json) |value| self.allocator.free(value);
        if (self.published_events_json) |value| self.allocator.free(value);
    }
};

pub const EventContext = struct {
    event_type: []const u8 = "",
    event_name: []const u8 = "",
    actor: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    paths: ?[]const []u8 = null,
    labels: ?[]const []u8 = null,
};

pub const RunMetadata = struct {
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

pub const PullRefs = struct {
    allocator: Allocator,
    base_ref: []u8,
    head_ref: []u8,

    pub fn deinit(self: *PullRefs) void {
        self.allocator.free(self.base_ref);
        self.allocator.free(self.head_ref);
    }
};

pub const RunTargets = struct {
    workflow: ResolvedTarget,
    code: ResolvedTarget,
    workflow_trusted: bool,

    pub fn deinit(self: *RunTargets) void {
        self.workflow.deinit();
        self.code.deinit();
    }
};

pub const RunClaim = struct {
    allocator: Allocator,
    path: []u8,
    file: std.Io.File,

    pub fn deinit(self: *RunClaim) void {
        self.file.close(@import("compat").io());
        std.Io.Dir.deleteFileAbsolute(@import("compat").io(), self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub const PipelineManifest = struct {
    allocator: Allocator,
    path: []u8,
    name: []u8,
    tools: [][]u8,
    permissions: []KeyValuePair,

    pub fn deinit(self: *PipelineManifest) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        git.freeStringList(self.allocator, self.tools);
        freeKeyValuePairs(self.allocator, self.permissions);
    }
};

pub const JobState = enum {
    pending,
    skipped,
    completed,
};

pub const DiagnosticFile = struct {
    path: []u8,
    bytes: []u8,
};

pub const RunDiagnostics = struct {
    allocator: Allocator,
    attempt_id: []u8,
    started_at: []u8,
    files: std.ArrayList(DiagnosticFile) = .empty,
    job_outputs: std.ArrayList(JobJsonFragment) = .empty,
    job_artifacts: std.ArrayList(JobJsonFragment) = .empty,
    published_events: std.ArrayList([]u8) = .empty,
    log_refs: std.ArrayList(LogRef) = .empty,

    pub fn init(allocator: Allocator) !RunDiagnostics {
        return .{
            .allocator = allocator,
            .attempt_id = try util.newUuidV7(allocator),
            .started_at = try util.rfc3339Now(allocator),
        };
    }

    pub fn deinit(self: *RunDiagnostics) void {
        self.allocator.free(self.attempt_id);
        self.allocator.free(self.started_at);
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.bytes);
        }
        self.files.deinit(self.allocator);
        for (self.job_outputs.items) |fragment| {
            self.allocator.free(fragment.job_id);
            self.allocator.free(fragment.json);
        }
        self.job_outputs.deinit(self.allocator);
        for (self.job_artifacts.items) |fragment| {
            self.allocator.free(fragment.job_id);
            self.allocator.free(fragment.json);
        }
        self.job_artifacts.deinit(self.allocator);
        for (self.published_events.items) |event_hash| self.allocator.free(event_hash);
        self.published_events.deinit(self.allocator);
        for (self.log_refs.items) |ref| {
            self.allocator.free(ref.job_id);
            self.allocator.free(ref.stream);
            self.allocator.free(ref.path);
        }
        self.log_refs.deinit(self.allocator);
    }

    pub fn addCopy(self: *RunDiagnostics, path: []const u8, bytes: []const u8) !void {
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }

    pub fn addJobOutputCopy(self: *RunDiagnostics, job_id: []const u8, json: []const u8) !void {
        try self.job_outputs.append(self.allocator, .{
            .job_id = try self.allocator.dupe(u8, job_id),
            .json = try self.allocator.dupe(u8, json),
        });
    }

    pub fn addJobArtifactsCopy(self: *RunDiagnostics, job_id: []const u8, json: []const u8) !void {
        try self.job_artifacts.append(self.allocator, .{
            .job_id = try self.allocator.dupe(u8, job_id),
            .json = try self.allocator.dupe(u8, json),
        });
    }

    pub fn addPublishedEventCopy(self: *RunDiagnostics, event_hash: []const u8) !void {
        try self.published_events.append(self.allocator, try self.allocator.dupe(u8, event_hash));
    }

    pub fn addLogRefCopy(self: *RunDiagnostics, job_id: []const u8, stream: []const u8, path: []const u8) !void {
        try self.log_refs.append(self.allocator, .{
            .job_id = try self.allocator.dupe(u8, job_id),
            .stream = try self.allocator.dupe(u8, stream),
            .path = try self.allocator.dupe(u8, path),
        });
    }
};

pub const JobJsonFragment = struct {
    job_id: []u8,
    json: []u8,
};

pub const LogRef = struct {
    job_id: []u8,
    stream: []u8,
    path: []u8,
};

pub const DiagnosticRef = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    runner_id: []u8,

    pub fn deinit(self: *DiagnosticRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
        self.allocator.free(self.runner_id);
    }
};

pub fn freeKeyValuePairs(allocator: Allocator, values: []KeyValuePair) void {
    for (values) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(values);
}
