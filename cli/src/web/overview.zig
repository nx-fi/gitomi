const std = @import("std");
const git = @import("../git.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const appendEmptyState = shared.appendEmptyState;
const appendFmt = shared.appendFmt;
const appendHtml = shared.appendHtml;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const ensureIndex = index.ensureIndex;
const freeIndexedEvent = index.freeIndexedEvent;
const indexedEventFromStmt = index.indexedEventFromStmt;
const index_event_columns = index.index_event_columns;
const sqlite = index.sqlite;

const max_sloc_output = 512 * 1024;
const local_sloc_bin = "tools/sloc";

const SlocRow = struct {
    ext: []u8,
    code: u64,
    test_count: u64,
    comment: u64,

    fn deinit(self: SlocRow, allocator: Allocator) void {
        allocator.free(self.ext);
    }

    fn total(self: SlocRow) u64 {
        return self.code + self.test_count + self.comment;
    }
};

const SlocStats = struct {
    rows: []SlocRow,
    total_code: u64,
    total_test: u64,
    total_comment: u64,

    fn deinit(self: *SlocStats, allocator: Allocator) void {
        for (self.rows) |row| row.deinit(allocator);
        allocator.free(self.rows);
    }

    fn total(self: SlocStats) u64 {
        return self.total_code + self.total_test + self.total_comment;
    }
};

pub fn renderHomePage(allocator: Allocator, repo: Repo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Overview", "overview");

    const branch = try git.currentBranch(allocator);
    defer allocator.free(branch);
    const changes = git.workingTreeChangeCount(allocator) catch 0;
    var sloc_stats = loadSlocStats(allocator, repo) catch null;
    defer if (sloc_stats) |*stats| stats.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<section class="panel hero">
        \\  <div>
        \\    <p class="eyebrow">Local repository</p>
        \\    <h1>
    );
    try appendHtml(&buf, allocator, std.fs.path.basename(repo.root));
    try buf.appendSlice(allocator, "</h1><p class=\"muted\">");
    try appendHtml(&buf, allocator, repo.root);
    try buf.appendSlice(allocator,
        \\</p>
        \\  </div>
    );
    try appendSlocSummary(&buf, allocator, sloc_stats);
    try buf.appendSlice(allocator,
        \\</section>
        \\<section class="grid two">
        \\  <div class="panel">
        \\    <h2>Repository</h2>
        \\    <dl class="facts">
        \\      <div><dt>Branch</dt><dd>
    );
    try appendHtml(&buf, allocator, branch);
    try buf.appendSlice(allocator, "</dd></div><div><dt>Working tree</dt><dd>");
    try appendFmt(&buf, allocator, "{d} change{s}", .{ changes, if (changes == 1) "" else "s" });
    try buf.appendSlice(allocator,
        \\</dd></div><div><dt>Git directory</dt><dd>
    );
    try appendHtml(&buf, allocator, repo.git_dir);
    try buf.appendSlice(allocator,
        \\</dd></div>
        \\    </dl>
        \\  </div>
        \\  <div class="panel">
        \\    <div class="section-head">
        \\      <h2>Recent Activity</h2>
        \\      <a class="button secondary" href="/events">View all</a>
        \\    </div>
    );
    try appendEventList(&buf, allocator, repo, 6);
    try buf.appendSlice(allocator,
        \\  </div>
        \\</section>
    );

    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendSlocSummary(buf: *std.ArrayList(u8), allocator: Allocator, stats_opt: ?SlocStats) !void {
    try buf.appendSlice(allocator, "<div class=\"sloc-summary\" aria-label=\"Source lines of code\">");
    if (stats_opt) |stats| {
        const total = stats.total();
        try buf.appendSlice(allocator, "<div class=\"sloc-head\"><span>Languages</span><strong>");
        try appendGroupedUnsigned(buf, allocator, total);
        try buf.appendSlice(allocator, " lines</strong></div>");

        if (total == 0 or stats.rows.len == 0) {
            try buf.appendSlice(allocator, "<p class=\"sloc-empty\">No counted source files.</p></div>");
            return;
        }

        try buf.appendSlice(allocator, "<div class=\"language-bar\" aria-hidden=\"true\">");
        for (stats.rows) |row| {
            if (row.total() == 0) continue;
            try buf.appendSlice(allocator, "<span style=\"--share: ");
            try appendPercent(buf, allocator, row.total(), total);
            try buf.appendSlice(allocator, "; --language-color: ");
            try buf.appendSlice(allocator, languageColor(row.ext));
            try buf.appendSlice(allocator, ";\"></span>");
        }
        try buf.appendSlice(allocator, "</div><ul class=\"language-list\">");
        for (stats.rows) |row| {
            if (row.total() == 0) continue;
            try buf.appendSlice(allocator, "<li><span class=\"language-dot\" style=\"--language-color: ");
            try buf.appendSlice(allocator, languageColor(row.ext));
            try buf.appendSlice(allocator, ";\"></span><span class=\"language-name\">");
            try appendHtml(buf, allocator, languageName(row.ext));
            try buf.appendSlice(allocator, "</span><span class=\"language-percent\">");
            try appendPercent(buf, allocator, row.total(), total);
            try buf.appendSlice(allocator, "</span></li>");
        }
        try buf.appendSlice(allocator, "</ul><div class=\"sloc-totals\">");
        try appendSlocTotal(buf, allocator, stats.total_code, "code");
        try appendSlocTotal(buf, allocator, stats.total_test, "tests");
        try appendSlocTotal(buf, allocator, stats.total_comment, "comments");
        try buf.appendSlice(allocator, "</div>");
    } else {
        try buf.appendSlice(allocator,
            \\<div class="sloc-head"><span>Languages</span><strong>Unavailable</strong></div>
            \\<p class="sloc-empty">No SLOC data available.</p>
        );
    }
    try buf.appendSlice(allocator, "</div>");
}

fn appendSlocTotal(buf: *std.ArrayList(u8), allocator: Allocator, value: u64, label: []const u8) !void {
    try buf.appendSlice(allocator, "<span><strong>");
    try appendGroupedUnsigned(buf, allocator, value);
    try buf.appendSlice(allocator, "</strong>");
    try appendHtml(buf, allocator, label);
    try buf.appendSlice(allocator, "</span>");
}

fn appendEventList(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, limit: usize) !void {
    try ensureIndex(allocator, repo);
    var db = try SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    var stmt = try db.prepare("SELECT " ++ index_event_columns ++ " FROM events ORDER BY ordinal LIMIT ?");
    defer stmt.deinit();
    if (limit > std.math.maxInt(i64)) return error.ValueTooLarge;
    try stmt.bindInt64(1, @intCast(limit));

    try buf.appendSlice(allocator, "<div class=\"activity-list\">");
    var shown: usize = 0;
    while (try stmt.step()) {
        const event = try indexedEventFromStmt(allocator, &stmt);
        defer freeIndexedEvent(allocator, event);
        try buf.appendSlice(allocator, "<article><span class=\"dot\"></span><div><strong>");
        try appendHtml(buf, allocator, if (event.valid_json) event.event_type else "invalid-event");
        try buf.appendSlice(allocator, "</strong><p>");
        try appendHtml(buf, allocator, event.subject);
        try buf.appendSlice(allocator, "</p><small>");
        try appendHtml(buf, allocator, event.actor_principal);
        if (event.object_id.len != 0) {
            try buf.appendSlice(allocator, " / #");
            try appendHtml(buf, allocator, event.object_id[0..@min(event.object_id.len, 7)]);
        }
        try buf.appendSlice(allocator, "</small></div></article>");
        shown += 1;
    }
    if (shown == 0) {
        try appendEmptyState(buf, allocator, "No activity yet.", "Gitomi events will appear here after issues, pull requests, or workflow runs are recorded.");
    }
    try buf.appendSlice(allocator, "</div>");
}

fn loadSlocStats(allocator: Allocator, repo: Repo) !?SlocStats {
    const env_cmd = slocCommandFromEnv(allocator) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_cmd) |command| {
        defer allocator.free(command);
        if (std.mem.trim(u8, command, " \t\r\n").len != 0) {
            if (try loadSlocStatsWithCommand(allocator, repo, command)) |stats| return stats;
        }
    }

    const repo_sloc = try std.fs.path.join(allocator, &.{ repo.root, local_sloc_bin });
    defer allocator.free(repo_sloc);

    const candidates = [_][]const u8{ repo_sloc, "sloc" };
    for (candidates) |command| {
        if (try loadSlocStatsWithCommand(allocator, repo, command)) |stats| return stats;
    }
    return null;
}

fn slocCommandFromEnv(allocator: Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "GITOMI_SLOC_BIN") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "SLOC_BIN") catch |fallback_err| switch (fallback_err) {
            error.EnvironmentVariableNotFound => null,
            else => return fallback_err,
        },
        else => return err,
    };
}

fn loadSlocStatsWithCommand(allocator: Allocator, repo: Repo, command: []const u8) !?SlocStats {
    const argv = [_][]const u8{ command, "--summary" };
    var result = runCommandInDir(allocator, &argv, repo.root, max_sloc_output) catch return null;
    defer result.deinit();
    if (result.exitCode() != 0) return null;
    return parseSlocSummary(allocator, result.stdout) catch null;
}

fn runCommandInDir(allocator: Allocator, argv: []const []const u8, cwd: []const u8, max_output_bytes: usize) !git.RunOutput {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    try child.spawn();
    errdefer _ = child.kill() catch {};

    try child.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    const term = try child.wait();

    return .{
        .allocator = allocator,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = term,
    };
}

fn parseSlocSummary(allocator: Allocator, output: []const u8) !?SlocStats {
    var rows: std.ArrayList(SlocRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    var total_code: u64 = 0;
    var total_test: u64 = 0;
    var total_comment: u64 = 0;
    var saw_total = false;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
        const code_token = tokens.next() orelse continue;
        const test_token = tokens.next() orelse continue;
        const comment_token = tokens.next() orelse continue;
        const label = tokens.next() orelse continue;

        const code = parseSlocNumber(code_token) catch continue;
        const test_count = parseSlocNumber(test_token) catch continue;
        const comment = parseSlocNumber(comment_token) catch continue;

        if (std.mem.eql(u8, label, "TOTAL")) {
            total_code = code;
            total_test = test_count;
            total_comment = comment;
            saw_total = true;
            continue;
        }

        if (label.len < 2 or label[0] != '.') continue;
        const ext = try allocator.dupe(u8, label[1..]);
        rows.append(allocator, .{
            .ext = ext,
            .code = code,
            .test_count = test_count,
            .comment = comment,
        }) catch |err| {
            allocator.free(ext);
            return err;
        };
    }

    if (rows.items.len == 0 and !saw_total) return null;

    if (!saw_total) {
        for (rows.items) |row| {
            total_code += row.code;
            total_test += row.test_count;
            total_comment += row.comment;
        }
    }

    std.mem.sort(SlocRow, rows.items, {}, struct {
        fn lessThan(_: void, a: SlocRow, b: SlocRow) bool {
            if (a.total() != b.total()) return a.total() > b.total();
            return std.mem.lessThan(u8, a.ext, b.ext);
        }
    }.lessThan);

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .total_code = total_code,
        .total_test = total_test,
        .total_comment = total_comment,
    };
}

fn parseSlocNumber(text: []const u8) !u64 {
    var value: u64 = 0;
    var saw_digit = false;
    for (text) |c| {
        if (c == ',') continue;
        if (c < '0' or c > '9') return error.InvalidSlocNumber;
        saw_digit = true;
        value = try std.math.add(u64, try std.math.mul(u64, value, 10), c - '0');
    }
    if (!saw_digit) return error.InvalidSlocNumber;
    return value;
}

fn appendGroupedUnsigned(buf: *std.ArrayList(u8), allocator: Allocator, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&digits, "{d}", .{value});
    for (text, 0..) |c, i| {
        if (i != 0 and (text.len - i) % 3 == 0) try buf.append(allocator, ',');
        try buf.append(allocator, c);
    }
}

fn appendPercent(buf: *std.ArrayList(u8), allocator: Allocator, value: u64, total: u64) !void {
    const tenths = percentTenths(value, total);
    try appendFmt(buf, allocator, "{d}.{d}%", .{ tenths / 10, tenths % 10 });
}

fn percentTenths(value: u64, total: u64) u64 {
    if (total == 0) return 0;
    const scaled = (@as(u128, value) * 1000 + @as(u128, total) / 2) / @as(u128, total);
    return @intCast(@min(scaled, 1000));
}

fn languageName(ext: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return "Zig";
    if (std.ascii.eqlIgnoreCase(ext, "js") or std.ascii.eqlIgnoreCase(ext, "mjs") or std.ascii.eqlIgnoreCase(ext, "cjs")) return "JavaScript";
    if (std.ascii.eqlIgnoreCase(ext, "ts") or std.ascii.eqlIgnoreCase(ext, "tsx")) return "TypeScript";
    if (std.ascii.eqlIgnoreCase(ext, "css")) return "CSS";
    if (std.ascii.eqlIgnoreCase(ext, "sh") or std.ascii.eqlIgnoreCase(ext, "bash")) return "Shell";
    if (std.ascii.eqlIgnoreCase(ext, "md")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(ext, "py")) return "Python";
    if (std.ascii.eqlIgnoreCase(ext, "rs")) return "Rust";
    if (std.ascii.eqlIgnoreCase(ext, "go")) return "Go";
    if (std.ascii.eqlIgnoreCase(ext, "html") or std.ascii.eqlIgnoreCase(ext, "htm")) return "HTML";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return "SVG";
    if (std.ascii.eqlIgnoreCase(ext, "yml") or std.ascii.eqlIgnoreCase(ext, "yaml")) return "YAML";
    if (std.ascii.eqlIgnoreCase(ext, "sql")) return "SQL";
    if (std.ascii.eqlIgnoreCase(ext, "nix")) return "Nix";
    return ext;
}

fn languageColor(ext: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return "#ec915c";
    if (std.ascii.eqlIgnoreCase(ext, "js") or std.ascii.eqlIgnoreCase(ext, "mjs") or std.ascii.eqlIgnoreCase(ext, "cjs")) return "#f1e05a";
    if (std.ascii.eqlIgnoreCase(ext, "ts") or std.ascii.eqlIgnoreCase(ext, "tsx")) return "#3178c6";
    if (std.ascii.eqlIgnoreCase(ext, "css")) return "#563d7c";
    if (std.ascii.eqlIgnoreCase(ext, "sh") or std.ascii.eqlIgnoreCase(ext, "bash")) return "#89e051";
    if (std.ascii.eqlIgnoreCase(ext, "md")) return "#083fa1";
    if (std.ascii.eqlIgnoreCase(ext, "py")) return "#3572a5";
    if (std.ascii.eqlIgnoreCase(ext, "rs")) return "#dea584";
    if (std.ascii.eqlIgnoreCase(ext, "go")) return "#00add8";
    if (std.ascii.eqlIgnoreCase(ext, "html") or std.ascii.eqlIgnoreCase(ext, "htm")) return "#e34c26";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "#292929";
    if (std.ascii.eqlIgnoreCase(ext, "svg") or std.ascii.eqlIgnoreCase(ext, "xml")) return "#0060ac";
    if (std.ascii.eqlIgnoreCase(ext, "yml") or std.ascii.eqlIgnoreCase(ext, "yaml")) return "#cb171e";
    if (std.ascii.eqlIgnoreCase(ext, "sql")) return "#e38c00";
    if (std.ascii.eqlIgnoreCase(ext, "nix")) return "#7e7eff";
    return "#8b949e";
}

test "web overview parses sloc summary rows" {
    const output =
        \\  CODE   TEST  COMMENT  TYPE
        \\─────────────────────────────────────────────────
        \\ 1,247      0        0  .css █▊
        \\   409      0       39  .js  ▋
        \\12,830    479        0  .zig ████████████████████
        \\──────────────────────
        \\14,486    479       39  TOTAL
        \\
    ;
    var stats = (try parseSlocSummary(std.testing.allocator, output)).?;
    defer stats.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 14_486), stats.total_code);
    try std.testing.expectEqual(@as(u64, 479), stats.total_test);
    try std.testing.expectEqual(@as(u64, 39), stats.total_comment);
    try std.testing.expectEqual(@as(usize, 3), stats.rows.len);
    try std.testing.expectEqualStrings("zig", stats.rows[0].ext);
    try std.testing.expectEqual(@as(u64, 13_309), stats.rows[0].total());
}

test "web overview formats sloc percentages" {
    try std.testing.expectEqual(@as(u64, 833), percentTenths(5, 6));
    try std.testing.expectEqual(@as(u64, 0), percentTenths(0, 0));
}
