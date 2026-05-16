const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const appendUrlEncoded = shared.appendUrlEncoded;
const groupedUnsigned = shared.groupedUnsigned;
const sqlite = index.sqlite;

pub fn renderLabelsPage(allocator: Allocator, repo: Repo) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Labels", "labels", "/labels")) |body| return body;
    try index.ensureIndex(allocator, repo);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const label_count = try countLabels(&db);

    try appendShellStart(&buf, allocator, repo, "Labels", "labels");
    try shared.appendSettingsLayoutStart(&buf, allocator, "labels");
    try appendLabelsHeader(&buf, allocator);
    try appendLabelsToolbar(&buf, allocator);
    try appendLabelsListStart(&buf, allocator, label_count);

    var stmt = try db.prepare(
        \\SELECT label, SUM(issue_count), SUM(pull_count)
        \\FROM (
        \\  SELECT label, COUNT(DISTINCT issue_id) AS issue_count, 0 AS pull_count
        \\  FROM issue_labels
        \\  GROUP BY label
        \\  UNION ALL
        \\  SELECT label, 0 AS issue_count, COUNT(DISTINCT pull_id) AS pull_count
        \\  FROM pull_labels
        \\  GROUP BY label
        \\)
        \\GROUP BY label
        \\ORDER BY lower(label), label
    );
    defer stmt.deinit();

    var shown: usize = 0;
    while (try stmt.step()) {
        const label = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(label);
        const issue_count = @as(usize, @intCast(stmt.columnInt64(1)));
        const pull_count = @as(usize, @intCast(stmt.columnInt64(2)));
        try appendLabelRow(&buf, allocator, label, issue_count, pull_count);
        shown += 1;
    }

    if (shown == 0) {
        try buf.appendSlice(allocator, "<div class=\"labels-empty-state\"><strong>No labels found.</strong><p>Labels appear here after issues or pull requests use them.</p></div>");
    }

    try buf.appendSlice(allocator,
        \\    </div>
        \\  <div class="labels-empty-state" data-label-empty hidden><strong>No matching labels.</strong><p>Change the search text to widen the list.</p></div>
        \\  </section>
        \\</section>
    );
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn countLabels(db: *SqliteDb) !usize {
    var stmt = try db.prepare(
        \\SELECT COUNT(*)
        \\FROM (
        \\  SELECT label FROM issue_labels
        \\  UNION
        \\  SELECT label FROM pull_labels
        \\)
    );
    defer stmt.deinit();
    if (!(try stmt.step())) return 0;
    return @as(usize, @intCast(stmt.columnInt64(0)));
}

fn appendLabelsHeader(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<section class="labels-page" data-labels-page>
        \\  <header class="labels-page-head">
        \\    <h1>Labels</h1>
        \\    <button class="button primary labels-new-button" type="button" disabled>New label</button>
        \\  </header>
    );
}

fn appendLabelsToolbar(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\  <div class="labels-toolbar">
        \\    <label class="labels-search"><span class="button-icon icon-search" aria-hidden="true"></span><input type="search" placeholder="Search all labels" aria-label="Search all labels" data-label-search></label>
        \\    <details class="issues-filter-menu labels-sort-menu" data-popover-menu>
        \\      <summary>Sort: <span data-label-sort-label>Name</span></summary>
        \\      <div class="issues-filter-popover labels-sort-popover" role="menu">
        \\        <button class="issues-filter-option selected" type="button" role="menuitem" data-label-sort="name"><span>Name</span></button>
        \\        <button class="issues-filter-option" type="button" role="menuitem" data-label-sort="usage"><span>Most used</span></button>
        \\      </div>
        \\    </details>
        \\  </div>
    );
}

fn appendLabelsListStart(buf: *std.ArrayList(u8), allocator: Allocator, label_count: usize) !void {
    try appendTemplate(buf, allocator,
        \\  <section class="panel labels-panel">
        \\    <header class="labels-list-head">
        \\      <strong><span data-label-visible-count>{label_count}</span> <span data-label-count-word>{label_word}</span></strong>
        \\    </header>
        \\    <div class="labels-list" data-label-list>
    , .{
        .label_count = groupedUnsigned(@intCast(label_count)),
        .label_word = if (label_count == 1) "label" else "labels",
    });
}

fn appendLabelRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    issue_count: usize,
    pull_count: usize,
) !void {
    const total_count = issue_count + pull_count;
    const summary = try labelUsageSummaryOwned(allocator, issue_count, pull_count);
    defer allocator.free(summary);
    try appendTemplate(buf, allocator,
        \\<article class="labels-list-row" data-label-row data-label-name="{label}" data-label-total="{total_count}" data-label-search-text="{label} {summary}">
        \\  <div class="labels-row-main">
    , .{
        .label = label,
        .total_count = total_count,
        .summary = summary,
    });
    try appendLabelChip(buf, allocator, label);
    try appendTemplate(buf, allocator,
        \\    <p>{summary}</p>
        \\  </div>
        \\  <div class="labels-row-links">
    , .{ .summary = summary });
    try appendIssueLink(buf, allocator, label, issue_count);
    try appendTemplate(buf, allocator,
        \\    <span>{pull_count} {pull_label}</span>
        \\  </div>
    , .{
        .pull_count = groupedUnsigned(@intCast(pull_count)),
        .pull_label = if (pull_count == 1) "pull request" else "pull requests",
    });
    try appendLabelActionMenu(buf, allocator);
    try buf.appendSlice(allocator, "</article>");
}

fn labelUsageSummaryOwned(allocator: Allocator, issue_count: usize, pull_count: usize) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Used by {d} {s} and {d} {s}",
        .{
            issue_count,
            if (issue_count == 1) "issue" else "issues",
            pull_count,
            if (pull_count == 1) "pull request" else "pull requests",
        },
    );
}

fn appendIssueLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, issue_count: usize) !void {
    if (issue_count == 0) {
        try buf.appendSlice(allocator, "<span>0 issues</span>");
        return;
    }

    try buf.appendSlice(allocator, "<a href=\"/issues?state=all&amp;label=");
    try appendUrlEncoded(buf, allocator, label);
    try appendTemplate(buf, allocator,
        \\">{issue_count} {issue_label}</a>
    , .{
        .issue_count = groupedUnsigned(@intCast(issue_count)),
        .issue_label = if (issue_count == 1) "issue" else "issues",
    });
}

fn appendLabelActionMenu(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try buf.appendSlice(allocator,
        \\<details class="issue-action-menu labels-row-menu" data-popover-menu>
        \\  <summary class="issue-kebab-button" aria-label="Label actions" title="Label actions"></summary>
        \\  <div class="issue-action-popover labels-row-popover" role="menu">
        \\    <button type="button" role="menuitem" disabled>Edit label</button>
        \\    <button type="button" role="menuitem" disabled>Delete label</button>
        \\  </div>
        \\</details>
    );
}

fn appendLabelChip(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="issue-label {kind} {color_class}">{label}</span>
    , .{
        .kind = labelKind(label),
        .color_class = labelColorClass(label),
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

fn labelColorClass(label: []const u8) []const u8 {
    return switch (std.hash.Wyhash.hash(0, label) % 12) {
        0 => "label-color-0",
        1 => "label-color-1",
        2 => "label-color-2",
        3 => "label-color-3",
        4 => "label-color-4",
        5 => "label-color-5",
        6 => "label-color-6",
        7 => "label-color-7",
        8 => "label-color-8",
        9 => "label-color-9",
        10 => "label-color-10",
        else => "label-color-11",
    };
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}
