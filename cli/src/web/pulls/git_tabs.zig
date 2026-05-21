const std = @import("std");
const git = @import("../../git.zig");
const repo_mod = @import("../../repo.zig");
const work_items = @import("../../work_items.zig");
const diff_render = @import("../diff/render.zig");
const shared = @import("../shared.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const PullDetail = work_items.PullDetail;
const appendEmptyState = shared.appendEmptyState;
const appendTemplate = shared.appendTemplate;
const commitHref = shared.commitHref;

const max_pull_diff_bytes = work_items.max_pull_diff_bytes;

pub const Counts = struct {
    commits: ?usize = null,
    files: ?usize = null,
};

const PullCommit = struct {
    full_hash: []u8,
    short_hash: []u8,
    author: []u8,
    relative: []u8,
    subject: []u8,

    fn deinit(self: PullCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.relative);
        allocator.free(self.subject);
    }
};

pub fn loadCounts(allocator: Allocator, repo: Repo, detail: PullDetail) !Counts {
    var counts: Counts = .{};
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return counts;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return counts;

    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    if (try work_items.gitMaybe(allocator, repo, &.{ "rev-list", "--count", range }, 64 * 1024)) |raw_count| {
        defer allocator.free(raw_count);
        const trimmed = std.mem.trim(u8, raw_count, " \t\r\n");
        counts.commits = std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
    }

    if (try work_items.gitMaybe(allocator, repo, &.{ "diff", "--name-only", "--find-renames", base, git_refs.head }, max_pull_diff_bytes)) |raw_files| {
        defer allocator.free(raw_files);
        var files: usize = 0;
        var lines = std.mem.splitScalar(u8, raw_files, '\n');
        while (lines.next()) |raw_line| {
            if (std.mem.trim(u8, raw_line, " \t\r\n").len != 0) files += 1;
        }
        counts.files = files;
    }

    return counts;
}

pub fn appendCommits(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
    const commits_opt = try loadCommits(allocator, repo, detail);
    const commits = commits_opt orelse {
        if (detail.commit_count) |count| {
            const hint = try gitDataFetchHint(allocator, detail);
            defer allocator.free(hint);
            const detail_text = try std.fmt.allocPrint(allocator, "GitHub reported {d} {s}. {s}", .{ count, commitWord(count), hint });
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "Commit range unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "Commit range unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer freeCommits(allocator, commits);
    if (commits.len == 0) {
        try appendEmptyState(buf, allocator, "No commits in this range.", "The head ref currently has no commits ahead of the merge base.");
        return;
    }
    try buf.appendSlice(allocator, "<section class=\"panel commits-panel\"><div class=\"commit-list\">");
    for (commits) |commit| {
        try appendTemplate(buf, allocator,
            \\<article class="commit-row pull-commit-row"><div><a class="commit-title" href="{href}">{subject}</a><p>{author} committed {relative}</p></div><code class="commit-sha">{short_hash}</code></article>
        , .{
            .href = commitHref(commit.full_hash),
            .subject = commit.subject,
            .author = commit.author,
            .relative = commit.relative,
            .short_hash = commit.short_hash,
        });
    }
    try buf.appendSlice(allocator, "</div></section>");
}

pub fn appendFiles(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail, raw_ref: []const u8) !void {
    const diff_opt = try work_items.loadPullDiff(allocator, repo, detail, 3);
    const diff = diff_opt orelse {
        if (detail.changed_files != null or detail.additions != null or detail.deletions != null) {
            const detail_text = try importedFileSummary(allocator, detail);
            defer allocator.free(detail_text);
            try appendEmptyState(buf, allocator, "File changes unavailable.", detail_text);
        } else {
            try appendEmptyState(buf, allocator, "File changes unavailable.", "Fetch or create the base and head refs locally to inspect this pull request.");
        }
        return;
    };
    defer allocator.free(diff);
    try buf.appendSlice(allocator, "<section class=\"diff-section pull-diff-section\" data-diff-review-action=\"/pulls/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "/comments\">");
    try diff_render.append(buf, allocator, diff, .{
        .empty_message = "The head ref currently has no patch ahead of the merge base.",
    });
    try buf.appendSlice(allocator, "</section>");
}

fn importedFileSummary(allocator: Allocator, detail: PullDetail) ![]u8 {
    const file_count = detail.changed_files orelse 0;
    const additions = detail.additions orelse 0;
    const deletions = detail.deletions orelse 0;
    const hint = try gitDataFetchHint(allocator, detail);
    defer allocator.free(hint);
    if (detail.additions != null or detail.deletions != null) {
        return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s} with +{d} -{d}. {s}", .{ file_count, if (file_count == 1) "file" else "files", additions, deletions, hint });
    }
    return std.fmt.allocPrint(allocator, "GitHub reported {d} changed {s}. {s}", .{ file_count, if (file_count == 1) "file" else "files", hint });
}

fn gitDataFetchHint(allocator: Allocator, detail: PullDetail) ![]u8 {
    if (detail.legacy_number > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Fetch the PR head with `git fetch origin pull/{d}/head:refs/remotes/origin/pr/{d}`, then reload this page.",
            .{ detail.legacy_number, detail.legacy_number },
        );
    }
    return allocator.dupe(u8, "Fetch or create the base and head refs locally, then reload this page.");
}

fn loadCommits(allocator: Allocator, repo: Repo, detail: PullDetail) !?[]PullCommit {
    const git_refs = (try work_items.loadPullGitRefs(allocator, repo, detail)) orelse return null;
    defer git_refs.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, git_refs.base, git_refs.head);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return null;
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, git_refs.head });
    defer allocator.free(range);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "log", "--reverse", "--format=%H%x00%h%x00%an%x00%cr%x00%s", range }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var commits: std.ArrayList(PullCommit) = .empty;
    errdefer {
        for (commits.items) |commit| commit.deinit(allocator);
        commits.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, 0);
        try commits.append(allocator, .{
            .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .short_hash = try allocator.dupe(u8, cols.next() orelse ""),
            .author = try allocator.dupe(u8, cols.next() orelse ""),
            .relative = try allocator.dupe(u8, cols.next() orelse ""),
            .subject = try allocator.dupe(u8, cols.next() orelse ""),
        });
    }
    return try commits.toOwnedSlice(allocator);
}

fn freeCommits(allocator: Allocator, commits: []PullCommit) void {
    for (commits) |commit| commit.deinit(allocator);
    allocator.free(commits);
}

fn commitWord(count: usize) []const u8 {
    return if (count == 1) "commit" else "commits";
}
