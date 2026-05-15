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
    dialect: WorkflowDialect,
    jobs: []WorkflowJob,
    schedules: [][]u8,

    pub fn deinit(self: *Workflow) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        for (self.triggers) |trigger| self.allocator.free(trigger);
        self.allocator.free(self.triggers);
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

pub const WorkflowJob = struct {
    allocator: Allocator,
    id: []u8,
    backend: []u8,
    uses: ?[]u8 = null,
    image: ?[]u8 = null,
    steps: []WorkflowStep = &.{},

    pub fn deinit(self: *WorkflowJob) void {
        self.allocator.free(self.id);
        self.allocator.free(self.backend);
        if (self.uses) |value| self.allocator.free(value);
        if (self.image) |value| self.allocator.free(value);
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

    pub fn deinit(self: *RunRequest) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.workflow);
        if (self.target_ref) |value| self.allocator.free(value);
        if (self.target_oid) |value| self.allocator.free(value);
        self.allocator.free(self.event_name);
        self.allocator.free(self.gitomi_event_type);
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

    fn deinit(self: *ExecuteResult) void {
        if (self.diagnostics_ref) |value| self.allocator.free(value);
        if (self.diagnostics_oid) |value| self.allocator.free(value);
    }
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

    fn deinit(self: *DiagnosticRef) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.oid);
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
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var target = try resolveTarget(allocator, target_ref, target_oid);
    defer target.deinit();

    const workflows = try loadWorkflows(allocator, target.target_oid);
    defer freeWorkflows(allocator, workflows);

    const event_name = githubEventName(event_type);
    var matched: usize = 0;
    var failed = false;
    for (workflows) |workflow| {
        if (!workflowMatches(workflow, event_type, event_name)) continue;
        matched += 1;
        if (options.dry_run) {
            try io.out("would run {s} for {s} at {s}\n", .{ workflow.path, event_type, target.target_oid });
            continue;
        }

        if (try requestAndExecuteWorkflow(allocator, repo, workflow, target, event_name, event_type, object_id, options)) {
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
            options,
        ) catch |err| blk: {
            if (!errors.isReported(err)) try io.eprint("gt actions: execution failed: {s}\n", .{@errorName(err)});
            break :blk ExecuteResult{ .allocator = allocator, .conclusion = "failure" };
        };
        defer execution.deinit();
        var completed = try createRunCompletedEvent(
            allocator,
            request.run_id,
            execution.conclusion,
            target.target_ref,
            target.target_oid,
            workflow.path,
            request.event_name,
            execution.diagnostics_ref,
            execution.diagnostics_oid,
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
            try runScheduledEvent(allocator, "push", "HEAD", head, null, options);
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
        \\SELECT ordinal, event_type, object_id
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

        if (std.mem.startsWith(u8, event_type, "action.")) continue;
        try runScheduledEvent(allocator, event_type, null, null, if (object_id.len == 0) null else object_id, options);
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
    scheduleEvent(allocator, event_type, target_ref, target_oid, object_id, daemonRunOptions(options)) catch |err| {
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
            if (!workflowScheduleDue(workflow, minute * 60)) continue;
            if (options.dry_run) {
                try io.out("would run scheduled {s} for minute {d}\n", .{ workflow.path, minute });
                continue;
            }
            if (try requestAndExecuteWorkflow(allocator, repo, workflow, target, "schedule", "workflow.schedule", null, daemonRunOptions(options))) {
                failed = true;
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
    options: Options,
) !bool {
    var request = try createRunRequestedEvent(
        allocator,
        workflow.path,
        target.target_ref,
        target.target_oid,
        event_name,
        event_type,
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
        options,
    ) catch |err| blk: {
        if (!errors.isReported(err)) try io.eprint("gt actions: execution failed: {s}\n", .{@errorName(err)});
        break :blk ExecuteResult{ .allocator = allocator, .conclusion = "failure" };
    };
    defer execution.deinit();

    var completed = try createRunCompletedEvent(
        allocator,
        request.run_id,
        execution.conclusion,
        target.target_ref,
        target.target_oid,
        workflow.path,
        event_name,
        execution.diagnostics_ref,
        execution.diagnostics_oid,
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
    options: Options,
) !ExecuteResult {
    const event_path = try writeActEventPayload(allocator, repo, run_id, workflow, target, event_name, gitomi_event_type, object_id);
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
    if (writeRunDiagnostics(allocator, repo, run_id, workflow, target, conclusion, diagnostics)) |diag_ref| {
        result.diagnostics_ref = diag_ref.ref;
        result.diagnostics_oid = diag_ref.oid;
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

    var action_required = false;
    for (workflow.jobs) |job| {
        const conclusion = try executeGitomiJob(allocator, run_id, workflow, job, event_path, worktree_path, options, diagnostics);
        if (std.mem.eql(u8, conclusion, "failure")) return "failure";
        if (std.mem.eql(u8, conclusion, "action_required")) action_required = true;
    }
    return if (action_required) "action_required" else "success";
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
    defer allocator.free(runner_id);

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
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, manifest_path, run_json);

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
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn localRunnerId(allocator: Allocator, repo: repo_mod.Repo) ![]u8 {
    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch return allocator.dupe(u8, "local");
    defer cfg.deinit();
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ cfg.principal, cfg.device });
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

    return .{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, run_id),
        .workflow = try allocator.dupe(u8, workflow),
        .target_ref = if (event_mod.jsonString(payload.get("target_ref"))) |value| try allocator.dupe(u8, value) else null,
        .target_oid = if (event_mod.jsonString(payload.get("target_oid"))) |value| try allocator.dupe(u8, value) else null,
        .event_name = try allocator.dupe(u8, event_name),
        .gitomi_event_type = try allocator.dupe(u8, gitomi_event_type),
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
    var triggers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (triggers.items) |trigger| allocator.free(trigger);
        triggers.deinit(allocator);
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
    var in_jobs_block = false;
    var in_schedule_block = false;
    var on_child_indent: ?usize = null;
    var schedule_indent: ?usize = null;
    var jobs_child_indent: ?usize = null;
    var current_job: ?usize = null;
    var job_field_indent: ?usize = null;
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
            in_jobs_block = false;
            in_schedule_block = false;
            on_child_indent = null;
            schedule_indent = null;
            jobs_child_indent = null;
            current_job = null;
            job_field_indent = null;
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
                } else if (std.mem.eql(u8, kv.key, "jobs") and dialect == .gitomi) {
                    in_jobs_block = true;
                }
            }
            continue;
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
                try parseJobField(allocator, &jobs.items[current_job.?], clean);
                if (parseYamlKeyValue(clean)) |kv| {
                    if (std.mem.eql(u8, kv.key, "steps")) in_steps_block = true;
                }
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
    return .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, path),
        .name = display_name,
        .triggers = try triggers.toOwnedSlice(allocator),
        .dialect = dialect,
        .jobs = try jobs.toOwnedSlice(allocator),
        .schedules = try schedules.toOwnedSlice(allocator),
    };
}

fn workflowMatches(workflow: Workflow, event_type: []const u8, event_name: []const u8) bool {
    const family = eventFamily(event_type);
    for (workflow.triggers) |trigger| {
        if (std.mem.eql(u8, trigger, event_type)) return true;
        if (std.mem.eql(u8, trigger, event_name)) return true;
        if (std.mem.eql(u8, trigger, family)) return true;
        if (std.mem.eql(u8, trigger, "schedule") and std.mem.eql(u8, event_type, "workflow.schedule")) return true;
        if (std.mem.eql(u8, trigger, "workflow_dispatch") and std.mem.eql(u8, event_type, "workflow.manual")) return true;
    }
    return false;
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

fn parseYamlKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = unquoteScalar(std.mem.trim(u8, line[0..colon], " \t\r\n"));
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
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
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
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
    try std.testing.expect(workflowMatches(workflow, "push", "push"));
    try std.testing.expect(workflowMatches(workflow, "pull.opened", "pull_request"));
}

test "github action value uses event suffix" {
    try std.testing.expectEqualStrings("opened", githubActionValue("issue.opened"));
    try std.testing.expectEqualStrings("push", githubActionValue("push"));
}
