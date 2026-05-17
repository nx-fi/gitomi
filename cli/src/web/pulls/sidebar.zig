const std = @import("std");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const work_items = @import("../../work_items.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const PullDetail = work_items.PullDetail;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;
const runCommand = git.runCommand;

pub fn append(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, db: *SqliteDb, detail: PullDetail, pull_ref: []const u8) !void {
    try appendPeopleSection(buf, allocator, db, "Reviewers", "Manage reviewers", "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id, "No reviewers");
    try appendPeopleSection(buf, allocator, db, "Assignees", "Manage assignees", "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id, "No one assigned");
    try appendLabels(buf, allocator, db, detail.id);
    try appendEmptySection(buf, allocator, "Projects", "Manage projects", "No projects");
    try appendEmptySection(buf, allocator, "Milestone", "Set milestone", "No milestone");
    try appendDevelopment(buf, allocator, repo, detail, pull_ref);
    try appendNotifications(buf, allocator);
    try appendParticipants(buf, allocator, db, detail);
}

fn appendSectionStart(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="issue-sidebar-section"><div class="issue-sidebar-heading"><h2>{title}</h2><button class="pull-sidebar-gear" type="button" disabled aria-label="{menu_label}" title="{menu_label}"><span class="issue-sidebar-menu-icon" aria-hidden="true"></span></button></div>
    , .{
        .title = title,
        .menu_label = menu_label,
    });
}

fn appendSectionEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator, "</section>");
}

fn appendPeopleSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    title: []const u8,
    menu_label: []const u8,
    comptime sql_text: []const u8,
    pull_id: []const u8,
    empty_text: []const u8,
) !void {
    try appendSectionStart(buf, allocator, title, menu_label);
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendPerson(buf, allocator, person);
        shown = true;
    }
    if (!shown) try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendSectionEnd(buf, allocator);
}

fn appendLabels(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, pull_id: []const u8) !void {
    try appendSectionStart(buf, allocator, "Labels", "Manage labels");
    var stmt = try db.prepare("SELECT DISTINCT label FROM pull_labels WHERE pull_id = ? ORDER BY label");
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    var shown = false;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        if (!shown) {
            try buf.appendSlice(allocator, "<div class=\"issue-sidebar-labels\">");
            shown = true;
        }
        try appendLabel(buf, allocator, label);
    }
    if (shown) {
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator, "<p class=\"issue-sidebar-empty\">None yet</p>");
    }
    try appendSectionEnd(buf, allocator);
}

fn appendEmptySection(buf: *std.ArrayList(u8), allocator: Allocator, title: []const u8, menu_label: []const u8, empty_text: []const u8) !void {
    try appendSectionStart(buf, allocator, title, menu_label);
    try appendTemplate(buf, allocator, "<p class=\"issue-sidebar-empty\">{empty_text}</p>", .{ .empty_text = empty_text });
    try appendSectionEnd(buf, allocator);
}

fn appendDevelopment(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, pull_ref: []const u8) !void {
    try appendSectionStart(buf, allocator, "Development", "Link development");
    try buf.appendSlice(allocator,
        \\<p class="issue-sidebar-empty">Successfully merging this pull request may close linked issues.</p>
        \\<div class="pull-sidebar-branches"><span><strong>Base</strong>
    );
    try appendPullBranchLink(buf, allocator, detail.base_ref);
    try buf.appendSlice(allocator, "</span><span><strong>Head</strong>");
    try appendPullBranchLink(buf, allocator, detail.head_ref);
    try buf.appendSlice(allocator, "</span></div>");
    if (detail.merge_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">merge</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.merge_oid),
            .short_oid = detail.merge_oid[0..@min(detail.merge_oid.len, 12)],
        });
    }
    if (detail.target_oid.len != 0) {
        try appendTemplate(buf, allocator,
            \\<a class="issue-sidebar-link-row" href="{href}"><span class="issue-sidebar-row-kind">target</span><code>{short_oid}</code></a>
        , .{
            .href = commitHref(detail.target_oid),
            .short_oid = detail.target_oid[0..@min(detail.target_oid.len, 12)],
        });
    }
    if (detail.merge_oid.len != 0 or detail.target_oid.len != 0) {
        try buf.appendSlice(allocator, "<p class=\"pull-sidebar-note\">");
        try appendLocalMergeCheck(buf, allocator, repo, detail);
        try buf.appendSlice(allocator, "</p>");
    }
    try appendTemplate(buf, allocator, "<p class=\"pull-sidebar-note\"><a href=\"/pulls/{pull_ref}\">/pulls/{pull_ref}</a></p>", .{ .pull_ref = pull_ref });
    try appendSectionEnd(buf, allocator);
}

fn appendNotifications(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendSectionStart(buf, allocator, "Notifications", "Customize notifications");
    try buf.appendSlice(allocator,
        \\<button class="button secondary issue-sidebar-full-button" type="button" disabled>Subscribe</button>
        \\<p class="issue-sidebar-empty">You're receiving notifications because you modified this pull request.</p>
    );
    try appendSectionEnd(buf, allocator);
}

fn appendParticipants(buf: *std.ArrayList(u8), allocator: Allocator, db: *SqliteDb, detail: PullDetail) !void {
    try appendSectionStart(buf, allocator, "Participants", "Manage participants");
    try buf.appendSlice(allocator, "<div class=\"issue-participants\">");
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    try appendParticipant(buf, allocator, &seen, detail.displayAuthor());
    try appendParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT assignee FROM pull_assignees WHERE pull_id = ? ORDER BY assignee", detail.id);
    try appendParticipantQuery(buf, allocator, db, &seen, "SELECT DISTINCT reviewer FROM pull_reviewers WHERE pull_id = ? ORDER BY reviewer", detail.id);
    try buf.appendSlice(allocator, "</div>");
    try appendSectionEnd(buf, allocator);
}

fn appendParticipantQuery(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    db: *SqliteDb,
    seen: *std.StringHashMap(void),
    comptime sql_text: []const u8,
    pull_id: []const u8,
) !void {
    var stmt = try db.prepare(sql_text);
    defer stmt.deinit();
    try stmt.bindText(1, pull_id);
    while (try stmt.step()) {
        const person = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(person);
        try appendParticipant(buf, allocator, seen, person);
    }
}

fn appendParticipant(buf: *std.ArrayList(u8), allocator: Allocator, seen: *std.StringHashMap(void), person: []const u8) !void {
    if (person.len == 0 or seen.contains(person)) return;
    const key = try allocator.dupe(u8, person);
    errdefer allocator.free(key);
    try seen.put(key, {});
    try appendAvatar(buf, allocator, person, "");
}

fn appendPerson(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try buf.appendSlice(allocator, "<div class=\"issue-sidebar-person\">");
    try appendAvatar(buf, allocator, name, "");
    try appendTemplate(buf, allocator, "<span>{name}</span></div>", .{ .name = name });
}

fn appendPullBranchLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="pull-branch-link" href="{href}"><code>{ref}</code></a>
    , .{
        .href = shared.codeHref(ref, ""),
        .ref = ref,
    });
}

fn appendLocalMergeCheck(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const oid = if (detail.target_oid.len != 0) detail.target_oid else detail.merge_oid;
    const status = try localContainsOid(allocator, repo, oid, detail.base_ref);
    if (status) |contains| {
        try buf.appendSlice(allocator, if (contains) "Confirmed in base ref" else "Not confirmed in base ref");
    } else {
        try buf.appendSlice(allocator, "Unavailable");
    }
}

fn localContainsOid(allocator: Allocator, repo: Repo, oid: []const u8, base_ref: []const u8) !?bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", repo.root, "merge-base", "--is-ancestor", oid, base_ref });
    var result = try runCommand(allocator, argv.items, null, 1024 * 1024);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
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

fn appendAvatar(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, extra_class: []const u8) !void {
    try shared.appendAvatar(buf, allocator, name, extra_class);
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
