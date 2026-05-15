const std = @import("std");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyCell = shared.appendEmptyCell;
const appendSectionHead = shared.appendSectionHead;
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

    try appendShellStart(&buf, allocator, repo, "Labels", "labels");
    try shared.appendSettingsLayoutStart(&buf, allocator, "labels");
    try buf.appendSlice(allocator, "<section class=\"panel settings-panel labels-panel\">");
    try appendSectionHead(&buf, allocator, "Settings", "Labels", null);
    try buf.appendSlice(allocator,
        \\  <div class="table-wrap">
        \\    <table>
        \\      <thead><tr><th>Label</th><th>Issues</th><th>Pull requests</th><th>Total</th></tr></thead>
        \\      <tbody>
    );

    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();

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
        try appendEmptyCell(&buf, allocator, 4, "No labels found.");
    }

    try buf.appendSlice(allocator,
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\</section>
    );
    try shared.appendSettingsLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendLabelRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    issue_count: usize,
    pull_count: usize,
) !void {
    try buf.appendSlice(allocator, "<tr><td class=\"labels-name-cell\">");
    try appendLabelChip(buf, allocator, label);
    try buf.appendSlice(allocator, "</td><td class=\"labels-count-cell\">");
    try appendIssueCount(buf, allocator, label, issue_count);
    try appendTemplate(buf, allocator,
        \\</td><td class="labels-count-cell">{pull_count}</td><td class="labels-count-cell labels-total-cell">{total_count}</td></tr>
    , .{
        .pull_count = groupedUnsigned(@intCast(pull_count)),
        .total_count = groupedUnsigned(@intCast(issue_count + pull_count)),
    });
}

fn appendIssueCount(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, issue_count: usize) !void {
    if (issue_count == 0) {
        try appendTemplate(buf, allocator, "{count}", .{ .count = groupedUnsigned(0) });
        return;
    }

    try buf.appendSlice(allocator, "<a href=\"/issues?state=all&amp;label=");
    try appendUrlEncoded(buf, allocator, label);
    try appendTemplate(buf, allocator, "\">{count}</a>", .{
        .count = groupedUnsigned(@intCast(issue_count)),
    });
}

fn appendLabelChip(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8) !void {
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
