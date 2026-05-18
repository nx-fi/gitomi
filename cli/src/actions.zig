const std = @import("std");
const errors = @import("errors.zig");
const event_model = @import("event/model.zig");
const event_builders = @import("event/builders.zig");
const event_json = @import("event/json.zig");
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

const model = @import("actions/model.zig");
const workflows_mod = @import("actions/workflows.zig");

pub const Options = model.Options;
pub const DaemonOptions = model.DaemonOptions;
pub const ResolvedTarget = model.ResolvedTarget;
pub const Workflow = model.Workflow;
pub const WorkflowDialect = model.WorkflowDialect;
pub const WorkflowSourcePolicy = model.WorkflowSourcePolicy;
pub const WorkflowTrigger = model.WorkflowTrigger;
pub const KeyValuePair = model.KeyValuePair;
pub const WorkflowJob = model.WorkflowJob;
pub const WorkflowStep = model.WorkflowStep;
pub const RunRequest = model.RunRequest;
pub const RequestResult = model.RequestResult;
pub const CompleteResult = model.CompleteResult;
const SchedulerState = model.SchedulerState;
const ExecuteResult = model.ExecuteResult;
const EventContext = model.EventContext;
const RunMetadata = model.RunMetadata;
const PullRefs = model.PullRefs;
const RunTargets = model.RunTargets;
const RunClaim = model.RunClaim;
const PipelineManifest = model.PipelineManifest;
const JobState = model.JobState;
const RunDiagnostics = model.RunDiagnostics;
const DiagnosticRef = model.DiagnosticRef;
const freeKeyValuePairs = model.freeKeyValuePairs;

pub const resolveTarget = workflows_mod.resolveTarget;
const duplicateTarget = workflows_mod.duplicateTarget;
pub const loadWorkflows = workflows_mod.loadWorkflows;
const loadWorkflowAtPath = workflows_mod.loadWorkflowAtPath;
pub const freeWorkflows = workflows_mod.freeWorkflows;
pub const printWorkflows = workflows_mod.printWorkflows;
const workflowMatches = workflows_mod.workflowMatches;
const workflowMatchesContext = workflows_mod.workflowMatchesContext;
const resolveWorkflowSelector = workflows_mod.resolveWorkflowSelector;
const githubEventName = workflows_mod.githubEventName;
const githubActionValue = workflows_mod.githubActionValue;
const cronMatches = workflows_mod.cronMatches;
const isConclusion = workflows_mod.isConclusion;
const isWorkflowPath = workflows_mod.isWorkflowPath;
const workflowDialect = workflows_mod.workflowDialect;
const parseWorkflow = workflows_mod.parseWorkflow;
const parseYamlKeyValue = workflows_mod.parseYamlKeyValue;
const parseStringListIntoSlice = workflows_mod.parseStringListIntoSlice;
const parseInlineMappingIntoSlice = workflows_mod.parseInlineMappingIntoSlice;
const appendStringToSlice = workflows_mod.appendStringToSlice;
const appendKeyValueToSlice = workflows_mod.appendKeyValueToSlice;
const splitTopLevel = workflows_mod.splitTopLevel;
const unquoteScalar = workflows_mod.unquoteScalar;
const stripYamlComment = workflows_mod.stripYamlComment;
const lineIndent = workflows_mod.lineIndent;
const runner_mod = @import("actions/runner.zig");
const executeWorkflow = runner_mod.executeWorkflow;
const buildPermissionGrantJson = runner_mod.buildPermissionGrantJson;
const workflowBackendSummary = runner_mod.workflowBackendSummary;
const workflowPipelineSummary = runner_mod.workflowPipelineSummary;
const loadPendingRequests = runner_mod.loadPendingRequests;
const selectRequests = runner_mod.selectRequests;

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

    var selected_target = try resolveTarget(allocator, target_ref, target_oid);
    defer selected_target.deinit();

    var pull_refs = try loadPullRefsForEvent(allocator, repo, event_type, object_id);
    defer if (pull_refs) |*refs| refs.deinit();

    var workflow_target = try defaultWorkflowTargetForEvent(allocator, selected_target, pull_refs, event_type, target_ref != null or target_oid != null);
    defer workflow_target.deinit();

    const workflows = try loadWorkflows(allocator, workflow_target.target_oid);
    defer freeWorkflows(allocator, workflows);

    const event_name = githubEventName(event_type);
    const branch = context_extra.branch orelse branchNameFromRef(workflow_target.target_ref);
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
    for (workflows) |*workflow| {
        try applyEventDefaultSourcePolicy(workflow, event_type);
        if (!workflowMatchesContext(workflow.*, context)) continue;
        matched += 1;
        if (options.dry_run) {
            try io.out("would run {s} for {s} at {s}\n", .{ workflow.path, event_type, workflow_target.target_oid });
            continue;
        }

        var run_targets = try resolveRunTargetsForWorkflow(allocator, selected_target, pull_refs, workflow.*);
        defer run_targets.deinit();
        var active_workflow = workflow.*;
        var reloaded_workflow: ?Workflow = null;
        defer if (reloaded_workflow) |*value| value.deinit();
        if (!std.mem.eql(u8, run_targets.workflow.target_oid, workflow.source_oid)) {
            reloaded_workflow = try loadWorkflowAtPath(allocator, run_targets.workflow.target_oid, workflow.path);
            if (reloaded_workflow == null) {
                try io.eprint("gt actions: workflow {s} is not present at source {s}\n", .{ workflow.path, run_targets.workflow.target_oid });
                failed = true;
                continue;
            }
            if (reloaded_workflow) |*loaded| {
                try loaded.source.setWorkflowFrom(loaded.allocator, workflow.source.workflow_from);
                try loaded.source.setCodeFrom(loaded.allocator, workflow.source.code_from);
                active_workflow = loaded.*;
            }
        }
        if (try requestAndExecuteWorkflow(allocator, repo, active_workflow, run_targets, event_name, event_type, object_id, .{}, options)) {
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

        const workflow_source_oid = request.workflow_source_oid orelse target.target_oid;
        const workflows = try loadWorkflows(allocator, workflow_source_oid);
        defer freeWorkflows(allocator, workflows);
        const workflow = try resolveWorkflowSelector(workflows, request.workflow);

        if (options.dry_run) {
            try io.out("would run requested {s} {s} at {s}\n", .{ request.run_id, workflow.path, target.target_oid });
            continue;
        }

        const workflow_target = ResolvedTarget{
            .allocator = allocator,
            .target_ref = if (request.workflow_source_ref) |value| try allocator.dupe(u8, value) else null,
            .target_oid = try allocator.dupe(u8, workflow_source_oid),
        };
        var run_targets = RunTargets{
            .workflow = workflow_target,
            .code = try duplicateTarget(allocator, target),
            .workflow_trusted = storedRequestWorkflowTrusted(request),
        };
        defer run_targets.deinit();

        var execution = executeWorkflow(
            allocator,
            repo,
            request.run_id,
            workflow,
            run_targets,
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
                .workflow_source_oid = execution.workflow_source_oid,
                .outputs_json = execution.outputs_json,
                .published_events_json = execution.published_events_json,
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
        for (workflows) |*workflow| {
            try applyEventDefaultSourcePolicy(workflow, "workflow.schedule");
            for (workflow.schedules) |schedule| {
                if (!cronMatches(schedule.cron, minute * 60)) continue;
                const slot = try scheduleSlotKey(allocator, target.target_oid, workflow.path, schedule.cron, schedule.timezone, target.target_ref, target.target_oid, minute * 60);
                defer allocator.free(slot);
                if (options.dry_run) {
                    try io.out("would run scheduled {s} for minute {d}\n", .{ workflow.path, minute });
                    continue;
                }
                var run_targets = RunTargets{
                    .workflow = try duplicateTarget(allocator, target),
                    .code = try duplicateTarget(allocator, target),
                    .workflow_trusted = true,
                };
                defer run_targets.deinit();
                if (try requestAndExecuteWorkflow(
                    allocator,
                    repo,
                    workflow.*,
                    run_targets,
                    "workflow.schedule",
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
    targets: RunTargets,
    event_name: []const u8,
    event_type: []const u8,
    object_id: ?[]const u8,
    metadata_extra: RunMetadata,
    options: Options,
) !bool {
    const permission_grant_json = try buildPermissionGrantJson(allocator, repo, workflow, targets.workflow_trusted);
    defer allocator.free(permission_grant_json);
    const metadata = RunMetadata{
        .workflow_name = workflow.name,
        .workflow_dialect = workflow.dialect.label(),
        .workflow_source_ref = targets.workflow.target_ref,
        .workflow_source_oid = targets.workflow.target_oid,
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
        targets.code.target_ref,
        targets.code.target_oid,
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
        targets,
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
        targets.code.target_ref,
        targets.code.target_oid,
        workflow.path,
        event_name,
        execution.diagnostics_ref,
        execution.diagnostics_oid,
        .{
            .attempt_id = execution.attempt_id,
            .runner_id = execution.runner_id,
            .workflow_source_oid = execution.workflow_source_oid,
            .outputs_json = execution.outputs_json,
            .published_events_json = execution.published_events_json,
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

fn isPullEvent(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "pull.");
}

fn loadPullRefsForEvent(allocator: Allocator, repo: repo_mod.Repo, event_type: []const u8, object_id: ?[]const u8) !?PullRefs {
    if (!isPullEvent(event_type)) return null;
    const pull_id = object_id orelse return null;
    try index.ensureIndex(allocator, repo);
    var db = try index.SqliteDb.open(allocator, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT base_ref, head_ref FROM pulls WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    if (!(try stmt.step())) return null;
    return .{
        .allocator = allocator,
        .base_ref = try stmt.columnTextDup(allocator, 0),
        .head_ref = try stmt.columnTextDup(allocator, 1),
    };
}

fn applyEventDefaultSourcePolicy(workflow: *Workflow, event_type: []const u8) !void {
    if (!isPullEvent(event_type)) return;
    try workflow.source.setWorkflowFromDefault(workflow.allocator, "base");
    try workflow.source.setCodeFromDefault(workflow.allocator, "head");
}

fn defaultWorkflowTargetForEvent(
    allocator: Allocator,
    selected: ResolvedTarget,
    pull_refs: ?PullRefs,
    event_type: []const u8,
    explicit_target: bool,
) !ResolvedTarget {
    _ = pull_refs;
    _ = event_type;
    _ = explicit_target;

    // Pull base/head refs come from PR metadata that the pull author can edit.
    // Workflow discovery must stay anchored to the runner-selected target.
    return duplicateTarget(allocator, selected);
}

fn resolveRunTargetsForWorkflow(
    allocator: Allocator,
    selected: ResolvedTarget,
    pull_refs: ?PullRefs,
    workflow: Workflow,
) !RunTargets {
    const workflow_source = try resolvePolicyTarget(allocator, selected, pull_refs, workflow.source.workflow_from);
    errdefer {
        var cleanup = workflow_source;
        cleanup.deinit();
    }
    const code_source = try resolvePolicyTarget(allocator, selected, pull_refs, workflow.source.code_from);
    return .{
        .workflow = workflow_source,
        .code = code_source,
        .workflow_trusted = !policySelectsUntrustedHead(workflow.source.workflow_from, pull_refs),
    };
}

fn resolvePolicyTarget(
    allocator: Allocator,
    selected: ResolvedTarget,
    pull_refs: ?PullRefs,
    policy: []const u8,
) !ResolvedTarget {
    if (std.mem.eql(u8, policy, "target")) return duplicateTarget(allocator, selected);
    if (std.mem.eql(u8, policy, "base")) {
        // Treat trusted base as the runner-selected target, not the mutable PR
        // base_ref. PR authors may choose base_ref on their own pull records.
        return duplicateTarget(allocator, selected);
    }
    if (std.mem.eql(u8, policy, "head")) {
        if (pull_refs) |refs| {
            return resolveTarget(allocator, refs.head_ref, null) catch |err| {
                if (errors.isUserError(err)) return duplicateTarget(allocator, selected);
                return err;
            };
        }
        return duplicateTarget(allocator, selected);
    }
    try io.eprint("gt actions: unsupported workflow source policy '{s}'\n", .{policy});
    return CliError.UserError;
}

fn policySelectsUntrustedHead(policy: []const u8, pull_refs: ?PullRefs) bool {
    return pull_refs != null and std.mem.eql(u8, policy, "head");
}

fn storedRequestWorkflowTrusted(request: RunRequest) bool {
    const source = request.source_workflow_from orelse return false;
    return request.workflow_source_oid != null and !std.mem.eql(u8, source, "head");
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
    if (event_json.jsonString(payload.get("base_ref"))) |value| return try allocator.dupe(u8, value);
    if (event_json.jsonString(payload.get("ref"))) |value| return try allocator.dupe(u8, value);
    return null;
}

fn scheduleSlotKey(
    allocator: Allocator,
    workflow_source_oid: []const u8,
    workflow_path: []const u8,
    cron: []const u8,
    timezone: []const u8,
    target_ref: ?[]const u8,
    target_oid: []const u8,
    scheduled_instant: i64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "workflow_source={s}|path={s}|cron={s}|timezone={s}|target_ref={s}|target_oid={s}|instant={d}",
        .{ workflow_source_oid, workflow_path, cron, timezone, target_ref orelse "", target_oid, scheduled_instant },
    );
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

    const event_body = try event_builders.buildActionRunRequestedJson(
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
    metadata: event_model.ActionRunCompletedMetadata,
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

    const event_body = try event_builders.buildActionRunCompletedJson(
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

test "workflow parser supports common on syntaxes" {
    const bytes =
        \\name: CI
        \\on:
        \\  push:
        \\    branches: [main]
        \\  pull_request:
        \\  - issues
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".github/workflows/ci.yml", bytes);
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
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".github/workflows/inline.yaml", bytes);
    defer workflow.deinit();
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatches(workflow, "action.run_requested", "workflow_dispatch"));
}

test "workflow parser supports inline trigger maps with filters" {
    const bytes =
        \\name: Filtered
        \\on: { push: { branches: [main, release] }, pull_request: { types: [opened, synchronize] } }
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".github/workflows/filtered.yml", bytes);
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
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/filtered.yml", bytes);
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
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/ci.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqual(WorkflowDialect.gitomi, workflow.dialect);
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatches(workflow, "workflow.schedule", "schedule"));
    try std.testing.expectEqual(@as(usize, 1), workflow.schedules.len);
    try std.testing.expectEqualStrings("*/5 * * * *", workflow.schedules[0].cron);
    try std.testing.expectEqualStrings("UTC", workflow.schedules[0].timezone);
    try std.testing.expectEqual(@as(usize, 1), workflow.jobs.len);
    try std.testing.expectEqualStrings("test", workflow.jobs[0].id);
    try std.testing.expectEqualStrings("shell", workflow.jobs[0].backend);
    try std.testing.expectEqual(@as(usize, 2), workflow.jobs[0].steps.len);
    try std.testing.expectEqualStrings("unit tests", workflow.jobs[0].steps[0].name.?);
    try std.testing.expectEqualStrings("zig build test", workflow.jobs[0].steps[0].run.?);
    try std.testing.expectEqualStrings("echo done", workflow.jobs[0].steps[1].run.?);
}

test "native workflow schedules retain timezone and slot identity context" {
    const bytes =
        \\name: Scheduled
        \\on:
        \\  schedule:
        \\    - cron: "0 9 * * 1"
        \\      timezone: "Europe/Zurich"
        \\jobs:
        \\  test:
        \\    backend: shell
        \\    steps:
        \\      - run: echo scheduled
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "workflow-source", ".gitomi/workflows/scheduled.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqual(@as(usize, 1), workflow.schedules.len);
    try std.testing.expectEqualStrings("0 9 * * 1", workflow.schedules[0].cron);
    try std.testing.expectEqualStrings("Europe/Zurich", workflow.schedules[0].timezone);

    const slot = try scheduleSlotKey(
        std.testing.allocator,
        "workflow-source",
        workflow.path,
        workflow.schedules[0].cron,
        workflow.schedules[0].timezone,
        "refs/heads/main",
        "target-oid",
        1_778_835_600,
    );
    defer std.testing.allocator.free(slot);
    try std.testing.expect(std.mem.indexOf(u8, slot, "workflow_source=workflow-source") != null);
    try std.testing.expect(std.mem.indexOf(u8, slot, "timezone=Europe/Zurich") != null);
    try std.testing.expect(std.mem.indexOf(u8, slot, "target_oid=target-oid") != null);
}

test "native workflow name is required" {
    const bytes =
        \\on: workflow_dispatch
        \\jobs:
        \\  test:
        \\    backend: shell
        \\    steps:
        \\      - run: echo unnamed
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/unnamed.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqualStrings("", workflow.name);
    try std.testing.expectError(CliError.UserError, workflows_mod.validateLoadedWorkflow(workflow));
}

test "workflow parser initializes optional policy fields" {
    const bytes =
        \\name: Defaults
        \\on: workflow_dispatch
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/defaults.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectEqual(@as(usize, 1), workflow.trigger_defs.len);
    try std.testing.expectEqualStrings("workflow_dispatch", workflow.trigger_defs[0].name);
    try std.testing.expectEqualStrings("target", workflow.source.workflow_from);
    try std.testing.expectEqualStrings("target", workflow.source.code_from);
    try std.testing.expectEqual(@as(usize, 0), workflow.permissions.len);
}

test "loaded workflows reject unsupported source policy values" {
    const bytes =
        \\name: Invalid Source
        \\on: workflow_dispatch
        \\source:
        \\  workflow_from: trusted-typo
        \\  code_from: target
        \\jobs:
        \\  test:
        \\    backend: shell
        \\    steps:
        \\      - run: echo test
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/invalid.yml", bytes);
    defer workflow.deinit();
    try std.testing.expectError(CliError.UserError, workflows_mod.validateLoadedWorkflow(workflow));
}

test "pull events default workflow source to base and code source to head" {
    const bytes =
        \\name: Pull Review
        \\on: pull.updated
        \\jobs:
        \\  review:
        \\    backend: shell
        \\    steps:
        \\      - run: echo review
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/review.yml", bytes);
    defer workflow.deinit();
    try applyEventDefaultSourcePolicy(&workflow, "pull.updated");
    try std.testing.expectEqualStrings("base", workflow.source.workflow_from);
    try std.testing.expectEqualStrings("head", workflow.source.code_from);
}

test "pull base policy stays on selected target instead of mutable pull base ref" {
    var selected = ResolvedTarget{
        .allocator = std.testing.allocator,
        .target_ref = try std.testing.allocator.dupe(u8, "refs/heads/main"),
        .target_oid = try std.testing.allocator.dupe(u8, "trusted-base-oid"),
    };
    defer selected.deinit();
    var refs = PullRefs{
        .allocator = std.testing.allocator,
        .base_ref = try std.testing.allocator.dupe(u8, "refs/heads/attacker-base"),
        .head_ref = try std.testing.allocator.dupe(u8, "refs/heads/attacker-head"),
    };
    defer refs.deinit();

    var workflow_target = try defaultWorkflowTargetForEvent(std.testing.allocator, selected, refs, "pull.opened", false);
    defer workflow_target.deinit();
    try std.testing.expectEqualStrings("refs/heads/main", workflow_target.target_ref.?);
    try std.testing.expectEqualStrings("trusted-base-oid", workflow_target.target_oid);

    var base_target = try resolvePolicyTarget(std.testing.allocator, selected, refs, "base");
    defer base_target.deinit();
    try std.testing.expectEqualStrings("refs/heads/main", base_target.target_ref.?);
    try std.testing.expectEqualStrings("trusted-base-oid", base_target.target_oid);
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
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/review.yml", bytes);
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

test "permission grant trust is supplied by resolved run context" {
    const bytes =
        \\name: Context Trust
        \\on: workflow_dispatch
        \\permissions:
        \\  contents: write-all
        \\source:
        \\  workflow_from: base
        \\  code_from: head
        \\jobs:
        \\  review:
        \\    backend: shell
        \\    permissions:
        \\      issues: write
        \\    steps:
        \\      - run: echo review
    ;
    var workflow = try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/context.yml", bytes);
    defer workflow.deinit();

    var context = runner_mod.GrantContext{
        .allocator = std.testing.allocator,
        .role = try std.testing.allocator.dupe(u8, "owner"),
    };
    defer context.deinit();

    const untrusted = try runner_mod.buildPermissionGrantJsonWithContext(std.testing.allocator, workflow, context, false);
    defer std.testing.allocator.free(untrusted);
    try std.testing.expect(std.mem.indexOf(u8, untrusted, "\"source_trust\":\"untrusted_workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, untrusted, "\"contents\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, untrusted, "\"issues\":\"read\"") != null);

    const trusted = try runner_mod.buildPermissionGrantJsonWithContext(std.testing.allocator, workflow, context, true);
    defer std.testing.allocator.free(trusted);
    try std.testing.expect(std.mem.indexOf(u8, trusted, "\"source_trust\":\"trusted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trusted, "\"contents\":\"write-all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trusted, "\"issues\":\"write\"") != null);
}

test "workflow runtime helpers are semantically checked" {
    if (std.time.timestamp() == std.math.minInt(i64)) {
        const repo: repo_mod.Repo = undefined;
        const workflow: Workflow = undefined;
        const targets: RunTargets = undefined;
        var result = try executeWorkflow(
            std.testing.allocator,
            repo,
            "018f0000-0000-7000-8000-000000000000",
            workflow,
            targets,
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
        try parseWorkflow(std.testing.allocator, "test-source", ".github/workflows/ci.yml",
            \\name: CI
            \\on: push
        ),
        try parseWorkflow(std.testing.allocator, "test-source", ".gitomi/workflows/ci.yml",
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
