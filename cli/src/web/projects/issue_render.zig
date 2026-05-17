const std = @import("std");
const index = @import("../../index.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const SqliteDb = index.SqliteDb;
const appendTemplate = shared.appendTemplate;

pub fn appendProjectIssueAssignees(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT assignee FROM issue_assignees WHERE issue_id = ? ORDER BY assignee LIMIT 4");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const assignee = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(assignee);
        try appendIssueAvatar(buf, allocator, assignee, "project-table-avatar");
        shown = true;
    }
    if (!shown) try buf.appendSlice(allocator, "<span class=\"muted\">Unassigned</span>");
}

pub fn appendKanbanCardLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, issue_id: []const u8) !void {
    var stmt = try db.prepare("SELECT DISTINCT label FROM issue_labels WHERE issue_id = ? ORDER BY label LIMIT 4");
    defer stmt.deinit();
    try stmt.bindText(1, issue_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"kanban-card-labels\">");
            shown = true;
        }
        try appendIssueLabel(buf, allocator, label);
    }
    if (shown) try buf.appendSlice(allocator, "</div>");
}

fn appendIssueLabel(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind}">{label}</span>
    , .{
        .kind = issueLabelKind(label),
        .label = label,
    });
}

pub fn appendIssueAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-avatar {extra_class}" title="{name}" aria-label="{name}">
    , .{
        .extra_class = extra_class,
        .name = name,
    });
    var initial_buf = [_]u8{'?'};
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            initial_buf[0] = std.ascii.toUpper(c);
            break;
        }
    }
    try shared.appendHtml(buf, allocator, initial_buf[0..]);
    try buf.appendSlice(allocator, "</span>");
}

fn issueLabelKind(label: []const u8) []const u8 {
    if (asciiEqlIgnoreCase(label, "bug")) return "label-bug";
    if (asciiEqlIgnoreCase(label, "enhancement") or asciiEqlIgnoreCase(label, "feature") or asciiEqlIgnoreCase(label, "feat")) return "label-enhancement";
    if (asciiEqlIgnoreCase(label, "docs") or asciiEqlIgnoreCase(label, "documentation")) return "label-docs";
    if (asciiEqlIgnoreCase(label, "question")) return "label-question";
    if (asciiEqlIgnoreCase(label, "security")) return "label-security";
    return "label-default";
}

pub fn columnTone(column: []const u8) []const u8 {
    if (column.len == 0) return "neutral";
    if (asciiEqlIgnoreCase(column, "Draft")) return "draft";
    if (asciiEqlIgnoreCase(column, "Todo")) return "todo";
    if (asciiEqlIgnoreCase(column, "WIP")) return "progress";
    if (asciiEqlIgnoreCase(column, "Failed")) return "failed";
    if (asciiContainsIgnoreCase(column, "done") or asciiContainsIgnoreCase(column, "complete") or asciiContainsIgnoreCase(column, "closed")) return "done";
    if (asciiContainsIgnoreCase(column, "progress") or asciiContainsIgnoreCase(column, "doing")) return "progress";
    if (asciiContainsIgnoreCase(column, "review")) return "review";
    if (asciiContainsIgnoreCase(column, "triage") or asciiContainsIgnoreCase(column, "backlog")) return "backlog";
    if (asciiContainsIgnoreCase(column, "todo") or asciiContainsIgnoreCase(column, "to do") or asciiContainsIgnoreCase(column, "ready") or asciiContainsIgnoreCase(column, "now") or asciiContainsIgnoreCase(column, "next")) return "todo";
    return "neutral";
}

pub fn columnDescription(column: []const u8) []const u8 {
    if (column.len == 0) return "Issues without a project column";
    if (asciiEqlIgnoreCase(column, "Draft")) return "Scoped but not ready";
    if (asciiEqlIgnoreCase(column, "Todo")) return "Not started yet";
    if (asciiEqlIgnoreCase(column, "WIP")) return "Actively being worked on";
    if (asciiEqlIgnoreCase(column, "Review")) return "Waiting for review";
    if (asciiEqlIgnoreCase(column, "Failed")) return "Needs recovery before moving on";
    if (asciiContainsIgnoreCase(column, "done") or asciiContainsIgnoreCase(column, "complete") or asciiContainsIgnoreCase(column, "closed")) return "This has been completed";
    if (asciiContainsIgnoreCase(column, "progress") or asciiContainsIgnoreCase(column, "doing")) return "This is actively being worked on";
    if (asciiContainsIgnoreCase(column, "review")) return "Waiting for review";
    if (asciiContainsIgnoreCase(column, "triage")) return "Needs review before planning";
    if (asciiContainsIgnoreCase(column, "backlog")) return "Ready to be picked up";
    if (asciiContainsIgnoreCase(column, "ready")) return "Ready to start";
    if (asciiContainsIgnoreCase(column, "todo") or asciiContainsIgnoreCase(column, "to do")) return "This item has not been started";
    if (asciiContainsIgnoreCase(column, "now")) return "Current planning horizon";
    if (asciiContainsIgnoreCase(column, "next")) return "Planned next";
    if (asciiContainsIgnoreCase(column, "later")) return "Parked for later";
    return "Issues in this stage";
}

pub fn priorityTone(priority: []const u8) []const u8 {
    if (std.mem.eql(u8, priority, "P0")) return "p0";
    if (std.mem.eql(u8, priority, "P1")) return "p1";
    if (std.mem.eql(u8, priority, "P2")) return "p2";
    if (std.mem.eql(u8, priority, "P3")) return "p3";
    return "none";
}

pub fn effectiveStatusLabel(status: []const u8, fallback: []const u8) []const u8 {
    return if (status.len != 0) status else fallback;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
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
