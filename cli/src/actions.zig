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
    dry_run: bool = false,
    extra_args: []const []const u8 = &.{},
};

pub const DaemonOptions = struct {
    act_path: []const u8 = "act",
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

    pub fn deinit(self: *Workflow) void {
        self.allocator.free(self.path);
        self.allocator.free(self.name);
        for (self.triggers) |trigger| self.allocator.free(trigger);
        self.allocator.free(self.triggers);
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
    const raw = git.gitChecked(allocator, &.{ "ls-tree", "-r", "--name-only", rev, ".github/workflows" }) catch |err| {
        if (err == CliError.GitFailed) {
            try io.eprint("gt actions: failed to read .github/workflows from {s}\n", .{rev});
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
            try appendJsonFieldStringArray(&line, allocator, "triggers", workflow.triggers, false);
            try line.append(allocator, '}');
            try io.out("{s}\n", .{line.items});
        } else {
            try io.out("{s}\t{s}\t", .{ workflow.path, workflow.name });
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
    return try createRunCompletedEvent(allocator, run_id, conclusion, target.target_ref, target.target_oid, workflow, event_name, false);
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

        const conclusion = executeWorkflow(
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
            break :blk "failure";
        };
        var completed = try createRunCompletedEvent(
            allocator,
            request.run_id,
            conclusion,
            target.target_ref,
            target.target_oid,
            workflow.path,
            event_name,
            false,
        );
        defer completed.deinit();
        if (!std.mem.eql(u8, conclusion, "success")) failed = true;
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

        const conclusion = executeWorkflow(
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
            break :blk "failure";
        };
        var completed = try createRunCompletedEvent(
            allocator,
            request.run_id,
            conclusion,
            target.target_ref,
            target.target_oid,
            workflow.path,
            request.event_name,
            false,
        );
        defer completed.deinit();
        if (!std.mem.eql(u8, conclusion, "success")) failed = true;
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
    if (!state.exists and !options.replay) {
        state.last_event_ordinal = max_ordinal;
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

fn daemonRunOptions(options: DaemonOptions) Options {
    return .{
        .act_path = options.act_path,
        .dry_run = options.dry_run,
        .extra_args = options.extra_args,
    };
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
        "last_event_ordinal={d}\nlast_head_oid={s}\n",
        .{ state.last_event_ordinal, state.last_head_oid },
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
) ![]const u8 {
    const event_path = try writeActEventPayload(allocator, repo, run_id, workflow, target, event_name, gitomi_event_type, object_id);
    defer {
        std.fs.deleteFileAbsolute(event_path) catch {};
        allocator.free(event_path);
    }

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

    return if (result.exitCode() == 0) "success" else "failure";
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
    if (!std.mem.startsWith(u8, path, ".github/workflows/")) return false;
    return std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml");
}

fn parseWorkflow(allocator: Allocator, path: []const u8, bytes: []const u8) !Workflow {
    var name: ?[]u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var triggers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (triggers.items) |trigger| allocator.free(trigger);
        triggers.deinit(allocator);
    }

    var in_on_block = false;
    var on_child_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const clean = std.mem.trim(u8, stripYamlComment(line_raw), " \t\r\n");
        if (clean.len == 0) continue;
        const indent = lineIndent(line_raw);

        if (indent == 0) {
            in_on_block = false;
            on_child_indent = null;
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
                }
            }
            continue;
        }

        if (!in_on_block) continue;
        if (on_child_indent == null) on_child_indent = indent;
        if (indent != on_child_indent.?) continue;
        try addTriggerBlockLine(allocator, &triggers, clean);
    }

    const display_name = name orelse try allocator.dupe(u8, std.fs.path.basename(path));
    name = null;
    return .{
        .allocator = allocator,
        .path = try allocator.dupe(u8, path),
        .name = display_name,
        .triggers = try triggers.toOwnedSlice(allocator),
    };
}

fn workflowMatches(workflow: Workflow, event_type: []const u8, event_name: []const u8) bool {
    const family = eventFamily(event_type);
    for (workflow.triggers) |trigger| {
        if (std.mem.eql(u8, trigger, event_type)) return true;
        if (std.mem.eql(u8, trigger, event_name)) return true;
        if (std.mem.eql(u8, trigger, family)) return true;
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
