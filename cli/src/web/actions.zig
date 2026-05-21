const std = @import("std");
const actions = @import("../actions.zig");
const errors = @import("../errors.zig");
const event_json = @import("../event/json.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const zwf = @import("../zwf.zig");

const Allocator = std.mem.Allocator;
const Button = shared.Button;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendRelativeTime = shared.appendRelativeTime;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const appendUrlEncoded = shared.appendUrlEncoded;
const class = shared.class;
const classAttr = shared.classAttr;
const ensureIndex = index.ensureIndex;
const groupedUnsigned = shared.groupedUnsigned;
const literalHref = shared.literalHref;
const queryValueOwned = shared.queryValueOwned;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const ActionsFilters = struct {
    allocator: Allocator,
    workflow: ?[]u8 = null,
    query: ?[]u8 = null,
    event: ?[]u8 = null,
    status: ?[]u8 = null,
    branch: ?[]u8 = null,
    actor: ?[]u8 = null,

    fn deinit(self: *ActionsFilters) void {
        if (self.workflow) |value| self.allocator.free(value);
        if (self.query) |value| self.allocator.free(value);
        if (self.event) |value| self.allocator.free(value);
        if (self.status) |value| self.allocator.free(value);
        if (self.branch) |value| self.allocator.free(value);
        if (self.actor) |value| self.allocator.free(value);
    }
};

const ActionsFilterKind = enum {
    workflow,
    event,
    status,
    branch,
    actor,
};

const ActionsHrefOverride = struct {
    param_name: ?[]const u8 = null,
    param_value: ?[]const u8 = null,
};

const ActionsFilterOption = struct {
    value: []const u8,
    label: []const u8,
    count: usize,
};

const RunRow = struct {
    allocator: Allocator,
    run_id: []u8,
    actor_principal: []u8,
    workflow: []u8,
    event_name: []u8,
    gitomi_event_type: []u8,
    target_ref: []u8,
    target_oid: []u8,
    requested_at: []u8,
    completed_at: []u8,
    conclusion: []u8,
    duration_seconds: ?i64,
    diagnostics_ref: []u8,
    diagnostics_oid: []u8,
    attempt_id: []u8,
    runner_id: []u8,

    fn deinit(self: *RunRow) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.workflow);
        self.allocator.free(self.event_name);
        self.allocator.free(self.gitomi_event_type);
        self.allocator.free(self.target_ref);
        self.allocator.free(self.target_oid);
        self.allocator.free(self.requested_at);
        self.allocator.free(self.completed_at);
        self.allocator.free(self.conclusion);
        self.allocator.free(self.diagnostics_ref);
        self.allocator.free(self.diagnostics_oid);
        self.allocator.free(self.attempt_id);
        self.allocator.free(self.runner_id);
    }
};

const ActionsStats = struct {
    workflows: usize,
    runs: usize,
    pending: usize,
    successful: usize,
    failed: usize,
    other: usize,
};

pub fn renderActionsPage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8) ![]u8 {
    return renderActionsPageWithMessage(allocator, repo, target, csrf_token, null);
}

fn renderActionsPageWithMessage(allocator: Allocator, repo: Repo, target: []const u8, csrf_token: []const u8, message: ?[]const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Pipelines", "actions", "/pipelines")) |body| return body;
    try ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const workflows = try loadHeadWorkflowsOrEmpty(allocator);
    defer actions.freeWorkflows(allocator, workflows);

    var runs = try loadRunRows(allocator, repo);
    defer {
        for (runs.items) |*row| row.deinit();
        runs.deinit(allocator);
    }

    var filters = try actionsFiltersFromTarget(allocator, target);
    defer filters.deinit();

    const pending = actions.countPendingRequests(allocator, repo) catch 0;
    const stats = actionsStats(workflows.len, runs.items, pending);

    try appendShellStart(&buf, allocator, repo, "Pipelines", "actions");
    try buf.appendSlice(allocator, "<div class=\"project-page-layout actions-layout\">");
    try appendActionsSidebar(&buf, allocator, workflows, runs.items, filters);
    try buf.appendSlice(allocator, "<div class=\"project-page-content actions-main\">");
    if (message) |value| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = value });
    } else if (std.mem.indexOf(u8, target, "requested=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Pipeline run requested.</div>");
    } else if (std.mem.indexOf(u8, target, "run=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Pending pipeline runs processed.</div>");
    }
    try appendActionsMain(&buf, allocator, workflows, runs.items, filters, stats, csrf_token);
    try buf.appendSlice(allocator, "</div></div>");

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadHeadWorkflows(allocator: Allocator) ![]actions.Workflow {
    var target = try actions.resolveTarget(allocator, null, null);
    defer target.deinit();
    return try actions.loadWorkflows(allocator, target.target_oid);
}

fn loadHeadWorkflowsOrEmpty(allocator: Allocator) ![]actions.Workflow {
    return loadHeadWorkflows(allocator) catch |err| switch (err) {
        CliError.UserError, CliError.GitFailed => try allocator.alloc(actions.Workflow, 0),
        else => return err,
    };
}

fn appendActionsSidebar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    workflows: []const actions.Workflow,
    runs: []const RunRow,
    filters: ActionsFilters,
) !void {
    try buf.appendSlice(allocator,
        \\<aside class="project-page-sidebar actions-sidebar">
        \\  <nav class="project-page-tabs actions-workflow-nav" aria-label="Pipelines">
    );
    try appendActionsSidebarLink(buf, allocator, filters, "All pipelines", null, filters.workflow == null, runs.len);
    for (workflows) |workflow| {
        try appendActionsSidebarLink(
            buf,
            allocator,
            filters,
            workflow.name,
            workflow.path,
            if (filters.workflow) |selected| std.mem.eql(u8, selected, workflow.path) else false,
            workflowRunCount(workflow.path, runs),
        );
    }
    if (workflows.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"actions-sidebar-empty\">No pipeline files found.</p>");
    }
    try appendTemplate(buf, allocator,
        \\  </nav>
        \\</aside>
    , .{});
}

fn appendActionsManualRun(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    workflows: []const actions.Workflow,
    filters: ActionsFilters,
    stats: ActionsStats,
    csrf_token: []const u8,
) !void {
    try buf.appendSlice(allocator, "  <details class=\"actions-manual-run\"");
    if (filters.workflow != null) try buf.appendSlice(allocator, " open");
    try appendTemplate(buf, allocator,
        \\>
        \\    <summary>Request pipeline</summary>
        \\    <form method="post" action="/pipelines/request">
        \\      <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\      <label>Pipeline<select name="workflow" required>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf_token = csrf_token });
    for (workflows) |workflow| {
        try appendTemplate(buf, allocator, "<option value=\"{path}\"", .{
            .path = workflow.path,
        });
        if (filters.workflow) |selected| {
            if (std.mem.eql(u8, selected, workflow.path)) try buf.appendSlice(allocator, " selected");
        }
        try appendTemplate(buf, allocator, ">{name}</option>", .{ .name = workflow.name });
    }
    if (workflows.len == 0) {
        try buf.appendSlice(allocator, "<option value=\"\" disabled selected>No pipelines found</option>");
    }
    try buf.appendSlice(allocator,
        \\      </select></label>
        \\      <label>Event<input name="event" value="workflow_dispatch"></label>
        \\      <label>Ref<input name="ref" value="HEAD"></label>
        \\      <div class="form-actions">
    );
    if (workflows.len == 0) {
        try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\" disabled>Request run</button>");
    } else {
        try buf.appendSlice(allocator, "<button class=\"button primary\" type=\"submit\">Request run</button>");
    }
    try appendTemplate(buf, allocator,
        \\      </div>
        \\    </form>
        \\    <form method="post" action="/pipelines/run-requested">
        \\      <input type="hidden" name="{csrf_field}" value="{csrf_token}">
        \\      <button class="button secondary" type="submit">Run pending ({pending})</button>
        \\    </form>
        \\  </details>
    , .{ .csrf_field = zwf.csrf.field_name, .csrf_token = csrf_token, .pending = stats.pending });
}

fn appendActionsStatus(buf: *std.ArrayList(u8), allocator: Allocator, stats: ActionsStats) !void {
    try appendTemplate(buf, allocator,
        \\  <div class="actions-status">
        \\    <h2>Status</h2>
        \\    <div class="actions-status-grid">
        \\      <span><strong>{workflows}</strong><small>Pipelines</small></span>
        \\      <span><strong>{runs}</strong><small>Runs</small></span>
        \\      <span><strong>{pending}</strong><small>Pending</small></span>
        \\      <span><strong>{successful}</strong><small>Successful</small></span>
        \\      <span><strong>{failed}</strong><small>Failed</small></span>
        \\      <span><strong>{other}</strong><small>Other</small></span>
        \\    </div>
        \\  </div>
    , .{
        .workflows = groupedUnsigned(@intCast(stats.workflows)),
        .runs = groupedUnsigned(@intCast(stats.runs)),
        .pending = groupedUnsigned(@intCast(stats.pending)),
        .successful = groupedUnsigned(@intCast(stats.successful)),
        .failed = groupedUnsigned(@intCast(stats.failed)),
        .other = groupedUnsigned(@intCast(stats.other)),
    });
}

fn appendActionsSidebarLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: ActionsFilters,
    label: []const u8,
    workflow: ?[]const u8,
    active: bool,
    count: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="
    , .{ .class_attr = classAttr("actions-workflow-link", &.{class("active", active)}) });
    try appendActionsHref(buf, allocator, filters, .{
        .param_name = "workflow",
        .param_value = workflow,
    });
    try appendTemplate(buf, allocator,
        \\"><span class="button-icon icon-workflow" aria-hidden="true"></span><span class="actions-workflow-label">{label}</span><small>{count}</small></a>
    , .{
        .label = label,
        .count = count,
    });
}

fn appendActionsMain(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    workflows: []const actions.Workflow,
    runs: []const RunRow,
    filters: ActionsFilters,
    stats: ActionsStats,
    csrf_token: []const u8,
) !void {
    const visible_count = filteredRunCount(runs, filters);
    const selected_title = if (filters.workflow) |selected| workflowDisplayName(workflows, selected) else "All pipelines";
    const query = filters.query orelse "";

    try buf.appendSlice(allocator, "<section class=\"panel actions-panel\">");
    try appendSectionHead(buf, allocator, "Pipelines", selected_title, Button{
        .label = "New pipeline",
        .href = literalHref("/code?ref=HEAD&path=.github/workflows"),
        .kind = "primary",
    });
    try appendTemplate(buf, allocator,
        \\<div class="actions-main-body">
        \\<div class="actions-main-head">
        \\  <p>{subtitle}</p>
        \\  <form class="actions-filter" method="get" action="/pipelines">
    , .{
        .subtitle = if (filters.workflow == null) "Showing runs from all pipelines" else "Showing runs from the selected pipeline",
    });
    try appendActionsFilterHiddenInputs(buf, allocator, filters);
    try appendTemplate(buf, allocator,
        \\    <span class="actions-filter-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" placeholder="Filter pipeline runs" aria-label="Filter pipeline runs">
        \\  </form>
        \\</div>
    , .{
        .query = query,
    });

    try appendActionsStatus(buf, allocator, stats);
    try appendActionsManualRun(buf, allocator, workflows, filters, stats, csrf_token);
    try appendWorkflowOverview(buf, allocator, workflows, runs, filters);

    try appendTemplate(buf, allocator,
        \\<section class="actions-runs-panel">
        \\  <div class="actions-runs-head">
        \\    <strong>{count} pipeline {run_label}</strong>
        \\    <div class="actions-runs-filters">
    , .{
        .count = groupedUnsigned(@intCast(visible_count)),
        .run_label = if (visible_count == 1) "run" else "runs",
    });
    try appendActionsFilterMenu(buf, allocator, workflows, runs, filters, .workflow);
    try appendActionsFilterMenu(buf, allocator, workflows, runs, filters, .event);
    try appendActionsFilterMenu(buf, allocator, workflows, runs, filters, .status);
    try appendActionsFilterMenu(buf, allocator, workflows, runs, filters, .branch);
    try appendActionsFilterMenu(buf, allocator, workflows, runs, filters, .actor);
    try buf.appendSlice(allocator,
        \\    </div>
        \\  </div>
    );

    var shown: usize = 0;
    for (runs) |row| {
        if (!runMatchesFilters(row, filters)) continue;
        try appendRunRow(buf, allocator, workflows, row, csrf_token);
        shown += 1;
    }
    if (shown == 0) {
        if (hasRestrictiveActionsFilters(filters)) {
            try appendEmptyState(buf, allocator, "No matching pipeline runs.", "Change or clear filters to widen the run list.");
        } else {
            try appendEmptyState(buf, allocator, "No pipeline runs yet.", "Request a pipeline run or start the actions daemon to populate this list.");
        }
    }
    try buf.appendSlice(allocator, "</section></div></section>");
}

fn appendActionsFilterHiddenInputs(buf: *std.ArrayList(u8), allocator: Allocator, filters: ActionsFilters) !void {
    try appendActionsHiddenInputIfPresent(buf, allocator, "pipeline", filters.workflow);
    try appendActionsHiddenInputIfPresent(buf, allocator, "event", filters.event);
    try appendActionsHiddenInputIfPresent(buf, allocator, "status", filters.status);
    try appendActionsHiddenInputIfPresent(buf, allocator, "branch", filters.branch);
    try appendActionsHiddenInputIfPresent(buf, allocator, "actor", filters.actor);
}

fn appendActionsHiddenInputIfPresent(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: ?[]const u8) !void {
    if (value) |payload| {
        try appendTemplate(buf, allocator,
            \\    <input type="hidden" name="{name}" value="{value}">
        , .{
            .name = name,
            .value = payload,
        });
    }
}

fn appendActionsFilterMenu(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    workflows: []const actions.Workflow,
    runs: []const RunRow,
    filters: ActionsFilters,
    kind: ActionsFilterKind,
) !void {
    const active = actionsFilterValue(filters, kind);
    try appendTemplate(buf, allocator,
        \\<details{class_attr} data-popover-menu><summary>{label}
    , .{
        .class_attr = classAttr("actions-filter-menu", &.{class("active", active != null)}),
        .label = actionsFilterLabel(kind),
    });
    if (active) |value| {
        try appendTemplate(buf, allocator, ": {value}", .{
            .value = actionsFilterDisplayLabel(workflows, kind, value),
        });
    }
    try buf.appendSlice(allocator, "</summary><div class=\"actions-filter-popover\" role=\"menu\">");

    try appendActionsFilterMenuLink(
        buf,
        allocator,
        filters,
        kind,
        null,
        actionsFilterAllLabel(kind),
        countRunsMatchingFiltersExcept(runs, filters, kind),
        active == null,
    );

    var options: std.ArrayList(ActionsFilterOption) = .empty;
    defer options.deinit(allocator);
    for (runs) |row| {
        if (!runMatchesFiltersExcept(row, filters, kind)) continue;
        const value = actionsRunFilterValue(row, kind);
        if (value.len == 0) continue;
        if (findActionsFilterOptionIndex(options.items, value)) |option_index| {
            options.items[option_index].count += 1;
            continue;
        }
        try options.append(allocator, .{
            .value = value,
            .label = actionsFilterDisplayLabel(workflows, kind, value),
            .count = 1,
        });
    }
    std.mem.sort(ActionsFilterOption, options.items, {}, actionsFilterOptionLessThan);

    for (options.items) |option| {
        try appendActionsFilterMenuLink(
            buf,
            allocator,
            filters,
            kind,
            option.value,
            option.label,
            option.count,
            active != null and std.mem.eql(u8, active.?, option.value),
        );
    }
    if (options.items.len == 0) {
        try buf.appendSlice(allocator, "<span class=\"actions-filter-empty\">No values</span>");
    }
    try buf.appendSlice(allocator, "</div></details>");
}

fn appendActionsFilterMenuLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    filters: ActionsFilters,
    kind: ActionsFilterKind,
    value: ?[]const u8,
    label: []const u8,
    count: usize,
    selected: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" role="menuitem" href="
    , .{ .classes = shared.classes("actions-filter-option", &.{shared.class("selected", selected)}) });
    try appendActionsHref(buf, allocator, filters, .{
        .param_name = actionsFilterParamName(kind),
        .param_value = value,
    });
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><small>{count}</small></a>
    , .{
        .label = label,
        .count = groupedUnsigned(@intCast(count)),
    });
}

fn appendRunRow(buf: *std.ArrayList(u8), allocator: Allocator, workflows: []const actions.Workflow, row: RunRow, csrf_token: []const u8) !void {
    const workflow_name = workflowDisplayName(workflows, row.workflow);
    const title = try runTitleOwned(allocator, workflow_name, row);
    defer allocator.free(title);
    const short_run = row.run_id[0..@min(row.run_id.len, 12)];
    const branch = if (row.target_ref.len != 0) row.target_ref else row.target_oid[0..@min(row.target_oid.len, 12)];
    const duration = try durationLabelOwned(allocator, row);
    defer allocator.free(duration);

    try appendTemplate(buf, allocator,
        \\<article class="actions-run-row">
        \\  <div class="actions-run-status actions-run-status-{status_class}" title="{conclusion}" aria-label="{conclusion}"></div>
        \\  <div class="actions-run-content">
        \\    <div class="actions-run-title-line">
        \\      <strong>{title}</strong>
        \\      <span class="actions-run-badge">{event_name}</span>
        \\    </div>
        \\    <p><span>{workflow}</span> <span class="actions-run-number">#{run_id}</span> by <strong>{actor}</strong></p>
        \\  </div>
        \\  <span class="actions-branch-pill">{branch}</span>
        \\  <div class="actions-run-time">
    , .{
        .status_class = conclusionClass(row.conclusion),
        .conclusion = row.conclusion,
        .title = title,
        .event_name = row.event_name,
        .workflow = workflow_name,
        .run_id = short_run,
        .actor = row.actor_principal,
        .branch = branch,
    });
    if (row.requested_at.len != 0) {
        try appendRelativeTime(buf, allocator, row.requested_at);
    } else {
        try buf.appendSlice(allocator, "<span>Unknown time</span>");
    }
    try appendTemplate(buf, allocator,
        \\    <small>{duration}</small>
        \\  </div>
        \\  <details class="actions-run-menu-wrap" data-popover-menu>
        \\    <summary class="actions-run-menu" aria-label="Run actions" title="Run actions"></summary>
        \\    <div class="actions-run-popover" role="menu">
    , .{ .duration = duration });
    try appendRunMenu(buf, allocator, row, csrf_token);
    try buf.appendSlice(allocator, "</div></details></article>");
}

fn appendRunMenu(buf: *std.ArrayList(u8), allocator: Allocator, row: RunRow, csrf_token: []const u8) !void {
    if (row.workflow.len != 0) {
        try appendRunMenuCodeLink(buf, allocator, "Pipeline file", "HEAD", row.workflow);
    } else {
        try appendRunMenuDisabled(buf, allocator, "Pipeline file");
    }

    if (row.target_oid.len != 0) {
        try appendTemplate(buf, allocator, "<a role=\"menuitem\" href=\"/commit?sha=", .{});
        try appendUrlEncoded(buf, allocator, row.target_oid);
        try appendTemplate(buf, allocator, "\"><span class=\"actions-menu-icon actions-menu-icon-commit\" aria-hidden=\"true\"></span><span>Target commit</span></a>", .{});
    } else {
        try appendRunMenuDisabled(buf, allocator, "Target commit");
    }

    if (row.diagnostics_ref.len != 0) {
        try appendRunMenuCodeLink(buf, allocator, "Diagnostics", row.diagnostics_ref, "run.json");
    } else {
        try appendRunMenuDisabled(buf, allocator, "Diagnostics");
    }

    try buf.appendSlice(allocator, "<div class=\"actions-run-popover-divider\" aria-hidden=\"true\"></div>");
    try appendRunRequestForm(buf, allocator, row, "Rerun pipeline", false, csrf_token);
    try appendRunRequestForm(buf, allocator, row, "Run now", true, csrf_token);
}

fn appendRunMenuCodeLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, ref: []const u8, path: []const u8) !void {
    try appendTemplate(buf, allocator, "<a role=\"menuitem\" href=\"/code?ref=", .{});
    try appendUrlEncoded(buf, allocator, ref);
    if (path.len != 0) {
        try buf.appendSlice(allocator, "&amp;path=");
        try appendUrlEncoded(buf, allocator, path);
    }
    try appendTemplate(buf, allocator, "\"><span class=\"actions-menu-icon actions-menu-icon-file\" aria-hidden=\"true\"></span><span>{label}</span></a>", .{ .label = label });
}

fn appendRunMenuDisabled(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button type="button" role="menuitem" disabled><span class="actions-menu-icon actions-menu-icon-file" aria-hidden="true"></span><span>{label}</span></button>
    , .{ .label = label });
}

fn appendRunRequestForm(buf: *std.ArrayList(u8), allocator: Allocator, row: RunRow, label: []const u8, pending_only: bool, csrf_token: []const u8) !void {
    const disabled = pending_only and !std.mem.eql(u8, row.conclusion, "pending");
    if (pending_only) {
        try appendTemplate(buf, allocator,
            \\<form method="post" action="/pipelines/run-requested"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="run" value="{run_id}">
        , .{ .csrf_field = zwf.csrf.field_name, .csrf_token = csrf_token, .run_id = row.run_id });
    } else {
        try appendTemplate(buf, allocator,
            \\<form method="post" action="/pipelines/request"><input type="hidden" name="{csrf_field}" value="{csrf_token}"><input type="hidden" name="workflow" value="{workflow}"><input type="hidden" name="event" value="{event_name}">
        , .{
            .csrf_field = zwf.csrf.field_name,
            .csrf_token = csrf_token,
            .workflow = row.workflow,
            .event_name = row.event_name,
        });
        if (row.target_ref.len != 0) {
            try appendTemplate(buf, allocator, "<input type=\"hidden\" name=\"ref\" value=\"{target_ref}\">", .{ .target_ref = row.target_ref });
        } else if (row.target_oid.len != 0) {
            try appendTemplate(buf, allocator, "<input type=\"hidden\" name=\"oid\" value=\"{target_oid}\">", .{ .target_oid = row.target_oid });
        }
    }
    try appendTemplate(buf, allocator,
        \\<button type="submit" role="menuitem"
    , .{});
    if (disabled or row.workflow.len == 0) try buf.appendSlice(allocator, " disabled");
    try appendTemplate(buf, allocator,
        \\><span class="actions-menu-icon actions-menu-icon-run" aria-hidden="true"></span><span>{label}</span></button></form>
    , .{ .label = label });
}

fn appendWorkflowOverview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    workflows: []const actions.Workflow,
    runs: []const RunRow,
    filters: ActionsFilters,
) !void {
    if (workflows.len == 0) return;

    if (filters.workflow) |selected| {
        if (findWorkflow(workflows, selected)) |workflow| {
            try appendSelectedWorkflow(buf, allocator, workflow, workflowRunCount(workflow.path, runs));
            return;
        }
    }

    try appendTemplate(buf, allocator,
        \\<section class="actions-workflow-overview" aria-label="Pipeline definitions">
        \\  <div class="actions-section-head">
        \\    <h2>Pipelines</h2>
        \\    <span>{count} discovered</span>
        \\  </div>
        \\  <div class="actions-workflow-grid">
    , .{ .count = groupedUnsigned(@intCast(workflows.len)) });
    for (workflows) |workflow| {
        try appendWorkflowCard(buf, allocator, filters, workflow, workflowRunCount(workflow.path, runs));
    }
    try buf.appendSlice(allocator, "</div></section>");
}

fn appendSelectedWorkflow(buf: *std.ArrayList(u8), allocator: Allocator, workflow: actions.Workflow, run_count: usize) !void {
    try appendTemplate(buf, allocator,
        \\<section class="actions-workflow-detail">
    , .{});
    try shared.appendDetailBackButton(buf, allocator, shared.literalHref("/pipelines"), "Back to pipelines");
    try appendTemplate(buf, allocator,
        \\  <div class="actions-workflow-detail-head">
        \\    <div>
        \\      <span class="actions-kicker">{dialect}</span>
        \\      <h2>{name}</h2>
        \\      <code>{path}</code>
        \\    </div>
        \\    <a class="button secondary" href="/code?ref=HEAD&amp;path=
    , .{
        .dialect = workflowDialectLabel(workflow.dialect),
        .name = workflow.name,
        .path = workflow.path,
    });
    try appendUrlEncoded(buf, allocator, workflow.path);
    try buf.appendSlice(allocator,
        \\">View file</a>
        \\  </div>
        \\  <div class="actions-workflow-meta">
    );
    try appendWorkflowMetaItem(buf, allocator, "Runs", groupedUnsigned(@intCast(run_count)));
    try appendWorkflowMetaItem(buf, allocator, "Triggers", groupedUnsigned(@intCast(workflow.triggers.len)));
    try appendWorkflowMetaItem(buf, allocator, "Jobs", groupedUnsigned(@intCast(workflow.jobs.len)));
    try appendWorkflowMetaItem(buf, allocator, "Source", workflowSourceLabel(workflow));
    try buf.appendSlice(allocator, "</div>");
    try appendWorkflowTriggerSection(buf, allocator, workflow);
    try appendWorkflowJobs(buf, allocator, workflow);
    try buf.appendSlice(allocator, "</section>");
}

fn appendWorkflowCard(buf: *std.ArrayList(u8), allocator: Allocator, filters: ActionsFilters, workflow: actions.Workflow, run_count: usize) !void {
    try appendTemplate(buf, allocator,
        \\<article class="actions-workflow-card">
        \\  <div class="actions-workflow-card-head">
        \\    <a href="
    , .{});
    try appendActionsHref(buf, allocator, filters, .{
        .param_name = "workflow",
        .param_value = workflow.path,
    });
    try appendTemplate(buf, allocator,
        \\">{name}</a>
        \\    <span>{dialect}</span>
        \\  </div>
        \\  <code>{path}</code>
        \\  <div class="actions-workflow-card-pills">
    , .{
        .name = workflow.name,
        .dialect = workflowDialectLabel(workflow.dialect),
        .path = workflow.path,
    });
    try appendTriggerPills(buf, allocator, workflow.triggers, 4);
    try appendTemplate(buf, allocator,
        \\  </div>
        \\  <dl class="actions-workflow-card-stats">
        \\    <div><dt>Runs</dt><dd>{runs}</dd></div>
        \\    <div><dt>Jobs</dt><dd>{jobs}</dd></div>
        \\    <div><dt>Source</dt><dd>{source}</dd></div>
        \\  </dl>
        \\</article>
    , .{
        .runs = groupedUnsigned(@intCast(run_count)),
        .jobs = groupedUnsigned(@intCast(workflow.jobs.len)),
        .source = workflowSourceLabel(workflow),
    });
}

fn appendWorkflowMetaItem(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, value: anytype) !void {
    try appendTemplate(buf, allocator,
        \\<span><small>{label}</small><strong>{value}</strong></span>
    , .{
        .label = label,
        .value = value,
    });
}

fn appendWorkflowTriggerSection(buf: *std.ArrayList(u8), allocator: Allocator, workflow: actions.Workflow) !void {
    try buf.appendSlice(allocator, "<div class=\"actions-workflow-section\"><h3>Triggers</h3>");
    if (workflow.triggers.len == 0) {
        try buf.appendSlice(allocator, "<p>No triggers declared.</p></div>");
        return;
    }
    try buf.appendSlice(allocator, "<div class=\"actions-trigger-list\">");
    for (workflow.trigger_defs) |trigger| {
        try appendTriggerDetail(buf, allocator, trigger);
    }
    try buf.appendSlice(allocator, "</div></div>");
}

fn appendTriggerDetail(buf: *std.ArrayList(u8), allocator: Allocator, trigger: actions.WorkflowTrigger) !void {
    try appendTemplate(buf, allocator,
        \\<div class="actions-trigger-detail">
        \\  <strong>{name}</strong>
    , .{ .name = trigger.name });
    if (trigger.branches.len == 0 and
        trigger.branches_ignore.len == 0 and
        trigger.paths.len == 0 and
        trigger.paths_ignore.len == 0 and
        trigger.types.len == 0 and
        trigger.actors.len == 0 and
        trigger.labels.len == 0)
    {
        try buf.appendSlice(allocator, "<span>No filters</span></div>");
        return;
    }
    try buf.appendSlice(allocator, "<dl>");
    try appendStringListTerm(buf, allocator, "Types", trigger.types);
    try appendStringListTerm(buf, allocator, "Branches", trigger.branches);
    try appendStringListTerm(buf, allocator, "Ignored branches", trigger.branches_ignore);
    try appendStringListTerm(buf, allocator, "Paths", trigger.paths);
    try appendStringListTerm(buf, allocator, "Ignored paths", trigger.paths_ignore);
    try appendStringListTerm(buf, allocator, "Actors", trigger.actors);
    try appendStringListTerm(buf, allocator, "Labels", trigger.labels);
    try buf.appendSlice(allocator, "</dl></div>");
}

fn appendWorkflowJobs(buf: *std.ArrayList(u8), allocator: Allocator, workflow: actions.Workflow) !void {
    try buf.appendSlice(allocator, "<div class=\"actions-workflow-section\"><h3>Jobs</h3>");
    if (workflow.jobs.len == 0) {
        try appendTemplate(buf, allocator, "<p>{message}</p></div>", .{
            .message = if (workflow.dialect == .github_actions) "Job details are delegated to the GitHub Actions-compatible runner." else "No native jobs declared.",
        });
        return;
    }
    try buf.appendSlice(allocator, "<div class=\"actions-job-list\">");
    for (workflow.jobs) |job| {
        try appendWorkflowJob(buf, allocator, job);
    }
    try buf.appendSlice(allocator, "</div></div>");
}

fn appendWorkflowJob(buf: *std.ArrayList(u8), allocator: Allocator, job: actions.WorkflowJob) !void {
    try appendTemplate(buf, allocator,
        \\<article class="actions-job-row">
        \\  <div>
        \\    <strong>{id}</strong>
        \\    <span>{backend}</span>
        \\  </div>
    , .{
        .id = job.id,
        .backend = effectiveJobBackendLabel(job),
    });
    if (job.uses) |uses| {
        try appendTemplate(buf, allocator, "<code>{uses}</code>", .{ .uses = uses });
    } else if (job.steps.len != 0) {
        try appendTemplate(buf, allocator, "<small>{count} {step_label}</small>", .{
            .count = groupedUnsigned(@intCast(job.steps.len)),
            .step_label = if (job.steps.len == 1) "step" else "steps",
        });
    } else {
        try buf.appendSlice(allocator, "<small>No steps</small>");
    }
    try buf.appendSlice(allocator, "</article>");
}

fn appendTriggerPills(buf: *std.ArrayList(u8), allocator: Allocator, values: []const []u8, limit: usize) !void {
    if (values.len == 0) {
        try buf.appendSlice(allocator, "<span class=\"actions-trigger-pill muted\">No triggers</span>");
        return;
    }
    for (values, 0..) |value, idx| {
        if (idx >= limit) break;
        try appendTemplate(buf, allocator, "<span class=\"actions-trigger-pill\">{value}</span>", .{ .value = value });
    }
    if (values.len > limit) {
        try appendTemplate(buf, allocator, "<span class=\"actions-trigger-pill muted\">+{count}</span>", .{
            .count = groupedUnsigned(@intCast(values.len - limit)),
        });
    }
}

fn appendStringListTerm(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, values: []const []u8) !void {
    if (values.len == 0) return;
    try appendTemplate(buf, allocator, "<div><dt>{label}</dt><dd>", .{ .label = label });
    for (values, 0..) |value, idx| {
        if (idx != 0) try buf.appendSlice(allocator, ", ");
        try appendTemplate(buf, allocator, "<code>{value}</code>", .{ .value = value });
    }
    try buf.appendSlice(allocator, "</dd></div>");
}

fn actionsFiltersFromTarget(allocator: Allocator, target: []const u8) !ActionsFilters {
    var filters = ActionsFilters{ .allocator = allocator };
    errdefer filters.deinit();

    if (try queryTextValueOwned(allocator, target, "pipeline")) |pipeline| {
        filters.workflow = pipeline;
    } else if (try queryTextValueOwned(allocator, target, "workflow")) |workflow| {
        filters.workflow = workflow;
    }
    if (try queryTextValueOwned(allocator, target, "q")) |query| {
        filters.query = query;
    }
    if (try queryTextValueOwned(allocator, target, "event")) |event| {
        filters.event = event;
    }
    if (try queryTextValueOwned(allocator, target, "status")) |status| {
        filters.status = status;
    }
    if (try queryTextValueOwned(allocator, target, "branch")) |branch| {
        filters.branch = branch;
    }
    if (try queryTextValueOwned(allocator, target, "actor")) |actor| {
        filters.actor = actor;
    }

    return filters;
}

fn queryTextValueOwned(allocator: Allocator, target: []const u8, name: []const u8) !?[]u8 {
    const owned = try queryValueOwned(allocator, target, name) orelse return null;
    const trimmed = std.mem.trim(u8, owned, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(owned);
        return null;
    }
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}

fn appendActionsHref(buf: *std.ArrayList(u8), allocator: Allocator, filters: ActionsFilters, override: ActionsHrefOverride) !void {
    try buf.appendSlice(allocator, "/pipelines");
    var first = true;
    if (actionsFilterHrefValue(filters, override, "workflow")) |value| try appendActionsHrefParam(buf, allocator, &first, "pipeline", value);
    if (actionsFilterHrefValue(filters, override, "q")) |value| try appendActionsHrefParam(buf, allocator, &first, "q", value);
    if (actionsFilterHrefValue(filters, override, "event")) |value| try appendActionsHrefParam(buf, allocator, &first, "event", value);
    if (actionsFilterHrefValue(filters, override, "status")) |value| try appendActionsHrefParam(buf, allocator, &first, "status", value);
    if (actionsFilterHrefValue(filters, override, "branch")) |value| try appendActionsHrefParam(buf, allocator, &first, "branch", value);
    if (actionsFilterHrefValue(filters, override, "actor")) |value| try appendActionsHrefParam(buf, allocator, &first, "actor", value);
}

fn actionsFilterHrefValue(filters: ActionsFilters, override: ActionsHrefOverride, name: []const u8) ?[]const u8 {
    if (override.param_name) |param| {
        if (std.mem.eql(u8, param, name)) return override.param_value;
    }
    if (std.mem.eql(u8, name, "workflow")) return filters.workflow;
    if (std.mem.eql(u8, name, "q")) return filters.query;
    if (std.mem.eql(u8, name, "event")) return filters.event;
    if (std.mem.eql(u8, name, "status")) return filters.status;
    if (std.mem.eql(u8, name, "branch")) return filters.branch;
    if (std.mem.eql(u8, name, "actor")) return filters.actor;
    return null;
}

fn appendActionsHrefParam(buf: *std.ArrayList(u8), allocator: Allocator, first: *bool, name: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, if (first.*) "?" else "&amp;");
    first.* = false;
    try appendUrlEncoded(buf, allocator, name);
    try buf.append(allocator, '=');
    try appendUrlEncoded(buf, allocator, value);
}

test "web actions filters parse and preserve href parameters" {
    var filters = try actionsFiltersFromTarget(std.testing.allocator, "/pipelines?pipeline=.github/workflows/ci.yml&q=deploy+main&event=push&status=success&branch=refs/heads/main&actor=alice");
    defer filters.deinit();

    try std.testing.expectEqualStrings(".github/workflows/ci.yml", filters.workflow.?);
    try std.testing.expectEqualStrings("deploy main", filters.query.?);
    try std.testing.expectEqualStrings("push", filters.event.?);
    try std.testing.expectEqualStrings("success", filters.status.?);
    try std.testing.expectEqualStrings("refs/heads/main", filters.branch.?);
    try std.testing.expectEqualStrings("alice", filters.actor.?);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendActionsHref(&buf, std.testing.allocator, filters, .{
        .param_name = "status",
        .param_value = null,
    });
    try std.testing.expectEqualStrings("/pipelines?pipeline=.github/workflows/ci.yml&amp;q=deploy%20main&amp;event=push&amp;branch=refs/heads/main&amp;actor=alice", buf.items);
}

test "web actions filters accept legacy workflow parameter" {
    var filters = try actionsFiltersFromTarget(std.testing.allocator, "/workflows?workflow=.github/workflows/ci.yml");
    defer filters.deinit();

    try std.testing.expectEqualStrings(".github/workflows/ci.yml", filters.workflow.?);
}

fn workflowRunCount(workflow: []const u8, runs: []const RunRow) usize {
    var count: usize = 0;
    for (runs) |row| {
        if (std.mem.eql(u8, row.workflow, workflow)) count += 1;
    }
    return count;
}

fn actionsStats(workflow_count: usize, runs: []const RunRow, pending_count: usize) ActionsStats {
    var stats = ActionsStats{
        .workflows = workflow_count,
        .runs = runs.len,
        .pending = pending_count,
        .successful = 0,
        .failed = 0,
        .other = 0,
    };
    for (runs) |row| {
        if (std.mem.eql(u8, row.conclusion, "success")) {
            stats.successful += 1;
        } else if (std.mem.eql(u8, row.conclusion, "pending")) {
            continue;
        } else if (std.mem.eql(u8, row.conclusion, "failure") or
            std.mem.eql(u8, row.conclusion, "cancelled") or
            std.mem.eql(u8, row.conclusion, "timed_out") or
            std.mem.eql(u8, row.conclusion, "action_required"))
        {
            stats.failed += 1;
        } else {
            stats.other += 1;
        }
    }
    return stats;
}

fn hasRestrictiveActionsFilters(filters: ActionsFilters) bool {
    return filters.workflow != null or
        filters.query != null or
        filters.event != null or
        filters.status != null or
        filters.branch != null or
        filters.actor != null;
}

fn actionsFilterValue(filters: ActionsFilters, kind: ActionsFilterKind) ?[]const u8 {
    return switch (kind) {
        .workflow => filters.workflow,
        .event => filters.event,
        .status => filters.status,
        .branch => filters.branch,
        .actor => filters.actor,
    };
}

fn actionsFilterLabel(kind: ActionsFilterKind) []const u8 {
    return switch (kind) {
        .workflow => "Pipeline",
        .event => "Event",
        .status => "Status",
        .branch => "Branch",
        .actor => "Actor",
    };
}

fn actionsFilterAllLabel(kind: ActionsFilterKind) []const u8 {
    return switch (kind) {
        .workflow => "Any pipeline",
        .event => "Any event",
        .status => "Any status",
        .branch => "Any branch",
        .actor => "Anyone",
    };
}

fn actionsFilterParamName(kind: ActionsFilterKind) []const u8 {
    return switch (kind) {
        .workflow => "workflow",
        .event => "event",
        .status => "status",
        .branch => "branch",
        .actor => "actor",
    };
}

fn actionsFilterDisplayLabel(workflows: []const actions.Workflow, kind: ActionsFilterKind, value: []const u8) []const u8 {
    return switch (kind) {
        .workflow => workflowDisplayName(workflows, value),
        .status => conclusionLabel(value),
        else => value,
    };
}

fn actionsRunFilterValue(row: RunRow, kind: ActionsFilterKind) []const u8 {
    return switch (kind) {
        .workflow => row.workflow,
        .event => row.event_name,
        .status => row.conclusion,
        .branch => branchFilterValue(row),
        .actor => row.actor_principal,
    };
}

fn branchFilterValue(row: RunRow) []const u8 {
    if (row.target_ref.len != 0) return row.target_ref;
    return row.target_oid;
}

fn conclusionLabel(conclusion: []const u8) []const u8 {
    if (std.mem.eql(u8, conclusion, "success")) return "Success";
    if (std.mem.eql(u8, conclusion, "pending")) return "Pending";
    if (std.mem.eql(u8, conclusion, "failure")) return "Failure";
    if (std.mem.eql(u8, conclusion, "cancelled")) return "Cancelled";
    if (std.mem.eql(u8, conclusion, "skipped")) return "Skipped";
    if (std.mem.eql(u8, conclusion, "timed_out")) return "Timed out";
    if (std.mem.eql(u8, conclusion, "action_required")) return "Action required";
    return conclusion;
}

fn findActionsFilterOptionIndex(options: []const ActionsFilterOption, value: []const u8) ?usize {
    for (options, 0..) |option, option_index| {
        if (std.mem.eql(u8, option.value, value)) return option_index;
    }
    return null;
}

fn actionsFilterOptionLessThan(_: void, left: ActionsFilterOption, right: ActionsFilterOption) bool {
    if (asciiLessThanIgnoreCase(left.label, right.label)) return true;
    if (asciiEqlIgnoreCase(left.label, right.label)) return asciiLessThanIgnoreCase(left.value, right.value);
    return false;
}

fn asciiLessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    const shared_len = @min(a.len, b.len);
    var offset: usize = 0;
    while (offset < shared_len) : (offset += 1) {
        const left = std.ascii.toLower(a[offset]);
        const right = std.ascii.toLower(b[offset]);
        if (left < right) return true;
        if (left > right) return false;
    }
    return a.len < b.len;
}

fn findWorkflow(workflows: []const actions.Workflow, workflow_path: []const u8) ?actions.Workflow {
    for (workflows) |workflow| {
        if (std.mem.eql(u8, workflow.path, workflow_path)) return workflow;
    }
    return null;
}

fn workflowDialectLabel(dialect: actions.WorkflowDialect) []const u8 {
    return switch (dialect) {
        .github_actions => "github-actions",
        .gitomi => "gitomi",
    };
}

fn workflowSourceLabel(workflow: actions.Workflow) []const u8 {
    if (std.mem.eql(u8, workflow.source.workflow_from, workflow.source.code_from)) return workflow.source.workflow_from;
    return "split";
}

fn effectiveJobBackendLabel(job: actions.WorkflowJob) []const u8 {
    if (job.backend.len == 0 and job.steps.len != 0) return "shell";
    if (job.backend.len == 0) return "unspecified";
    return job.backend;
}

fn filteredRunCount(runs: []const RunRow, filters: ActionsFilters) usize {
    var count: usize = 0;
    for (runs) |row| {
        if (runMatchesFilters(row, filters)) count += 1;
    }
    return count;
}

fn runMatchesFilters(row: RunRow, filters: ActionsFilters) bool {
    return runMatchesFiltersExcept(row, filters, null);
}

fn countRunsMatchingFiltersExcept(runs: []const RunRow, filters: ActionsFilters, except: ActionsFilterKind) usize {
    var count: usize = 0;
    for (runs) |row| {
        if (runMatchesFiltersExcept(row, filters, except)) count += 1;
    }
    return count;
}

fn runMatchesFiltersExcept(row: RunRow, filters: ActionsFilters, except: ?ActionsFilterKind) bool {
    if (filterApplies(except, .workflow)) {
        if (filters.workflow) |workflow| {
            if (!std.mem.eql(u8, row.workflow, workflow)) return false;
        }
    }
    if (filterApplies(except, .event)) {
        if (filters.event) |event| {
            if (!std.mem.eql(u8, row.event_name, event)) return false;
        }
    }
    if (filterApplies(except, .status)) {
        if (filters.status) |status| {
            if (!std.mem.eql(u8, row.conclusion, status)) return false;
        }
    }
    if (filterApplies(except, .branch)) {
        if (filters.branch) |branch| {
            if (!std.mem.eql(u8, branchFilterValue(row), branch)) return false;
        }
    }
    if (filterApplies(except, .actor)) {
        if (filters.actor) |actor| {
            if (!std.mem.eql(u8, row.actor_principal, actor)) return false;
        }
    }
    if (filters.query) |query| {
        if (!containsIgnoreCase(row.workflow, query) and
            !containsIgnoreCase(row.event_name, query) and
            !containsIgnoreCase(row.gitomi_event_type, query) and
            !containsIgnoreCase(row.target_ref, query) and
            !containsIgnoreCase(row.target_oid, query) and
            !containsIgnoreCase(row.run_id, query) and
            !containsIgnoreCase(row.actor_principal, query) and
            !containsIgnoreCase(row.conclusion, query))
        {
            return false;
        }
    }
    return true;
}

fn filterApplies(except: ?ActionsFilterKind, kind: ActionsFilterKind) bool {
    if (except) |skip| return skip != kind;
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn workflowDisplayName(workflows: []const actions.Workflow, workflow_path: []const u8) []const u8 {
    for (workflows) |workflow| {
        if (std.mem.eql(u8, workflow.path, workflow_path)) return workflow.name;
    }
    return std.fs.path.basename(workflow_path);
}

fn runTitleOwned(allocator: Allocator, workflow_name: []const u8, row: RunRow) ![]u8 {
    if (row.gitomi_event_type.len != 0) {
        return std.fmt.allocPrint(allocator, "{s} for {s}", .{ workflow_name, row.gitomi_event_type });
    }
    return std.fmt.allocPrint(allocator, "{s} run", .{workflow_name});
}

fn durationLabelOwned(allocator: Allocator, row: RunRow) ![]u8 {
    if (row.duration_seconds) |seconds| {
        if (seconds < 0) return allocator.dupe(u8, "Completed");
        if (seconds < 60) return std.fmt.allocPrint(allocator, "{d}s", .{seconds});
        const minutes = @divFloor(seconds, 60);
        const remaining_seconds = @mod(seconds, 60);
        if (minutes < 60) return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, remaining_seconds });
        const hours = @divFloor(minutes, 60);
        const remaining_minutes = @mod(minutes, 60);
        return std.fmt.allocPrint(allocator, "{d}h {d}m", .{ hours, remaining_minutes });
    }
    if (row.completed_at.len != 0) return allocator.dupe(u8, "Completed");
    return allocator.dupe(u8, "Pending");
}

fn conclusionClass(conclusion: []const u8) []const u8 {
    if (std.mem.eql(u8, conclusion, "success")) return "success";
    if (std.mem.eql(u8, conclusion, "pending")) return "pending";
    if (std.mem.eql(u8, conclusion, "cancelled")) return "cancelled";
    if (std.mem.eql(u8, conclusion, "skipped")) return "skipped";
    return "failure";
}

fn loadRunRows(allocator: Allocator, repo: Repo) !std.ArrayList(RunRow) {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\WITH completed AS (
        \\  SELECT object_id, MAX(ordinal) AS ordinal
        \\  FROM events
        \\  WHERE event_type = 'action.run_completed'
        \\    AND domain_status = 'accepted'
        \\  GROUP BY object_id
        \\)
        \\SELECT r.object_id, r.actor_principal, r.occurred_at, r.body, COALESCE(c.occurred_at, ''), COALESCE(c.body, ''),
        \\       CASE
        \\         WHEN c.occurred_at IS NULL THEN NULL
        \\         ELSE CAST(strftime('%s', c.occurred_at) - strftime('%s', r.occurred_at) AS INTEGER)
        \\       END
        \\FROM events r
        \\LEFT JOIN completed cc ON cc.object_id = r.object_id
        \\LEFT JOIN events c ON c.ordinal = cc.ordinal
        \\WHERE r.event_type = 'action.run_requested'
        \\  AND r.domain_status = 'accepted'
        \\ORDER BY r.ordinal DESC
        \\LIMIT 100
    );
    defer stmt.deinit();

    var rows: std.ArrayList(RunRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    while (try stmt.step()) {
        const run_id = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(run_id);
        const actor_principal = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(actor_principal);
        const requested_at = try stmt.columnTextDup(allocator, 2);
        errdefer allocator.free(requested_at);
        const request_body = try stmt.columnTextDup(allocator, 3);
        defer allocator.free(request_body);
        const completed_at = try stmt.columnTextDup(allocator, 4);
        errdefer allocator.free(completed_at);
        const completed_body = try stmt.columnTextDup(allocator, 5);
        defer allocator.free(completed_body);
        const duration_seconds: ?i64 = if (stmt.columnIsNull(6)) null else stmt.columnInt64(6);

        const workflow = try payloadStringOwned(allocator, request_body, "workflow", "");
        errdefer allocator.free(workflow);
        const event_name = try payloadStringOwned(allocator, request_body, "event_name", "workflow_dispatch");
        errdefer allocator.free(event_name);
        const gitomi_event_type = try payloadStringOwned(allocator, request_body, "gitomi_event_type", "");
        errdefer allocator.free(gitomi_event_type);
        const target_ref = try payloadStringOwned(allocator, request_body, "target_ref", "");
        errdefer allocator.free(target_ref);
        const target_oid = try payloadStringOwned(allocator, request_body, "target_oid", "");
        errdefer allocator.free(target_oid);
        const conclusion = if (completed_body.len == 0)
            try allocator.dupe(u8, "pending")
        else
            try payloadStringOwned(allocator, completed_body, "conclusion", "unknown");
        errdefer allocator.free(conclusion);
        const diagnostics_ref = try payloadStringOwned(allocator, completed_body, "diagnostics_ref", "");
        errdefer allocator.free(diagnostics_ref);
        const diagnostics_oid = try payloadStringOwned(allocator, completed_body, "diagnostics_oid", "");
        errdefer allocator.free(diagnostics_oid);
        const attempt_id = try payloadStringOwned(allocator, completed_body, "attempt_id", "");
        errdefer allocator.free(attempt_id);
        const runner_id = try payloadStringOwned(allocator, completed_body, "runner_id", "");
        errdefer allocator.free(runner_id);

        try rows.append(allocator, .{
            .allocator = allocator,
            .run_id = run_id,
            .actor_principal = actor_principal,
            .workflow = workflow,
            .event_name = event_name,
            .gitomi_event_type = gitomi_event_type,
            .target_ref = target_ref,
            .target_oid = target_oid,
            .requested_at = requested_at,
            .completed_at = completed_at,
            .conclusion = conclusion,
            .duration_seconds = duration_seconds,
            .diagnostics_ref = diagnostics_ref,
            .diagnostics_oid = diagnostics_oid,
            .attempt_id = attempt_id,
            .runner_id = runner_id,
        });
    }

    return rows;
}

fn payloadStringOwned(allocator: Allocator, body: []const u8, field: []const u8, default_value: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return allocator.dupe(u8, default_value);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return allocator.dupe(u8, default_value),
    };
    const payload = switch (root.get("payload") orelse return allocator.dupe(u8, default_value)) {
        .object => |object| object,
        else => return allocator.dupe(u8, default_value),
    };
    const value = event_json.jsonString(payload.get(field)) orelse default_value;
    return allocator.dupe(u8, value);
}

pub fn handleActionsRequestPost(allocator: Allocator, repo: Repo, stream: @import("compat").net.Stream, csrf_token: []const u8, form_body: []const u8) !void {
    const workflow_owned = (try shared.formValueOwned(allocator, form_body, "workflow")) orelse try allocator.dupe(u8, "");
    defer allocator.free(workflow_owned);
    const event_owned = (try shared.formValueOwned(allocator, form_body, "event")) orelse try allocator.dupe(u8, "workflow_dispatch");
    defer allocator.free(event_owned);
    const ref_owned = (try shared.formValueOwned(allocator, form_body, "ref")) orelse try allocator.dupe(u8, "HEAD");
    defer allocator.free(ref_owned);
    const oid_owned = (try shared.formValueOwned(allocator, form_body, "oid")) orelse try allocator.dupe(u8, "");
    defer allocator.free(oid_owned);

    const workflow = std.mem.trim(u8, workflow_owned, " \t\r\n");
    const event_name = std.mem.trim(u8, event_owned, " \t\r\n");
    const target_ref = std.mem.trim(u8, ref_owned, " \t\r\n");
    const target_oid = std.mem.trim(u8, oid_owned, " \t\r\n");
    if (workflow.len == 0) {
        const body = try renderActionsPageWithMessage(allocator, repo, "/pipelines", csrf_token, "Pipeline is required.");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var result = actions.requestWorkflow(
        allocator,
        workflow,
        if (target_oid.len == 0) if (target_ref.len == 0) "HEAD" else target_ref else null,
        if (target_oid.len == 0) null else target_oid,
        if (event_name.len == 0) "workflow_dispatch" else event_name,
        null,
    ) catch {
        const body = try renderActionsPageWithMessage(allocator, repo, "/pipelines", csrf_token, "Could not request the pipeline. Check signing and the pipeline selector.");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };
    defer result.deinit();

    try sendRedirect(allocator, stream, "/pipelines?requested=1");
}

pub fn handleRunRequestedPost(allocator: Allocator, stream: @import("compat").net.Stream, form_body: []const u8) !void {
    const run_owned = try shared.formValueOwned(allocator, form_body, "run");
    defer if (run_owned) |value| allocator.free(value);
    const run_filter: ?[]const u8 = if (run_owned) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len == 0) null else trimmed;
    } else null;

    actions.runRequested(allocator, run_filter, .{}) catch |err| {
        if (!errors.isUserError(err)) {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Pipeline runner failed\n");
            return;
        }
        try sendPlainResponse(allocator, stream, 409, "Conflict", "No matching pending pipeline run\n");
        return;
    };
    try sendRedirect(allocator, stream, "/pipelines?run=1");
}
