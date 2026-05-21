const std = @import("std");
const compat = @import("compat");
const errors = @import("../errors.zig");
const event_validation = @import("../event/validation.zig");
const event_json = @import("../event/json.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
const runs_mod = @import("../runs.zig");
const util = @import("../util.zig");
const model = @import("model.zig");
const workflows_mod = @import("workflows.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;
const appendJsonFieldUnsigned = json_writer.appendJsonFieldUnsigned;
const appendJsonString = json_writer.appendJsonString;

const Options = model.Options;
const ResolvedTarget = model.ResolvedTarget;
const Workflow = model.Workflow;
const KeyValuePair = model.KeyValuePair;
const WorkflowJob = model.WorkflowJob;
const RunRequest = model.RunRequest;
const RunTargets = model.RunTargets;
const RunClaim = model.RunClaim;
const PipelineManifest = model.PipelineManifest;
const JobState = model.JobState;
const RunDiagnostics = model.RunDiagnostics;
const DiagnosticRef = model.DiagnosticRef;
const ExecuteResult = model.ExecuteResult;
const JobJsonFragment = model.JobJsonFragment;
const LogRef = model.LogRef;
const freeKeyValuePairs = model.freeKeyValuePairs;

const githubActionValue = workflows_mod.githubActionValue;
const parseYamlKeyValue = workflows_mod.parseYamlKeyValue;
const parseStringListIntoSlice = workflows_mod.parseStringListIntoSlice;
const parseInlineMappingIntoSlice = workflows_mod.parseInlineMappingIntoSlice;
const appendStringToSlice = workflows_mod.appendStringToSlice;
const appendKeyValueToSlice = workflows_mod.appendKeyValueToSlice;
const unquoteScalar = workflows_mod.unquoteScalar;
const stripYamlComment = workflows_mod.stripYamlComment;
const lineIndent = workflows_mod.lineIndent;

pub fn executeWorkflow(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    object_id: ?[]const u8,
    schedule_slot: ?[]const u8,
    options: Options,
) !ExecuteResult {
    var claim = try acquireRunClaim(allocator, repo, run_id);
    defer claim.deinit();

    var diagnostics = try RunDiagnostics.init(allocator);
    defer diagnostics.deinit();

    const output_root = try std.fmt.allocPrint(allocator, "/tmp/gitomi-run-outputs-{s}-{s}", .{ run_id, diagnostics.attempt_id });
    defer {
        std.Io.Dir.cwd().deleteTree(@import("compat").io(), output_root) catch {};
        allocator.free(output_root);
    }
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), output_root);

    const permission_grant_json = try buildPermissionGrantJson(allocator, repo, workflow, targets.workflow_trusted);
    defer allocator.free(permission_grant_json);
    const event_path = try writeActEventPayload(allocator, repo, run_id, diagnostics.attempt_id, workflow, targets, event_name, gitomi_event_type, object_id, schedule_slot, permission_grant_json, output_root);
    defer {
        std.Io.Dir.deleteFileAbsolute(@import("compat").io(), event_path) catch {};
        allocator.free(event_path);
    }

    const worktree_path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-code-{s}", .{run_id});
    defer allocator.free(worktree_path);

    const added = git.gitChecked(allocator, &.{ "worktree", "add", "--detach", "--quiet", worktree_path, targets.code.target_oid }) catch |err| {
        if (err == CliError.GitFailed) {
            try io.eprint("gt actions: failed to create temporary worktree for {s}\n", .{targets.code.target_oid});
            return CliError.UserError;
        }
        return err;
    };
    allocator.free(added);

    defer cleanupTemporaryWorktree(allocator, worktree_path);

    var workflow_worktree_path: ?[]u8 = null;
    defer if (workflow_worktree_path) |path| {
        cleanupTemporaryWorktree(allocator, path);
        allocator.free(path);
    };
    const workflow_tree = if (std.mem.eql(u8, targets.workflow.target_oid, targets.code.target_oid))
        worktree_path
    else blk: {
        const path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-workflow-{s}", .{run_id});
        workflow_worktree_path = path;
        const workflow_added = git.gitChecked(allocator, &.{ "worktree", "add", "--detach", "--quiet", path, targets.workflow.target_oid }) catch |err| {
            if (err == CliError.GitFailed) {
                try io.eprint("gt actions: failed to create workflow worktree for {s}\n", .{targets.workflow.target_oid});
                return CliError.UserError;
            }
            return err;
        };
        allocator.free(workflow_added);
        break :blk path;
    };

    const conclusion = switch (workflow.dialect) {
        .github_actions => if (try refuseUntrustedLocalExecution(workflow.path, "github-actions", targets.workflow_trusted, options))
            "action_required"
        else
            try executeGithubActionsWorkflow(allocator, workflow, event_name, event_path, worktree_path, workflow_tree, options, &diagnostics),
        .gitomi => try executeGitomiWorkflow(allocator, repo, run_id, workflow, targets, event_name, gitomi_event_type, event_path, worktree_path, workflow_tree, output_root, permission_grant_json, options, &diagnostics),
    };

    var result = ExecuteResult{ .allocator = allocator, .conclusion = conclusion };
    result.attempt_id = try allocator.dupe(u8, diagnostics.attempt_id);
    result.workflow_source_oid = try allocator.dupe(u8, targets.workflow.target_oid);
    result.outputs_json = try buildCompletionOutputsJson(allocator, diagnostics);
    result.published_events_json = try buildPublishedEventsJson(allocator, diagnostics);
    if (writeRunDiagnostics(allocator, repo, run_id, workflow, targets, conclusion, diagnostics)) |diag_ref_value| {
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

fn cleanupTemporaryWorktree(allocator: Allocator, path: []const u8) void {
    if (git.gitChecked(allocator, &.{ "worktree", "remove", path })) |removed| {
        allocator.free(removed);
        return;
    } else |_| {}

    std.Io.Dir.cwd().deleteTree(@import("compat").io(), path) catch {};
    if (git.gitChecked(allocator, &.{ "worktree", "prune" })) |pruned| {
        allocator.free(pruned);
    } else |_| {}
}

pub fn executeGithubActionsWorkflow(
    allocator: Allocator,
    workflow: Workflow,
    event_name: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const workflow_path_arg = if (std.mem.eql(u8, worktree_path, workflow_worktree_path))
        workflow.path
    else
        try std.fs.path.join(allocator, &.{ workflow_worktree_path, workflow.path });
    defer if (!std.mem.eql(u8, workflow_path_arg, workflow.path)) allocator.free(workflow_path_arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.act_path);
    try argv.append(allocator, githubEventNameForBackend(event_name));
    try argv.append(allocator, "-W");
    try argv.append(allocator, workflow_path_arg);
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

pub fn executeGitomiWorkflow(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
    output_root: []const u8,
    permission_grant_json: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
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
            };
            if (!needs_satisfied) continue;
            if (!conditionAllowsJob(job.condition)) {
                try io.out("gt actions: {s} skipped by if condition\n", .{job.id});
                states[idx] = .skipped;
                completed_count += 1;
                progressed = true;
                continue;
            }
            const conclusion = try executeGitomiJob(allocator, repo, run_id, workflow, targets, job, event_name, gitomi_event_type, event_path, worktree_path, workflow_worktree_path, output_root, permission_grant_json, options, diagnostics);
            if (std.mem.eql(u8, conclusion, "failure")) return "failure";
            if (std.mem.eql(u8, conclusion, "timed_out")) return "timed_out";
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

pub fn jobNeedsSatisfied(workflow: Workflow, states: []const JobState, job: WorkflowJob) !bool {
    for (job.needs) |need| {
        const idx = findWorkflowJob(workflow, need) orelse return error.UnknownWorkflowJobNeed;
        if (states[idx] == .pending) return false;
    }
    return true;
}

pub fn findWorkflowJob(workflow: Workflow, id: []const u8) ?usize {
    for (workflow.jobs, 0..) |job, idx| {
        if (std.mem.eql(u8, job.id, id)) return idx;
    }
    return null;
}

pub fn conditionAllowsJob(condition: ?[]const u8) bool {
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

pub fn executeGitomiJob(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    job: WorkflowJob,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
    output_root: []const u8,
    permission_grant_json: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const backend = if (job.backend.len == 0 and job.steps.len != 0) "shell" else job.backend;
    if (try refuseUntrustedLocalExecution(workflow.path, backend, targets.workflow_trusted, options)) return "action_required";
    if (!try enforceJobPermissionGrant(allocator, repo, workflow, job, targets.workflow_trusted)) return "action_required";

    const safe_job = try sanitizePathSegment(allocator, job.id);
    defer allocator.free(safe_job);
    const job_output_dir = try std.fs.path.join(allocator, &.{ output_root, safe_job });
    defer allocator.free(job_output_dir);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), job_output_dir);

    const backend_input_json = try buildBackendInputJson(allocator, run_id, diagnostics.attempt_id, workflow, targets, event_name, gitomi_event_type, job, permission_grant_json, job_output_dir);
    defer allocator.free(backend_input_json);
    const backend_input_path = try std.fs.path.join(allocator, &.{ job_output_dir, "backend-input.json" });
    defer allocator.free(backend_input_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(@import("compat").io(), backend_input_path, .{ .truncate = true });
        defer file.close(@import("compat").io());
        try file.writeStreamingAll(@import("compat").io(), backend_input_json);
    }
    const backend_input_diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/backend/{s}-input.json", .{ diagnostics.attempt_id, safe_job });
    defer allocator.free(backend_input_diag_path);
    try diagnostics.addCopy(backend_input_diag_path, backend_input_json);

    const backend_env = try buildBackendEnv(allocator, job.env, run_id, diagnostics.attempt_id, event_path, backend_input_path, job_output_dir, permission_grant_json);
    defer freeKeyValuePairs(allocator, backend_env);

    var conclusion: []const u8 = undefined;
    if (std.mem.eql(u8, backend, "shell")) {
        conclusion = try executeShellJob(allocator, job, worktree_path, backend_env, diagnostics);
    } else if (std.mem.eql(u8, backend, "container")) {
        conclusion = try executeContainerJob(allocator, job, worktree_path, backend_env, diagnostics);
    } else if (std.mem.eql(u8, backend, "agent")) {
        conclusion = try executeAgentJob(allocator, repo, run_id, workflow, targets.workflow_trusted, job, event_path, backend_input_path, job_output_dir, permission_grant_json, worktree_path, workflow_worktree_path, options, diagnostics);
    } else if (std.mem.eql(u8, backend, "github-actions")) {
        conclusion = try executeGithubActionsJob(allocator, job, event_name, event_path, worktree_path, workflow_worktree_path, options, diagnostics);
    } else {
        try io.eprint("gt actions: native job {s} uses unsupported backend '{s}'\n", .{ job.id, backend });
        conclusion = "action_required";
    }
    try collectBackendOutputs(allocator, diagnostics, job, job_output_dir);
    return conclusion;
}

pub fn shouldBlockUntrustedLocalExecution(workflow_trusted: bool, options: Options) bool {
    return !workflow_trusted and !options.allow_untrusted_local_execution;
}

fn refuseUntrustedLocalExecution(workflow_path: []const u8, backend: []const u8, workflow_trusted: bool, options: Options) !bool {
    if (!shouldBlockUntrustedLocalExecution(workflow_trusted, options)) return false;
    try io.eprint(
        "gt actions: refusing local {s} execution for untrusted workflow {s}; rerun with --allow-untrusted-local-execution only if you trust this workflow\n",
        .{ backend, workflow_path },
    );
    return true;
}

test "untrusted workflow local execution defaults to blocked" {
    try std.testing.expect(shouldBlockUntrustedLocalExecution(false, .{}));
    try std.testing.expect(!shouldBlockUntrustedLocalExecution(false, .{ .allow_untrusted_local_execution = true }));
    try std.testing.expect(!shouldBlockUntrustedLocalExecution(true, .{}));
}

pub fn executeShellJob(
    allocator: Allocator,
    job: WorkflowJob,
    worktree_path: []const u8,
    env: []const KeyValuePair,
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
        var result = try runCommandInDirWithEnvTimed(allocator, &.{ "sh", "-lc", command }, worktree_path, null, git.max_git_output, env, job.timeout_minutes);
        defer result.deinit();
        if (result.output.stdout.len != 0) try io.out("{s}", .{result.output.stdout});
        if (result.output.stderr.len != 0) try io.eprint("{s}", .{result.output.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.output.stdout, result.output.stderr);
        if (result.timed_out) return "timed_out";
        if (result.output.exitCode() != 0) return "failure";
    }
    return "success";
}

pub fn executeContainerJob(
    allocator: Allocator,
    job: WorkflowJob,
    worktree_path: []const u8,
    env: []const KeyValuePair,
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

    const volume = try std.fmt.allocPrint(allocator, "{s}:/workspace:rw", .{worktree_path});
    defer allocator.free(volume);
    const user_arg = try std.fmt.allocPrint(allocator, "{d}", .{std.c.getuid()});
    defer allocator.free(user_arg);

    for (job.steps, 0..) |step, idx| {
        const command = step.run orelse continue;
        const step_label = step.name orelse command;
        try io.out("gt actions: {s}[{d}] {s}\n", .{ job.id, idx + 1, step_label });
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        var env_args: std.ArrayList([]u8) = .empty;
        defer {
            for (env_args.items) |value| allocator.free(value);
            env_args.deinit(allocator);
        }
        try appendContainerSandboxArgs(&argv, allocator, volume, user_arg);
        for (env) |entry| {
            const env_arg = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value });
            errdefer allocator.free(env_arg);
            try env_args.append(allocator, env_arg);
            try argv.append(allocator, "-e");
            try argv.append(allocator, env_arg);
        }
        try argv.appendSlice(allocator, &.{ image, "sh", "-lc", command });
        var result = try runCommandInDirTimed(allocator, argv.items, worktree_path, null, git.max_git_output, job.timeout_minutes);
        defer result.deinit();
        if (result.output.stdout.len != 0) try io.out("{s}", .{result.output.stdout});
        if (result.output.stderr.len != 0) try io.eprint("{s}", .{result.output.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.output.stdout, result.output.stderr);
        if (result.timed_out) return "timed_out";
        if (result.output.exitCode() != 0) return "failure";
    }
    return "success";
}

fn appendContainerSandboxArgs(argv: *std.ArrayList([]const u8), allocator: Allocator, volume: []const u8, user_arg: []const u8) !void {
    try argv.appendSlice(allocator, &.{
        "docker",
        "run",
        "--rm",
        "--network",
        "none",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        "256",
        "--read-only",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,nodev,size=64m",
        "--user",
        user_arg,
        "-v",
        volume,
        "-w",
        "/workspace",
    });
}

test "container backend includes Docker sandbox flags" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);

    try appendContainerSandboxArgs(&argv, std.testing.allocator, "/tmp/work:/workspace:rw", "123:456");

    try std.testing.expect(containsArg(argv.items, "--network"));
    try std.testing.expect(containsArg(argv.items, "none"));
    try std.testing.expect(containsArg(argv.items, "--cap-drop"));
    try std.testing.expect(containsArg(argv.items, "ALL"));
    try std.testing.expect(containsArg(argv.items, "--read-only"));
    try std.testing.expect(containsArg(argv.items, "--user"));
    try std.testing.expect(containsArg(argv.items, "123:456"));
}

fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

pub fn executeGithubActionsJob(
    allocator: Allocator,
    job: WorkflowJob,
    event_name: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    const workflow_path = job.uses orelse {
        try io.eprint("gt actions: github-actions job {s} requires uses: .github/workflows/<file>\n", .{job.id});
        return "failure";
    };
    if (!isSafeRelativeBackendPath(workflow_path)) {
        try io.eprint("gt actions: github-actions job {s} uses invalid workflow path '{s}'\n", .{ job.id, workflow_path });
        return "failure";
    }
    const workflow_path_arg = try std.fs.path.join(allocator, &.{ workflow_worktree_path, workflow_path });
    defer allocator.free(workflow_path_arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.act_path);
    try argv.append(allocator, githubEventNameForBackend(event_name));
    try argv.append(allocator, "-W");
    try argv.append(allocator, workflow_path_arg);
    try argv.append(allocator, "-e");
    try argv.append(allocator, event_path);
    for (options.extra_args) |arg| try argv.append(allocator, arg);

    var result = runCommandInDirTimed(allocator, argv.items, worktree_path, null, git.max_git_output, job.timeout_minutes) catch |err| switch (err) {
        error.FileNotFound => {
            try io.eprint("gt actions: nektos/act executable not found: {s}\n", .{options.act_path});
            return CliError.UserError;
        },
        else => return err,
    };
    defer result.deinit();
    if (result.output.stdout.len != 0) try io.out("{s}", .{result.output.stdout});
    if (result.output.stderr.len != 0) try io.eprint("{s}", .{result.output.stderr});
    try addStepLogs(allocator, diagnostics, job.id, 1, result.output.stdout, result.output.stderr);
    if (result.timed_out) return "timed_out";
    return if (result.output.exitCode() == 0) "success" else "failure";
}

pub fn executeAgentJob(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    workflow_trusted: bool,
    job: WorkflowJob,
    event_path: []const u8,
    backend_input_path: []const u8,
    output_dir: []const u8,
    permission_grant_json: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
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
    var manifest = validateAgentPipelinePackage(allocator, workflow_worktree_path, pipeline) catch |err| switch (err) {
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
    if (!try enforceAgentManifestGrant(allocator, repo, workflow, job, manifest, workflow_trusted)) return "action_required";
    const manifest_json = try buildPipelineManifestDiagnosticJson(allocator, manifest);
    defer allocator.free(manifest_json);
    const safe_job = try sanitizePathSegment(allocator, job.id);
    defer allocator.free(safe_job);
    const manifest_diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/pipelines/{s}-manifest.json", .{ diagnostics.attempt_id, safe_job });
    defer allocator.free(manifest_diag_path);
    try diagnostics.addCopy(manifest_diag_path, manifest_json);

    var result = try runCommandInDirTimed(allocator, &.{
        runner,
        "run",
        "--run-id",
        run_id,
        "--attempt-id",
        diagnostics.attempt_id,
        "--job",
        job.id,
        "--workflow",
        workflow.path,
        "--pipeline",
        pipeline,
        "--event",
        event_path,
        "--backend-input",
        backend_input_path,
        "--permission-grant",
        permission_grant_json,
        "--outputs-dir",
        output_dir,
        "--worktree",
        worktree_path,
        "--workflow-worktree",
        workflow_worktree_path,
    }, worktree_path, null, git.max_git_output, job.timeout_minutes);
    defer result.deinit();
    if (result.output.stdout.len != 0) try io.out("{s}", .{result.output.stdout});
    if (result.output.stderr.len != 0) try io.eprint("{s}", .{result.output.stderr});
    try addStepLogs(allocator, diagnostics, job.id, 1, result.output.stdout, result.output.stderr);
    if (result.timed_out) return "timed_out";
    return if (result.output.exitCode() == 0) "success" else "failure";
}

pub fn validateAgentPipelinePackage(allocator: Allocator, worktree_path: []const u8, pipeline: []const u8) !PipelineManifest {
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
    const bytes = std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), manifest_yml, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const alt = std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), manifest_yaml, allocator, .limited(256 * 1024)) catch |alt_err| switch (alt_err) {
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

pub fn buildPipelineManifestDiagnosticJson(allocator: Allocator, manifest: PipelineManifest) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:pipeline-manifest:v1", true);
    try appendJsonFieldString(&buf, allocator, "path", manifest.path, true);
    try appendJsonFieldString(&buf, allocator, "name", manifest.name, true);
    try appendJsonFieldStringArray(&buf, allocator, "tools", manifest.tools, true);
    try appendJsonString(&buf, allocator, "permissions");
    try buf.append(allocator, ':');
    try appendRawPermissionObject(&buf, allocator, manifest.permissions);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn buildBackendInputJson(
    allocator: Allocator,
    run_id: []const u8,
    attempt_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    job: WorkflowJob,
    permission_grant_json: []const u8,
    output_dir: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:backend-input:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonString(&buf, allocator, "event");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(&buf, allocator, "event_name", event_name, true);
    try appendJsonFieldString(&buf, allocator, "gitomi_event_type", gitomi_event_type, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonString(&buf, allocator, "target");
    try buf.appendSlice(allocator, ":{");
    if (targets.code.target_ref) |value| try appendJsonFieldString(&buf, allocator, "ref", value, true);
    try appendJsonFieldString(&buf, allocator, "oid", targets.code.target_oid, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonString(&buf, allocator, "workflow");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(&buf, allocator, "path", workflow.path, true);
    try appendJsonFieldString(&buf, allocator, "name", workflow.name, true);
    try appendJsonFieldString(&buf, allocator, "source_oid", targets.workflow.target_oid, false);
    try buf.appendSlice(allocator, "},");
    try appendJsonString(&buf, allocator, "job");
    try buf.append(allocator, ':');
    try appendJobPlanJson(&buf, allocator, workflow, job);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "effective_grant");
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, permission_grant_json);
    try buf.append(allocator, ',');
    try appendJsonFieldString(&buf, allocator, "output_dir", output_dir, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn appendJobPlanJson(buf: *std.ArrayList(u8), allocator: Allocator, workflow: Workflow, job: WorkflowJob) !void {
    try buf.append(allocator, '{');
    try appendJsonFieldString(buf, allocator, "id", job.id, true);
    try appendJsonFieldString(buf, allocator, "backend", effectiveJobBackend(job), true);
    if (job.uses) |uses| try appendJsonFieldString(buf, allocator, "uses", uses, true);
    if (job.condition) |condition| try appendJsonFieldString(buf, allocator, "if", condition, true);
    if (job.timeout_minutes) |timeout| try appendJsonFieldUnsigned(buf, allocator, "timeout_minutes", timeout, true);
    try appendJsonFieldStringArray(buf, allocator, "needs", job.needs, true);
    try appendJsonString(buf, allocator, "inputs");
    try buf.append(allocator, ':');
    try appendKeyValueObject(buf, allocator, job.with);
    try buf.append(allocator, ',');
    try appendJsonString(buf, allocator, "permissions");
    try buf.append(allocator, ':');
    try appendRawPermissionObject(buf, allocator, effectiveRequestedPermissions(workflow, job));
    if (buf.items[buf.items.len - 1] == ',') buf.items.len -= 1;
    try buf.append(allocator, '}');
}

pub fn appendKeyValueObject(buf: *std.ArrayList(u8), allocator: Allocator, pairs: []const KeyValuePair) !void {
    try buf.append(allocator, '{');
    for (pairs, 0..) |entry, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, entry.key);
        try buf.append(allocator, ':');
        try appendJsonString(buf, allocator, entry.value);
    }
    try buf.append(allocator, '}');
}

pub fn buildBackendEnv(
    allocator: Allocator,
    job_env: []const KeyValuePair,
    run_id: []const u8,
    attempt_id: []const u8,
    event_path: []const u8,
    backend_input_path: []const u8,
    output_dir: []const u8,
    permission_grant_json: []const u8,
) ![]KeyValuePair {
    var env: []KeyValuePair = &.{};
    errdefer freeKeyValuePairs(allocator, env);
    for (job_env) |entry| try appendKeyValueToSlice(allocator, &env, entry.key, entry.value);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_RUN_ID", run_id);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_ATTEMPT_ID", attempt_id);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_EVENT_PATH", event_path);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_BACKEND_INPUT", backend_input_path);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_OUTPUT_DIR", output_dir);
    try appendKeyValueToSlice(allocator, &env, "GITOMI_PERMISSION_GRANT", permission_grant_json);
    return env;
}

pub fn collectBackendOutputs(allocator: Allocator, diagnostics: *RunDiagnostics, job: WorkflowJob, output_dir: []const u8) !void {
    if (try readOutputFile(allocator, output_dir, "result.json")) |bytes| {
        defer allocator.free(bytes);
        const safe_job = try sanitizePathSegment(allocator, job.id);
        defer allocator.free(safe_job);
        const diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/outputs/{s}-result.json", .{ diagnostics.attempt_id, safe_job });
        defer allocator.free(diag_path);
        try diagnostics.addCopy(diag_path, bytes);
        if (try json_writer.canonicalizeJsonValue(allocator, bytes, .object)) |output_json| {
            defer allocator.free(output_json);
            try diagnostics.addJobOutputCopy(job.id, output_json);
        }
        try collectResultJsonMetadata(allocator, diagnostics, job, bytes);
    } else if (try readOutputFile(allocator, output_dir, "outputs.json")) |bytes| {
        defer allocator.free(bytes);
        const safe_job = try sanitizePathSegment(allocator, job.id);
        defer allocator.free(safe_job);
        const diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/outputs/{s}.json", .{ diagnostics.attempt_id, safe_job });
        defer allocator.free(diag_path);
        try diagnostics.addCopy(diag_path, bytes);
        if (try json_writer.canonicalizeJsonValue(allocator, bytes, .object)) |output_json| {
            defer allocator.free(output_json);
            try diagnostics.addJobOutputCopy(job.id, output_json);
        }
    }
    if (try readOutputFile(allocator, output_dir, "artifacts.json")) |bytes| {
        defer allocator.free(bytes);
        const safe_job = try sanitizePathSegment(allocator, job.id);
        defer allocator.free(safe_job);
        const diag_path = try std.fmt.allocPrint(allocator, "attempts/{s}/artifacts/{s}.json", .{ diagnostics.attempt_id, safe_job });
        defer allocator.free(diag_path);
        try diagnostics.addCopy(diag_path, bytes);
        if (try json_writer.canonicalizeJsonValue(allocator, bytes, .array)) |artifact_json| {
            defer allocator.free(artifact_json);
            try diagnostics.addJobArtifactsCopy(job.id, artifact_json);
        }
    }
    if (try readOutputFile(allocator, output_dir, "published_events.json")) |bytes| {
        defer allocator.free(bytes);
        try collectPublishedEventsArray(allocator, diagnostics, bytes);
    }
}

pub fn collectResultJsonMetadata(allocator: Allocator, diagnostics: *RunDiagnostics, job: WorkflowJob, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    if (root.get("artifacts")) |value| {
        switch (value) {
            .array => {
                const artifact_json = try json_writer.stringifyJsonValue(allocator, value);
                defer allocator.free(artifact_json);
                try diagnostics.addJobArtifactsCopy(job.id, artifact_json);
            },
            else => {},
        }
    }
    if (root.get("published_events")) |value| {
        switch (value) {
            .array => {
                const events_json = try json_writer.stringifyJsonValue(allocator, value);
                defer allocator.free(events_json);
                try collectPublishedEventsArray(allocator, diagnostics, events_json);
            },
            else => {},
        }
    }
}

pub fn readOutputFile(allocator: Allocator, output_dir: []const u8, file_name: []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ output_dir, file_name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn collectPublishedEventsArray(allocator: Allocator, diagnostics: *RunDiagnostics, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |item| {
        switch (item) {
            .string => |event_hash| try diagnostics.addPublishedEventCopy(event_hash),
            else => {},
        }
    }
}

test "job-controlled result conclusion does not override backend failure" {
    const allocator = std.testing.allocator;

    const test_id = try util.newUuidV7(allocator);
    defer allocator.free(test_id);
    const base_path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-output-forgery-test-{s}", .{test_id});
    defer allocator.free(base_path);
    defer std.Io.Dir.cwd().deleteTree(@import("compat").io(), base_path) catch {};
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), base_path);

    const output_root = try std.fs.path.join(allocator, &.{ base_path, "outputs" });
    defer allocator.free(output_root);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), output_root);

    const forged_output_dir = try std.fs.path.join(allocator, &.{ output_root, "forged" });
    defer allocator.free(forged_output_dir);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), forged_output_dir);

    const result_path = try std.fs.path.join(allocator, &.{ forged_output_dir, "result.json" });
    defer allocator.free(result_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(@import("compat").io(), result_path, .{ .truncate = true });
        defer file.close(@import("compat").io());
        try file.writeStreamingAll(@import("compat").io(), "{\"conclusion\":\"success\",\"payload\":true}");
    }

    var repo = repo_mod.Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, base_path),
        .git_dir = try std.fs.path.join(allocator, &.{ base_path, ".git" }),
        .gitomi_dir = try std.fs.path.join(allocator, &.{ base_path, ".gitomi" }),
        .config_path = try std.fs.path.join(allocator, &.{ base_path, "missing-config.toml" }),
        .index_path = try std.fs.path.join(allocator, &.{ base_path, "index.db" }),
        .cursors_path = try std.fs.path.join(allocator, &.{ base_path, "cursors" }),
        .settings_path = try std.fs.path.join(allocator, &.{ base_path, "settings.toml" }),
    };
    defer repo.deinit();

    const workflow_bytes =
        \\name: Forgery Test
        \\on: push
        \\jobs:
        \\  forged:
        \\    backend: container
    ;
    var workflow = try workflows_mod.parseWorkflow(allocator, "workflow-oid", ".gitomi/workflows/forgery.yml", workflow_bytes);
    defer workflow.deinit();

    var targets = RunTargets{
        .workflow = .{
            .allocator = allocator,
            .target_ref = try allocator.dupe(u8, "refs/heads/main"),
            .target_oid = try allocator.dupe(u8, "workflow-oid"),
        },
        .code = .{
            .allocator = allocator,
            .target_ref = try allocator.dupe(u8, "refs/heads/main"),
            .target_oid = try allocator.dupe(u8, "code-oid"),
        },
        .workflow_trusted = true,
    };
    defer targets.deinit();

    var diagnostics = try RunDiagnostics.init(allocator);
    defer diagnostics.deinit();

    const conclusion = try executeGitomiJob(
        allocator,
        repo,
        "run-id",
        workflow,
        targets,
        workflow.jobs[0],
        "push",
        "push",
        "/tmp/gitomi-forgery-event.json",
        base_path,
        base_path,
        output_root,
        "{}",
        .{},
        &diagnostics,
    );

    try std.testing.expectEqualStrings("failure", conclusion);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.job_outputs.items.len);
    try std.testing.expectEqualStrings("forged", diagnostics.job_outputs.items[0].job_id);
    try std.testing.expectEqualStrings("{\"conclusion\":\"success\",\"payload\":true}", diagnostics.job_outputs.items[0].json);
}

pub fn addStepLogs(
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
    try diagnostics.addLogRefCopy(job_id, "stdout", stdout_path);
    try diagnostics.addLogRefCopy(job_id, "stderr", stderr_path);
}

pub fn writeRunDiagnostics(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    conclusion: []const u8,
    diagnostics: RunDiagnostics,
) !DiagnosticRef {
    const runner_id = try localRunnerId(allocator, repo);
    errdefer allocator.free(runner_id);

    const run_ref = try std.fmt.allocPrint(allocator, "refs/gitomi/runs/{s}/{s}", .{ runner_id, run_id });
    errdefer allocator.free(run_ref);

    const index_path = try std.fmt.allocPrint(allocator, "/tmp/gitomi-run-index-{s}-{s}", .{ run_id, diagnostics.attempt_id });
    defer {
        std.Io.Dir.deleteFileAbsolute(@import("compat").io(), index_path) catch {};
        allocator.free(index_path);
    }

    const completed_at = try util.rfc3339Now(allocator);
    defer allocator.free(completed_at);

    const run_json = try buildRunDiagnosticJson(allocator, run_id, workflow, targets, conclusion, runner_id, diagnostics.attempt_id, diagnostics.started_at, completed_at);
    defer allocator.free(run_json);
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, "run.json", run_json);

    const manifest_path = try std.fmt.allocPrint(allocator, "attempts/{s}/manifest.json", .{diagnostics.attempt_id});
    defer allocator.free(manifest_path);
    const manifest_json = try buildAttemptManifestJson(allocator, run_id, workflow, targets, conclusion, runner_id, diagnostics.attempt_id, diagnostics.started_at, completed_at);
    defer allocator.free(manifest_json);
    try writeDiagnosticBlobToIndex(allocator, repo, index_path, manifest_path, manifest_json);

    const output_path = try std.fmt.allocPrint(allocator, "attempts/{s}/outputs/final.json", .{diagnostics.attempt_id});
    defer allocator.free(output_path);
    const output_json = try buildFinalOutputJson(allocator, run_id, diagnostics.attempt_id, conclusion, diagnostics);
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
    runs_mod.prune(allocator, .{ .quiet = true }) catch |err| {
        if (!errors.isReported(err)) try io.eprint("gt actions: failed to prune retained run diagnostics: {s}\n", .{@errorName(err)});
    };

    return .{
        .allocator = allocator,
        .ref = run_ref,
        .oid = commit_oid,
        .runner_id = runner_id,
    };
}

pub fn writeDiagnosticBlobToIndex(
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

pub fn buildRunDiagnosticJson(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    conclusion: []const u8,
    runner_id: []const u8,
    attempt_id: []const u8,
    started_at: []const u8,
    completed_at: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-run:v1", true);
    try appendJsonFieldUnsigned(&buf, allocator, "schema_version", 1, true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "runner_id", runner_id, true);
    try appendJsonFieldString(&buf, allocator, "workflow", workflow.path, true);
    try appendJsonFieldString(&buf, allocator, "workflow_name", workflow.name, true);
    try appendJsonFieldString(&buf, allocator, "workflow_source_oid", targets.workflow.target_oid, true);
    try appendJsonFieldString(&buf, allocator, "dialect", workflow.dialect.label(), true);
    try appendJsonFieldString(&buf, allocator, "target_ref", targets.code.target_ref orelse "", true);
    try appendJsonFieldString(&buf, allocator, "target_oid", targets.code.target_oid, true);
    try appendJsonFieldString(&buf, allocator, "started_at", started_at, true);
    try appendJsonFieldString(&buf, allocator, "completed_at", completed_at, true);
    try appendJsonString(&buf, allocator, "known_attempts");
    try buf.appendSlice(allocator, ":[");
    try appendJsonString(&buf, allocator, attempt_id);
    try buf.appendSlice(allocator, "],");
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

pub fn buildAttemptManifestJson(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    conclusion: []const u8,
    runner_id: []const u8,
    attempt_id: []const u8,
    started_at: []const u8,
    completed_at: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-attempt:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "runner_id", runner_id, true);
    try appendJsonFieldString(&buf, allocator, "workflow", workflow.path, true);
    try appendJsonFieldString(&buf, allocator, "workflow_source_oid", targets.workflow.target_oid, true);
    try appendJsonFieldString(&buf, allocator, "target_oid", targets.code.target_oid, true);
    try appendJsonFieldString(&buf, allocator, "started_at", started_at, true);
    try appendJsonFieldString(&buf, allocator, "completed_at", completed_at, true);
    try appendJsonFieldString(&buf, allocator, "backend_kind", workflowBackendSummary(workflow) orelse "", true);
    try appendJsonFieldString(&buf, allocator, "backend_version", "gitomi-v1", true);
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
    const final_output_path = try std.fmt.allocPrint(allocator, "attempts/{s}/outputs/final.json", .{attempt_id});
    defer allocator.free(final_output_path);
    try appendJsonFieldString(&buf, allocator, "outputs", final_output_path, true);
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn buildFinalOutputJson(allocator: Allocator, run_id: []const u8, attempt_id: []const u8, conclusion: []const u8, diagnostics: RunDiagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-output:v1", true);
    try appendJsonFieldString(&buf, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&buf, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, true);
    try appendJsonString(&buf, allocator, "outputs");
    try buf.append(allocator, ':');
    try appendJobJsonFragmentObject(&buf, allocator, diagnostics.job_outputs.items, .object);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "artifacts");
    try buf.append(allocator, ':');
    try appendJobJsonFragmentObject(&buf, allocator, diagnostics.job_artifacts.items, .array);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "logs");
    try buf.append(allocator, ':');
    try appendLogRefsArray(&buf, allocator, diagnostics.log_refs.items);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "published_events");
    try buf.append(allocator, ':');
    try appendStringArrayRaw(&buf, allocator, diagnostics.published_events.items);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn buildCompletionOutputsJson(allocator: Allocator, diagnostics: RunDiagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendJobJsonFragmentObject(&buf, allocator, diagnostics.job_outputs.items, .object);
    return try buf.toOwnedSlice(allocator);
}

pub fn buildPublishedEventsJson(allocator: Allocator, diagnostics: RunDiagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendStringArrayRaw(&buf, allocator, diagnostics.published_events.items);
    return try buf.toOwnedSlice(allocator);
}

pub fn appendJobJsonFragmentObject(buf: *std.ArrayList(u8), allocator: Allocator, fragments: []const model.JobJsonFragment, root_kind: json_writer.JsonRootKind) !void {
    try buf.append(allocator, '{');
    for (fragments, 0..) |fragment, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, fragment.job_id);
        try buf.append(allocator, ':');
        const canonical = try json_writer.requireCanonicalJsonValue(allocator, fragment.json, root_kind);
        defer allocator.free(canonical);
        try buf.appendSlice(allocator, canonical);
    }
    try buf.append(allocator, '}');
}

test "job JSON fragments are canonicalized before object assembly" {
    const allocator = std.testing.allocator;
    const job_id = try allocator.dupe(u8, "build");
    defer allocator.free(job_id);
    const json = try allocator.dupe(u8, " { \"ok\" : true } ");
    defer allocator.free(json);
    const fragments = [_]model.JobJsonFragment{.{
        .job_id = job_id,
        .json = json,
    }};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendJobJsonFragmentObject(&buf, allocator, &fragments, .object);

    try std.testing.expectEqualStrings("{\"build\":{\"ok\":true}}", buf.items);
}

test "job JSON fragments reject structural injection" {
    const allocator = std.testing.allocator;
    const job_id = try allocator.dupe(u8, "build");
    defer allocator.free(job_id);
    const json = try allocator.dupe(u8, "{}},\"conclusion\":\"success\",\"pad\":{");
    defer allocator.free(json);
    const fragments = [_]model.JobJsonFragment{.{
        .job_id = job_id,
        .json = json,
    }};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try std.testing.expectError(error.InvalidJsonValue, appendJobJsonFragmentObject(&buf, allocator, &fragments, .object));
}

pub fn appendLogRefsArray(buf: *std.ArrayList(u8), allocator: Allocator, logs: []const model.LogRef) !void {
    try buf.append(allocator, '[');
    for (logs, 0..) |log, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(buf, allocator, "job_id", log.job_id, true);
        try appendJsonFieldString(buf, allocator, "stream", log.stream, true);
        try appendJsonFieldString(buf, allocator, "path", log.path, false);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

pub fn appendStringArrayRaw(buf: *std.ArrayList(u8), allocator: Allocator, values: []const []u8) !void {
    try buf.append(allocator, '[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, value);
    }
    try buf.append(allocator, ']');
}

pub fn canonicalConclusion(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "success")) return "success";
    if (std.mem.eql(u8, value, "failure")) return "failure";
    if (std.mem.eql(u8, value, "cancelled")) return "cancelled";
    if (std.mem.eql(u8, value, "skipped")) return "skipped";
    if (std.mem.eql(u8, value, "neutral")) return "neutral";
    if (std.mem.eql(u8, value, "timed_out")) return "timed_out";
    if (std.mem.eql(u8, value, "action_required")) return "action_required";
    return null;
}

pub fn buildPermissionGrantJson(allocator: Allocator, repo: repo_mod.Repo, workflow: Workflow, workflow_trusted: bool) ![]u8 {
    var context = try loadGrantContext(allocator, repo);
    defer context.deinit();
    return buildPermissionGrantJsonWithContext(allocator, workflow, context, workflow_trusted);
}

pub fn buildPermissionGrantJsonWithContext(allocator: Allocator, workflow: Workflow, context: GrantContext, workflow_trusted: bool) ![]u8 {
    const reduce_write = !workflow_trusted;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonFieldString(&buf, allocator, "schema", "urn:gitomi:workflow-permission-grant:v1", true);
    if (context.principal) |principal| try appendJsonFieldString(&buf, allocator, "actor_principal", principal, true);
    if (context.role) |role| try appendJsonFieldString(&buf, allocator, "rbac_role", role, true);
    try appendJsonFieldString(&buf, allocator, "source_trust", if (reduce_write) "untrusted_workflow" else "trusted", true);
    try appendJsonString(&buf, allocator, "derivation");
    try buf.appendSlice(allocator, ":{");
    try appendJsonFieldString(&buf, allocator, "rbac", if (context.role != null) "current_actor_role" else "no_authorized_role", true);
    try appendJsonFieldString(&buf, allocator, "workflow_policy", "workflow_and_job_permissions", true);
    try appendJsonFieldString(&buf, allocator, "source_trust", if (reduce_write) "write_reduced_to_read" else "trusted_source", true);
    try appendJsonFieldString(&buf, allocator, "backend_policy", "backend_local_enforcement", true);
    try buf.appendSlice(allocator, "\"approvals\":[]},");
    try appendJsonString(&buf, allocator, "workflow");
    try buf.append(allocator, ':');
    try appendPermissionObject(&buf, allocator, workflow.permissions, reduce_write, context);
    try buf.append(allocator, ',');
    try appendJsonString(&buf, allocator, "jobs");
    try buf.appendSlice(allocator, ":[");
    for (workflow.jobs, 0..) |job, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonFieldString(&buf, allocator, "id", job.id, true);
        try appendJsonFieldString(&buf, allocator, "backend", effectiveJobBackend(job), true);
        try appendJsonString(&buf, allocator, "requested_permissions");
        try buf.append(allocator, ':');
        try appendRawPermissionObject(&buf, allocator, effectiveRequestedPermissions(workflow, job));
        try buf.append(allocator, ',');
        try appendJsonString(&buf, allocator, "permissions");
        try buf.append(allocator, ':');
        try appendPermissionObject(&buf, allocator, effectiveRequestedPermissions(workflow, job), reduce_write, context);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

pub fn appendPermissionObject(buf: *std.ArrayList(u8), allocator: Allocator, permissions: []const KeyValuePair, reduce_write: bool, context: GrantContext) !void {
    try buf.append(allocator, '{');
    for (permissions, 0..) |entry, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, entry.key);
        try buf.append(allocator, ':');
        try appendJsonString(buf, allocator, effectivePermissionValue(entry.key, entry.value, reduce_write, context));
    }
    try buf.append(allocator, '}');
}

pub fn appendRawPermissionObject(buf: *std.ArrayList(u8), allocator: Allocator, permissions: []const KeyValuePair) !void {
    try buf.append(allocator, '{');
    for (permissions, 0..) |entry, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, entry.key);
        try buf.append(allocator, ':');
        try appendJsonString(buf, allocator, entry.value);
    }
    try buf.append(allocator, '}');
}

pub fn effectivePermissionValue(key: []const u8, value: []const u8, reduce_write: bool, context: GrantContext) []const u8 {
    if (isWritePermissionValue(value)) {
        if (reduce_write) return if (roleAllowsRead(context.role)) "read" else "none";
        if (roleAllowsWriteScope(context.role, key)) return value;
        return if (roleAllowsRead(context.role)) "read" else "none";
    }
    if (isReadPermissionValue(value)) return if (roleAllowsRead(context.role)) value else "none";
    return value;
}

pub const GrantContext = struct {
    allocator: Allocator,
    principal: ?[]u8 = null,
    role: ?[]u8 = null,

    pub fn deinit(self: *GrantContext) void {
        if (self.principal) |value| self.allocator.free(value);
        if (self.role) |value| self.allocator.free(value);
    }
};

pub fn loadGrantContext(allocator: Allocator, repo: repo_mod.Repo) !GrantContext {
    var context = GrantContext{ .allocator = allocator };
    errdefer context.deinit();
    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch return context;
    defer cfg.deinit();
    context.principal = try allocator.dupe(u8, cfg.principal);
    context.role = try index.effectiveWriteRoleForPrincipal(allocator, repo, cfg.principal);
    return context;
}

pub fn effectiveRequestedPermissions(workflow: Workflow, job: WorkflowJob) []const KeyValuePair {
    return if (job.permissions.len != 0) job.permissions else workflow.permissions;
}

pub fn enforceJobPermissionGrant(allocator: Allocator, repo: repo_mod.Repo, workflow: Workflow, job: WorkflowJob, workflow_trusted: bool) !bool {
    var context = try loadGrantContext(allocator, repo);
    defer context.deinit();
    const reduce_write = !workflow_trusted;
    const requested = effectiveRequestedPermissions(workflow, job);
    for (requested) |entry| {
        if (!permissionRequestSatisfied(entry.key, entry.value, reduce_write, context)) {
            try io.eprint(
                "gt actions: native job {s} requested {s}:{s}, but the effective grant does not allow it\n",
                .{ job.id, entry.key, entry.value },
            );
            return false;
        }
    }
    return true;
}

pub fn enforceAgentManifestGrant(allocator: Allocator, repo: repo_mod.Repo, _: Workflow, job: WorkflowJob, manifest: PipelineManifest, workflow_trusted: bool) !bool {
    var context = try loadGrantContext(allocator, repo);
    defer context.deinit();
    const reduce_write = !workflow_trusted;
    for (manifest.permissions) |entry| {
        if (!permissionRequestSatisfied(entry.key, entry.value, reduce_write, context)) {
            try io.eprint(
                "gt actions: agent job {s} pipeline requests {s}:{s}, but the effective grant does not allow it\n",
                .{ job.id, entry.key, entry.value },
            );
            return false;
        }
    }
    for (manifest.tools) |tool| {
        if (!toolClassAllowed(tool, reduce_write, context)) {
            try io.eprint("gt actions: agent job {s} pipeline tool {s} is not allowed by the effective grant\n", .{ job.id, tool });
            return false;
        }
    }
    return true;
}

pub fn permissionRequestSatisfied(key: []const u8, value: []const u8, reduce_write: bool, context: GrantContext) bool {
    const effective = effectivePermissionValue(key, value, reduce_write, context);
    if (isWritePermissionValue(value)) return isWritePermissionValue(effective);
    if (isReadPermissionValue(value)) return isReadPermissionValue(effective) or isWritePermissionValue(effective);
    return !std.mem.eql(u8, effective, "none");
}

pub fn toolClassAllowed(tool: []const u8, reduce_write: bool, context: GrantContext) bool {
    if (std.mem.endsWith(u8, tool, ".write") or std.mem.indexOf(u8, tool, "write") != null or std.mem.eql(u8, tool, "repo.write")) {
        if (reduce_write) return false;
        return roleAllowsWriteScope(context.role, tool);
    }
    return roleAllowsRead(context.role);
}

pub fn roleAllowsRead(role: ?[]const u8) bool {
    const value = role orelse return false;
    return event_validation.roleAtLeast(value, "reader");
}

pub fn roleAllowsWriteScope(role: ?[]const u8, key: []const u8) bool {
    const value = role orelse return false;
    if (std.mem.eql(u8, key, "write-all")) return event_validation.roleAtLeast(value, "owner");
    if (std.mem.eql(u8, key, "*")) return event_validation.roleAtLeast(value, "owner");
    if (std.mem.indexOf(u8, key, "acl") != null or std.mem.indexOf(u8, key, "identity") != null) return event_validation.roleAtLeast(value, "owner");
    if (std.mem.indexOf(u8, key, "comment") != null or std.mem.indexOf(u8, key, "comments") != null) return event_validation.roleAtLeast(value, "reporter");
    return event_validation.roleAtLeast(value, "maintainer");
}

pub fn isWritePermissionValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "write") or
        std.mem.eql(u8, value, "write-all") or
        std.mem.endsWith(u8, value, ".write") or
        std.mem.indexOf(u8, value, "write") != null;
}

pub fn isReadPermissionValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "read") or
        std.mem.eql(u8, value, "read-all") or
        std.mem.endsWith(u8, value, ".read") or
        std.mem.indexOf(u8, value, "read") != null;
}

pub fn effectiveJobBackend(job: WorkflowJob) []const u8 {
    if (job.backend.len == 0 and job.steps.len != 0) return "shell";
    return job.backend;
}

pub fn workflowBackendSummary(workflow: Workflow) ?[]const u8 {
    if (workflow.dialect == .github_actions) return "github-actions";
    if (workflow.jobs.len == 0) return null;
    const first = effectiveJobBackend(workflow.jobs[0]);
    for (workflow.jobs[1..]) |job| {
        if (!std.mem.eql(u8, first, effectiveJobBackend(job))) return "mixed";
    }
    return first;
}

pub fn workflowPipelineSummary(workflow: Workflow) ?[]const u8 {
    for (workflow.jobs) |job| {
        if (std.mem.eql(u8, effectiveJobBackend(job), "agent")) {
            if (job.uses) |uses| return uses;
        }
    }
    return null;
}

pub fn localRunnerId(allocator: Allocator, repo: repo_mod.Repo) ![]u8 {
    const runner_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "runner" });
    defer allocator.free(runner_dir);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), runner_dir);

    const id_path = try std.fs.path.join(allocator, &.{ runner_dir, "id" });
    defer allocator.free(id_path);
    if (std.Io.Dir.cwd().readFileAlloc(@import("compat").io(), id_path, allocator, .limited(4 * 1024))) |bytes| {
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

pub fn writeRunnerId(id_path: []const u8, runner_id: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(@import("compat").io(), id_path, .{ .truncate = true });
    defer file.close(@import("compat").io());
    try file.writeStreamingAll(@import("compat").io(), runner_id);
    try file.writeStreamingAll(@import("compat").io(), "\n");
}

pub fn acquireRunClaim(allocator: Allocator, repo: repo_mod.Repo, run_id: []const u8) !RunClaim {
    const runner_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "runner", "claims" });
    defer allocator.free(runner_dir);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), runner_dir);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.claim", .{run_id});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ runner_dir, file_name });
    errdefer allocator.free(path);

    const file = std.Io.Dir.createFileAbsolute(@import("compat").io(), path, .{
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
    try file.writeStreamingAll(@import("compat").io(), run_id);
    try file.writeStreamingAll(@import("compat").io(), "\n");
    return .{ .allocator = allocator, .path = path, .file = file };
}

pub fn runCheckedInDirSimple(
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

pub fn sanitizePathSegment(allocator: Allocator, value: []const u8) ![]u8 {
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

pub fn githubEventNameForBackend(event_name: []const u8) []const u8 {
    if (std.mem.eql(u8, event_name, "workflow.schedule")) return "schedule";
    if (std.mem.eql(u8, event_name, "workflow.manual")) return "workflow_dispatch";
    return event_name;
}

pub fn isSafeRelativeBackendPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub fn writeActEventPayload(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    attempt_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
    event_name: []const u8,
    gitomi_event_type: []const u8,
    object_id: ?[]const u8,
    schedule_slot: ?[]const u8,
    permission_grant_json: []const u8,
    output_root: []const u8,
) ![]u8 {
    const events_dir = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, "action-events" });
    defer allocator.free(events_dir);
    try std.Io.Dir.cwd().createDirPath(@import("compat").io(), events_dir);

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
    try appendJsonFieldString(&payload, allocator, "ref", targets.code.target_ref orelse "", true);
    try appendJsonFieldString(&payload, allocator, "after", targets.code.target_oid, true);
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
            try appendMinimalPullRequestPayload(&payload, allocator, value, targets.code);
        }
    }
    try payload.appendSlice(allocator, "\"gitomi\":{");
    try appendJsonFieldString(&payload, allocator, "run_id", run_id, true);
    try appendJsonFieldString(&payload, allocator, "attempt_id", attempt_id, true);
    try appendJsonFieldString(&payload, allocator, "event_type", gitomi_event_type, true);
    try appendJsonFieldString(&payload, allocator, "normalized_event", gitomi_event_type, true);
    try appendJsonFieldString(&payload, allocator, "workflow_source_oid", targets.workflow.target_oid, true);
    if (targets.workflow.target_ref) |value| try appendJsonFieldString(&payload, allocator, "workflow_source_ref", value, true);
    try appendJsonFieldString(&payload, allocator, "target_oid", targets.code.target_oid, true);
    if (targets.code.target_ref) |value| try appendJsonFieldString(&payload, allocator, "target_ref", value, true);
    try appendJsonFieldString(&payload, allocator, "backend_output_dir", output_root, true);
    if (object_id) |value| try appendJsonFieldString(&payload, allocator, "object_id", value, true);
    if (schedule_slot) |value| try appendJsonFieldString(&payload, allocator, "schedule_slot", value, true);
    try appendJsonString(&payload, allocator, "permission_grant");
    try payload.append(allocator, ':');
    try payload.appendSlice(allocator, permission_grant_json);
    try payload.append(allocator, ',');
    if (payload.items[payload.items.len - 1] == ',') payload.items.len -= 1;
    try payload.appendSlice(allocator, "}}");

    const file = try std.Io.Dir.createFileAbsolute(@import("compat").io(), event_path, .{ .truncate = true });
    defer file.close(@import("compat").io());
    try file.writeStreamingAll(@import("compat").io(), payload.items);
    return event_path;
}

pub fn appendMinimalIssuePayload(buf: *std.ArrayList(u8), allocator: Allocator, object_id: []const u8) !void {
    try buf.appendSlice(allocator, "\"issue\":{");
    try appendJsonFieldString(buf, allocator, "id", object_id, true);
    try appendJsonFieldString(buf, allocator, "node_id", object_id, true);
    try appendJsonFieldUnsigned(buf, allocator, "number", 0, false);
    try buf.appendSlice(allocator, "},");
}

pub fn appendMinimalPullRequestPayload(buf: *std.ArrayList(u8), allocator: Allocator, object_id: []const u8, target: ResolvedTarget) !void {
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

pub const TimedRunOutput = struct {
    output: git.RunOutput,
    timed_out: bool = false,

    pub fn deinit(self: *TimedRunOutput) void {
        self.output.deinit();
    }
};

const TimeoutState = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn runCommandInDir(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
) !git.RunOutput {
    const result = try runCommandInDirTimed(allocator, argv, cwd, input, max_output_bytes, null);
    return result.output;
}

pub fn runCommandInDirTimed(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
    timeout_minutes: ?u64,
) !TimedRunOutput {
    return runCommandInDirWithEnvTimed(allocator, argv, cwd, input, max_output_bytes, &.{}, timeout_minutes);
}

pub fn runCommandInDirWithEnv(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
    env: []const KeyValuePair,
) !git.RunOutput {
    const result = try runCommandInDirWithEnvTimed(allocator, argv, cwd, input, max_output_bytes, env, null);
    return result.output;
}

pub fn runCommandInDirWithEnvTimed(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
    env: []const KeyValuePair,
    timeout_minutes: ?u64,
) !TimedRunOutput {
    var env_map: std.process.Environ.Map = undefined;
    var has_env_map = false;
    defer if (has_env_map) env_map.deinit();
    if (env.len != 0) {
        env_map = std.process.Environ.Map.init(allocator);
        has_env_map = true;
        try populateIsolatedChildEnv(&env_map);
        for (env) |entry| try env_map.put(entry.key, entry.value);
    }

    var child = try compat.spawnChild(argv, cwd, input, if (has_env_map) &env_map else null);
    defer child.kill(compat.io());

    var timeout_state = TimeoutState{ .child = &child };
    var timeout_thread: ?std.Thread = null;
    if (timeout_minutes) |minutes| {
        timeout_thread = try std.Thread.spawn(.{}, timeoutKillerThread, .{ &timeout_state, timeoutNanos(minutes) });
    }

    if (input) |bytes| {
        try compat.writeChildInput(&child, bytes);
    }

    const output = try compat.collectChildOutput(allocator, &child, max_output_bytes);
    errdefer {
        allocator.free(output.stdout);
        allocator.free(output.stderr);
    }
    const term = try child.wait(compat.io());
    timeout_state.done.store(true, .release);
    if (timeout_thread) |thread| thread.join();
    const timed_out = timeout_state.timed_out.load(.acquire);

    return .{
        .output = .{
            .allocator = allocator,
            .stdout = output.stdout,
            .stderr = output.stderr,
            .term = term,
        },
        .timed_out = timed_out,
    };
}

fn populateIsolatedChildEnv(env_map: *std.process.Environ.Map) !void {
    try env_map.put("PATH", "/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    try env_map.put("TMPDIR", "/tmp");
    try env_map.put("LANG", "C.UTF-8");
}

test "explicit command env is isolated from parent environment" {
    const allocator = std.testing.allocator;
    var test_env = [_]KeyValuePair{.{
        .key = try allocator.dupe(u8, "GITOMI_TEST_ENV"),
        .value = try allocator.dupe(u8, "present"),
    }};
    defer {
        allocator.free(test_env[0].key);
        allocator.free(test_env[0].value);
    }

    var result = try runCommandInDirWithEnv(std.testing.allocator, &.{
        "sh",
        "-lc",
        "printf '%s|%s|%s' \"$GITOMI_TEST_ENV\" \"${HOME-unset}\" \"$PATH\"",
    }, ".", null, 1024, test_env[0..]);
    defer result.deinit();

    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "present|unset|"));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "/run/current-system/sw/bin") != null);
}

fn timeoutNanos(minutes: u64) u64 {
    const ns_per_minute: u64 = 60 * std.time.ns_per_s;
    if (minutes > std.math.maxInt(u64) / ns_per_minute) return std.math.maxInt(u64);
    return minutes * ns_per_minute;
}

fn timeoutKillerThread(state: *TimeoutState, timeout_ns: u64) void {
    const quantum = 100 * std.time.ns_per_ms;
    var remaining = timeout_ns;
    while (remaining != 0 and !state.done.load(.acquire)) {
        const sleep_ns = @min(remaining, quantum);
        @import("compat").sleep(sleep_ns);
        remaining -= sleep_ns;
    }
    if (!state.done.load(.acquire)) {
        state.timed_out.store(true, .release);
        compat.terminateChildNoWait(state.child);
    }
}

pub fn loadPendingRequests(allocator: Allocator, repo: repo_mod.Repo) ![]RunRequest {
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

pub fn parseRunRequest(allocator: Allocator, run_id: []const u8, body: []const u8) !RunRequest {
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

    const workflow = event_json.jsonString(payload.get("workflow")) orelse return error.InvalidEventEnvelope;
    const event_name = event_json.jsonString(payload.get("event_name")) orelse "workflow_dispatch";
    const gitomi_event_type = event_json.jsonString(payload.get("gitomi_event_type")) orelse "";
    const schedule_slot = event_json.jsonString(payload.get("schedule_slot"));
    const workflow_source_ref = event_json.jsonString(payload.get("workflow_source_ref"));
    const workflow_source_oid = event_json.jsonString(payload.get("workflow_source_oid"));
    const source_workflow_from = event_json.jsonString(payload.get("source_workflow_from"));
    const source_code_from = event_json.jsonString(payload.get("source_code_from"));

    return .{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, run_id),
        .workflow = try allocator.dupe(u8, workflow),
        .workflow_source_ref = if (workflow_source_ref) |value| try allocator.dupe(u8, value) else null,
        .workflow_source_oid = if (workflow_source_oid) |value| try allocator.dupe(u8, value) else null,
        .target_ref = if (event_json.jsonString(payload.get("target_ref"))) |value| try allocator.dupe(u8, value) else null,
        .target_oid = if (event_json.jsonString(payload.get("target_oid"))) |value| try allocator.dupe(u8, value) else null,
        .event_name = try allocator.dupe(u8, event_name),
        .gitomi_event_type = try allocator.dupe(u8, gitomi_event_type),
        .schedule_slot = if (schedule_slot) |value| try allocator.dupe(u8, value) else null,
        .source_workflow_from = if (source_workflow_from) |value| try allocator.dupe(u8, value) else null,
        .source_code_from = if (source_code_from) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn selectRequests(allocator: Allocator, requests: []RunRequest, run_filter: ?[]const u8) ![]usize {
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
