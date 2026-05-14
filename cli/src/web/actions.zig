const std = @import("std");
const actions = @import("../actions.zig");
const errors = @import("../errors.zig");
const event_mod = @import("../event.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const issues_page = @import("issues.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendRelativeTime = shared.appendRelativeTime;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const appendUrlEncoded = shared.appendUrlEncoded;
const class = shared.class;
const classAttr = shared.classAttr;
const ensureIndex = index.ensureIndex;
const groupedUnsigned = shared.groupedUnsigned;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const ActionsFilters = struct {
    allocator: Allocator,
    workflow: ?[]u8 = null,
    query: ?[]u8 = null,

    fn deinit(self: *ActionsFilters) void {
        if (self.workflow) |value| self.allocator.free(value);
        if (self.query) |value| self.allocator.free(value);
    }
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
    }
};

pub fn renderActionsPage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    return renderActionsPageWithMessage(allocator, repo, target, null);
}

fn renderActionsPageWithMessage(allocator: Allocator, repo: Repo, target: []const u8, message: ?[]const u8) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Actions", "actions", "/actions")) |body| return body;
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

    try appendShellStart(&buf, allocator, repo, "Actions", "actions");
    try buf.appendSlice(allocator, "<div class=\"actions-layout\">");
    try appendActionsSidebar(&buf, allocator, workflows, runs.items, filters, pending);
    try buf.appendSlice(allocator, "<section class=\"actions-main\">");
    if (message) |value| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = value });
    } else if (std.mem.indexOf(u8, target, "requested=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Workflow run requested.</div>");
    } else if (std.mem.indexOf(u8, target, "run=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Pending action runs processed.</div>");
    }
    try appendActionsMain(&buf, allocator, workflows, runs.items, filters);
    try buf.appendSlice(allocator, "</section></div>");

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
    pending: usize,
) !void {
    try buf.appendSlice(allocator,
        \\<aside class="actions-sidebar">
        \\  <div class="actions-sidebar-head">
        \\    <h1>Actions</h1>
        \\    <a class="button primary actions-new-workflow" href="/code?ref=HEAD&amp;path=.github/workflows">New workflow</a>
        \\  </div>
        \\  <nav class="actions-workflow-nav" aria-label="Workflows">
    );
    try appendActionsSidebarLink(buf, allocator, "All workflows", null, filters.workflow == null, runs.len);
    for (workflows) |workflow| {
        try appendActionsSidebarLink(
            buf,
            allocator,
            workflow.name,
            workflow.path,
            if (filters.workflow) |selected| std.mem.eql(u8, selected, workflow.path) else false,
            workflowRunCount(workflow.path, runs),
        );
    }
    if (workflows.len == 0) {
        try buf.appendSlice(allocator, "<p class=\"actions-sidebar-empty\">No workflow files found.</p>");
    }
    try appendTemplate(buf, allocator,
        \\  </nav>
        \\  <details class="actions-manual-run">
        \\    <summary>Request workflow</summary>
        \\    <form method="post" action="/actions/request">
        \\      <label>Workflow<select name="workflow" required>
    , .{});
    for (workflows) |workflow| {
        try appendTemplate(buf, allocator, "<option value=\"{path}\">{name}</option>", .{
            .path = workflow.path,
            .name = workflow.name,
        });
    }
    if (workflows.len == 0) {
        try buf.appendSlice(allocator, "<option value=\"\" disabled selected>No workflows found</option>");
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
        \\    <form method="post" action="/actions/run-requested">
        \\      <button class="button secondary" type="submit">Run pending ({pending})</button>
        \\    </form>
        \\  </details>
        \\  <div class="actions-management">
        \\    <h2>Management</h2>
        \\    <span class="actions-management-link actions-icon-caches">Caches</span>
        \\    <span class="actions-management-link actions-icon-attestations">Attestations</span>
        \\    <span class="actions-management-link actions-icon-runners">Runners</span>
        \\    <span class="actions-management-link actions-icon-metrics">Usage metrics</span>
        \\    <span class="actions-management-link actions-icon-metrics">Performance metrics</span>
        \\  </div>
        \\</aside>
    , .{ .pending = pending });
}

fn appendActionsSidebarLink(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    workflow: ?[]const u8,
    active: bool,
    count: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<a{class_attr} href="
    , .{ .class_attr = classAttr("actions-workflow-link", &.{class("active", active)}) });
    try appendActionsHref(buf, allocator, workflow, null);
    try appendTemplate(buf, allocator,
        \\"><span>{label}</span><small>{count}</small></a>
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
) !void {
    const visible_count = filteredRunCount(runs, filters);
    const selected_title = if (filters.workflow) |selected| workflowDisplayName(workflows, selected) else "All workflows";
    const query = filters.query orelse "";

    try appendTemplate(buf, allocator,
        \\<div class="actions-main-head">
        \\  <div>
        \\    <h1>{title}</h1>
        \\    <p>{subtitle}</p>
        \\  </div>
        \\  <form class="actions-filter" method="get" action="/actions">
    , .{
        .title = selected_title,
        .subtitle = if (filters.workflow == null) "Showing runs from all workflows" else "Showing runs from the selected workflow",
    });
    if (filters.workflow) |workflow| {
        try appendTemplate(buf, allocator, "<input type=\"hidden\" name=\"workflow\" value=\"{workflow}\">", .{ .workflow = workflow });
    }
    try appendTemplate(buf, allocator,
        \\    <span class="actions-filter-icon" aria-hidden="true"></span>
        \\    <input type="search" name="q" value="{query}" placeholder="Filter workflow runs" aria-label="Filter workflow runs">
        \\  </form>
        \\</div>
        \\<section class="actions-runs-panel">
        \\  <div class="actions-runs-head">
        \\    <strong>{count} workflow {run_label}</strong>
        \\    <div class="actions-runs-filters" aria-hidden="true">
        \\      <span>Workflow</span>
        \\      <span>Event</span>
        \\      <span>Status</span>
        \\      <span>Branch</span>
        \\      <span>Actor</span>
        \\    </div>
        \\  </div>
    , .{
        .query = query,
        .count = groupedUnsigned(@intCast(visible_count)),
        .run_label = if (visible_count == 1) "run" else "runs",
    });

    var shown: usize = 0;
    for (runs) |row| {
        if (!runMatchesFilters(row, filters)) continue;
        try appendRunRow(buf, allocator, workflows, row);
        shown += 1;
    }
    if (shown == 0) {
        if (filters.workflow != null or filters.query != null) {
            try appendEmptyState(buf, allocator, "No matching workflow runs.", "Change the workflow or search filter to widen the run list.");
        } else {
            try appendEmptyState(buf, allocator, "No workflow runs yet.", "Request a workflow run or start the actions daemon to populate this list.");
        }
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendRunRow(buf: *std.ArrayList(u8), allocator: Allocator, workflows: []const actions.Workflow, row: RunRow) !void {
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
        \\  <button class="actions-run-menu" type="button" aria-label="Run menu" disabled></button>
        \\</article>
    , .{ .duration = duration });
}

fn actionsFiltersFromTarget(allocator: Allocator, target: []const u8) !ActionsFilters {
    var filters = ActionsFilters{ .allocator = allocator };
    errdefer filters.deinit();

    if (try queryTextValueOwned(allocator, target, "workflow")) |workflow| {
        filters.workflow = workflow;
    }
    if (try queryTextValueOwned(allocator, target, "q")) |query| {
        filters.query = query;
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

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try issues_page.percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try issues_page.percentDecodeForm(allocator, raw_value);
    }
    return null;
}

fn appendActionsHref(buf: *std.ArrayList(u8), allocator: Allocator, workflow: ?[]const u8, query: ?[]const u8) !void {
    try buf.appendSlice(allocator, "/actions");
    var has_query = false;
    if (workflow) |value| {
        try buf.appendSlice(allocator, "?workflow=");
        try appendUrlEncoded(buf, allocator, value);
        has_query = true;
    }
    if (query) |value| {
        try buf.appendSlice(allocator, if (has_query) "&amp;q=" else "?q=");
        try appendUrlEncoded(buf, allocator, value);
    }
}

fn workflowRunCount(workflow: []const u8, runs: []const RunRow) usize {
    var count: usize = 0;
    for (runs) |row| {
        if (std.mem.eql(u8, row.workflow, workflow)) count += 1;
    }
    return count;
}

fn filteredRunCount(runs: []const RunRow, filters: ActionsFilters) usize {
    var count: usize = 0;
    for (runs) |row| {
        if (runMatchesFilters(row, filters)) count += 1;
    }
    return count;
}

fn runMatchesFilters(row: RunRow, filters: ActionsFilters) bool {
    if (filters.workflow) |workflow| {
        if (!std.mem.eql(u8, row.workflow, workflow)) return false;
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
    const value = event_mod.jsonString(payload.get(field)) orelse default_value;
    return allocator.dupe(u8, value);
}

pub fn handleActionsRequestPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const workflow_owned = (try issues_page.formValueOwned(allocator, form_body, "workflow")) orelse try allocator.dupe(u8, "");
    defer allocator.free(workflow_owned);
    const event_owned = (try issues_page.formValueOwned(allocator, form_body, "event")) orelse try allocator.dupe(u8, "workflow_dispatch");
    defer allocator.free(event_owned);
    const ref_owned = (try issues_page.formValueOwned(allocator, form_body, "ref")) orelse try allocator.dupe(u8, "HEAD");
    defer allocator.free(ref_owned);

    const workflow = std.mem.trim(u8, workflow_owned, " \t\r\n");
    const event_name = std.mem.trim(u8, event_owned, " \t\r\n");
    const target_ref = std.mem.trim(u8, ref_owned, " \t\r\n");
    if (workflow.len == 0) {
        const body = try renderActionsPageWithMessage(allocator, repo, "/actions", "Workflow is required.");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 422, "Unprocessable Entity", "text/html", body, null);
        return;
    }

    var result = actions.requestWorkflow(
        allocator,
        workflow,
        if (target_ref.len == 0) "HEAD" else target_ref,
        null,
        if (event_name.len == 0) "workflow_dispatch" else event_name,
        null,
    ) catch {
        const body = try renderActionsPageWithMessage(allocator, repo, "/actions", "Could not request the workflow. Check signing and the workflow selector.");
        defer allocator.free(body);
        try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
        return;
    };
    defer result.deinit();

    try sendRedirect(allocator, stream, "/actions?requested=1");
}

pub fn handleRunRequestedPost(allocator: Allocator, stream: std.net.Stream) !void {
    actions.runRequested(allocator, null, .{}) catch |err| {
        if (!errors.isUserError(err)) {
            try sendPlainResponse(allocator, stream, 500, "Internal Server Error", "Action runner failed\n");
            return;
        }
    };
    try sendRedirect(allocator, stream, "/actions?run=1");
}
