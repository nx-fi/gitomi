const std = @import("std");
const event_mod = @import("../../event.zig");
const index = @import("../../index.zig");
const work_items = @import("../../work_items.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendRelativeTime = shared.appendRelativeTime;
const appendTemplate = shared.appendTemplate;

const IssueProjectSummary = struct {
    project: []const u8,
    column: []const u8,
};

pub fn append(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try work_items.prepareTimelineStmt(db, "issue", issue_id);
    defer stmt.deinit();

    while (try stmt.step()) {
        const row = try work_items.timelineEventFromStmt(allocator, &stmt);
        defer row.deinit(allocator);
        try appendEvent(buf, allocator, row.event_type, row.actor_principal, row.occurred_at, row.body, row.event_hash);
    }
}

fn appendEvent(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    actor: []const u8,
    occurred_at: []const u8,
    body: []const u8,
    event_hash: []const u8,
) !void {
    const anchor = event_hash[0..@min(event_hash.len, 12)];
    try appendTemplate(buf, allocator,
        \\<div class="issue-timeline-item issue-event-item" id="event-{anchor}">
        \\  <div class="issue-timeline-avatar"><span class="issue-event-icon {icon_class}" aria-hidden="true"></span></div>
        \\  <div class="issue-event-content"><strong>{actor}</strong>
    , .{
        .anchor = anchor,
        .icon_class = eventIcon(event_type, body),
        .actor = actor,
    });
    try buf.append(allocator, ' ');
    try appendMessage(buf, allocator, event_type, body);
    try buf.append(allocator, ' ');
    try appendRelativeTime(buf, allocator, occurred_at);
    try buf.appendSlice(allocator, "</div></div>");
}

fn eventIcon(event_type: []const u8, body: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "issue.state_set")) {
        if (payloadStringEquals(body, "state", "closed")) return "is-closed";
        if (payloadStringEquals(body, "state", "open")) return "is-open";
        return "is-state";
    }
    if (std.mem.eql(u8, event_type, "issue.priority_set") or std.mem.eql(u8, event_type, "issue.type_set") or std.mem.eql(u8, event_type, "issue.status_set")) return "is-project";
    if (std.mem.eql(u8, event_type, "issue.updated")) {
        if (payloadStringEquals(body, "state", "closed")) return "is-closed";
        if (payloadStringEquals(body, "state", "open")) return "is-open";
        return "is-edit";
    }
    if (std.mem.indexOf(u8, event_type, "label") != null) return "is-label";
    if (std.mem.indexOf(u8, event_type, "assignee") != null) return "is-assignee";
    if (std.mem.indexOf(u8, event_type, "milestone") != null) return "is-milestone";
    if (std.mem.indexOf(u8, event_type, "project") != null) return "is-project";
    return "is-edit";
}

fn appendMessage(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    event_type: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
        return;
    };
    defer parsed.deinit();
    const payload = eventPayload(parsed.value) orelse {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
        return;
    };

    if (std.mem.eql(u8, event_type, "issue.title_set")) {
        try buf.appendSlice(allocator, "changed the title");
    } else if (std.mem.eql(u8, event_type, "issue.body_set")) {
        try buf.appendSlice(allocator, "edited the description");
    } else if (std.mem.eql(u8, event_type, "issue.state_set")) {
        try appendStateMessage(buf, allocator, event_mod.jsonString(payload.get("state")) orelse "");
    } else if (std.mem.eql(u8, event_type, "issue.priority_set")) {
        try appendTemplate(buf, allocator, "set priority to <span class=\"issue-event-value\">{priority}</span>", .{
            .priority = event_mod.jsonString(payload.get("priority")) orelse "priority",
        });
    } else if (std.mem.eql(u8, event_type, "issue.type_set")) {
        try appendTemplate(buf, allocator, "set type to <span class=\"issue-event-value\">{issue_type}</span>", .{
            .issue_type = issueTypeLabel(event_mod.jsonString(payload.get("type")) orelse "type"),
        });
    } else if (std.mem.eql(u8, event_type, "issue.status_set")) {
        try appendTemplate(buf, allocator, "set status to <span class=\"issue-event-value\">{status}</span>", .{
            .status = event_mod.jsonString(payload.get("status")) orelse "status",
        });
    } else if (std.mem.eql(u8, event_type, "issue.label_added")) {
        try buf.appendSlice(allocator, "added ");
        try appendLabel(buf, allocator, event_mod.jsonString(payload.get("label")) orelse "label");
    } else if (std.mem.eql(u8, event_type, "issue.label_removed")) {
        try buf.appendSlice(allocator, "removed ");
        try appendLabel(buf, allocator, event_mod.jsonString(payload.get("label")) orelse "label");
    } else if (std.mem.eql(u8, event_type, "issue.assignee_added")) {
        try appendTemplate(buf, allocator, "assigned <span class=\"issue-event-value\">{assignee}</span>", .{
            .assignee = event_mod.jsonString(payload.get("assignee")) orelse "someone",
        });
    } else if (std.mem.eql(u8, event_type, "issue.assignee_removed")) {
        try appendTemplate(buf, allocator, "unassigned <span class=\"issue-event-value\">{assignee}</span>", .{
            .assignee = event_mod.jsonString(payload.get("assignee")) orelse "someone",
        });
    } else if (std.mem.eql(u8, event_type, "issue.milestone_set")) {
        try appendMilestoneMessage(buf, allocator, event_mod.jsonString(payload.get("milestone")) orelse "");
    } else if (std.mem.eql(u8, event_type, "issue.project_added")) {
        try appendProjectMessage(buf, allocator, "added this to", .{
            .project = event_mod.jsonString(payload.get("project")) orelse "project",
            .column = event_mod.jsonString(payload.get("column")) orelse "",
        });
    } else if (std.mem.eql(u8, event_type, "issue.project_removed")) {
        try appendProjectMessage(buf, allocator, "removed this from", .{
            .project = event_mod.jsonString(payload.get("project")) orelse "project",
            .column = event_mod.jsonString(payload.get("column")) orelse "",
        });
    } else if (std.mem.eql(u8, event_type, "issue.updated")) {
        try appendUpdatedMessage(buf, allocator, payload);
    } else {
        try appendTemplate(buf, allocator, "recorded <code>{event_type}</code>", .{ .event_type = event_type });
    }
}

fn eventPayload(value: std.json.Value) ?std.json.ObjectMap {
    const root = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const payload_value = root.get("payload") orelse return null;
    return switch (payload_value) {
        .object => |object| object,
        else => null,
    };
}

fn payloadStringEquals(body: []const u8, key: []const u8, expected: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const payload = eventPayload(parsed.value) orelse return false;
    const value = event_mod.jsonString(payload.get(key)) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn appendStateMessage(buf: *std.ArrayList(u8), allocator: Allocator, state: []const u8) !void {
    if (std.mem.eql(u8, state, "closed")) {
        try buf.appendSlice(allocator, "closed this as completed");
    } else if (std.mem.eql(u8, state, "open")) {
        try buf.appendSlice(allocator, "reopened this");
    } else {
        try appendTemplate(buf, allocator, "changed state to <span class=\"issue-event-value\">{state}</span>", .{ .state = state });
    }
}

fn appendMilestoneMessage(buf: *std.ArrayList(u8), allocator: Allocator, milestone: []const u8) !void {
    if (milestone.len == 0) {
        try buf.appendSlice(allocator, "cleared the milestone");
    } else {
        try appendTemplate(buf, allocator, "set milestone to <span class=\"issue-sidebar-pill\">{milestone}</span>", .{ .milestone = milestone });
    }
}

fn appendProjectMessage(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    verb: []const u8,
    project: IssueProjectSummary,
) !void {
    try appendTemplate(buf, allocator, "{verb} <span class=\"issue-sidebar-pill\">{project}", .{
        .verb = verb,
        .project = project.project,
    });
    if (project.column.len != 0) {
        try appendTemplate(buf, allocator, " / {column}", .{ .column = project.column });
    }
    try buf.appendSlice(allocator, "</span>");
}

fn appendUpdatedMessage(buf: *std.ArrayList(u8), allocator: Allocator, payload: std.json.ObjectMap) !void {
    if (event_mod.jsonString(payload.get("state"))) |state| {
        try appendStateMessage(buf, allocator, state);
    } else if (event_mod.jsonString(payload.get("milestone"))) |milestone| {
        try appendMilestoneMessage(buf, allocator, milestone);
    } else if (event_mod.jsonString(payload.get("priority"))) |priority| {
        try appendTemplate(buf, allocator, "set priority to <span class=\"issue-event-value\">{priority}</span>", .{ .priority = priority });
    } else if (event_mod.jsonString(payload.get("type"))) |issue_type| {
        try appendTemplate(buf, allocator, "set type to <span class=\"issue-event-value\">{issue_type}</span>", .{ .issue_type = issueTypeLabel(issue_type) });
    } else if (event_mod.jsonString(payload.get("status"))) |status| {
        try appendTemplate(buf, allocator, "set status to <span class=\"issue-event-value\">{status}</span>", .{ .status = status });
    } else if (firstStringFromJsonArray(payload, "labels_added")) |label| {
        try buf.appendSlice(allocator, "added ");
        try appendLabel(buf, allocator, label);
    } else if (firstStringFromJsonArray(payload, "labels_removed")) |label| {
        try buf.appendSlice(allocator, "removed ");
        try appendLabel(buf, allocator, label);
    } else if (firstStringFromJsonArray(payload, "assignees_added")) |assignee| {
        try appendTemplate(buf, allocator, "assigned <span class=\"issue-event-value\">{assignee}</span>", .{ .assignee = assignee });
    } else if (firstStringFromJsonArray(payload, "assignees_removed")) |assignee| {
        try appendTemplate(buf, allocator, "unassigned <span class=\"issue-event-value\">{assignee}</span>", .{ .assignee = assignee });
    } else if (firstProjectFromJsonArray(payload, "projects")) |project| {
        try appendProjectMessage(buf, allocator, "added this to", project);
    } else if (payload.get("title") != null) {
        try buf.appendSlice(allocator, "changed the title");
    } else if (payload.get("body") != null) {
        try buf.appendSlice(allocator, "edited the description");
    } else {
        try buf.appendSlice(allocator, "updated this issue");
    }
}

fn issueTypeLabel(issue_type: []const u8) []const u8 {
    if (std.mem.eql(u8, issue_type, "bug")) return "Bug";
    if (std.mem.eql(u8, issue_type, "feature")) return "Feature";
    if (std.mem.eql(u8, issue_type, "task")) return "Task";
    return issue_type;
}

fn firstStringFromJsonArray(payload: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = payload.get(key) orelse return null;
    const array = switch (value) {
        .array => |items| items,
        else => return null,
    };
    for (array.items) |item| {
        if (item == .string) return item.string;
    }
    return null;
}

fn firstProjectFromJsonArray(payload: std.json.ObjectMap, key: []const u8) ?IssueProjectSummary {
    const value = payload.get(key) orelse return null;
    const array = switch (value) {
        .array => |items| items,
        else => return null,
    };
    for (array.items) |item| {
        const object = switch (item) {
            .object => |project| project,
            else => continue,
        };
        return .{
            .project = event_mod.jsonString(object.get("project")) orelse "project",
            .column = event_mod.jsonString(object.get("column")) orelse "",
        };
    }
    return null;
}

fn appendLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = labelKind(label),
        .label = label,
    });
}

fn labelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}
