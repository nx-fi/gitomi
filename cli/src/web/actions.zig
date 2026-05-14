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
const appendEmptyCell = shared.appendEmptyCell;
const appendEmptyState = shared.appendEmptyState;
const appendSectionHead = shared.appendSectionHead;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendStatePill = shared.appendStatePill;
const appendTemplate = shared.appendTemplate;
const ensureIndex = index.ensureIndex;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;
const sqlite = index.sqlite;

const RunRow = struct {
    allocator: Allocator,
    run_id: []u8,
    workflow: []u8,
    event_name: []u8,
    gitomi_event_type: []u8,
    target_ref: []u8,
    target_oid: []u8,
    requested_at: []u8,
    completed_at: []u8,
    conclusion: []u8,

    fn deinit(self: *RunRow) void {
        self.allocator.free(self.run_id);
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

    try appendShellStart(&buf, allocator, repo, "Actions", "actions");
    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(&buf, allocator, "Automation", "Actions", null);
    if (message) |value| {
        try appendTemplate(&buf, allocator, "<div class=\"flash error\">{message}</div>", .{ .message = value });
    } else if (std.mem.indexOf(u8, target, "requested=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Workflow run requested.</div>");
    } else if (std.mem.indexOf(u8, target, "run=1") != null) {
        try buf.appendSlice(allocator, "<div class=\"flash success\">Pending action runs processed.</div>");
    }
    try appendActionsSummary(&buf, allocator, repo);
    try buf.appendSlice(allocator, "</section>");

    try buf.appendSlice(allocator, "<section class=\"grid two\">");
    try appendWorkflowPanel(&buf, allocator);
    try appendRequestPanel(&buf, allocator);
    try buf.appendSlice(allocator, "</section>");

    try appendRunsPanel(&buf, allocator, repo);

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendActionsSummary(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo) !void {
    const pending = actions.countPendingRequests(allocator, repo) catch 0;
    try appendTemplate(buf, allocator,
        \\<dl class="facts">
        \\  <div><dt>Scheduler</dt><dd><code>gt actions daemon</code></dd></div>
        \\  <div><dt>Pending runs</dt><dd>{pending}</dd></div>
        \\  <div><dt>Runner</dt><dd><code>nektos/act</code></dd></div>
        \\</dl>
    , .{ .pending = pending });
}

fn appendWorkflowPanel(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "<div class=\"panel\">");
    try appendSectionHead(buf, allocator, "Workflows", "Discovered", null);

    const workflows = loadHeadWorkflows(allocator) catch |err| switch (err) {
        CliError.UserError, CliError.GitFailed => {
            try appendEmptyState(buf, allocator, "No workflows found.", "Add workflow files under .github/workflows in the selected commit.");
            try buf.appendSlice(allocator, "</div>");
            return;
        },
        else => return err,
    };
    defer actions.freeWorkflows(allocator, workflows);

    try buf.appendSlice(allocator,
        \\<div class="table-wrap"><table>
        \\  <thead><tr><th>Workflow</th><th>Triggers</th></tr></thead>
        \\  <tbody>
    );
    if (workflows.len == 0) {
        try appendEmptyCell(buf, allocator, 2, "No workflow files found.");
    } else {
        for (workflows) |workflow| {
            try appendTemplate(buf, allocator, "<tr><td><strong>{name}</strong><br><code>{path}</code></td><td>", .{
                .name = workflow.name,
                .path = workflow.path,
            });
            if (workflow.triggers.len == 0) {
                try buf.appendSlice(allocator, "<span class=\"muted\">No triggers detected</span>");
            } else {
                for (workflow.triggers, 0..) |trigger, idx| {
                    if (idx != 0) try buf.append(allocator, ' ');
                    try appendTemplate(buf, allocator, "<span class=\"pill\">{trigger}</span>", .{ .trigger = trigger });
                }
            }
            try buf.appendSlice(allocator, "</td></tr>");
        }
    }
    try buf.appendSlice(allocator, "</tbody></table></div></div>");
}

fn appendRequestPanel(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "<div class=\"panel\">");
    try appendSectionHead(buf, allocator, "Manual Run", "Request Workflow", null);

    const workflows = loadHeadWorkflows(allocator) catch try allocator.alloc(actions.Workflow, 0);
    defer actions.freeWorkflows(allocator, workflows);

    try buf.appendSlice(allocator,
        \\<form method="post" action="/actions/request" class="issue-form">
        \\  <label>Workflow<select name="workflow" required>
    );
    for (workflows) |workflow| {
        try appendTemplate(buf, allocator, "<option value=\"{path}\">{name}</option>", .{
            .path = workflow.path,
            .name = workflow.name,
        });
    }
    try buf.appendSlice(allocator,
        \\  </select></label>
        \\  <label>Event<input name="event" value="workflow_dispatch"></label>
        \\  <label>Ref<input name="ref" value="HEAD"></label>
        \\  <div class="form-actions">
        \\    <button class="button primary" type="submit">Request run</button>
        \\  </div>
        \\</form>
        \\<form method="post" action="/actions/run-requested" class="issue-form">
        \\  <div class="form-actions">
        \\    <button class="button secondary" type="submit">Run pending</button>
        \\  </div>
        \\</form>
        \\</div>
    );
}

fn appendRunsPanel(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo) !void {
    var runs = try loadRunRows(allocator, repo);
    defer {
        for (runs.items) |*row| row.deinit();
        runs.deinit(allocator);
    }

    try buf.appendSlice(allocator, "<section class=\"panel\">");
    try appendSectionHead(buf, allocator, "Runs", "Recent Workflow Runs", null);
    try buf.appendSlice(allocator,
        \\<div class="table-wrap"><table>
        \\  <thead><tr><th>Run</th><th>Workflow</th><th>Event</th><th>Target</th><th>Conclusion</th></tr></thead>
        \\  <tbody>
    );
    if (runs.items.len == 0) {
        try appendEmptyCell(buf, allocator, 5, "No action runs recorded.");
    } else {
        for (runs.items) |row| {
            try appendTemplate(buf, allocator, "<tr><td><code>{run}</code><br><small>{requested_at}</small></td><td><code>{workflow}</code></td><td>{event_name}", .{
                .run = row.run_id[0..@min(row.run_id.len, 12)],
                .requested_at = row.requested_at,
                .workflow = row.workflow,
                .event_name = row.event_name,
            });
            if (row.gitomi_event_type.len != 0) {
                try appendTemplate(buf, allocator, "<br><small>{gitomi_event_type}</small>", .{ .gitomi_event_type = row.gitomi_event_type });
            }
            try appendTemplate(buf, allocator, "</td><td><code>{target}</code></td><td>", .{
                .target = if (row.target_ref.len != 0) row.target_ref else row.target_oid,
            });
            try appendStatePill(buf, allocator, row.conclusion);
            if (row.completed_at.len != 0) {
                try appendTemplate(buf, allocator, "<br><small>{completed_at}</small>", .{ .completed_at = row.completed_at });
            }
            try buf.appendSlice(allocator, "</td></tr>");
        }
    }
    try buf.appendSlice(allocator, "</tbody></table></div></section>");
}

fn loadHeadWorkflows(allocator: Allocator) ![]actions.Workflow {
    var target = try actions.resolveTarget(allocator, null, null);
    defer target.deinit();
    return try actions.loadWorkflows(allocator, target.target_oid);
}

fn loadRunRows(allocator: Allocator, repo: Repo) !std.ArrayList(RunRow) {
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare(
        \\SELECT r.object_id, r.occurred_at, r.body, COALESCE(c.occurred_at, ''), COALESCE(c.body, '')
        \\FROM events r
        \\LEFT JOIN events c
        \\  ON c.event_type = 'action.run_completed'
        \\ AND c.object_id = r.object_id
        \\ AND c.domain_status = 'accepted'
        \\WHERE r.event_type = 'action.run_requested'
        \\  AND r.domain_status = 'accepted'
        \\ORDER BY r.ordinal DESC
        \\LIMIT 50
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
        const requested_at = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(requested_at);
        const request_body = try stmt.columnTextDup(allocator, 2);
        defer allocator.free(request_body);
        const completed_at = try stmt.columnTextDup(allocator, 3);
        errdefer allocator.free(completed_at);
        const completed_body = try stmt.columnTextDup(allocator, 4);
        defer allocator.free(completed_body);

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
            .workflow = workflow,
            .event_name = event_name,
            .gitomi_event_type = gitomi_event_type,
            .target_ref = target_ref,
            .target_oid = target_oid,
            .requested_at = requested_at,
            .completed_at = completed_at,
            .conclusion = conclusion,
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
