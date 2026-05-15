const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const EventWriter = event_writer_mod.EventWriter;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonString = json_writer.appendJsonString;

pub const Options = struct {
    act_path: []const u8 = "act",
    agent_runner_path: ?[]const u8 = null,
    dry_run: bool = false,
    extra_args: []const []const u8 = &.{},
};

pub const DaemonOptions = struct {
    act_path: []const u8 = "act",
    agent_runner_path: ?[]const u8 = null,
    dry_run: bool = false,
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
    triggers: [][]u8,
    trigger_defs: []WorkflowTrigger,
    dialect: WorkflowDialect,
    source: WorkflowSourcePolicy,
    permissions: []KeyValuePair,
    jobs: []WorkflowJob,
    schedules: [][]u8,

    pub fn deinit(self: *Workflow) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        for (self.triggers) |trigger| self.allocator.free(trigger);
        self.allocator.free(self.triggers);
        for (self.trigger_defs) |*trigger| trigger.deinit();
        self.allocator.free(self.trigger_defs);
        self.source.deinit(self.allocator);
        freeKeyValuePairs(self.allocator, self.permissions);
        for (self.jobs) |*job| job.deinit();
        self.allocator.free(self.jobs);
        for (self.schedules) |schedule| self.allocator.free(schedule);
        self.allocator.free(self.schedules);
    }
};

pub const WorkflowDialect = enum {
    github_actions,
    gitomi,

    fn label(self: WorkflowDialect) []const u8 {
        return switch (self) {
            .github_actions => "github-actions",
            .gitomi => "gitomi",
        };
    }
};

pub const WorkflowSourcePolicy = struct {
    workflow_from: []u8,
    code_from: []u8,

    fn initDefaults(allocator: Allocator) !WorkflowSourcePolicy {
        return .{
            .workflow_from = try allocator.dupe(u8, "target"),
            .code_from = try allocator.dupe(u8, "target"),
        };
    }

    fn deinit(self: *WorkflowSourcePolicy, allocator: Allocator) void {
        allocator.free(self.workflow_from);
        allocator.free(self.code_from);
    }

    fn setWorkflowFrom(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
        const owned = try allocator.dupe(u8, value);
        allocator.free(self.workflow_from);
        self.workflow_from = owned;
    }

    fn setCodeFrom(self: *WorkflowSourcePolicy, allocator: Allocator, value: []const u8) !void {
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

    fn deinit(self: *WorkflowTrigger) void {
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
    target_ref: ?[]u8,
    target_oid: ?[]u8,
    event_name: []u8,
    gitomi_event_type: []u8,
    schedule_slot: ?[]u8 = null,

    pub fn deinit(self: *RunRequest) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.workflow);
        if (self.target_ref) |value| self.allocator.free(value);
        if (self.target_oid) |value| self.allocator.free(value);
        self.allocator.free(self.event_name);
        self.allocator.free(self.gitomi_event_type);
        if (self.schedule_slot) |value| self.allocator.free(value);
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

const SchedulerState = struct {
    allocator: Allocator,
    exists: bool = false,
    last_event_ordinal: i64 = 0,
    last_schedule_minute: i64 = 0,
    last_head_oid: []u8,

    fn init(allocator: Allocator) !SchedulerState {
        return .{
            .allocator = allocator,
            .last_head_oid = try allocator.dupe(u8, ""),
        };
    }

    fn deinit(self: *SchedulerState) void {
        self.allocator.free(self.last_head_oid);
    }

    fn setHead(self: *SchedulerState, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.last_head_oid);
        self.last_head_oid = owned;
    }
};

const ExecuteResult = struct {
    allocator: Allocator,
    conclusion: []const u8,
    diagnostics_ref: ?[]u8 = null,
    diagnostics_oid: ?[]u8 = null,
    attempt_id: ?[]u8 = null,
    runner_id: ?[]u8 = null,

    fn deinit(self: *ExecuteResult) void {
        if (self.diagnostics_ref) |value| self.allocator.free(value);
        if (self.diagnostics_oid) |value| self.allocator.free(value);
        if (self.attempt_id) |value| self.allocator.free(value);
        if (self.runner_id) |value| self.allocator.free(value);
    }
};

const EventContext = struct {
    event_type: []const u8 = "",
    event_name: []const u8 = "",
    actor: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    paths: ?[]const []u8 = null,
    labels: ?[]const []u8 = null,
};

const RunMetadata = struct {
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

const RunClaim = struct {
    allocator: Allocator,
    path: []u8,
    file: std.fs.File,

    fn deinit(self: *RunClaim) void {
        self.file.close();
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }
};

const PipelineManifest = struct {
    allocator: Allocator,
    path: []u8,
    name: []u8,
    tools: [][]u8,
    permissions: []KeyValuePair,

    fn deinit(self: *PipelineManifest) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        git.freeStringList(self.allocator, self.tools);
        freeKeyValuePairs(self.allocator, self.permissions);
    }
};

const JobState = enum {
    pending,
    skipped,
    completed,
};

const DiagnosticFile = struct {
    path: []u8,
    bytes: []u8,
};

const RunDiagnostics = struct {
    allocator: Allocator,
    attempt_id: []u8,
    files: std.ArrayList(DiagnosticFile) = .empty,

    fn init(allocator: Allocator) !RunDiagnostics {
        return .{
            .allocator = allocator,
            .attempt_id = try util.newUuidV7(allocator),
        };
    }

    fn deinit(self: *RunDiagnostics) void {
        self.allocator.free(self.attempt_id);
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.bytes);
        }
        self.files.deinit(self.allocator);
    }

    fn addCopy(self: *RunDiagnostics, path: []const u8, bytes: []const u8) !void {
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }
};

const DiagnosticRef = struct {
    allocator: Allocator,
    ref: []u8,
    oid: []u8,
    runner_id: []u8,

    fn deinit(self: *DiagnosticRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
        self.allocator.free(self.runner_id);
    }
};

pub fn resolveTarget(allocator: Allocator, target_ref: ?[]const u8, target_oid: ?[]const u8) !ResolvedTarget {
    var owned_ref: ?[]u8 = null;
    errdefer if (owned_ref) |value| allocator.free(value);

    const rev = if (target_oid) |oid| blk: {
        if (target_ref) |ref| owned_ref = try allocator.dupe(u8, ref);
        break :blk oid;
    } else blk: {
        const ref = target_ref orelse "HEAD";
        owned_ref = try allocator.dupe(u8, ref);
        break :blk ref;
    };

    const commitish = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{rev});
    defer allocator.free(commitish);
    const oid_raw = git.gitChecked(allocator, &.{ "rev-parse", "--verify", commitish }) catch |err| {
        if (err == CliError.GitFailed) {
            try io.eprint("gt actions: target '{s}' does not resolve to a commit\n", .{rev});
            return CliError.UserError;
        }
        return err;
    };
    const oid = try util.trimOwned(allocator, oid_raw);
    errdefer allocator.free(oid);

    return .{
        .allocator = allocator,
        .target_ref = owned_ref,
        .target_oid = oid,
    };
}

pub fn loadWorkflows(allocator: Allocator, rev: []const u8) ![]Workflow {
    const raw = git.gitChecked(allocator, &.{ "ls-tree", "-r", "--name-only", rev, ".gitomi/workflows", ".github/workflows" }) catch |err| {
        if (err == CliError.GitFailed) {
            try io.eprint("gt actions: failed to read workflow definitions from {s}\n", .{rev});
            return CliError.UserError;
        }
        return err;
    };
    defer allocator.free(raw);

    var workflows: std.ArrayList(Workflow) = .empty;
    errdefer {
        for (workflows.items) |*workflow| workflow.deinit();
        workflows.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const path = std.mem.trim(u8, line_raw, " \t\r\n");
        if (!isWorkflowPath(path)) continue;

        const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rev, path });
        defer allocator.free(spec);
        const contents = try git.gitChecked(allocator, &.{ "show", spec });
        defer allocator.free(contents);

        const workflow = try parseWorkflow(allocator, path, contents);
        try workflows.append(allocator, workflow);
    }

    return workflows.toOwnedSlice(allocator);
}

pub fn freeWorkflows(allocator: Allocator, workflows: []Workflow) void {
    for (workflows) |*workflow| workflow.deinit();
    allocator.free(workflows);
}

pub fn printWorkflows(allocator: Allocator, target_ref: ?[]const u8, target_oid: ?[]const u8, json: bool) !void {
    var target = try resolveTarget(allocator, target_ref, target_oid);
    defer target.deinit();
    const workflows = try loadWorkflows(allocator, target.target_oid);
    defer freeWorkflows(allocator, workflows);

    for (workflows) |workflow| {
        if (json) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);
            try line.append(allocator, '{');
            try appendJsonFieldString(&line, allocator, "path", workflow.path, true);
            try appendJsonFieldString(&line, allocator, "name", workflow.name, true);
            try appendJsonFieldString(&line, allocator, "dialect", workflow.dialect.label(), true);
            try appendJsonFieldStringArray(&line, allocator, "triggers", workflow.triggers, false);
            try line.append(allocator, '}');
            try io.out("{s}\n", .{line.items});
        } else {
            try io.out("{s}\t{s}\t{s}\t", .{ workflow.path, workflow.name, workflow.dialect.label() });
            for (workflow.triggers, 0..) |trigger, idx| {
                if (idx != 0) try io.out(",", .{});
                try io.out("{s}", .{trigger});
            }
            try io.out("\n", .{});
        }
    }
}

pub fn requestWorkflow(
    allocator: Allocator,
    selector: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    event_name: ?[]const u8,
    gitomi_event_type: ?[]const u8,
) !RequestResult {
    var target = try resolveTarget(allocator, target_ref, target_oid);
    defer target.deinit();

    const workflows = try loadWorkflows(allocator, target.target_oid);
    defer freeWorkflows(allocator, workflows);
    const workflow = try resolveWorkflowSelector(workflows, selector);

    return try createRunRequestedEvent(
        allocator,
        workflow.path,
        target.target_ref,
        target.target_oid,
        event_name orelse "workflow_dispatch",
        gitomi_event_type,
        false,
    );
}

pub fn completeRun(
    allocator: Allocator,
    run_id: []const u8,
    conclusion: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    workflow: ?[]const u8,
    event_name: ?[]const u8,
) !CompleteResult {
    if (!util.looksLikeUuid(run_id)) {
        try io.eprint("gt actions complete: RUN must be a run UUID\n", .{});
        return CliError.UserError;
    }
    if (!isConclusion(conclusion)) {
        try io.eprint("gt actions complete: --conclusion must be success, failure, cancelled, skipped, neutral, timed_out, or action_required\n", .{});
        return CliError.UserError;
    }

    var target = try resolveTarget(allocator, target_ref, target_oid);
    defer target.deinit();
    return try createRunCompletedEvent(allocator, run_id, conclusion, target.target_ref, target.target_oid, workflow, event_name, null, null, false);
}

pub fn scheduleEvent(
    allocator: Allocator,
    event_type: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    object_id: ?[]const u8,
    options: Options,
) !void {
    try scheduleEventWithContext(allocator, event_type, target_ref, target_oid, object_id, .{}, options);
}

fn scheduleEventWithContext(
    allocator: Allocator,
    event_type: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    object_id: ?[]const u8,
    context_extra: EventContext,
    options: Options,
) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var target = try resolveTarget(allocator, target_ref, target_oid);
    defer target.deinit();

    const workflows = try loadWorkflows(allocator, target.target_oid);
    defer freeWorkflows(allocator, workflows);

    const event_name = githubEventName(event_type);
    const branch = context_extra.branch orelse branchNameFromRef(target.target_ref);
    const context = EventContext{
        .event_type = event_type,
        .event_name = event_name,
        .actor = context_extra.actor,
        .branch = branch,
        .paths = context_extra.paths,
        .labels = context_extra.labels,
    };
    var matched: usize = 0;
    var failed = false;
    for (workflows) |workflow| {
        if (!workflowMatchesContext(workflow, context)) continue;
        matched += 1;
        if (options.dry_run) {
            try io.out("would run {s} for {s} at {s}\n", .{ workflow.path, event_type, target.target_oid });
            continue;
        }

        if (try requestAndExecuteWorkflow(allocator, repo, workflow, target, event_name, event_type, object_id, .{}, options)) {
            failed = true;
        }
    }

    if (matched == 0) {
        try io.out("no workflows matched {s}\n", .{event_type});
        return;
    }
    if (failed) return CliError.UserError;
}

pub fn runRequested(allocator: Allocator, run_filter: ?[]const u8, options: Options) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();
    try runRequestedWithRepo(allocator, repo, run_filter, options);
}

fn runRequestedWithRepo(allocator: Allocator, repo: repo_mod.Repo, run_filter: ?[]const u8, options: Options) !void {
    const requests = try loadPendingRequests(allocator, repo);
    defer {
        for (requests) |*request| request.deinit();
        allocator.free(requests);
    }

    if (requests.len == 0) {
        try io.out("no pending action run requests\n", .{});
        return;
    }

    const selected = try selectRequests(allocator, requests, run_filter);
    defer allocator.free(selected);

    var failed = false;
    for (selected) |idx| {
        const request = requests[idx];
        var target = if (request.target_oid) |target_oid| ResolvedTarget{
            .allocator = allocator,
            .target_ref = if (request.target_ref) |value| try allocator.dupe(u8, value) else null,
            .target_oid = try allocator.dupe(u8, target_oid),
        } else try resolveTarget(allocator, request.target_ref, null);
        defer target.deinit();

        const workflows = try loadWorkflows(allocator, target.target_oid);
        defer freeWorkflows(allocator, workflows);
        const workflow = try resolveWorkflowSelector(workflows, request.workflow);

        if (options.dry_run) {
            try io.out("would run requested {s} {s} at {s}\n", .{ request.run_id, workflow.path, target.target_oid });
            continue;
        }

        var execution = executeWorkflow(
            allocator,
            repo,
            request.run_id,
            workflow,
            target,
            request.event_name,
            if (request.gitomi_event_type.len == 0) "action.run_requested" else request.gitomi_event_type,
            null,
            request.schedule_slot,
            options,
        ) catch |err| blk: {
            if (!errors.isReported(err)) try io.eprint("gt actions: execution failed: {s}\n", .{@errorName(err)});
            break :blk ExecuteResult{ .allocator = allocator, .conclusion = "failure" };
        };
        defer execution.deinit();
        var completed = try createRunCompletedEventWithMetadata(
            allocator,
            request.run_id,
            execution.conclusion,
            target.target_ref,
            target.target_oid,
            workflow.path,
            request.event_name,
            execution.diagnostics_ref,
            execution.diagnostics_oid,
            .{
                .attempt_id = execution.attempt_id,
                .runner_id = execution.runner_id,
            },
            false,
        );
        defer completed.deinit();
        if (!std.mem.eql(u8, execution.conclusion, "success")) failed = true;
    }

    if (failed) return CliError.UserError;
}

pub fn runDaemon(allocator: Allocator, options: DaemonOptions) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    try io.out("gt actions daemon: watching {s}\n", .{repo.root});
    if (options.replay) {
        try io.out("gt actions daemon: replaying existing accepted events\n", .{});
    }

    var tick_options = options;
    while (true) {
        try runDaemonTick(allocator, repo, tick_options);
        if (options.once) return;
        tick_options.replay = false;
        std.Thread.sleep(options.interval_ms * std.time.ns_per_ms);
    }
}

fn runDaemonTick(allocator: Allocator, repo: repo_mod.Repo, options: DaemonOptions) !void {
    try index.ensureIndex(allocator, repo);

    if (try countPendingRequests(allocator, repo) != 0) {
        runRequestedWithRepo(allocator, repo, null, daemonRunOptions(options)) catch |err| {
            if (!errors.isUserError(err)) return err;
            if (!errors.isReported(err)) {
                try io.eprint("gt actions daemon: pending run failed: {s}\n", .{@errorName(err)});
            }
        };
        try index.ensureIndex(allocator, repo);
    }

    var state = try loadSchedulerState(allocator, repo, options.replay);
    defer state.deinit();

    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    const max_ordinal = try maxAcceptedOrdinal(&db);
    const current_schedule_minute = @divTrunc(std.time.timestamp(), 60);
    if (!state.exists and !options.replay) {
        state.last_event_ordinal = max_ordinal;
        state.last_schedule_minute = current_schedule_minute;
        if (try currentHeadOid(allocator)) |head| {
            defer allocator.free(head);
            try state.setHead(head);
        }
        if (!options.dry_run) try saveSchedulerState(allocator, repo, state);
        try io.out("gt actions daemon: initialized scheduler cursor at event {d}\n", .{state.last_event_ordinal});
        return;
    }

    try scheduleAcceptedEventsAfter(allocator, repo, &db, state.last_event_ordinal, options);
    state.last_event_ordinal = max_ordinal;

    if (try currentHeadOid(allocator)) |head| {
        defer allocator.free(head);
        if (options.replay or state.last_head_oid.len == 0 or !std.mem.eql(u8, state.last_head_oid, head)) {
            const push_ref = (try currentBranchRef(allocator)) orelse try allocator.dupe(u8, "HEAD");
            defer allocator.free(push_ref);
            const changed_paths = if (!options.replay and state.last_head_oid.len != 0)
                try changedPathsBetween(allocator, state.last_head_oid, head)
            else
                try allocator.alloc([]u8, 0);
            defer git.freeStringList(allocator, changed_paths);
            try runScheduledEventWithContext(
                allocator,
                "push",
                push_ref,
                head,
                null,
                .{
                    .branch = branchNameFromRef(push_ref),
                    .paths = changed_paths,
                },
                options,
            );
            try state.setHead(head);
        }
    }

    try scheduleDueWorkflows(allocator, repo, &state, current_schedule_minute, options);

    if (!options.dry_run) try saveSchedulerState(allocator, repo, state);
}

fn scheduleAcceptedEventsAfter(
    allocator: Allocator,
    repo: repo_mod.Repo,
    db: *index.SqliteDb,
    last_ordinal: i64,
    options: DaemonOptions,
) !void {
    _ = repo;
    var stmt = try db.prepare(
        \\SELECT ordinal, event_type, object_id, actor_principal, body
        \\FROM events
        \\WHERE valid_json != 0 AND domain_status = 'accepted' AND ordinal > ?
        \\ORDER BY ordinal
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, last_ordinal);

    while (try stmt.step()) {
        const event_type = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(event_type);
        const object_id = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(object_id);
        const actor = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(actor);
        const body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(body);

        if (std.mem.startsWith(u8, event_type, "action.")) continue;
        const labels = try labelsFromEventPayload(allocator, body);
        defer git.freeStringList(allocator, labels);
        const branch = try branchFromIndexedEvent(allocator, db, event_type, object_id, body);
        defer if (branch) |value| allocator.free(value);
        try runScheduledEventWithContext(
            allocator,
            event_type,
            null,
            null,
            if (object_id.len == 0) null else object_id,
            .{
                .actor = actor,
                .branch = branch,
                .labels = labels,
            },
            options,
        );
    }
}

fn runScheduledEvent(
    allocator: Allocator,
    event_type: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    object_id: ?[]const u8,
    options: DaemonOptions,
) !void {
    try runScheduledEventWithContext(allocator, event_type, target_ref, target_oid, object_id, .{}, options);
}

fn runScheduledEventWithContext(
    allocator: Allocator,
    event_type: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    object_id: ?[]const u8,
    context: EventContext,
    options: DaemonOptions,
) !void {
    scheduleEventWithContext(allocator, event_type, target_ref, target_oid, object_id, context, daemonRunOptions(options)) catch |err| {
        if (errors.isUserError(err)) return;
        return err;
    };
}

fn scheduleDueWorkflows(
    allocator: Allocator,
    repo: repo_mod.Repo,
    state: *SchedulerState,
    current_minute: i64,
    options: DaemonOptions,
) !void {
    if (current_minute <= 0) return;
    var start_minute = state.last_schedule_minute + 1;
    if (state.last_schedule_minute <= 0 or options.replay) start_minute = current_minute;
    if (current_minute - start_minute > 1440) start_minute = current_minute - 1440;
    if (start_minute > current_minute) return;

    const head = (try currentHeadOid(allocator)) orelse return;
    defer allocator.free(head);
    var target = ResolvedTarget{
        .allocator = allocator,
        .target_ref = try allocator.dupe(u8, "HEAD"),
        .target_oid = try allocator.dupe(u8, head),
    };
    defer target.deinit();

    const workflows = try loadWorkflows(allocator, target.target_oid);
    defer freeWorkflows(allocator, workflows);

    var failed = false;
    var minute = start_minute;
    while (minute <= current_minute) : (minute += 1) {
        for (workflows) |workflow| {
            for (workflow.schedules) |cron| {
                if (!cronMatches(cron, minute * 60)) continue;
                const slot = try scheduleSlotKey(allocator, workflow.path, cron, minute);
                defer allocator.free(slot);
                if (options.dry_run) {
                    try io.out("would run scheduled {s} for minute {d}\n", .{ workflow.path, minute });
                    continue;
                }
                if (try requestAndExecuteWorkflow(
                    allocator,
                    repo,
                    workflow,
                    target,
                    "schedule",
                    "workflow.schedule",
                    null,
                    .{ .schedule_slot = slot },
                    daemonRunOptions(options),
                )) {
                    failed = true;
                }
            }
        }
    }
    state.last_schedule_minute = current_minute;
    if (failed) return CliError.UserError;
}

fn daemonRunOptions(options: DaemonOptions) Options {
    return .{
        .act_path = options.act_path,
        .agent_runner_path = options.agent_runner_path,
        .dry_run = options.dry_run,
        .extra_args = options.extra_args,
    };
}

fn requestAndExecuteWorkflow(
    allocator: Allocator,
    repo: repo_mod.Repo,
    workflow: Workflow,
    target: ResolvedTarget,
    event_name: []const u8,
    event_type: []const u8,
    object_id: ?[]const u8,
    metadata_extra: RunMetadata,
    options: Options,
) !bool {
    const permission_grant_json = try buildPermissionGrantJson(allocator, workflow);
    defer allocator.free(permission_grant_json);
    const metadata = RunMetadata{
        .workflow_name = workflow.name,
        .workflow_dialect = workflow.dialect.label(),
        .workflow_source_ref = target.target_ref,
        .workflow_source_oid = target.target_oid,
        .backend_kind = workflowBackendSummary(workflow),
        .pipeline = workflowPipelineSummary(workflow),
        .schedule_slot = metadata_extra.schedule_slot,
        .source_workflow_from = workflow.source.workflow_from,
        .source_code_from = workflow.source.code_from,
        .permission_grant_json = permission_grant_json,
    };
    var request = try createRunRequestedEventWithMetadata(
        allocator,
        workflow.path,
        target.target_ref,
        target.target_oid,
        event_name,
        event_type,
        metadata,
        false,
    );
    defer request.deinit();

    var execution = executeWorkflow(
        allocator,
        repo,
        request.run_id,
        workflow,
        target,
        event_name,
        event_type,
        object_id,
        metadata_extra.schedule_slot,
        options,
    ) catch |err| blk: {
        if (!errors.isReported(err)) try io.eprint("gt actions: execution failed: {s}\n", .{@errorName(err)});
        break :blk ExecuteResult{ .allocator = allocator, .conclusion = "failure" };
    };
    defer execution.deinit();

    var completed = try createRunCompletedEventWithMetadata(
        allocator,
        request.run_id,
        execution.conclusion,
        target.target_ref,
        target.target_oid,
        workflow.path,
        event_name,
        execution.diagnostics_ref,
        execution.diagnostics_oid,
        .{
            .attempt_id = execution.attempt_id,
            .runner_id = execution.runner_id,
        },
        false,
    );
    defer completed.deinit();

    return !std.mem.eql(u8, execution.conclusion, "success");
}

pub fn countPendingRequests(allocator: Allocator, repo: repo_mod.Repo) !usize {
    const requests = try loadPendingRequests(allocator, repo);
    defer {
        for (requests) |*request| request.deinit();
        allocator.free(requests);
    }
    return requests.len;
}

fn maxAcceptedOrdinal(db: *index.SqliteDb) !i64 {
    var stmt = try db.prepare("SELECT COALESCE(MAX(ordinal), 0) FROM events WHERE domain_status = 'accepted'");
    defer stmt.deinit();
    if (try stmt.step()) return stmt.columnInt64(0);
    return 0;
}

fn currentHeadOid(allocator: Allocator) !?[]u8 {
    var argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD^{commit}" };
    var result = try git.runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return null;
    return try util.trimDup(allocator, result.stdout);
}

fn currentBranchRef(allocator: Allocator) !?[]u8 {
    var argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "HEAD" };
    var result = try git.runCommand(allocator, &argv, null, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return null;
    return try util.trimDup(allocator, result.stdout);
}

fn changedPathsBetween(allocator: Allocator, before_oid: []const u8, after_oid: []const u8) ![][]u8 {
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ before_oid, after_oid });
    defer allocator.free(range);
    var argv = [_][]const u8{ "git", "diff", "--name-only", range };
    var result = try git.runCommand(allocator, &argv, null, git.max_git_output);
    defer result.deinit();
    if (result.exitCode() != 0) return allocator.alloc([]u8, 0);

    var paths: [][]u8 = &.{};
    errdefer git.freeStringList(allocator, paths);
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line_raw| {
        const path = std.mem.trim(u8, line_raw, " \t\r\n");
        if (path.len != 0) try appendStringToSlice(allocator, &paths, path);
    }
    return paths;
}

fn branchNameFromRef(ref: ?[]const u8) ?[]const u8 {
    const value = ref orelse return null;
    if (std.mem.startsWith(u8, value, "refs/heads/")) return value["refs/heads/".len..];
    if (std.mem.startsWith(u8, value, "heads/")) return value["heads/".len..];
    if (std.mem.eql(u8, value, "HEAD")) return null;
    return value;
}

fn labelsFromEventPayload(allocator: Allocator, body: []const u8) ![][]u8 {
    var labels: [][]u8 = &.{};
    errdefer git.freeStringList(allocator, labels);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return labels;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return labels,
    };
    const payload = switch (root.get("payload") orelse return labels) {
        .object => |object| object,
        else => return labels,
    };
    try appendPayloadLabels(allocator, &labels, payload, "label");
    try appendPayloadLabels(allocator, &labels, payload, "labels");
    try appendPayloadLabels(allocator, &labels, payload, "labels_added");
    return labels;
}

fn appendPayloadLabels(allocator: Allocator, labels: *[][]u8, payload: std.json.ObjectMap, key: []const u8) !void {
    const value = payload.get(key) orelse return;
    switch (value) {
        .string => |label| try appendStringToSlice(allocator, labels, label),
        .array => |items| {
            for (items.items) |item| {
                switch (item) {
                    .string => |label| try appendStringToSlice(allocator, labels, label),
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn branchFromIndexedEvent(allocator: Allocator, db: *index.SqliteDb, event_type: []const u8, object_id: []const u8, body: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, event_type, "pull.")) return branchFromEventPayload(allocator, body);
    if (object_id.len != 0) {
        var stmt = try db.prepare("SELECT base_ref FROM pulls WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, object_id);
        if (try stmt.step()) return try stmt.columnTextDup(allocator, 0);
    }
    return branchFromEventPayload(allocator, body);
}

fn branchFromEventPayload(allocator: Allocator, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const payload = switch (root.get("payload") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    if (event_mod.jsonString(payload.get("base_ref"))) |value| return try allocator.dupe(u8, value);
    if (event_mod.jsonString(payload.get("ref"))) |value| return try allocator.dupe(u8, value);
    return null;
}

fn scheduleSlotKey(allocator: Allocator, workflow_path: []const u8, cron: []const u8, minute: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}:{s}", .{ minute, workflow_path, cron });
}

fn schedulerStatePath(allocator: Allocator, repo: repo_mod.Repo) ![]u8 {
    return std.fs.path.join(allocator, &.{ repo.gitomi_dir, "actions-scheduler.state" });
}

fn loadSchedulerState(allocator: Allocator, repo: repo_mod.Repo, replay: bool) !SchedulerState {
    var state = try SchedulerState.init(allocator);
    errdefer state.deinit();
    if (replay) return state;

    const path = try schedulerStatePath(allocator, repo);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => return state,
        else => return err,
    };
    defer allocator.free(bytes);

    state.exists = true;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "last_event_ordinal")) {
            state.last_event_ordinal = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "last_head_oid")) {
            try state.setHead(value);
        } else if (std.mem.eql(u8, key, "last_schedule_minute")) {
            state.last_schedule_minute = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }
    return state;
}

fn saveSchedulerState(allocator: Allocator, repo: repo_mod.Repo, state: SchedulerState) !void {
    try std.fs.cwd().makePath(repo.gitomi_dir);
    const path = try schedulerStatePath(allocator, repo);
    defer allocator.free(path);
    const contents = try std.fmt.allocPrint(
        allocator,
        "last_event_ordinal={d}\nlast_head_oid={s}\nlast_schedule_minute={d}\n",
        .{ state.last_event_ordinal, state.last_head_oid, state.last_schedule_minute },
    );
    defer allocator.free(contents);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

pub fn createRunRequestedEvent(
    allocator: Allocator,
    workflow: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    event_name: ?[]const u8,
    gitomi_event_type: ?[]const u8,
    quiet: bool,
) !RequestResult {
    return createRunRequestedEventWithMetadata(
        allocator,
        workflow,
        target_ref,
        target_oid,
        event_name,
        gitomi_event_type,
        .{},
        quiet,
    );
}

fn createRunRequestedEventWithMetadata(
    allocator: Allocator,
    workflow: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    event_name: ?[]const u8,
    gitomi_event_type: ?[]const u8,
    metadata: RunMetadata,
    quiet: bool,
) !RequestResult {
    var writer = try EventWriter.init(allocator, "gt actions request");
    defer writer.deinit();

    const run_id = try util.newUuidV7(allocator);
    errdefer allocator.free(run_id);
    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildActionRunRequestedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        run_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        workflow,
        target_ref,
        target_oid,
        event_name,
        gitomi_event_type,
        .{
            .workflow_name = metadata.workflow_name,
            .workflow_dialect = metadata.workflow_dialect,
            .workflow_source_ref = metadata.workflow_source_ref,
            .workflow_source_oid = metadata.workflow_source_oid,
            .backend_kind = metadata.backend_kind,
            .pipeline = metadata.pipeline,
            .schedule_slot = metadata.schedule_slot,
            .source_workflow_from = metadata.source_workflow_from,
            .source_code_from = metadata.source_code_from,
            .permission_grant_json = metadata.permission_grant_json,
        },
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "action.run_requested #{s} {s}", .{ run_id[0..7], workflow });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt actions request", subject, event_body);
    errdefer allocator.free(commit_oid);

    if (!quiet) {
        try io.out("requested action run #{s}\n", .{run_id[0..7]});
        try io.out("  id:       {s}\n", .{run_id});
        try io.out("  workflow: {s}\n", .{workflow});
        try io.out("  commit:   {s}\n", .{commit_oid});
        try io.out("  ref:      {s}\n", .{writer.inbox_ref});
    }

    return .{ .allocator = allocator, .run_id = run_id, .commit_oid = commit_oid };
}

pub fn createRunCompletedEvent(
    allocator: Allocator,
    run_id: []const u8,
    conclusion: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    workflow: ?[]const u8,
    event_name: ?[]const u8,
    diagnostics_ref: ?[]const u8,
    diagnostics_oid: ?[]const u8,
    quiet: bool,
) !CompleteResult {
    return createRunCompletedEventWithMetadata(
        allocator,
        run_id,
        conclusion,
        target_ref,
        target_oid,
        workflow,
        event_name,
        diagnostics_ref,
        diagnostics_oid,
        .{},
        quiet,
    );
}

fn createRunCompletedEventWithMetadata(
    allocator: Allocator,
    run_id: []const u8,
    conclusion: []const u8,
    target_ref: ?[]const u8,
    target_oid: ?[]const u8,
    workflow: ?[]const u8,
    event_name: ?[]const u8,
    diagnostics_ref: ?[]const u8,
    diagnostics_oid: ?[]const u8,
    metadata: event_mod.ActionRunCompletedMetadata,
    quiet: bool,
) !CompleteResult {
    var writer = try EventWriter.init(allocator, "gt actions complete");
    defer writer.deinit();

    const event_uuid = try util.newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try util.newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try util.rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const event_body = try event_mod.buildActionRunCompletedJson(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        run_id,
        event_uuid,
        idem,
        occurred_at,
        writer.eventParents(),
        conclusion,
        target_ref,
        target_oid,
        workflow,
        event_name,
        diagnostics_ref,
        diagnostics_oid,
        metadata,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "action.run_completed #{s} {s}", .{ run_id[0..@min(run_id.len, 7)], conclusion });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt actions complete", subject, event_body);
    errdefer allocator.free(commit_oid);

    if (!quiet) {
        try io.out("completed action run #{s}\n", .{run_id[0..@min(run_id.len, 7)]});
        try io.out("  conclusion: {s}\n", .{conclusion});
        try io.out("  commit:     {s}\n", .{commit_oid});
        try io.out("  ref:        {s}\n", .{writer.inbox_ref});
    }

    return .{ .allocator = allocator, .commit_oid = commit_oid };
}

fn executeWorkflow(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    object_id: ?[]const u8,
    schedule_slot: ?[]const u8,
    options: Options,
) !ExecuteResult {
    var claim = try acquireRunClaim(allocator, repo, run_id);
    defer claim.deinit();

    const permission_grant_json = try buildPermissionGrantJson(allocator, workflow);
    defer allocator.free(permission_grant_json);
    const event_path = try writeActEventPayload(allocator, repo, run_id, workflow, target, event_name, gitomi_event_type, object_id, schedule_slot, permission_grant_json);
    defer {
        std.fs.deleteFileAbsolute(event_path) catch {};
        allocator.free(event_path);
    }

    var diagnostics = try RunDiagnostics.init(allocator);
    defer diagnostics.deinit();

    const worktree_path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-act-{s}", .{run_id});
    defer allocator.free(worktree_path);

    const added = git.gitChecked(allocator, &.{ "worktree", "add", "--detach", "--quiet", worktree_path, target.target_oid }) catch |err| {
        if (err == CliError.GitFailed) {
            try io.eprint("gt actions: failed to create temporary worktree for {s}\n", .{target.target_oid});
            return CliError.UserError;
        }
        return err;
    };
    allocator.free(added);

    defer {
        if (git.gitChecked(allocator, &.{ "worktree", "remove", "--force", worktree_path })) |removed| {
            allocator.free(removed);
        } else |_| {}
    }

    const conclusion = switch (workflow.dialect) {
        .github_actions => try executeGithubActionsWorkflow(allocator, workflow, event_name, event_path, worktree_path, options, &diagnostics),
        .gitomi => try executeGitomiWorkflow(allocator, repo, run_id, workflow, target, event_name, gitomi_event_type, event_path, worktree_path, options, &diagnostics),
    };

    var result = ExecuteResult{ .allocator = allocator, .conclusion = conclusion };
    result.attempt_id = try allocator.dupe(u8, diagnostics.attempt_id);
    if (writeRunDiagnostics(allocator, repo, run_id, workflow, target, conclusion, diagnostics)) |diag_ref_value| {
        var diag_ref = diag_ref_value;
        defer diag_ref.deinit();
        result.diagnostics_ref = try allocator.dupe(u8, diag_ref.ref);
        result.diagnostics_oid = try allocator.dupe(u8, diag_ref.oid);
        result.runner_id = try allocator.dupe(u8, diag_ref.runner_id);
    } else |err| {
        if (!errors.isReported(err)) try io.eprint("gt actions: failed to write run diagnostics: {s}\n", .{@errorName(err)});
    }
    return result;
}

fn executeGithubActionsWorkflow(
    allocator: Allocator,
    workflow: Workflow,
    event_name: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.act_path);
    try argv.append(allocator, event_name);
    try argv.append(allocator, "-W");
    try argv.append(allocator, workflow.path);
    try argv.append(allocator, "-e");
    try argv.append(allocator, event_path);
    for (options.extra_args) |arg| try argv.append(allocator, arg);

    var result = runCommandInDir(allocator, argv.items, worktree_path, null, git.max_git_output) catch |err| switch (err) {
        error.FileNotFound => {
            try io.eprint("gt actions: nektos/act executable not found: {s}\n", .{options.act_path});
            return CliError.UserError;
        },
        else => return err,
    };
    defer result.deinit();

    if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
    if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
    try addStepLogs(allocator, diagnostics, "act", 1, result.stdout, result.stderr);

    return if (result.exitCode() == 0) "success" else "failure";
}

fn executeGitomiWorkflow(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    _ = repo;
    _ = target;
    _ = event_name;
    _ = gitomi_event_type;

    if (workflow.jobs.len == 0) {
        try io.eprint("gt actions: native workflow {s} has no jobs\n", .{workflow.path});
        return "failure";
    }

    const states = try allocator.alloc(JobState, workflow.jobs.len);
    defer allocator.free(states);
    @memset(states, .pending);

    var completed_count: usize = 0;
    var action_required = false;
    while (completed_count < workflow.jobs.len) {
        var progressed = false;
        for (workflow.jobs, 0..) |job, idx| {
            if (states[idx] != .pending) continue;
            const needs_satisfied = jobNeedsSatisfied(workflow, states, job) catch |err| switch (err) {
                error.UnknownWorkflowJobNeed => {
                    try io.eprint("gt actions: native job {s} references an unknown dependency\n", .{job.id});
                    return "failure";
                },
                else => return err,
            };
            if (!needs_satisfied) continue;
            if (!conditionAllowsJob(job.condition)) {
                try io.out("gt actions: {s} skipped by if condition\n", .{job.id});
                states[idx] = .skipped;
                completed_count += 1;
                progressed = true;
                continue;
            }
            const conclusion = try executeGitomiJob(allocator, run_id, workflow, job, event_path, worktree_path, options, diagnostics);
            if (std.mem.eql(u8, conclusion, "failure")) return "failure";
            if (std.mem.eql(u8, conclusion, "action_required")) action_required = true;
            states[idx] = .completed;
            completed_count += 1;
            progressed = true;
        }
        if (!progressed) {
            try io.eprint("gt actions: native workflow {s} has unknown or cyclic job dependencies\n", .{workflow.path});
            return "failure";
        }
    }
    return if (action_required) "action_required" else "success";
}

fn jobNeedsSatisfied(workflow: Workflow, states: []const JobState, job: WorkflowJob) !bool {
    for (job.needs) |need| {
        const idx = findWorkflowJob(workflow, need) orelse return error.UnknownWorkflowJobNeed;
        if (states[idx] == .pending) return false;
    }
    return true;
}

fn findWorkflowJob(workflow: Workflow, id: []const u8) ?usize {
    for (workflow.jobs, 0..) |job, idx| {
        if (std.mem.eql(u8, job.id, id)) return idx;
    }
    return null;
}

fn conditionAllowsJob(condition: ?[]const u8) bool {
    const raw = condition orelse return true;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "always()")) return true;
    if (std.mem.eql(u8, value, "success()")) return true;
    if (std.mem.eql(u8, value, "cancelled()")) return false;
    return true;
}

fn executeGitomiJob(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    job: WorkflowJob,
    event_path: []const u8,
    worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const backend = if (job.backend.len == 0 and job.steps.len != 0) "shell" else job.backend;
    if (std.mem.eql(u8, backend, "shell")) {
        return try executeShellJob(allocator, job, worktree_path, diagnostics);
    }
    if (std.mem.eql(u8, backend, "container")) {
        return try executeContainerJob(allocator, job, worktree_path, diagnostics);
    }
    if (std.mem.eql(u8, backend, "agent")) {
        return try executeAgentJob(allocator, run_id, workflow, job, event_path, worktree_path, options, diagnostics);
    }
    if (std.mem.eql(u8, backend, "github-actions")) {
        try io.eprint("gt actions: native job {s} uses github-actions backend; use .github/workflows for act-backed workflows\n", .{job.id});
        return "action_required";
    }
    try io.eprint("gt actions: native job {s} uses unsupported backend '{s}'\n", .{ job.id, backend });
    return "action_required";
}

fn executeShellJob(
    allocator: Allocator,
    job: WorkflowJob,
    worktree_path: []const u8,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    if (job.steps.len == 0) {
        try io.eprint("gt actions: shell job {s} has no run steps\n", .{job.id});
        return "failure";
    }
    for (job.steps, 0..) |step, idx| {
        const command = step.run orelse continue;
        const step_label = step.name orelse command;
        try io.out("gt actions: {s}[{d}] {s}\n", .{ job.id, idx + 1, step_label });
        var result = try runCommandInDir(allocator, &.{ "sh", "-lc", command }, worktree_path, null, git.max_git_output);
        defer result.deinit();
        if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
        if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.stdout, result.stderr);
        if (result.exitCode() != 0) return "failure";
    }
    return "success";
}

fn executeContainerJob(
    allocator: Allocator,
    job: WorkflowJob,
    worktree_path: []const u8,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const image = job.image orelse job.uses orelse {
        try io.eprint("gt actions: container job {s} requires image or uses\n", .{job.id});
        return "failure";
    };
    if (job.steps.len == 0) {
        try io.eprint("gt actions: container job {s} has no run steps\n", .{job.id});
        return "failure";
    }

    const volume = try std.fmt.allocPrint(allocator, "{s}:/workspace", .{worktree_path});
    defer allocator.free(volume);

    for (job.steps, 0..) |step, idx| {
        const command = step.run orelse continue;
        const step_label = step.name orelse command;
        try io.out("gt actions: {s}[{d}] {s}\n", .{ job.id, idx + 1, step_label });
        var result = try runCommandInDir(allocator, &.{ "docker", "run", "--rm", "-v", volume, "-w", "/workspace", image, "sh", "-lc", command }, worktree_path, null, git.max_git_output);
        defer result.deinit();
        if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
        if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.stdout, result.stderr);
        if (result.exitCode() != 0) return "failure";
    }
    return "success";
}

fn executeAgentJob(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    job: WorkflowJob,
    event_path: []const u8,
    worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const runner = options.agent_runner_path orelse {
        try io.eprint("gt actions: agent job {s} requires --agent-runner PATH\n", .{job.id});
        return "action_required";
    };
    const pipeline = job.uses orelse {
        try io.eprint("gt actions: agent job {s} requires uses: .gitomi/pipelines/<name>\n", .{job.id});
        return "failure";
    };
    var manifest = validateAgentPipelinePackage(allocator, worktree_path, pipeline) catch |err| switch (err) {
        error.InvalidPipelinePath => {
            try io.eprint("gt actions: agent job {s} uses invalid pipeline path '{s}'\n", .{ job.id, pipeline });
            return "failure";
        },
        error.PipelineManifestMissing => {
            try io.eprint("gt actions: agent job {s} pipeline {s} is missing pipeline.yml or pipeline.yaml\n", .{ job.id, pipeline });
            return "failure";
        },
        else => return err,
    };
    defer manifest.deinit();
    const manifest_json = try buildPipelineManifestDiagnosticJson(allocator, manifest);
    defer allocator.free(manifest_json);
    const safe_job = try sanitizePathSegment(allocator, job.id);
    defer allocator.free(safe_job);
    const manifest_diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/pipelines/{s}-manifest.json", .{ diagnostics.attempt_id, safe_job });
    defer allocator.free(manifest_diag_path);
    try diagnostics.addCopy(manifest_diag_path, manifest_json);

    var result = try runCommandInDir(allocator, &.{
        runner,
        "run",
        "--run-id",
        run_id,
        "--job",
        job.id,
        "--workflow",
        workflow.path,
        "--pipeline",
        pipeline,
        "--event",
        event_path,
        "--worktree",
        worktree_path,
    }, worktree_path, null, git.max_git_output);
    defer result.deinit();
    if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
    if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
    try addStepLogs(allocator, diagnostics, job.id, 1, result.stdout, result.stderr);
    return if (result.exitCode() == 0) "success" else "failure";
}

fn validateAgentPipelinePackage(allocator: Allocator, worktree_path: []const u8, pipeline: []const u8) !PipelineManifest {
    if (!std.mem.startsWith(u8, pipeline, ".gitomi/pipelines/")) return error.InvalidPipelinePath;
    if (std.fs.path.isAbsolute(pipeline)) return error.InvalidPipelinePath;
    var components = std.mem.tokenizeScalar(u8, pipeline, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) return error.InvalidPipelinePath;
    }

    const manifest_yml = try std.fs.path.join(allocator, &.{ worktree_path, pipeline, "pipeline.yml" });
    defer allocator.free(manifest_yml);
    const manifest_yaml = try std.fs.path.join(allocator, &.{ worktree_path, pipeline, "pipeline.yaml" });
    defer allocator.free(manifest_yaml);

    var manifest_path: ?[]u8 = null;
    const bytes = std.fs.cwd().readFileAlloc(allocator, manifest_yml, 256 * 1024) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const alt = std.fs.cwd().readFileAlloc(allocator, manifest_yaml, 256 * 1024) catch |alt_err| switch (alt_err) {
                error.FileNotFound => return error.PipelineManifestMissing,
                else => return alt_err,
            };
            manifest_path = try allocator.dupe(u8, manifest_yaml);
            break :blk alt;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    if (manifest_path == null) manifest_path = try allocator.dupe(u8, manifest_yml);
    errdefer if (manifest_path) |value| allocator.free(value);

    var name: ?[]u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var tools: [][]u8 = &.{};
    errdefer git.freeStringList(allocator, tools);
    var permissions: []KeyValuePair = &.{};
    errdefer freeKeyValuePairs(allocator, permissions);

    var in_tools = false;
    var in_permissions = false;
    var child_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const clean = std.mem.trim(u8, stripYamlComment(line_raw), " \t\r\n");
        if (clean.len == 0) continue;
        const indent = lineIndent(line_raw);
        if (indent == 0) {
            in_tools = false;
            in_permissions = false;
            child_indent = null;
            if (parseYamlKeyValue(clean)) |kv| {
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (name) |old| allocator.free(old);
                    name = try allocator.dupe(u8, unquoteScalar(kv.value));
                } else if (std.mem.eql(u8, kv.key, "tools")) {
                    if (kv.value.len == 0) {
                        in_tools = true;
                    } else {
                        try parseStringListIntoSlice(allocator, &tools, kv.value);
                    }
                } else if (std.mem.eql(u8, kv.key, "permissions")) {
                    if (kv.value.len == 0) {
                        in_permissions = true;
                    } else if (kv.value[0] == '{') {
                        try parseInlineMappingIntoSlice(allocator, &permissions, kv.value);
                    } else {
                        try appendKeyValueToSlice(allocator, &permissions, "*", unquoteScalar(kv.value));
                    }
                }
            }
            continue;
        }
        if (child_indent == null) child_indent = indent;
        if (indent != child_indent.?) continue;
        if (in_tools and std.mem.startsWith(u8, clean, "-")) {
            const value = unquoteScalar(std.mem.trim(u8, clean[1..], " \t\r\n"));
            if (value.len != 0) try appendStringToSlice(allocator, &tools, value);
        } else if (in_permissions) {
            if (parseYamlKeyValue(clean)) |kv| try appendKeyValueToSlice(allocator, &permissions, kv.key, unquoteScalar(kv.value));
        }
    }

    const manifest_name = name orelse try allocator.dupe(u8, std.fs.path.basename(pipeline));
    name = null;
    return .{
        .allocator = allocator,
        .path = manifest_path.?,
        .name = manifest_name,
        .tools = tools,
        .permissions = permissions,
    };
}

fn buildPipelineManifestDiagnosticJson(allocator: Allocator, manifest: PipelineManifest) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:pipeline-manifest:v1", true);
    try appendJsonFieldString(&buf, allocator, "path", manifest.path, true);
    try appendJsonFieldString(&buf, allocator, "name", manifest.name, true);
    try appendJsonFieldStringArray(&buf, allocator, "tools", manifest.tools, true);
    try appendJsonString(&buf, allocator, "permissions");
    try buf.append(allocator, ':');
    try appendPermissionObject(&buf, allocator, manifest.permissions, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn addStepLogs(
    allocator: Allocator,
    diagnostics: *RunDiagnostics,
    job_id: []const u8,
    step_number: usize,
    stdout: []const u8,
    stderr: []const u8,
) !void {
    const safe_job = try sanitizePathSegment(allocator, job_id);
    defer allocator.free(safe_job);
    const stdout_path = try std.fmt.allocPrint(allocator, "attempts/{s}/logs/{s}-{d}-stdout.log", .{ diagnostics.attempt_id, safe_job, step_number });
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "attempts/{s}/logs/{s}-{d}-stderr.log", .{ diagnostics.attempt_id, safe_job, step_number });
    defer allocator.free(stderr_path);
    try diagnostics.addCopy(stdout_path, stdout);
    try diagnostics.addCopy(stderr_path, stderr);
}

fn writeRunDiagnostics(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    conclusion: []const u8,
    diagnostics: RunDiagnostics,
) !DiagnosticRef {
    const runner_id = try localRunnerId(allocator, repo);
    errdefer allocator.free(runner_id);

    const run_ref = try std.fmt.allocPrint(allocator, "refs/gitomi/runs/{s}/{s}", .{ runner_id, run_id });
    errdefer allocator.free(run_ref);

    const index_path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-run-index-{s}-{s}", .{ run_id, diagnostics.attempt_id });
    defer {
        std.fs.deleteFileAbsolute(index_path) catch {};
        allocator.free(index_path);
    }

    const run_json = try buildRunDiagnosticJson(allocator, run_id, workflow, target, conclusion, runner_id, diagnostics.attempt_id);
    defer allocator.free(run_json);
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, "run.json", run_json);

    const manifest_path = try std.fmt.allocPrint(allocator, "attempts/{s}/manifest.json", .{diagnostics.attempt_id});
    defer allocator.free(manifest_path);
    const manifest_json = try buildAttemptManifestJson(allocator, run_id, workflow, target, conclusion, runner_id, diagnostics.attempt_id);
    defer allocator.free(manifest_json);
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, manifest_path, manifest_json);

    const output_path = try std.fmt.allocPrint(allocator, "attempts/{s}/outputs/final.json", .{diagnostics.attempt_id});
    defer allocator.free(output_path);
    const output_json = try buildFinalOutputJson(allocator, run_id, diagnostics.attempt_id, conclusion);
    defer allocator.free(output_json);
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, output_path, output_json);

    for (diagnostics.files.items) |file| {
        try writeDiagnosticBlobToIndex(allocator, repo, index_path, file.path, file.bytes);
    }

    const index_env = try std.fmt.allocPrint(allocator, "GIT_INDEX_FILE={s}", .{index_path});
    defer allocator.free(index_env);
    const tree_raw = try runCheckedInDirSimple(allocator, &.{ "env", index_env, "git", "write-tree" }, repo.root, null, git.max_git_output);
    const tree_oid = try util.trimOwned(allocator, tree_raw);
    defer allocator.free(tree_oid);

    const message = try std.fmt.allocPrint(allocator, "gitomi workflow run {s}", .{run_id});
    defer allocator.free(message);
    const commit_raw = try runCheckedInDirSimple(allocator, &.{ "git", "commit-tree", tree_oid, "-m", message }, repo.root, null, git.max_git_output);
    const commit_oid = try util.trimOwned(allocator, commit_raw);
    errdefer allocator.free(commit_oid);

    const updated = try git.gitChecked(allocator, &.{ "update-ref", run_ref, commit_oid });
    allocator.free(updated);

    return .{
        .allocator = allocator,
        .ref = run_ref,
        .oid = commit_oid,
        .runner_id = runner_id,
    };
}

fn writeDiagnosticBlobToIndex(
    allocator: Allocator,
    repo: repo_mod.Repo,
    index_path: []const u8,
    path: []const u8,
    bytes: []const u8,
) !void {
    const blob_raw = try runCheckedInDirSimple(allocator, &.{ "git", "hash-object", "-w", "--stdin" }, repo.root, bytes, git.max_git_output);
    const blob_oid = try util.trimOwned(allocator, blob_raw);
    defer allocator.free(blob_oid);

    const index_env = try std.fmt.allocPrint(allocator, "GIT_INDEX_FILE={s}", .{index_path});
    defer allocator.free(index_env);
    const cacheinfo = try std.fmt.allocPrint(allocator, "100644,{s},{s}", .{ blob_oid, path });
    defer allocator.free(cacheinfo);
    const updated = try runCheckedInDirSimple(allocator, &.{ "env", index_env, "git", "update-index", "--add", "--cacheinfo", cacheinfo }, repo.root, null, git.max_git_output);
    allocator.free(updated);
}

fn buildRunDiagnosticJson(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    conclusion: []const u8,
    runner_id: []const u8,
    attempt_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-run:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "runner_id", runner_id, true);
    try appendJsonFieldString(&buf, allocator, "workflow", workflow.path, true);
    try appendJsonFieldString(&buf, allocator, "workflow_name", workflow.name, true);
    try appendJsonFieldString(&buf, allocator, "dialect", workflow.dialect.label(), true);
    try appendJsonFieldString(&buf, allocator, "target_ref", target.target_ref orelse "", true);
    try appendJsonFieldString(&buf, allocator, "target_oid", target.target_oid, true);
    try appendJsonString(&buf, allocator, "source");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(&buf, allocator, "workflow_from", workflow.source.workflow_from, true);
    try appendJsonFieldString(&buf, allocator, "code_from", workflow.source.code_from, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonString(&buf, allocator, "jobs");
    try buf.appendSlice(allocator, ":[");
    for (workflow.jobs, 0..) |job, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "id", job.id, true);
        try appendJsonFieldString(&buf, allocator, "backend", effectiveJobBackend(job), true);
        if (job.uses) |uses| try appendJsonFieldString(&buf, allocator, "uses", uses, true);
        if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],");
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildAttemptManifestJson(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    conclusion: []const u8,
    runner_id: []const u8,
    attempt_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-attempt:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "runner_id", runner_id, true);
    try appendJsonFieldString(&buf, allocator, "workflow", workflow.path, true);
    try appendJsonFieldString(&buf, allocator, "target_oid", target.target_oid, true);
    try appendJsonString(&buf, allocator, "jobs");
    try buf.appendSlice(allocator, ":[");
    for (workflow.jobs, 0..) |job, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "id", job.id, true);
        try appendJsonFieldString(&buf, allocator, "backend", effectiveJobBackend(job), true);
        if (job.uses) |uses| try appendJsonFieldString(&buf, allocator, "uses", uses, true);
        try appendJsonFieldStringArray(&buf, allocator, "needs", job.needs, false);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],");
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildFinalOutputJson(allocator: Allocator, run_id: []const u8, attempt_id: []const u8, conclusion: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-output:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, true);
    try buf.appendSlice(allocator, "\"outputs\":{}");
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildPermissionGrantJson(allocator: Allocator, workflow: Workflow) ![]u8 {
    const untrusted_head = std.mem.eql(u8, workflow.source.workflow_from, "head");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-permission-grant:v1", true);
    try appendJsonFieldString(&buf, allocator, "source_trust", if (untrusted_head) "untrusted_head" else "trusted", true);
    try appendJsonString(&buf, allocator, "workflow");
    try buf.append(allocator, ':');
    try appendPermissionObject(&buf, allocator, workflow.permissions, untrusted_head);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "jobs");
    try buf.appendSlice(allocator, ":[");
    for (workflow.jobs, 0..) |job, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "id", job.id, true);
        try appendJsonFieldString(&buf, allocator, "backend", effectiveJobBackend(job), true);
        try appendJsonString(&buf, allocator, "permissions");
        try buf.append(allocator, ':');
        try appendPermissionObject(&buf, allocator, job.permissions, untrusted_head);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

fn appendPermissionObject(buf: *std.ArrayList(u8), allocator: Allocator, permissions: []const KeyValuePair, reduce_write: bool) !void {
    try buf.append(allocator, '{');
    for (permissions, 0..) |entry, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, entry.key);
        try buf.append(allocator, ':');
        try appendJsonString(buf, allocator, effectivePermissionValue(entry.value, reduce_write));
    }
    try buf.append(allocator, '}');
}

fn effectivePermissionValue(value: []const u8, reduce_write: bool) []const u8 {
    if (!reduce_write) return value;
    if (std.mem.eql(u8, value, "write-all")) return "read-all";
    if (std.mem.indexOf(u8, value, "write") != null) return "read";
    return value;
}

fn effectiveJobBackend(job: WorkflowJob) []const u8 {
    if (job.backend.len == 0 and job.steps.len != 0) return "shell";
    return job.backend;
}

fn workflowBackendSummary(workflow: Workflow) ?[]const u8 {
    if (workflow.dialect == .github_actions) return "github-actions";
    if (workflow.jobs.len == 0) return null;
    const first = effectiveJobBackend(workflow.jobs[0]);
    for (workflow.jobs[1..]) |job| {
        if (!std.mem.eql(u8, first, effectiveJobBackend(job))) return "mixed";
    }
    return first;
}

fn workflowPipelineSummary(workflow: Workflow) ?[]const u8 {
    for (workflow.jobs) |job| {
        if (std.mem.eql(u8, effectiveJobBackend(job), "agent")) {
            if (job.uses) |uses| return uses;
        }
    }
    return null;
}

fn localRunnerId(allocator: Allocator, repo: repo_mod.Repo) ![]u8 {
    const runner_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "runner" });
    defer allocator.free(runner_dir);
    try std.fs.cwd().makePath(runner_dir);

    const id_path = try std.fs.path.join(allocator, &.{ runner_dir, "id" });
    defer allocator.free(id_path);
    if (std.fs.cwd().readFileAlloc(allocator, id_path, 4 * 1024)) |bytes| {
        defer allocator.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len != 0) return try allocator.dupe(u8, trimmed);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch {
        const fallback = try allocator.dupe(u8, "local");
        try writeRunnerId(id_path, fallback);
        return fallback;
    };
    defer cfg.deinit();
    const raw = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ cfg.principal, cfg.device });
    defer allocator.free(raw);
    const runner_id = try sanitizePathSegment(allocator, raw);
    try writeRunnerId(id_path, runner_id);
    return runner_id;
}

fn writeRunnerId(id_path: []const u8, runner_id: []const u8) !void {
    const file = try std.fs.createFileAbsolute(id_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(runner_id);
    try file.writeAll("\n");
}

fn acquireRunClaim(allocator: Allocator, repo: repo_mod.Repo, run_id: []const u8) !RunClaim {
    const runner_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "runner", "claims" });
    defer allocator.free(runner_dir);
    try std.fs.cwd().makePath(runner_dir);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.claim", .{run_id});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ runner_dir, file_name });
    errdefer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try io.eprint("gt actions: run {s} is already claimed locally\n", .{run_id});
            return CliError.UserError;
        },
        else => return err,
    };
    try file.writeAll(run_id);
    try file.writeAll("\n");
    return .{ .allocator = allocator, .path = path, .file = file };
}

fn runCheckedInDirSimple(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
) ![]u8 {
    var result = try runCommandInDir(allocator, argv, cwd, input, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    defer result.deinit();
    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try io.eprint("{s} failed: {s}\n", .{ argv[0], stderr });
    } else {
        try io.eprint("{s} failed\n", .{argv[0]});
    }
    return CliError.UserError;
}

fn sanitizePathSegment(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "job");
    return try out.toOwnedSlice(allocator);
}

fn writeActEventPayload(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    target: ResolvedTarget,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    object_id: ?[]const u8,
    schedule_slot: ?[]const u8,
    permission_grant_json: []const u8,
) ![]u8 {
    const events_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "action-events" });
    defer allocator.free(events_dir);
    try std.fs.cwd().makePath(events_dir);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{run_id});
    defer allocator.free(file_name);
    const event_path = try std.fs.path.join(allocator, &.{ events_dir, file_name });
    errdefer allocator.free(event_path);

    const repo_name = std.fs.path.basename(repo.root);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.append(allocator, '{');
    try appendJsonFieldString(&payload, allocator, "action", githubActionValue(gitomi_event_type), true);
    try appendJsonFieldString(&payload, allocator, "event_name", event_name, true);
    try appendJsonFieldString(&payload, allocator, "ref", target.target_ref orelse "", true);
    try appendJsonFieldString(&payload, allocator, "after", target.target_oid, true);
    try payload.appendSlice(allocator, "\"repository\":{");
    try appendJsonFieldString(&payload, allocator, "name", repo_name, true);
    try appendJsonFieldString(&payload, allocator, "full_name", repo_name, false);
    try payload.appendSlice(allocator, "},");
    try payload.appendSlice(allocator, "\"workflow\":{");
    try appendJsonFieldString(&payload, allocator, "path", workflow.path, true);
    try appendJsonFieldString(&payload, allocator, "name", workflow.name, false);
    try payload.appendSlice(allocator, "},");
    if (object_id) |value| {
        if (std.mem.eql(u8, event_name, "issues")) {
            try appendMinimalIssuePayload(&payload, allocator, value);
        } else if (std.mem.eql(u8, event_name, "pull_request")) {
            try appendMinimalPullRequestPayload(&payload, allocator, value, target);
        }
    }
    try payload.appendSlice(allocator, "\"gitomi\":{");
    try appendJsonFieldString(&payload, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&payload, allocator, "event_type", gitomi_event_type, true);
    if (object_id) |value| try appendJsonFieldString(&payload, allocator, "object_id", value, true);
    if (schedule_slot) |value| try appendJsonFieldString(&payload, allocator, "schedule_slot", value, true);
    try appendJsonString(&payload, allocator, "permission_grant");
    try payload.append(allocator, ':');
    try payload.appendSlice(allocator, permission_grant_json);
    try payload.append(allocator, ',');
    if (payload.items[payload.items.len - 1] == ',') payload.items.len -= 1;
    try payload.appendSlice(allocator, "}}");

    const file = try std.fs.createFileAbsolute(event_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload.items);
    return event_path;
}

fn appendMinimalIssuePayload(buf: *std.ArrayList(u8), allocator: Allocator, object_id: []const u8) !void {
    try buf.appendSlice(allocator, "\"issue\":{");
    try appendJsonFieldString(buf, allocator, "id", object_id, true);
    try appendJsonFieldString(buf, allocator, "node_id", object_id, true);
    try appendJsonFieldUnsigned(buf, allocator, "number", 0, false);
    try buf.appendSlice(allocator, "},");
}

fn appendMinimalPullRequestPayload(buf: *std.ArrayList(u8), allocator: Allocator, object_id: []const u8, target: ResolvedTarget) !void {
    try buf.appendSlice(allocator, "\"pull_request\":{");
    try appendJsonFieldString(buf, allocator, "id", object_id, true);
    try appendJsonFieldString(buf, allocator, "node_id", object_id, true);
    try appendJsonFieldUnsigned(buf, allocator, "number", 0, true);
    try buf.appendSlice(allocator, "\"base\":{");
    try appendJsonFieldString(buf, allocator, "ref", target.target_ref orelse "", false);
    try buf.appendSlice(allocator, "},");
    try buf.appendSlice(allocator, "\"head\":{");
    try appendJsonFieldString(buf, allocator, "sha", target.target_oid, false);
    try buf.appendSlice(allocator, "}},");
}

fn runCommandInDir(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
) !git.RunOutput {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = if (input == null) .Ignore else .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (input) |bytes| {
        try child.stdin.?.writeAll(bytes);
        child.stdin.?.close();
        child.stdin = null;
    }

    try child.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    const term = try child.wait();

    return .{
        .allocator = allocator,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = term,
    };
}

fn loadPendingRequests(allocator: Allocator, repo: repo_mod.Repo) ![]RunRequest {
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

    var completed = std.BufSet.init(allocator);
    defer completed.deinit();
    var completed_stmt = try db.prepare("SELECT object_id FROM events WHERE event_type = 'action.run_completed' AND domain_status = 'accepted'");
    defer completed_stmt.deinit();
    while (try completed_stmt.step()) {
        const run_id = try completed_stmt.columnTextDup(allocator, 0);
        defer allocator.free(run_id);
        try completed.insert(run_id);
    }

    var stmt = try db.prepare("SELECT object_id, body FROM events WHERE event_type = 'action.run_requested' AND domain_status = 'accepted' ORDER BY ordinal");
    defer stmt.deinit();

    var requests: std.ArrayList(RunRequest) = .empty;
    errdefer {
        for (requests.items) |*request| request.deinit();
        requests.deinit(allocator);
    }

    while (try stmt.step()) {
        const run_id = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(run_id);
        if (completed.contains(run_id)) continue;

        const body = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(body);
        var request = try parseRunRequest(allocator, run_id, body);
        errdefer request.deinit();
        try requests.append(allocator, request);
    }

    return requests.toOwnedSlice(allocator);
}

fn parseRunRequest(allocator: Allocator, run_id: []const u8, body: []const u8) !RunRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidEventEnvelope,
    };
    const payload = switch (root.get("payload") orelse return error.InvalidEventEnvelope) {
        .object => |object| object,
        else => return error.InvalidEventEnvelope,
    };

    const workflow = event_mod.jsonString(payload.get("workflow")) orelse return error.InvalidEventEnvelope;
    const event_name = event_mod.jsonString(payload.get("event_name")) orelse "workflow_dispatch";
    const gitomi_event_type = event_mod.jsonString(payload.get("gitomi_event_type")) orelse "";
    const schedule_slot = event_mod.jsonString(payload.get("schedule_slot"));

    return .{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, run_id),
        .workflow = try allocator.dupe(u8, workflow),
        .target_ref = if (event_mod.jsonString(payload.get("target_ref"))) |value| try allocator.dupe(u8, value) else null,
        .target_oid = if (event_mod.jsonString(payload.get("target_oid"))) |value| try allocator.dupe(u8, value) else null,
        .event_name = try allocator.dupe(u8, event_name),
        .gitomi_event_type = try allocator.dupe(u8, gitomi_event_type),
        .schedule_slot = if (schedule_slot) |value| try allocator.dupe(u8, value) else null,
    };
}

fn selectRequests(allocator: Allocator, requests: []RunRequest, run_filter: ?[]const u8) ![]usize {
    var selected: std.ArrayList(usize) = .empty;
    errdefer selected.deinit(allocator);

    if (run_filter) |filter| {
        for (requests, 0..) |request, idx| {
            if (std.mem.startsWith(u8, request.run_id, filter)) try selected.append(allocator, idx);
        }
        if (selected.items.len == 0) {
            try io.eprint("gt actions run-requested: no pending run matches {s}\n", .{filter});
            return CliError.UserError;
        }
        if (selected.items.len > 1) {
            try io.eprint("gt actions run-requested: run prefix {s} is ambiguous\n", .{filter});
            return CliError.UserError;
        }
    } else {
        for (requests, 0..) |_, idx| try selected.append(allocator, idx);
    }

    return selected.toOwnedSlice(allocator);
}

fn isWorkflowPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, ".github/workflows/") and !std.mem.startsWith(u8, path, ".gitomi/workflows/")) return false;
    return std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml");
}

fn workflowDialect(path: []const u8) WorkflowDialect {
    if (std.mem.startsWith(u8, path, ".gitomi/workflows/")) return .gitomi;
    return .github_actions;
}

fn parseWorkflow(allocator: Allocator, path: []const u8, bytes: []const u8) !Workflow {
    const dialect = workflowDialect(path);
    var name: ?[]u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var source = try WorkflowSourcePolicy.initDefaults(allocator);
    errdefer source.deinit(allocator);
    var permissions: std.ArrayList(KeyValuePair) = .empty;
    errdefer {
        for (permissions.items) |*entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        permissions.deinit(allocator);
    }
    var triggers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (triggers.items) |trigger| allocator.free(trigger);
        triggers.deinit(allocator);
    }
    var trigger_defs = try parseWorkflowTriggersDetailed(allocator, bytes);
    errdefer {
        for (trigger_defs) |*trigger| trigger.deinit();
        allocator.free(trigger_defs);
    }
    var schedules: std.ArrayList([]u8) = .empty;
    errdefer {
        for (schedules.items) |schedule| allocator.free(schedule);
        schedules.deinit(allocator);
    }
    var jobs: std.ArrayList(WorkflowJob) = .empty;
    errdefer {
        for (jobs.items) |*job| job.deinit();
        jobs.deinit(allocator);
    }

    var in_on_block = false;
    var in_permissions_block = false;
    var in_source_block = false;
    var in_jobs_block = false;
    var in_schedule_block = false;
    var on_child_indent: ?usize = null;
    var permissions_indent: ?usize = null;
    var source_indent: ?usize = null;
    var schedule_indent: ?usize = null;
    var jobs_child_indent: ?usize = null;
    var current_job: ?usize = null;
    var job_field_indent: ?usize = null;
    var job_nested_block: ?JobNestedBlock = null;
    var in_steps_block = false;
    var steps_indent: ?usize = null;
    var current_step: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const clean = std.mem.trim(u8, stripYamlComment(line_raw), " \t\r\n");
        if (clean.len == 0) continue;
        const indent = lineIndent(line_raw);

        if (indent == 0) {
            in_on_block = false;
            in_permissions_block = false;
            in_source_block = false;
            in_jobs_block = false;
            in_schedule_block = false;
            on_child_indent = null;
            permissions_indent = null;
            source_indent = null;
            schedule_indent = null;
            jobs_child_indent = null;
            current_job = null;
            job_field_indent = null;
            job_nested_block = null;
            in_steps_block = false;
            steps_indent = null;
            current_step = null;
            if (parseYamlKeyValue(clean)) |kv| {
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (name) |old| allocator.free(old);
                    name = try allocator.dupe(u8, unquoteScalar(kv.value));
                } else if (std.mem.eql(u8, kv.key, "on")) {
                    if (kv.value.len == 0) {
                        in_on_block = true;
                    } else {
                        try addInlineTriggers(allocator, &triggers, kv.value);
                    }
                } else if (std.mem.eql(u8, kv.key, "permissions")) {
                    if (kv.value.len == 0) {
                        in_permissions_block = true;
                    } else {
                        try appendKeyValue(allocator, &permissions, "*", unquoteScalar(kv.value));
                    }
                } else if (std.mem.eql(u8, kv.key, "source")) {
                    if (kv.value.len == 0) in_source_block = true;
                } else if (std.mem.eql(u8, kv.key, "jobs") and dialect == .gitomi) {
                    in_jobs_block = true;
                }
            }
            continue;
        }

        if (in_permissions_block) {
            if (permissions_indent == null) permissions_indent = indent;
            if (indent == permissions_indent.?) {
                if (parseYamlKeyValue(clean)) |kv| try appendKeyValue(allocator, &permissions, kv.key, unquoteScalar(kv.value));
                continue;
            }
        }

        if (in_source_block) {
            if (source_indent == null) source_indent = indent;
            if (indent == source_indent.?) {
                if (parseYamlKeyValue(clean)) |kv| {
                    const value = unquoteScalar(kv.value);
                    if (std.mem.eql(u8, kv.key, "workflow_from")) {
                        try source.setWorkflowFrom(allocator, value);
                    } else if (std.mem.eql(u8, kv.key, "code_from")) {
                        try source.setCodeFrom(allocator, value);
                    }
                }
                continue;
            }
        }

        if (in_on_block) {
            if (on_child_indent == null) on_child_indent = indent;
            if (in_schedule_block and schedule_indent != null and indent > schedule_indent.?) {
                try addScheduleLine(allocator, &schedules, clean);
                continue;
            }
            if (indent == on_child_indent.?) {
                in_schedule_block = false;
                schedule_indent = null;
                if (triggerNameFromBlockLine(clean)) |trigger_name| {
                    if (std.mem.eql(u8, trigger_name, "schedule")) {
                        in_schedule_block = true;
                        schedule_indent = indent;
                    }
                }
                try addTriggerBlockLine(allocator, &triggers, clean);
                continue;
            }
        }

        if (in_jobs_block and dialect == .gitomi) {
            if (jobs_child_indent == null) jobs_child_indent = indent;
            if (indent == jobs_child_indent.?) {
                current_job = try appendWorkflowJob(allocator, &jobs, clean);
                job_field_indent = null;
                in_steps_block = false;
                steps_indent = null;
                current_step = null;
                continue;
            }
            if (current_job == null) continue;
            if (job_field_indent == null) job_field_indent = indent;
            if (indent == job_field_indent.?) {
                in_steps_block = false;
                steps_indent = null;
                current_step = null;
                job_nested_block = null;
                try parseJobField(allocator, &jobs.items[current_job.?], clean);
                if (parseYamlKeyValue(clean)) |kv| {
                    if (std.mem.eql(u8, kv.key, "steps")) {
                        in_steps_block = true;
                    } else if (kv.value.len == 0) {
                        job_nested_block = jobNestedBlockForKey(kv.key);
                    }
                }
                continue;
            }
            if (job_nested_block) |block| {
                try parseJobNestedLine(allocator, &jobs.items[current_job.?], block, clean);
                continue;
            }
            if (in_steps_block) {
                if (steps_indent == null) steps_indent = indent;
                try parseStepLine(allocator, &jobs.items[current_job.?], &current_step, clean, indent, steps_indent.?);
            }
        }
    }

    const display_name = name orelse try allocator.dupe(u8, std.fs.path.basename(path));
    name = null;
    for (schedules.items) |schedule| {
        _ = schedule;
        try addTrigger(allocator, &triggers, "workflow.schedule");
    }
    try ensureTriggerDefsFromNames(allocator, &trigger_defs, triggers.items);
    return .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, path),
        .name = display_name,
        .triggers = try triggers.toOwnedSlice(allocator),
        .trigger_defs = trigger_defs,
        .dialect = dialect,
        .source = source,
        .permissions = try permissions.toOwnedSlice(allocator),
        .jobs = try jobs.toOwnedSlice(allocator),
        .schedules = try schedules.toOwnedSlice(allocator),
    };
}

fn workflowMatches(workflow: Workflow, event_type: []const u8, event_name: []const u8) bool {
    return workflowMatchesContext(workflow, .{
        .event_type = event_type,
        .event_name = event_name,
    });
}

fn workflowMatchesContext(workflow: Workflow, context: EventContext) bool {
    const family = eventFamily(context.event_type);
    if (workflow.trigger_defs.len != 0) {
        for (workflow.trigger_defs) |trigger| {
            if (!triggerNameMatches(trigger.name, context.event_type, context.event_name, family)) continue;
            if (triggerFiltersMatch(trigger, context)) return true;
        }
        return false;
    }
    for (workflow.triggers) |trigger| {
        if (triggerNameMatches(trigger, context.event_type, context.event_name, family)) return true;
    }
    return false;
}

fn triggerNameMatches(trigger: []const u8, event_type: []const u8, event_name: []const u8, family: []const u8) bool {
    if (std.mem.eql(u8, trigger, event_type)) return true;
    if (std.mem.eql(u8, trigger, event_name)) return true;
    if (std.mem.eql(u8, trigger, family)) return true;
    if (std.mem.eql(u8, trigger, "schedule") and std.mem.eql(u8, event_type, "workflow.schedule")) return true;
    if (std.mem.eql(u8, trigger, "workflow_dispatch") and std.mem.eql(u8, event_type, "workflow.manual")) return true;
    if (std.mem.eql(u8, trigger, "pull_request") and std.mem.startsWith(u8, event_type, "pull.")) return true;
    if (std.mem.eql(u8, trigger, "issues") and std.mem.startsWith(u8, event_type, "issue.")) return true;
    return false;
}

fn triggerFiltersMatch(trigger: WorkflowTrigger, context: EventContext) bool {
    if (trigger.types.len != 0) {
        const action = githubActionValue(context.event_type);
        if (!anyGlobMatches(trigger.types, action)) return false;
    }

    if (trigger.actors.len != 0) {
        const actor = context.actor orelse return false;
        if (!anyGlobMatches(trigger.actors, actor)) return false;
    }

    if (trigger.branches.len != 0) {
        const branch = context.branch orelse return false;
        if (!anyGlobMatches(trigger.branches, branch)) return false;
    }
    if (trigger.branches_ignore.len != 0) {
        const branch = context.branch orelse return false;
        if (anyGlobMatches(trigger.branches_ignore, branch)) return false;
    }

    if (trigger.paths.len != 0) {
        const paths = context.paths orelse return false;
        if (!anyPathMatches(trigger.paths, paths)) return false;
    }
    if (trigger.paths_ignore.len != 0) {
        const paths = context.paths orelse return false;
        if (paths.len != 0 and allPathsMatch(trigger.paths_ignore, paths)) return false;
    }

    if (trigger.labels.len != 0) {
        const labels = context.labels orelse return false;
        if (!anyLabelMatches(trigger.labels, labels)) return false;
    }

    return true;
}

fn anyGlobMatches(patterns: []const []u8, value: []const u8) bool {
    for (patterns) |pattern| {
        if (globMatches(pattern, value)) return true;
    }
    return false;
}

fn anyPathMatches(patterns: []const []u8, paths: []const []u8) bool {
    for (paths) |path| {
        if (anyGlobMatches(patterns, path)) return true;
    }
    return false;
}

fn allPathsMatch(patterns: []const []u8, paths: []const []u8) bool {
    for (paths) |path| {
        if (!anyGlobMatches(patterns, path)) return false;
    }
    return true;
}

fn anyLabelMatches(patterns: []const []u8, labels: []const []u8) bool {
    for (labels) |label| {
        if (anyGlobMatches(patterns, label)) return true;
    }
    return false;
}

fn globMatches(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var match_after_star: usize = 0;

    while (v < value.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[v])) {
            p += 1;
            v += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1;
            star = p;
            match_after_star = v;
            continue;
        }
        if (star) |after_star| {
            p = after_star;
            match_after_star += 1;
            v = match_after_star;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn resolveWorkflowSelector(workflows: []Workflow, selector: []const u8) !Workflow {
    var found: ?usize = null;
    for (workflows, 0..) |workflow, idx| {
        if (!workflowSelectorMatches(workflow, selector)) continue;
        if (found != null) {
            try io.eprint("gt actions: workflow selector '{s}' is ambiguous\n", .{selector});
            return CliError.UserError;
        }
        found = idx;
    }

    if (found) |idx| return workflows[idx];
    try io.eprint("gt actions: workflow '{s}' was not found\n", .{selector});
    return CliError.UserError;
}

fn workflowSelectorMatches(workflow: Workflow, selector: []const u8) bool {
    if (std.mem.eql(u8, workflow.path, selector)) return true;
    if (std.mem.eql(u8, workflow.name, selector)) return true;
    const base = std.fs.path.basename(workflow.path);
    if (std.mem.eql(u8, base, selector)) return true;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (std.mem.eql(u8, base[0..dot], selector)) return true;
    }
    return false;
}

fn githubEventName(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "push")) return "push";
    if (std.mem.startsWith(u8, event_type, "issue.")) return "issues";
    if (std.mem.startsWith(u8, event_type, "pull.")) return "pull_request";
    if (std.mem.eql(u8, event_type, "action.run_requested")) return "workflow_dispatch";
    if (std.mem.eql(u8, event_type, "workflow.manual")) return "workflow_dispatch";
    if (std.mem.eql(u8, event_type, "workflow.schedule")) return "schedule";
    return event_type;
}

fn githubActionValue(event_type: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, event_type, '.')) |dot| {
        if (dot + 1 < event_type.len) return event_type[dot + 1 ..];
    }
    return event_type;
}

fn eventFamily(event_type: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, event_type, '.')) |dot| return event_type[0..dot];
    return event_type;
}

fn workflowScheduleDue(workflow: Workflow, timestamp_seconds: i64) bool {
    for (workflow.schedules) |cron| {
        if (cronMatches(cron, timestamp_seconds)) return true;
    }
    return false;
}

const UtcMinute = struct {
    minute: u8,
    hour: u8,
    day_of_month: u8,
    month: u8,
    day_of_week: u8,
};

fn cronMatches(expr: []const u8, timestamp_seconds: i64) bool {
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |field| {
        if (count >= fields.len) return false;
        fields[count] = field;
        count += 1;
    }
    if (count != fields.len) return false;

    const minute = utcMinute(timestamp_seconds);
    return cronFieldMatches(fields[0], minute.minute, 0, 59, false) and
        cronFieldMatches(fields[1], minute.hour, 0, 23, false) and
        cronFieldMatches(fields[2], minute.day_of_month, 1, 31, false) and
        cronFieldMatches(fields[3], minute.month, 1, 12, false) and
        cronFieldMatches(fields[4], minute.day_of_week, 0, 7, true);
}

fn cronFieldMatches(field: []const u8, value_raw: u8, min: u8, max: u8, sunday_alias: bool) bool {
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (cronPartMatches(part, value_raw, min, max, sunday_alias)) return true;
    }
    return false;
}

fn cronPartMatches(part: []const u8, value_raw: u8, min: u8, max: u8, sunday_alias: bool) bool {
    var base = part;
    var step: u8 = 1;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        base = part[0..slash];
        step = std.fmt.parseUnsigned(u8, part[slash + 1 ..], 10) catch return false;
        if (step == 0) return false;
    }

    const value: u8 = if (sunday_alias and value_raw == 0) 7 else value_raw;
    var start: u8 = min;
    var end: u8 = max;
    if (!std.mem.eql(u8, base, "*")) {
        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            start = normalizeCronValue(std.fmt.parseUnsigned(u8, base[0..dash], 10) catch return false, sunday_alias);
            end = normalizeCronValue(std.fmt.parseUnsigned(u8, base[dash + 1 ..], 10) catch return false, sunday_alias);
        } else {
            start = normalizeCronValue(std.fmt.parseUnsigned(u8, base, 10) catch return false, sunday_alias);
            end = start;
        }
    }
    if (start < min or start > max or end < min or end > max or start > end) return false;
    if (value < start or value > end) return false;
    return ((value - start) % step) == 0;
}

fn normalizeCronValue(value: u8, sunday_alias: bool) u8 {
    if (sunday_alias and value == 0) return 7;
    return value;
}

fn utcMinute(timestamp_seconds: i64) UtcMinute {
    const seconds_per_day: i64 = 24 * 60 * 60;
    const seconds = @max(timestamp_seconds, 0);
    const days = @divTrunc(seconds, seconds_per_day);
    const seconds_of_day = @mod(seconds, seconds_per_day);
    const date = civilFromDays(days);
    return .{
        .minute = @intCast(@divTrunc(@mod(seconds_of_day, 3600), 60)),
        .hour = @intCast(@divTrunc(seconds_of_day, 3600)),
        .day_of_month = @intCast(date.day),
        .month = @intCast(date.month),
        .day_of_week = @intCast(@mod(days + 4, 7)),
    };
}

const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719468;
    const era = @divTrunc(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    if (month <= 2) year += 1;
    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn isConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or
        std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "skipped") or
        std.mem.eql(u8, value, "neutral") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "action_required");
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

const JobNestedBlock = enum {
    env,
    with,
    permissions,
    needs,
};

fn parseYamlKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = unquoteScalar(std.mem.trim(u8, line[0..colon], " \t\r\n"));
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

fn jobNestedBlockForKey(key: []const u8) ?JobNestedBlock {
    if (std.mem.eql(u8, key, "env")) return .env;
    if (std.mem.eql(u8, key, "with")) return .with;
    if (std.mem.eql(u8, key, "permissions")) return .permissions;
    if (std.mem.eql(u8, key, "needs")) return .needs;
    return null;
}

fn parseJobNestedLine(allocator: Allocator, job: *WorkflowJob, block: JobNestedBlock, line: []const u8) !void {
    switch (block) {
        .env => {
            if (parseYamlKeyValue(line)) |kv| try appendKeyValueToSlice(allocator, &job.env, kv.key, unquoteScalar(kv.value));
        },
        .with => {
            if (parseYamlKeyValue(line)) |kv| try appendKeyValueToSlice(allocator, &job.with, kv.key, unquoteScalar(kv.value));
        },
        .permissions => {
            if (parseYamlKeyValue(line)) |kv| try appendKeyValueToSlice(allocator, &job.permissions, kv.key, unquoteScalar(kv.value));
        },
        .needs => {
            if (std.mem.startsWith(u8, line, "-")) {
                const value = unquoteScalar(std.mem.trim(u8, line[1..], " \t\r\n"));
                if (value.len != 0) try appendStringToSlice(allocator, &job.needs, value);
            } else if (parseYamlKeyValue(line)) |kv| {
                const value = unquoteScalar(kv.value);
                if (value.len != 0) try appendStringToSlice(allocator, &job.needs, value);
            }
        },
    }
}

fn addTriggerBlockLine(allocator: Allocator, triggers: *std.ArrayList([]u8), line: []const u8) !void {
    if (std.mem.startsWith(u8, line, "-")) {
        const scalar = std.mem.trim(u8, line[1..], " \t\r\n");
        try addTrigger(allocator, triggers, scalar);
        return;
    }

    if (parseYamlKeyValue(line)) |kv| {
        try addTrigger(allocator, triggers, kv.key);
    } else {
        try addTrigger(allocator, triggers, line);
    }
}

fn triggerNameFromBlockLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "-")) {
        const scalar = std.mem.trim(u8, line[1..], " \t\r\n");
        if (scalar.len == 0) return null;
        if (parseYamlKeyValue(scalar)) |kv| return kv.key;
        return unquoteScalar(scalar);
    }
    if (parseYamlKeyValue(line)) |kv| return kv.key;
    return unquoteScalar(line);
}

fn addScheduleLine(allocator: Allocator, schedules: *std.ArrayList([]u8), line: []const u8) !void {
    var clean = line;
    if (std.mem.startsWith(u8, clean, "-")) clean = std.mem.trim(u8, clean[1..], " \t\r\n");
    if (parseYamlKeyValue(clean)) |kv| {
        if (std.mem.eql(u8, kv.key, "cron")) {
            const cron = unquoteScalar(kv.value);
            if (cron.len != 0) try schedules.append(allocator, try allocator.dupe(u8, cron));
        }
    }
}

fn appendWorkflowJob(allocator: Allocator, jobs: *std.ArrayList(WorkflowJob), line: []const u8) !?usize {
    const kv = parseYamlKeyValue(line) orelse return null;
    const id = unquoteScalar(kv.key);
    if (id.len == 0) return null;
    const idx = jobs.items.len;
    try jobs.append(allocator, .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .backend = try allocator.dupe(u8, ""),
        .steps = try allocator.alloc(WorkflowStep, 0),
    });
    return idx;
}

fn parseJobField(allocator: Allocator, job: *WorkflowJob, line: []const u8) !void {
    const kv = parseYamlKeyValue(line) orelse return;
    if (std.mem.eql(u8, kv.key, "backend") or std.mem.eql(u8, kv.key, "runs-on")) {
        allocator.free(job.backend);
        job.backend = try allocator.dupe(u8, normalizeBackend(unquoteScalar(kv.value)));
    } else if (std.mem.eql(u8, kv.key, "uses")) {
        if (job.uses) |old| allocator.free(old);
        job.uses = try allocator.dupe(u8, unquoteScalar(kv.value));
    } else if (std.mem.eql(u8, kv.key, "image")) {
        if (job.image) |old| allocator.free(old);
        job.image = try allocator.dupe(u8, unquoteScalar(kv.value));
    } else if (std.mem.eql(u8, kv.key, "if")) {
        if (job.condition) |old| allocator.free(old);
        job.condition = try allocator.dupe(u8, unquoteScalar(kv.value));
    } else if (std.mem.eql(u8, kv.key, "timeout") or std.mem.eql(u8, kv.key, "timeout_minutes") or std.mem.eql(u8, kv.key, "timeout-minutes")) {
        const value = unquoteScalar(kv.value);
        if (value.len != 0) job.timeout_minutes = std.fmt.parseUnsigned(u64, value, 10) catch null;
    } else if (std.mem.eql(u8, kv.key, "needs")) {
        if (kv.value.len != 0) try parseStringListIntoSlice(allocator, &job.needs, kv.value);
    } else if (std.mem.eql(u8, kv.key, "env")) {
        if (kv.value.len != 0) try parseInlineMappingIntoSlice(allocator, &job.env, kv.value);
    } else if (std.mem.eql(u8, kv.key, "with")) {
        if (kv.value.len != 0) try parseInlineMappingIntoSlice(allocator, &job.with, kv.value);
    } else if (std.mem.eql(u8, kv.key, "permissions")) {
        if (kv.value.len != 0) {
            if (kv.value[0] == '{') {
                try parseInlineMappingIntoSlice(allocator, &job.permissions, kv.value);
            } else {
                try appendKeyValueToSlice(allocator, &job.permissions, "*", unquoteScalar(kv.value));
            }
        }
    }
}

fn parseStepLine(
    allocator: Allocator,
    job: *WorkflowJob,
    current_step: *?usize,
    line: []const u8,
    indent: usize,
    steps_indent: usize,
) !void {
    if (indent == steps_indent and std.mem.startsWith(u8, line, "-")) {
        const idx = try appendWorkflowStep(allocator, job);
        current_step.* = idx;
        const rest = std.mem.trim(u8, line[1..], " \t\r\n");
        if (rest.len != 0) try parseStepField(allocator, &job.steps[idx], rest);
        return;
    }
    if (current_step.*) |idx| {
        try parseStepField(allocator, &job.steps[idx], line);
    }
}

fn appendWorkflowStep(allocator: Allocator, job: *WorkflowJob) !usize {
    const old = job.steps;
    const next = try allocator.alloc(WorkflowStep, old.len + 1);
    for (old, 0..) |step, idx| next[idx] = step;
    next[old.len] = .{ .allocator = allocator };
    allocator.free(old);
    job.steps = next;
    return old.len;
}

fn parseStepField(allocator: Allocator, step: *WorkflowStep, line: []const u8) !void {
    const kv = parseYamlKeyValue(line) orelse return;
    if (std.mem.eql(u8, kv.key, "name")) {
        if (step.name) |old| allocator.free(old);
        step.name = try allocator.dupe(u8, unquoteScalar(kv.value));
    } else if (std.mem.eql(u8, kv.key, "run")) {
        if (step.run) |old| allocator.free(old);
        step.run = try allocator.dupe(u8, unquoteScalar(kv.value));
    }
}

fn normalizeBackend(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "agent")) return "agent";
    if (std.mem.eql(u8, raw, "container")) return "container";
    if (std.mem.eql(u8, raw, "github-actions")) return "github-actions";
    if (std.mem.startsWith(u8, raw, "ubuntu-") or
        std.mem.startsWith(u8, raw, "macos-") or
        std.mem.startsWith(u8, raw, "windows-"))
    {
        return "github-actions";
    }
    return raw;
}

fn addInlineTriggers(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return;
    if (value[0] == '[' and value[value.len - 1] == ']') {
        try addInlineTriggerParts(allocator, triggers, value[1 .. value.len - 1], false);
        return;
    }
    if (value[0] == '{' and value[value.len - 1] == '}') {
        try addInlineTriggerParts(allocator, triggers, value[1 .. value.len - 1], true);
        return;
    }
    try addTrigger(allocator, triggers, value);
}

fn addInlineTriggerParts(allocator: Allocator, triggers: *std.ArrayList([]u8), inner: []const u8, mapping: bool) !void {
    var start: usize = 0;
    var depth: usize = 0;
    var in_single = false;
    var in_double = false;
    var idx: usize = 0;
    while (idx <= inner.len) : (idx += 1) {
        const at_end = idx == inner.len;
        if (!at_end) {
            const c = inner[idx];
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                continue;
            }
            if (!in_single and !in_double) {
                if (c == ',' and depth == 0) {
                    try addInlineTriggerPart(allocator, triggers, inner[start..idx], mapping);
                    start = idx + 1;
                    continue;
                }
                if (c == '[' or c == '{') {
                    depth += 1;
                    continue;
                }
                if ((c == ']' or c == '}') and depth != 0) {
                    depth -= 1;
                    continue;
                }
            }
            continue;
        }
        try addInlineTriggerPart(allocator, triggers, inner[start..idx], mapping);
    }
}

fn addInlineTriggerPart(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8, mapping: bool) !void {
    const clean = std.mem.trim(u8, raw, " \t\r\n");
    if (clean.len == 0) return;
    if (mapping) {
        if (parseYamlKeyValue(clean)) |kv| {
            try addTrigger(allocator, triggers, kv.key);
            return;
        }
    }
    try addTrigger(allocator, triggers, clean);
}

fn addTrigger(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8) !void {
    var value = unquoteScalar(std.mem.trim(u8, raw, " \t\r\n"));
    if (value.len == 0) return;
    if (std.mem.indexOfAny(u8, value, " \t")) |space| value = value[0..space];
    if (value.len == 0 or std.mem.eql(u8, value, "{}")) return;
    for (triggers.items) |trigger| {
        if (std.mem.eql(u8, trigger, value)) return;
    }
    try triggers.append(allocator, try allocator.dupe(u8, value));
}

fn parseWorkflowTriggersDetailed(allocator: Allocator, bytes: []const u8) ![]WorkflowTrigger {
    var triggers: []WorkflowTrigger = &.{};
    errdefer {
        for (triggers) |*trigger| trigger.deinit();
        allocator.free(triggers);
    }

    var in_on_block = false;
    var on_child_indent: ?usize = null;
    var current_trigger: ?usize = null;
    var current_filter: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const clean = std.mem.trim(u8, stripYamlComment(line_raw), " \t\r\n");
        if (clean.len == 0) continue;
        const indent = lineIndent(line_raw);

        if (indent == 0) {
            in_on_block = false;
            on_child_indent = null;
            current_trigger = null;
            current_filter = null;
            if (parseYamlKeyValue(clean)) |kv| {
                if (std.mem.eql(u8, kv.key, "on")) {
                    if (kv.value.len == 0) {
                        in_on_block = true;
                    } else {
                        try addInlineTriggerDefs(allocator, &triggers, kv.value);
                    }
                }
            }
            continue;
        }

        if (!in_on_block) continue;
        if (on_child_indent == null) on_child_indent = indent;
        if (indent == on_child_indent.?) {
            current_filter = null;
            const trigger_name = triggerNameFromBlockLine(clean) orelse continue;
            current_trigger = try ensureTriggerDef(allocator, &triggers, trigger_name);
            if (parseYamlKeyValue(clean)) |kv| {
                if (kv.value.len != 0 and kv.value[0] == '{') {
                    try parseTriggerInlineFilters(allocator, &triggers[current_trigger.?], kv.value);
                }
            }
            continue;
        }
        if (current_trigger == null) continue;

        if (parseYamlKeyValue(clean)) |kv| {
            if (isTriggerFilterKey(kv.key)) {
                current_filter = kv.key;
                if (kv.value.len != 0) try addTriggerFilterValues(allocator, &triggers[current_trigger.?], kv.key, kv.value);
            } else if (std.mem.eql(u8, kv.key, "cron")) {
                current_filter = null;
            }
            continue;
        }

        if (std.mem.startsWith(u8, clean, "-")) {
            const rest = std.mem.trim(u8, clean[1..], " \t\r\n");
            if (parseYamlKeyValue(rest)) |kv| {
                if (isTriggerFilterKey(kv.key)) {
                    current_filter = kv.key;
                    if (kv.value.len != 0) try addTriggerFilterValues(allocator, &triggers[current_trigger.?], kv.key, kv.value);
                } else if (std.mem.eql(u8, kv.key, "cron")) {
                    current_filter = null;
                }
            } else if (current_filter) |filter| {
                try addTriggerFilterValues(allocator, &triggers[current_trigger.?], filter, rest);
            }
        }
    }

    return triggers;
}

fn addInlineTriggerDefs(allocator: Allocator, triggers: *[]WorkflowTrigger, raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return;
    if (value[0] == '[' and value[value.len - 1] == ']') {
        var parts = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
        while (parts.next()) |part| {
            const trigger = unquoteScalar(std.mem.trim(u8, part, " \t\r\n"));
            if (trigger.len != 0) _ = try ensureTriggerDef(allocator, triggers, trigger);
        }
        return;
    }
    if (value[0] == '{' and value[value.len - 1] == '}') {
        try parseInlineTriggerMap(allocator, triggers, value[1 .. value.len - 1]);
        return;
    }
    _ = try ensureTriggerDef(allocator, triggers, value);
}

fn parseInlineTriggerMap(allocator: Allocator, triggers: *[]WorkflowTrigger, inner: []const u8) !void {
    const parts = try splitTopLevel(allocator, inner, ',');
    defer git.freeStringList(allocator, parts);
    for (parts) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (parseYamlKeyValue(part)) |kv| {
            const idx = try ensureTriggerDef(allocator, triggers, kv.key);
            if (kv.value.len != 0 and kv.value[0] == '{') try parseTriggerInlineFilters(allocator, &triggers.*[idx], kv.value);
        }
    }
}

fn parseTriggerInlineFilters(allocator: Allocator, trigger: *WorkflowTrigger, raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return;
    const parts = try splitTopLevel(allocator, value[1 .. value.len - 1], ',');
    defer git.freeStringList(allocator, parts);
    for (parts) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (parseYamlKeyValue(part)) |kv| {
            if (isTriggerFilterKey(kv.key)) try addTriggerFilterValues(allocator, trigger, kv.key, kv.value);
        }
    }
}

fn ensureTriggerDefsFromNames(allocator: Allocator, triggers: *[]WorkflowTrigger, names: []const []u8) !void {
    for (names) |name| _ = try ensureTriggerDef(allocator, triggers, name);
}

fn ensureTriggerDef(allocator: Allocator, triggers: *[]WorkflowTrigger, raw_name: []const u8) !usize {
    var name = unquoteScalar(std.mem.trim(u8, raw_name, " \t\r\n"));
    if (name.len == 0) return triggers.*.len;
    if (std.mem.indexOfAny(u8, name, " \t")) |space| name = name[0..space];
    for (triggers.*, 0..) |trigger, idx| {
        if (std.mem.eql(u8, trigger.name, name)) return idx;
    }
    const old = triggers.*;
    const next = try allocator.alloc(WorkflowTrigger, old.len + 1);
    for (old, 0..) |trigger, idx| next[idx] = trigger;
    next[old.len] = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
    };
    allocator.free(old);
    triggers.* = next;
    return old.len;
}

fn isTriggerFilterKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "branches") or
        std.mem.eql(u8, key, "branches_ignore") or
        std.mem.eql(u8, key, "branches-ignore") or
        std.mem.eql(u8, key, "paths") or
        std.mem.eql(u8, key, "paths_ignore") or
        std.mem.eql(u8, key, "paths-ignore") or
        std.mem.eql(u8, key, "types") or
        std.mem.eql(u8, key, "actors") or
        std.mem.eql(u8, key, "labels");
}

fn addTriggerFilterValues(allocator: Allocator, trigger: *WorkflowTrigger, key: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, key, "branches")) return parseStringListIntoSlice(allocator, &trigger.branches, raw);
    if (std.mem.eql(u8, key, "branches_ignore") or std.mem.eql(u8, key, "branches-ignore")) return parseStringListIntoSlice(allocator, &trigger.branches_ignore, raw);
    if (std.mem.eql(u8, key, "paths")) return parseStringListIntoSlice(allocator, &trigger.paths, raw);
    if (std.mem.eql(u8, key, "paths_ignore") or std.mem.eql(u8, key, "paths-ignore")) return parseStringListIntoSlice(allocator, &trigger.paths_ignore, raw);
    if (std.mem.eql(u8, key, "types")) return parseStringListIntoSlice(allocator, &trigger.types, raw);
    if (std.mem.eql(u8, key, "actors")) return parseStringListIntoSlice(allocator, &trigger.actors, raw);
    if (std.mem.eql(u8, key, "labels")) return parseStringListIntoSlice(allocator, &trigger.labels, raw);
}

fn parseStringListIntoSlice(allocator: Allocator, target: *[][]u8, raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return;
    if (value[0] == '[' and value[value.len - 1] == ']') {
        const parts = try splitTopLevel(allocator, value[1 .. value.len - 1], ',');
        defer git.freeStringList(allocator, parts);
        for (parts) |part| {
            const scalar = unquoteScalar(std.mem.trim(u8, part, " \t\r\n"));
            if (scalar.len != 0) try appendStringToSlice(allocator, target, scalar);
        }
        return;
    }
    const scalar = unquoteScalar(value);
    if (scalar.len != 0) try appendStringToSlice(allocator, target, scalar);
}

fn parseInlineMappingIntoSlice(allocator: Allocator, target: *[]KeyValuePair, raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return;
    const parts = try splitTopLevel(allocator, value[1 .. value.len - 1], ',');
    defer git.freeStringList(allocator, parts);
    for (parts) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (parseYamlKeyValue(part)) |kv| try appendKeyValueToSlice(allocator, target, kv.key, unquoteScalar(kv.value));
    }
}

fn appendStringToSlice(allocator: Allocator, target: *[][]u8, value: []const u8) !void {
    for (target.*) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const old = target.*;
    const next = try allocator.alloc([]u8, old.len + 1);
    for (old, 0..) |item, idx| next[idx] = item;
    next[old.len] = try allocator.dupe(u8, value);
    allocator.free(old);
    target.* = next;
}

fn appendKeyValue(allocator: Allocator, list: *std.ArrayList(KeyValuePair), key: []const u8, value: []const u8) !void {
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
}

fn appendKeyValueToSlice(allocator: Allocator, target: *[]KeyValuePair, key: []const u8, value: []const u8) !void {
    const old = target.*;
    const next = try allocator.alloc(KeyValuePair, old.len + 1);
    for (old, 0..) |entry, idx| next[idx] = entry;
    next[old.len] = .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    };
    allocator.free(old);
    target.* = next;
}

fn splitTopLevel(allocator: Allocator, inner: []const u8, delimiter: u8) ![][]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }
    var start: usize = 0;
    var depth: usize = 0;
    var in_single = false;
    var in_double = false;
    var idx: usize = 0;
    while (idx <= inner.len) : (idx += 1) {
        const at_end = idx == inner.len;
        if (!at_end) {
            const c = inner[idx];
            if (c == '\'' and !in_double) {
                in_single = !in_single;
                continue;
            }
            if (c == '"' and !in_single) {
                in_double = !in_double;
                continue;
            }
            if (!in_single and !in_double) {
                if (c == '[' or c == '{') {
                    depth += 1;
                    continue;
                }
                if ((c == ']' or c == '}') and depth != 0) {
                    depth -= 1;
                    continue;
                }
                if (c == delimiter and depth == 0) {
                    try parts.append(allocator, try allocator.dupe(u8, inner[start..idx]));
                    start = idx + 1;
                    continue;
                }
            }
            continue;
        }
        try parts.append(allocator, try allocator.dupe(u8, inner[start..idx]));
    }
    return parts.toOwnedSlice(allocator);
}

fn freeKeyValuePairs(allocator: Allocator, values: []KeyValuePair) void {
    for (values) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(values);
}

fn unquoteScalar(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return value[1 .. value.len - 1];
    }
    return value;
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |c, idx| {
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (c == '#' and !in_single and !in_double and (idx == 0 or std.ascii.isWhitespace(line[idx - 1]))) {
            return line[0..idx];
        }
    }
    return line;
}

fn lineIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

test "workflow parser supports common on syntaxes" {
    const bytes =
        \\name: CI
        \\on:
        \\  push:
        \\    branches: [main]
        \\  pull_request:
        \\  - issues
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".github/workflows/ci.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqualStrings("CI", workflow.name);
    try std.testing.expect(!workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatchesContext(workflow, .{
        .event_type = "push",
        .event_name = "push",
        .branch = "main",
    }));
    try std.testing.expect(workflowMatches(workflow, "pull.opened", "pull_request"));
    try std.testing.expect(workflowMatches(workflow, "issue.opened", "issues"));
}

test "workflow parser supports inline trigger arrays" {
    const bytes =
        \\name: Inline
        \\on: [push, workflow_dispatch]
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".github/workflows/inline.yaml", bytes);
    defer workflow.deinit();
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatches(workflow, "action.run_requested", "workflow_dispatch"));
}

test "workflow parser supports inline trigger maps with filters" {
    const bytes =
        \\name: Filtered
        \\on: { push: { branches: [main, release] }, pull_request: { types: [opened, synchronize] } }
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".github/workflows/filtered.yml", bytes);
    defer workflow.deinit();
    try std.testing.expect(!workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatchesContext(workflow, .{
        .event_type = "push",
        .event_name = "push",
        .branch = "release",
    }));
    try std.testing.expect(!workflowMatchesContext(workflow, .{
        .event_type = "push",
        .event_name = "push",
        .branch = "feature",
    }));
    try std.testing.expect(workflowMatches(workflow, "pull.opened", "pull_request"));
    try std.testing.expect(!workflowMatches(workflow, "pull.merged", "pull_request"));
}

test "workflow filters match paths actors labels and ignores" {
    const bytes =
        \\name: Filtered
        \\on:
        \\  push:
        \\    branches: [main]
        \\    paths: ["src/*"]
        \\    paths-ignore: ["docs/*"]
        \\  issue:
        \\    actors: [alice]
        \\    labels: [ci]
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".gitomi/workflows/filtered.yml", bytes);
    defer workflow.deinit();
    const src_paths = [_][]u8{try std.testing.allocator.dupe(u8, "src/main.zig")};
    defer std.testing.allocator.free(src_paths[0]);
    try std.testing.expect(workflowMatchesContext(workflow, .{
        .event_type = "push",
        .event_name = "push",
        .branch = "main",
        .paths = &src_paths,
    }));
    const docs_paths = [_][]u8{try std.testing.allocator.dupe(u8, "docs/spec.md")};
    defer std.testing.allocator.free(docs_paths[0]);
    try std.testing.expect(!workflowMatchesContext(workflow, .{
        .event_type = "push",
        .event_name = "push",
        .branch = "main",
        .paths = &docs_paths,
    }));
    const labels = [_][]u8{try std.testing.allocator.dupe(u8, "ci")};
    defer std.testing.allocator.free(labels[0]);
    try std.testing.expect(workflowMatchesContext(workflow, .{
        .event_type = "issue.opened",
        .event_name = "issues",
        .actor = "alice",
        .labels = &labels,
    }));
    try std.testing.expect(!workflowMatchesContext(workflow, .{
        .event_type = "issue.opened",
        .event_name = "issues",
        .actor = "bob",
        .labels = &labels,
    }));
}

test "native workflow parser supports shell jobs and schedules" {
    const bytes =
        \\name: Native CI
        \\on:
        \\  push:
        \\  schedule:
        \\    - cron: "*/5 * * * *"
        \\jobs:
        \\  test:
        \\    backend: shell
        \\    steps:
        \\      - name: unit tests
        \\        run: zig build test
        \\      - run: echo done
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".gitomi/workflows/ci.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqual(WorkflowDialect.gitomi, workflow.dialect);
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatches(workflow, "workflow.schedule", "schedule"));
    try std.testing.expectEqual(@as(usize, 1), workflow.schedules.len);
    try std.testing.expectEqualStrings("*/5 * * * *", workflow.schedules[0]);
    try std.testing.expectEqual(@as(usize, 1), workflow.jobs.len);
    try std.testing.expectEqualStrings("test", workflow.jobs[0].id);
    try std.testing.expectEqualStrings("shell", workflow.jobs[0].backend);
    try std.testing.expectEqual(@as(usize, 2), workflow.jobs[0].steps.len);
    try std.testing.expectEqualStrings("unit tests", workflow.jobs[0].steps[0].name.?);
    try std.testing.expectEqualStrings("zig build test", workflow.jobs[0].steps[0].run.?);
    try std.testing.expectEqualStrings("echo done", workflow.jobs[0].steps[1].run.?);
}

test "workflow parser initializes optional policy fields" {
    const bytes =
        \\name: Defaults
        \\on: workflow_dispatch
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".gitomi/workflows/defaults.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqual(@as(usize, 1), workflow.trigger_defs.len);
    try std.testing.expectEqualStrings("workflow_dispatch", workflow.trigger_defs[0].name);
    try std.testing.expectEqualStrings("target", workflow.source.workflow_from);
    try std.testing.expectEqualStrings("target", workflow.source.code_from);
    try std.testing.expectEqual(@as(usize, 0), workflow.permissions.len);
}

test "native workflow parser supports source permissions and job metadata" {
    const bytes =
        \\name: Agent Review
        \\on: workflow_dispatch
        \\permissions:
        \\  contents: read
        \\source:
        \\  workflow_from: base
        \\  code_from: head
        \\jobs:
        \\  prep:
        \\    backend: shell
        \\    if: "true"
        \\    timeout_minutes: 10
        \\    steps:
        \\      - run: echo prep
        \\  review:
        \\    backend: agent
        \\    uses: .gitomi/pipelines/code-review
        \\    needs: [prep]
        \\    with:
        \\      mode: quick
        \\    env:
        \\      CI: "1"
        \\    permissions:
        \\      issues: write
    ;
    var workflow = try parseWorkflow(std.testing.allocator, ".gitomi/workflows/review.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqualStrings("base", workflow.source.workflow_from);
    try std.testing.expectEqualStrings("head", workflow.source.code_from);
    try std.testing.expectEqual(@as(usize, 1), workflow.permissions.len);
    try std.testing.expectEqualStrings("contents", workflow.permissions[0].key);
    try std.testing.expectEqualStrings("read", workflow.permissions[0].value);
    try std.testing.expectEqual(@as(usize, 2), workflow.jobs.len);
    try std.testing.expectEqualStrings("true", workflow.jobs[0].condition.?);
    try std.testing.expectEqual(@as(?u64, 10), workflow.jobs[0].timeout_minutes);
    try std.testing.expectEqualStrings(".gitomi/pipelines/code-review", workflow.jobs[1].uses.?);
    try std.testing.expectEqualStrings("prep", workflow.jobs[1].needs[0]);
    try std.testing.expectEqualStrings("quick", workflow.jobs[1].with[0].value);
    try std.testing.expectEqualStrings("1", workflow.jobs[1].env[0].value);
    try std.testing.expectEqualStrings("write", workflow.jobs[1].permissions[0].value);
}

test "workflow runtime helpers are semantically checked" {
    if (std.time.timestamp() == std.math.minInt(i64)) {
        const repo: repo_mod.Repo = undefined;
        const workflow: Workflow = undefined;
        const target: ResolvedTarget = undefined;
        var result = try executeWorkflow(
            std.testing.allocator,
            repo,
            "018f0000-0000-7000-8000-000000000000",
            workflow,
            target,
            "workflow_dispatch",
            "workflow.manual",
            null,
            null,
            .{},
        );
        result.deinit();
    }
}

test "cron matcher supports wildcards ranges lists and steps" {
    // 2026-05-15 12:10:00 UTC is Friday.
    const ts: i64 = 1_778_847_000;
    try std.testing.expect(cronMatches("*/5 12 * * 5", ts));
    try std.testing.expect(cronMatches("10 10-12 * 5 1,5", ts));
    try std.testing.expect(!cronMatches("11 12 * * 5", ts));
    try std.testing.expect(!cronMatches("*/15 12 * * 5", ts));
}

test "github action value uses event suffix" {
    try std.testing.expectEqualStrings("opened", githubActionValue("issue.opened"));
    try std.testing.expectEqualStrings("push", githubActionValue("push"));
}

test "workflow selectors match exact paths names basenames and detect ambiguity" {
    var workflows = [_]Workflow{
        try parseWorkflow(std.testing.allocator, ".github/workflows/ci.yml",
            \\name: CI
            \\on: push
        ),
        try parseWorkflow(std.testing.allocator, ".gitomi/workflows/ci.yml",
            \\name: Native CI
            \\on: workflow_dispatch
        ),
    };
    defer {
        for (&workflows) |*workflow| workflow.deinit();
    }

    const by_path = try resolveWorkflowSelector(workflows[0..], ".github/workflows/ci.yml");
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", by_path.path);

    const by_name = try resolveWorkflowSelector(workflows[0..], "Native CI");
    try std.testing.expectEqualStrings(".gitomi/workflows/ci.yml", by_name.path);

    try std.testing.expectError(CliError.UserError, resolveWorkflowSelector(workflows[0..], "ci"));
    try std.testing.expectError(CliError.UserError, resolveWorkflowSelector(workflows[0..], "missing"));
}

test "workflow path helpers classify supported files and dialects" {
    try std.testing.expect(isWorkflowPath(".github/workflows/ci.yml"));
    try std.testing.expect(isWorkflowPath(".gitomi/workflows/review.yaml"));
    try std.testing.expect(!isWorkflowPath(".github/workflows/ci.txt"));
    try std.testing.expect(!isWorkflowPath("ci.yml"));

    try std.testing.expectEqual(WorkflowDialect.github_actions, workflowDialect(".github/workflows/ci.yml"));
    try std.testing.expectEqual(WorkflowDialect.gitomi, workflowDialect(".gitomi/workflows/review.yml"));
    try std.testing.expectEqualStrings("github-actions", WorkflowDialect.github_actions.label());
    try std.testing.expectEqualStrings("gitomi", WorkflowDialect.gitomi.label());
}

test "yaml helper parsing handles quotes comments and nested inline values" {
    try std.testing.expectEqualStrings("key: \"#not a comment\" ", stripYamlComment("key: \"#not a comment\" # comment"));
    try std.testing.expectEqualStrings("quoted", unquoteScalar(" 'quoted' "));

    const parts = try splitTopLevel(
        std.testing.allocator,
        "push: { branches: [main, release] }, pull_request: { types: [opened, synchronize] }, label: 'a,b'",
        ',',
    );
    defer git.freeStringList(std.testing.allocator, parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("push: { branches: [main, release] }", std.mem.trim(u8, parts[0], " \t\r\n"));
    try std.testing.expectEqualStrings("pull_request: { types: [opened, synchronize] }", std.mem.trim(u8, parts[1], " \t\r\n"));
    try std.testing.expectEqualStrings("label: 'a,b'", std.mem.trim(u8, parts[2], " \t\r\n"));
}

test "cron matcher rejects malformed fields and sunday aliases correctly" {
    // 2026-05-17 00:00:00 UTC is Sunday.
    const sunday: i64 = 1_778_976_000;
    try std.testing.expect(cronMatches("0 0 * * 0", sunday));
    try std.testing.expect(cronMatches("0 0 * * 7", sunday));
    try std.testing.expect(!cronMatches("0 0 * * 8", sunday));
    try std.testing.expect(!cronMatches("0 0 * * */0", sunday));
    try std.testing.expect(!cronMatches("0 0 * *", sunday));
}
