const std = @import("std");
const git = @import("../git.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const source_stats = @import("source_stats.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const Button = shared.Button;
const appendButtonLink = shared.appendButtonLink;
const appendEmptyState = shared.appendEmptyState;
const appendFact = shared.appendFact;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const ensureIndex = index.ensureIndex;
const freeIndexedEvent = index.freeIndexedEvent;
const groupedUnsigned = shared.groupedUnsigned;
const indexedEventFromStmt = index.indexedEventFromStmt;
const index_event_columns = index.index_event_columns;
const literalHref = shared.literalHref;
const percent = shared.percent;
const sqlite = index.sqlite;

pub fn renderHomePage(allocator: Allocator, repo: Repo) ![]u8 {
    if (try shared.renderIndexingPageIfStale(allocator, repo, "Overview", "overview", "/overview")) |body| return body;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Overview", "overview");

    const branch = try git.currentBranch(allocator);
    defer allocator.free(branch);
    const changes = git.workingTreeChangeCount(allocator) catch 0;
    var sloc_stats = source_stats.loadRepositoryStats(allocator, repo) catch null;
    defer if (sloc_stats) |*stats| stats.deinit(allocator);

    try appendTemplate(&buf, allocator,
        \\<section class="panel hero">
        \\  <div>
        \\    <p class="eyebrow">Local repository</p>
        \\    <h1>{repo_name}</h1><p class="muted">{repo_root}</p>
        \\  </div>
    , .{
        .repo_name = std.fs.path.basename(repo.root),
        .repo_root = repo.root,
    });
    try appendSlocSummary(&buf, allocator, sloc_stats);
    try appendTemplate(&buf, allocator,
        \\</section>
        \\<section class="grid two">
        \\  <div class="panel">
        \\    <h2>Repository</h2>
        \\    <dl class="facts">
    , .{});
    try appendFact(&buf, allocator, "Branch", branch);
    try appendTemplate(&buf, allocator,
        \\      <div><dt>Working tree</dt><dd>{changes} {changes_label}</dd></div>
    , .{
        .changes = changes,
        .changes_label = if (changes == 1) "change" else "changes",
    });
    try appendFact(&buf, allocator, "Git directory", repo.git_dir);
    try appendTemplate(&buf, allocator,
        \\    </dl>
        \\  </div>
        \\  <div class="panel">
        \\    <div class="section-head">
        \\      <h2>Recent Activity</h2>
    , .{});
    try appendButtonLink(&buf, allocator, Button{ .label = "View all", .href = literalHref("/events") });
    try appendTemplate(&buf, allocator,
        \\    </div>
    , .{});
    try appendEventList(&buf, allocator, repo, 6);
    try appendTemplate(&buf, allocator,
        \\  </div>
        \\</section>
    , .{});

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendSlocSummary(buf: *std.ArrayList(u8), allocator: Allocator, stats_opt: ?source_stats.Stats) !void {
    try appendTemplate(buf, allocator,
        \\<div class="sloc-summary" aria-label="Source lines of code">
    , .{});
    if (stats_opt) |stats| {
        const total = stats.total();
        try appendTemplate(buf, allocator,
            \\<div class="sloc-head"><span>Languages</span><strong>{total} lines</strong></div>
        , .{ .total = groupedUnsigned(total) });

        if (total == 0 or stats.rows.len == 0) {
            try appendTemplate(buf, allocator,
                \\<p class="sloc-empty">No counted source files.</p></div>
            , .{});
            return;
        }

        try appendTemplate(buf, allocator,
            \\<div class="language-bar" aria-hidden="true">
        , .{});
        for (stats.rows) |row| {
            if (row.total() == 0) continue;
            try appendTemplate(buf, allocator,
                \\<span style="--share: {share}; --language-color: {color};"></span>
            , .{
                .share = percent(row.total(), total),
                .color = source_stats.languageColor(row.language),
            });
        }
        try appendTemplate(buf, allocator,
            \\</div><ul class="language-list">
        , .{});
        for (stats.rows) |row| {
            if (row.total() == 0) continue;
            try appendTemplate(buf, allocator,
                \\<li><span class="language-dot" style="--language-color: {color};"></span><span class="language-name">{name}</span><span class="language-percent">{share}</span></li>
            , .{
                .color = source_stats.languageColor(row.language),
                .name = source_stats.languageDisplayName(row.language),
                .share = percent(row.total(), total),
            });
        }
        try appendTemplate(buf, allocator,
            \\</ul><div class="sloc-totals">
        , .{});
        try appendSlocTotal(buf, allocator, stats.total_code, "code");
        try appendSlocTotal(buf, allocator, stats.total_test, "tests");
        try appendSlocTotal(buf, allocator, stats.total_comment, "comments");
        try appendTemplate(buf, allocator, "</div>", .{});
    } else {
        try appendTemplate(buf, allocator,
            \\<div class="sloc-head"><span>Languages</span><strong>Unavailable</strong></div>
            \\<p class="sloc-empty">No SLOC data available.</p>
        , .{});
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendSlocTotal(buf: *std.ArrayList(u8), allocator: Allocator, value: u64, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span><strong>{value}</strong>{label}</span>
    , .{
        .value = groupedUnsigned(value),
        .label = label,
    });
}

fn appendEventList(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, limit: usize) !void {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal LIMIT ?");
    defer stmt.deinit();
    if (limit > std.math.maxInt(i64)) return error.ValueTooLarge;
    try stmt.bindInt64(1, @intCast(limit));

    try appendTemplate(buf, allocator, "<div class=\"activity-list\">", .{});
    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try appendTemplate(buf, allocator,
            \\<article><span class="dot"></span><div><strong>{event_type}</strong><p>{subject}</p><small>{actor_principal}
        , .{
            .event_type = if (event.valid_json) event.event_type else "invalid-event",
            .subject = event.subject,
            .actor_principal = event.actor_principal,
        });
        if (event.object_id.len != 0) {
            try appendTemplate(buf, allocator, " / #{object_id}", .{
                .object_id = event.object_id[0..@min(event.object_id.len, 7)],
            });
        }
        try appendTemplate(buf, allocator, "</small></div></article>", .{});
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(buf, allocator, "No activity yet.", "Gitomi events will appear here after issues, pull requests, or workflow runs are recorded.");
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}
