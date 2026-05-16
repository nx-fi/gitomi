const std = @import("std");
const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const git = @import("../git.zig");
const index = @import("../index.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const repo_mod = @import("../repo.zig");
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

    const permission_grant_json = try buildPermissionGrantJson(allocator, workflow);
    defer allocator.free(permission_grant_json);
    const event_path = try writeActEventPayload(allocator, repo, run_id, workflow, targets, event_name, gitomi_event_type, object_id, schedule_slot, permission_grant_json);
    defer {
        std.fs.deleteFileAbsolute(event_path) catch {};
        allocator.free(event_path);
    }

    var diagnostics = try RunDiagnostics.init(allocator);
    defer diagnostics.deinit();

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

    defer {
        if (git.gitChecked(allocator, &.{ "worktree", "remove", "--force", worktree_path })) |removed| {
            allocator.free(removed);
        } else |_| {}
    }

    var workflow_worktree_path: ?[]u8 = null;
    defer if (workflow_worktree_path) |path| {
        if (git.gitChecked(allocator, &.{ "worktree", "remove", "--force", path })) |removed| {
            allocator.free(removed);
        } else |_| {}
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
        .github_actions => try executeGithubActionsWorkflow(allocator, workflow, event_name, event_path, worktree_path, workflow_tree, options, &diagnostics),
        .gitomi => try executeGitomiWorkflow(allocator, repo, run_id, workflow, event_name, gitomi_event_type, event_path, worktree_path, workflow_tree, options, &diagnostics),
    };

    var result = ExecuteResult{ .allocator = allocator, .conclusion = conclusion };
    result.attempt_id = try allocator.dupe(u8, diagnostics.attempt_id);
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
    try argv.append(allocator, event_name);
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
    event_name: []const u8,
    gitomi_event_type: []const u8,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
    options: Options,
    diagnostics: *RunDiagnostics,
) ![]const u8 {
    _ = repo;
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
            const conclusion = try executeGitomiJob(allocator, run_id, workflow, job, event_path, worktree_path, workflow_worktree_path, options, diagnostics);
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
    run_id: []const u8,
    workflow: Workflow,
    job: WorkflowJob,
    event_path: []const u8,
    worktree_path: []const u8,
    workflow_worktree_path: []const u8,
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
        return try executeAgentJob(allocator, run_id, workflow, job, event_path, worktree_path, workflow_worktree_path, options, diagnostics);
    }
    if (std.mem.eql(u8, backend, "github-actions")) {
        try io.eprint("gt actions: native job {s} uses github-actions backend; use .github/workflows for act-backed workflows\n", .{job.id});
        return "action_required";
    }
    try io.eprint("gt actions: native job {s} uses unsupported backend '{s}'\n", .{ job.id, backend });
    return "action_required";
}

pub fn executeShellJob(
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
        var result = try runCommandInDirWithEnv(allocator, &.{ "sh", "-lc", command }, worktree_path, null, git.max_git_output, job.env);
        defer result.deinit();
        if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
        if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.stdout, result.stderr);
        if (result.exitCode() != 0) return "failure";
    }
    return "success";
}

pub fn executeContainerJob(
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
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        var env_args: std.ArrayList([]u8) = .empty;
        defer {
            for (env_args.items) |value| allocator.free(value);
            env_args.deinit(allocator);
        }
        try argv.appendSlice(allocator, &.{ "docker", "run", "--rm", "-v", volume, "-w", "/workspace" });
        for (job.env) |entry| {
            const env_arg = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value });
            errdefer allocator.free(env_arg);
            try env_args.append(allocator, env_arg);
            try argv.append(allocator, "-e");
            try argv.append(allocator, env_arg);
        }
        try argv.appendSlice(allocator, &.{ image, "sh", "-lc", command });
        var result = try runCommandInDir(allocator, argv.items, worktree_path, null, git.max_git_output);
        defer result.deinit();
        if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
        if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
        try addStepLogs(allocator, diagnostics, job.id, idx + 1, result.stdout, result.stderr);
        if (result.exitCode() != 0) return "failure";
    }
    return "success";
}

pub fn executeAgentJob(
    allocator: Allocator,
    run_id: []const u8,
    workflow: Workflow,
    job: WorkflowJob,
    event_path: []const u8,
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
        "--workflow-worktree",
        workflow_worktree_path,
    }, worktree_path, null, git.max_git_output);
    defer result.deinit();
    if (result.stdout.len != 0) try io.out("{s}", .{result.stdout});
    if (result.stderr.len != 0) try io.eprint("{s}", .{result.stderr});
    try addStepLogs(allocator, diagnostics, job.id, 1, result.stdout, result.stderr);
    return if (result.exitCode() == 0) "success" else "failure";
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
    try appendPermissionObject(&buf, allocator, manifest.permissions, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
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
        std.fs.deleteFileAbsolute(index_path) catch {};
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
    try appendJsonFieldString(&buf, allocator, "conclusion", conclusion, false);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

pub fn buildFinalOutputJson(allocator: Allocator, run_id: []const u8, attempt_id: []const u8, conclusion: []const u8) ![]u8 {
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

pub fn buildPermissionGrantJson(allocator: Allocator, workflow: Workflow) ![]u8 {
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

pub fn appendPermissionObject(buf: *std.ArrayList(u8), allocator: Allocator, permissions: []const KeyValuePair, reduce_write: bool) !void {
    try buf.append(allocator, '{');
    for (permissions, 0..) |entry, idx| {
        if (idx != 0) try buf.append(allocator, ',');
        try appendJsonString(buf, allocator, entry.key);
        try buf.append(allocator, ':');
        try appendJsonString(buf, allocator, effectivePermissionValue(entry.value, reduce_write));
    }
    try buf.append(allocator, '}');
}

pub fn effectivePermissionValue(value: []const u8, reduce_write: bool) []const u8 {
    if (!reduce_write) return value;
    if (std.mem.eql(u8, value, "write-all")) return "read-all";
    if (std.mem.indexOf(u8, value, "write") != null) return "read";
    return value;
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

pub fn writeRunnerId(id_path: []const u8, runner_id: []const u8) !void {
    const file = try std.fs.createFileAbsolute(id_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(runner_id);
    try file.writeAll("\n");
}

pub fn acquireRunClaim(allocator: Allocator, repo: repo_mod.Repo, run_id: []const u8) !RunClaim {
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

pub fn writeActEventPayload(
    allocator: Allocator,
    repo: repo_mod.Repo,
    run_id: []const u8,
    workflow: Workflow,
    targets: RunTargets,
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
    try appendJsonFieldString(&payload, allocator, "event_type", gitomi_event_type, true);
    try appendJsonFieldString(&payload, allocator, "workflow_source_oid", targets.workflow.target_oid, true);
    if (targets.workflow.target_ref) |value| try appendJsonFieldString(&payload, allocator, "workflow_source_ref", value, true);
    try appendJsonFieldString(&payload, allocator, "target_oid", targets.code.target_oid, true);
    if (targets.code.target_ref) |value| try appendJsonFieldString(&payload, allocator, "target_ref", value, true);
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

pub fn runCommandInDir(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
) !git.RunOutput {
    return runCommandInDirWithEnv(allocator, argv, cwd, input, max_output_bytes, &.{});
}

pub fn runCommandInDirWithEnv(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
    env: []const KeyValuePair,
) !git.RunOutput {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = if (input == null) .Ignore else .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var env_map: std.process.EnvMap = undefined;
    var has_env_map = false;
    defer if (has_env_map) env_map.deinit();
    if (env.len != 0) {
        env_map = try std.process.getEnvMap(allocator);
        has_env_map = true;
        for (env) |entry| try env_map.put(entry.key, entry.value);
        child.env_map = &env_map;
    }

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

    const workflow = event_mod.jsonString(payload.get("workflow")) orelse return error.InvalidEventEnvelope;
    const event_name = event_mod.jsonString(payload.get("event_name")) orelse "workflow_dispatch";
    const gitomi_event_type = event_mod.jsonString(payload.get("gitomi_event_type")) orelse "";
    const schedule_slot = event_mod.jsonString(payload.get("schedule_slot"));
    const workflow_source_ref = event_mod.jsonString(payload.get("workflow_source_ref"));
    const workflow_source_oid = event_mod.jsonString(payload.get("workflow_source_oid"));

    return .{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, run_id),
        .workflow = try allocator.dupe(u8, workflow),
        .workflow_source_ref = if (workflow_source_ref) |value| try allocator.dupe(u8, value) else null,
        .workflow_source_oid = if (workflow_source_oid) |value| try allocator.dupe(u8, value) else null,
        .target_ref = if (event_mod.jsonString(payload.get("target_ref"))) |value| try allocator.dupe(u8, value) else null,
        .target_oid = if (event_mod.jsonString(payload.get("target_oid"))) |value| try allocator.dupe(u8, value) else null,
        .event_name = try allocator.dupe(u8, event_name),
        .gitomi_event_type = try allocator.dupe(u8, gitomi_event_type),
        .schedule_slot = if (schedule_slot) |value| try allocator.dupe(u8, value) else null,
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
