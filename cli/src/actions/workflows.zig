const std = @import("std");
const errors = @import("../errors.zig");
const git = @import("../git.zig");
const io = @import("../io.zig");
const json_writer = @import("../json_writer.zig");
const util = @import("../util.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const appendJsonFieldString = json_writer.appendJsonFieldString;
const appendJsonFieldStringArray = json_writer.appendJsonFieldStringArray;

pub const ResolvedTarget = model.ResolvedTarget;
pub const Workflow = model.Workflow;
pub const WorkflowDialect = model.WorkflowDialect;
pub const WorkflowSourcePolicy = model.WorkflowSourcePolicy;
pub const WorkflowTrigger = model.WorkflowTrigger;
pub const WorkflowSchedule = model.WorkflowSchedule;
pub const KeyValuePair = model.KeyValuePair;
pub const WorkflowJob = model.WorkflowJob;
pub const WorkflowStep = model.WorkflowStep;
pub const EventContext = model.EventContext;
const freeKeyValuePairs = model.freeKeyValuePairs;

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

pub fn duplicateTarget(allocator: Allocator, target: ResolvedTarget) !ResolvedTarget {
    return .{
        .allocator = allocator,
        .target_ref = if (target.target_ref) |value| try allocator.dupe(u8, value) else null,
        .target_oid = try allocator.dupe(u8, target.target_oid),
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

        const workflow = try parseWorkflow(allocator, rev, path, contents);
        try validateLoadedWorkflow(workflow);
        try workflows.append(allocator, workflow);
    }

    return workflows.toOwnedSlice(allocator);
}

pub fn loadWorkflowAtPath(allocator: Allocator, rev: []const u8, path: []const u8) !?Workflow {
    if (!isWorkflowPath(path)) return null;
    const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ rev, path });
    defer allocator.free(spec);
    const contents = git.gitChecked(allocator, &.{ "show", spec }) catch |err| {
        if (err == CliError.GitFailed) return null;
        return err;
    };
    defer allocator.free(contents);
    const workflow = try parseWorkflow(allocator, rev, path, contents);
    try validateLoadedWorkflow(workflow);
    return workflow;
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

pub fn isWorkflowPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, ".github/workflows/") and !std.mem.startsWith(u8, path, ".gitomi/workflows/")) return false;
    return std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml");
}

pub fn workflowDialect(path: []const u8) WorkflowDialect {
    if (std.mem.startsWith(u8, path, ".gitomi/workflows/")) return .gitomi;
    return .github_actions;
}

pub fn validateLoadedWorkflow(workflow: Workflow) !void {
    try validateWorkflowSourcePolicy(workflow);
    if (workflow.triggers.len == 0) {
        try io.eprint("gt actions: workflow {s} must declare at least one trigger\n", .{workflow.path});
        return CliError.UserError;
    }
    if (workflow.dialect != .gitomi) return;
    if (workflow.name.len == 0) {
        try io.eprint("gt actions: native workflow {s} must declare name\n", .{workflow.path});
        return CliError.UserError;
    }
    if (workflow.jobs.len == 0) {
        try io.eprint("gt actions: native workflow {s} must declare jobs\n", .{workflow.path});
        return CliError.UserError;
    }
    for (workflow.jobs) |job| {
        if (job.backend.len == 0) {
            try io.eprint("gt actions: native job {s} in {s} must declare backend\n", .{ job.id, workflow.path });
            return CliError.UserError;
        }
        if (std.mem.eql(u8, job.backend, "shell") or std.mem.eql(u8, job.backend, "container")) {
            if (job.steps.len == 0) {
                try io.eprint("gt actions: native job {s} in {s} must declare steps\n", .{ job.id, workflow.path });
                return CliError.UserError;
            }
        }
        if (std.mem.eql(u8, job.backend, "agent") and job.uses == null) {
            try io.eprint("gt actions: native agent job {s} in {s} must declare uses\n", .{ job.id, workflow.path });
            return CliError.UserError;
        }
        if (std.mem.eql(u8, job.backend, "github-actions") and job.uses == null) {
            try io.eprint("gt actions: native github-actions job {s} in {s} must declare uses\n", .{ job.id, workflow.path });
            return CliError.UserError;
        }
    }
}

fn validateWorkflowSourcePolicy(workflow: Workflow) !void {
    if (!isValidSourcePolicyValue(workflow.source.workflow_from)) {
        try io.eprint("gt actions: workflow {s} has unsupported source.workflow_from '{s}'\n", .{ workflow.path, workflow.source.workflow_from });
        return CliError.UserError;
    }
    if (!isValidSourcePolicyValue(workflow.source.code_from)) {
        try io.eprint("gt actions: workflow {s} has unsupported source.code_from '{s}'\n", .{ workflow.path, workflow.source.code_from });
        return CliError.UserError;
    }
}

fn isValidSourcePolicyValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "target") or
        std.mem.eql(u8, value, "base") or
        std.mem.eql(u8, value, "head");
}

pub fn parseWorkflow(allocator: Allocator, source_oid: []const u8, path: []const u8, bytes: []const u8) !Workflow {
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
    var schedules: std.ArrayList(WorkflowSchedule) = .empty;
    errdefer {
        for (schedules.items) |*schedule| schedule.deinit();
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
    var current_schedule: ?usize = null;
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
            current_schedule = null;
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
                try addScheduleLine(allocator, &schedules, &current_schedule, clean);
                continue;
            }
            if (indent == on_child_indent.?) {
                in_schedule_block = false;
                schedule_indent = null;
                current_schedule = null;
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

    const display_name = name orelse try allocator.dupe(u8, if (dialect == .gitomi) "" else std.fs.path.basename(path));
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
        .source_oid = try allocator.dupe(u8, source_oid),
        .triggers = try triggers.toOwnedSlice(allocator),
        .trigger_defs = trigger_defs,
        .dialect = dialect,
        .source = source,
        .permissions = try permissions.toOwnedSlice(allocator),
        .jobs = try jobs.toOwnedSlice(allocator),
        .schedules = try schedules.toOwnedSlice(allocator),
    };
}

pub fn workflowMatches(workflow: Workflow, event_type: []const u8, event_name: []const u8) bool {
    return workflowMatchesContext(workflow, .{
        .event_type = event_type,
        .event_name = event_name,
    });
}

pub fn workflowMatchesContext(workflow: Workflow, context: EventContext) bool {
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

pub fn triggerNameMatches(trigger: []const u8, event_type: []const u8, event_name: []const u8, family: []const u8) bool {
    if (std.mem.eql(u8, trigger, event_type)) return true;
    if (std.mem.eql(u8, trigger, event_name)) return true;
    if (std.mem.eql(u8, trigger, family)) return true;
    if (std.mem.eql(u8, trigger, "schedule") and std.mem.eql(u8, event_type, "workflow.schedule")) return true;
    if (std.mem.eql(u8, trigger, "workflow_dispatch") and std.mem.eql(u8, event_type, "workflow.manual")) return true;
    if (std.mem.eql(u8, trigger, "pull_request") and std.mem.startsWith(u8, event_type, "pull.")) return true;
    if (std.mem.eql(u8, trigger, "issues") and std.mem.startsWith(u8, event_type, "issue.")) return true;
    return false;
}

pub fn triggerFiltersMatch(trigger: WorkflowTrigger, context: EventContext) bool {
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

pub fn anyGlobMatches(patterns: []const []u8, value: []const u8) bool {
    for (patterns) |pattern| {
        if (globMatches(pattern, value)) return true;
    }
    return false;
}

pub fn anyPathMatches(patterns: []const []u8, paths: []const []u8) bool {
    for (paths) |path| {
        if (anyGlobMatches(patterns, path)) return true;
    }
    return false;
}

pub fn allPathsMatch(patterns: []const []u8, paths: []const []u8) bool {
    for (paths) |path| {
        if (!anyGlobMatches(patterns, path)) return false;
    }
    return true;
}

pub fn anyLabelMatches(patterns: []const []u8, labels: []const []u8) bool {
    for (labels) |label| {
        if (anyGlobMatches(patterns, label)) return true;
    }
    return false;
}

pub fn globMatches(pattern: []const u8, value: []const u8) bool {
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

pub fn resolveWorkflowSelector(workflows: []Workflow, selector: []const u8) !Workflow {
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

pub fn workflowSelectorMatches(workflow: Workflow, selector: []const u8) bool {
    if (std.mem.eql(u8, workflow.path, selector)) return true;
    if (std.mem.eql(u8, workflow.name, selector)) return true;
    const base = std.fs.path.basename(workflow.path);
    if (std.mem.eql(u8, base, selector)) return true;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (std.mem.eql(u8, base[0..dot], selector)) return true;
    }
    return false;
}

pub fn githubEventName(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "push")) return "push";
    if (std.mem.startsWith(u8, event_type, "issue.")) return "issues";
    if (std.mem.startsWith(u8, event_type, "pull.")) return "pull_request";
    if (std.mem.eql(u8, event_type, "action.run_requested")) return "workflow_dispatch";
    if (std.mem.eql(u8, event_type, "workflow.manual")) return "workflow_dispatch";
    if (std.mem.eql(u8, event_type, "workflow.schedule")) return "schedule";
    return event_type;
}

pub fn githubActionValue(event_type: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, event_type, '.')) |dot| {
        if (dot + 1 < event_type.len) return event_type[dot + 1 ..];
    }
    return event_type;
}

pub fn eventFamily(event_type: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, event_type, '.')) |dot| return event_type[0..dot];
    return event_type;
}

pub fn workflowScheduleDue(workflow: Workflow, timestamp_seconds: i64) bool {
    for (workflow.schedules) |schedule| {
        if (cronMatches(schedule.cron, timestamp_seconds)) return true;
    }
    return false;
}

pub const UtcMinute = struct {
    minute: u8,
    hour: u8,
    day_of_month: u8,
    month: u8,
    day_of_week: u8,
};

pub fn cronMatches(expr: []const u8, timestamp_seconds: i64) bool {
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

pub fn cronFieldMatches(field: []const u8, value_raw: u8, min: u8, max: u8, sunday_alias: bool) bool {
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (cronPartMatches(part, value_raw, min, max, sunday_alias)) return true;
    }
    return false;
}

pub fn cronPartMatches(part: []const u8, value_raw: u8, min: u8, max: u8, sunday_alias: bool) bool {
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

pub fn normalizeCronValue(value: u8, sunday_alias: bool) u8 {
    if (sunday_alias and value == 0) return 7;
    return value;
}

pub fn utcMinute(timestamp_seconds: i64) UtcMinute {
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

pub const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

pub fn civilFromDays(days_since_epoch: i64) CivilDate {
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

pub fn isConclusion(value: []const u8) bool {
    return std.mem.eql(u8, value, "success") or
        std.mem.eql(u8, value, "failure") or
        std.mem.eql(u8, value, "cancelled") or
        std.mem.eql(u8, value, "skipped") or
        std.mem.eql(u8, value, "neutral") or
        std.mem.eql(u8, value, "timed_out") or
        std.mem.eql(u8, value, "action_required");
}

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const JobNestedBlock = enum {
    env,
    with,
    permissions,
    needs,
};

pub fn parseYamlKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = unquoteScalar(std.mem.trim(u8, line[0..colon], " \t\r\n"));
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

pub fn jobNestedBlockForKey(key: []const u8) ?JobNestedBlock {
    if (std.mem.eql(u8, key, "env")) return .env;
    if (std.mem.eql(u8, key, "with")) return .with;
    if (std.mem.eql(u8, key, "permissions")) return .permissions;
    if (std.mem.eql(u8, key, "needs")) return .needs;
    return null;
}

pub fn parseJobNestedLine(allocator: Allocator, job: *WorkflowJob, block: JobNestedBlock, line: []const u8) !void {
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

pub fn addTriggerBlockLine(allocator: Allocator, triggers: *std.ArrayList([]u8), line: []const u8) !void {
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

pub fn triggerNameFromBlockLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "-")) {
        const scalar = std.mem.trim(u8, line[1..], " \t\r\n");
        if (scalar.len == 0) return null;
        if (parseYamlKeyValue(scalar)) |kv| return kv.key;
        return unquoteScalar(scalar);
    }
    if (parseYamlKeyValue(line)) |kv| return kv.key;
    return unquoteScalar(line);
}

pub fn addScheduleLine(
    allocator: Allocator,
    schedules: *std.ArrayList(WorkflowSchedule),
    current_schedule: *?usize,
    line: []const u8,
) !void {
    var clean = line;
    const starts_item = std.mem.startsWith(u8, clean, "-");
    if (starts_item) {
        clean = std.mem.trim(u8, clean[1..], " \t\r\n");
        current_schedule.* = null;
    }
    if (clean.len >= 2 and clean[0] == '{' and clean[clean.len - 1] == '}') {
        var entries: []KeyValuePair = &.{};
        defer freeKeyValuePairs(allocator, entries);
        try parseInlineMappingIntoSlice(allocator, &entries, clean);
        const idx = try appendWorkflowSchedule(allocator, schedules, "");
        current_schedule.* = idx;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "cron")) {
                try setScheduleCron(allocator, &schedules.items[idx], entry.value);
            } else if (std.mem.eql(u8, entry.key, "timezone")) {
                try setScheduleTimezone(allocator, &schedules.items[idx], entry.value);
            }
        }
        if (schedules.items[idx].cron.len == 0) {
            if (schedules.pop()) |removed_value| {
                var removed = removed_value;
                removed.deinit();
            }
            current_schedule.* = null;
        }
        return;
    }
    if (parseYamlKeyValue(clean)) |kv| {
        if (std.mem.eql(u8, kv.key, "cron")) {
            const cron = unquoteScalar(kv.value);
            if (cron.len != 0) {
                const idx = if (starts_item or current_schedule.* == null)
                    try appendWorkflowSchedule(allocator, schedules, cron)
                else blk: {
                    const existing = current_schedule.*.?;
                    try setScheduleCron(allocator, &schedules.items[existing], cron);
                    break :blk existing;
                };
                current_schedule.* = idx;
            }
        } else if (std.mem.eql(u8, kv.key, "timezone")) {
            const timezone = unquoteScalar(kv.value);
            if (timezone.len != 0) {
                const idx = current_schedule.* orelse try appendWorkflowSchedule(allocator, schedules, "");
                try setScheduleTimezone(allocator, &schedules.items[idx], timezone);
                current_schedule.* = idx;
            }
        }
    }
}

pub fn appendWorkflowSchedule(allocator: Allocator, schedules: *std.ArrayList(WorkflowSchedule), cron: []const u8) !usize {
    const idx = schedules.items.len;
    try schedules.append(allocator, .{
        .allocator = allocator,
        .cron = try allocator.dupe(u8, cron),
        .timezone = try allocator.dupe(u8, "UTC"),
    });
    return idx;
}

pub fn setScheduleCron(allocator: Allocator, schedule: *WorkflowSchedule, cron: []const u8) !void {
    const owned = try allocator.dupe(u8, cron);
    allocator.free(schedule.cron);
    schedule.cron = owned;
}

pub fn setScheduleTimezone(allocator: Allocator, schedule: *WorkflowSchedule, timezone: []const u8) !void {
    const owned = try allocator.dupe(u8, timezone);
    allocator.free(schedule.timezone);
    schedule.timezone = owned;
}

pub fn appendWorkflowJob(allocator: Allocator, jobs: *std.ArrayList(WorkflowJob), line: []const u8) !?usize {
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

pub fn parseJobField(allocator: Allocator, job: *WorkflowJob, line: []const u8) !void {
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
    } else if (std.mem.eql(u8, kv.key, "steps")) {
        return;
    } else {
        try io.eprint("gt actions: native job {s} has unsupported field '{s}'\n", .{ job.id, kv.key });
        return CliError.UserError;
    }
}

pub fn parseStepLine(
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

pub fn appendWorkflowStep(allocator: Allocator, job: *WorkflowJob) !usize {
    const old = job.steps;
    const next = try allocator.alloc(WorkflowStep, old.len + 1);
    for (old, 0..) |step, idx| next[idx] = step;
    next[old.len] = .{ .allocator = allocator };
    allocator.free(old);
    job.steps = next;
    return old.len;
}

pub fn parseStepField(allocator: Allocator, step: *WorkflowStep, line: []const u8) !void {
    const kv = parseYamlKeyValue(line) orelse return;
    if (std.mem.eql(u8, kv.key, "name")) {
        if (step.name) |old| allocator.free(old);
        step.name = try allocator.dupe(u8, unquoteScalar(kv.value));
    } else if (std.mem.eql(u8, kv.key, "run")) {
        if (step.run) |old| allocator.free(old);
        step.run = try allocator.dupe(u8, unquoteScalar(kv.value));
    }
}

pub fn normalizeBackend(raw: []const u8) []const u8 {
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

pub fn addInlineTriggers(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8) !void {
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

pub fn addInlineTriggerParts(allocator: Allocator, triggers: *std.ArrayList([]u8), inner: []const u8, mapping: bool) !void {
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

pub fn addInlineTriggerPart(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8, mapping: bool) !void {
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

pub fn addTrigger(allocator: Allocator, triggers: *std.ArrayList([]u8), raw: []const u8) !void {
    var value = unquoteScalar(std.mem.trim(u8, raw, " \t\r\n"));
    if (value.len == 0) return;
    if (std.mem.indexOfAny(u8, value, " \t")) |space| value = value[0..space];
    if (value.len == 0 or std.mem.eql(u8, value, "{}")) return;
    for (triggers.items) |trigger| {
        if (std.mem.eql(u8, trigger, value)) return;
    }
    try triggers.append(allocator, try allocator.dupe(u8, value));
}

pub fn parseWorkflowTriggersDetailed(allocator: Allocator, bytes: []const u8) ![]WorkflowTrigger {
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

pub fn addInlineTriggerDefs(allocator: Allocator, triggers: *[]WorkflowTrigger, raw: []const u8) !void {
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

pub fn parseInlineTriggerMap(allocator: Allocator, triggers: *[]WorkflowTrigger, inner: []const u8) !void {
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

pub fn parseTriggerInlineFilters(allocator: Allocator, trigger: *WorkflowTrigger, raw: []const u8) !void {
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

pub fn ensureTriggerDefsFromNames(allocator: Allocator, triggers: *[]WorkflowTrigger, names: []const []u8) !void {
    for (names) |name| _ = try ensureTriggerDef(allocator, triggers, name);
}

pub fn ensureTriggerDef(allocator: Allocator, triggers: *[]WorkflowTrigger, raw_name: []const u8) !usize {
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

pub fn isTriggerFilterKey(key: []const u8) bool {
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

pub fn addTriggerFilterValues(allocator: Allocator, trigger: *WorkflowTrigger, key: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, key, "branches")) return parseStringListIntoSlice(allocator, &trigger.branches, raw);
    if (std.mem.eql(u8, key, "branches_ignore") or std.mem.eql(u8, key, "branches-ignore")) return parseStringListIntoSlice(allocator, &trigger.branches_ignore, raw);
    if (std.mem.eql(u8, key, "paths")) return parseStringListIntoSlice(allocator, &trigger.paths, raw);
    if (std.mem.eql(u8, key, "paths_ignore") or std.mem.eql(u8, key, "paths-ignore")) return parseStringListIntoSlice(allocator, &trigger.paths_ignore, raw);
    if (std.mem.eql(u8, key, "types")) return parseStringListIntoSlice(allocator, &trigger.types, raw);
    if (std.mem.eql(u8, key, "actors")) return parseStringListIntoSlice(allocator, &trigger.actors, raw);
    if (std.mem.eql(u8, key, "labels")) return parseStringListIntoSlice(allocator, &trigger.labels, raw);
}

pub fn parseStringListIntoSlice(allocator: Allocator, target: *[][]u8, raw: []const u8) !void {
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

pub fn parseInlineMappingIntoSlice(allocator: Allocator, target: *[]KeyValuePair, raw: []const u8) !void {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return;
    const parts = try splitTopLevel(allocator, value[1 .. value.len - 1], ',');
    defer git.freeStringList(allocator, parts);
    for (parts) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (parseYamlKeyValue(part)) |kv| try appendKeyValueToSlice(allocator, target, kv.key, unquoteScalar(kv.value));
    }
}

pub fn appendStringToSlice(allocator: Allocator, target: *[][]u8, value: []const u8) !void {
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

pub fn appendKeyValue(allocator: Allocator, list: *std.ArrayList(KeyValuePair), key: []const u8, value: []const u8) !void {
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
}

pub fn appendKeyValueToSlice(allocator: Allocator, target: *[]KeyValuePair, key: []const u8, value: []const u8) !void {
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

pub fn splitTopLevel(allocator: Allocator, inner: []const u8, delimiter: u8) ![][]u8 {
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

pub fn unquoteScalar(raw: []const u8) []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return value[1 .. value.len - 1];
    }
    return value;
}

pub fn stripYamlComment(line: []const u8) []const u8 {
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

pub fn lineIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}
