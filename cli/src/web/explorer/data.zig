const std = @import("std");
const git = @import("../../git.zig");
const index = @import("../../index.zig");
const repo_mod = @import("../../repo.zig");
const shared = @import("../shared.zig");
const model = @import("model.zig");
const file_info = @import("file_info.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const sqlite = index.sqlite;
const runCommand = git.runCommand;

pub const unstaged_ref = "working tree";
pub const worktree_ref_prefix = "worktree:";
const max_blame_display_bytes = 16 * 1024 * 1024;
const max_blame_display_epoch_seconds: i64 = 253_402_300_799;
const max_git_path_output = 128 * 1024 * 1024;
const min_tree_entry_commit_history = 32;
const max_tree_entry_commit_history = 512;
const tree_entry_commit_history_per_entry = 4;
const max_tree_entry_commit_output = 1024 * 1024;
const max_tree_entry_commit_fallback_output = 64 * 1024;
const tree_entry_commit_format = "--format=%x1e%H%x09%s%x09%cr";

const TreeEntry = model.TreeEntry;
const TreeNavEntry = model.TreeNavEntry;
const BranchRef = model.BranchRef;
const WorktreeRef = model.WorktreeRef;
const BranchScope = model.BranchScope;
const TreeEntryCommit = model.TreeEntryCommit;
const ChangeState = model.ChangeState;
const CommitSummary = model.CommitSummary;
const BlameLine = model.BlameLine;
const BlameHeader = model.BlameHeader;
const RootEntryCounts = model.RootEntryCounts;
const RepositoryOperationState = model.RepositoryOperationState;
const RootGitStatus = model.RootGitStatus;
const BranchSyncStatus = model.BranchSyncStatus;
const PathQuery = model.PathQuery;
const containsNul = file_info.containsNul;
const findReadme = file_info.findReadme;
const normalizedPathOwned = file_info.normalizedPathOwned;
const queryValueOwned = file_info.queryValueOwned;
const trimOwned = file_info.trimOwned;

pub fn loadRootGitStatus(allocator: Allocator, repo: Repo) !RootGitStatus {
    var status = RootGitStatus{};

    if (try gitMaybe(allocator, repo, &.{ "status", "--porcelain=v2" }, git.max_git_output)) |raw| {
        defer allocator.free(raw);
        parseRootGitStatusV2(&status, raw);
    }
    try loadRootDiffStats(allocator, repo, &status);
    status.worktree_count = loadWorktreeCount(allocator, repo) catch 1;
    if (status.worktree_count == 0) status.worktree_count = 1;
    status.tracked_file_size_bytes = loadTrackedFileSizeBytes(allocator, repo) catch null;
    status.disk_size_bytes = loadDiskSizeBytes(allocator, repo) catch null;
    status.operation_state = loadRepositoryOperationState(allocator, repo) catch .clean;

    return status;
}

pub fn loadBranchSyncStatus(allocator: Allocator, repo: Repo, ref: []const u8) !?BranchSyncStatus {
    const root = try worktreeRootOwned(allocator, repo, ref) orelse try allocator.dupe(u8, repo.root);
    defer allocator.free(root);
    const branchish = if (isFilesystemRef(ref)) "HEAD" else ref;

    const upstream_ref = try std.fmt.allocPrint(allocator, "{s}@{{upstream}}", .{branchish});
    defer allocator.free(upstream_ref);

    const upstream_raw = try gitMaybeAt(allocator, root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", upstream_ref }, 4096) orelse return null;
    defer allocator.free(upstream_raw);
    const upstream = std.mem.trim(u8, upstream_raw, " \t\r\n");
    if (upstream.len == 0) return null;

    const range = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ upstream_ref, branchish });
    defer allocator.free(range);
    const counts_raw = try gitMaybeAt(allocator, root, &.{ "rev-list", "--left-right", "--count", range }, 4096) orelse return null;
    defer allocator.free(counts_raw);

    var fields = std.mem.tokenizeAny(u8, counts_raw, " \t\r\n");
    const behind_raw = fields.next() orelse return null;
    const ahead_raw = fields.next() orelse return null;
    const behind = std.fmt.parseUnsigned(usize, behind_raw, 10) catch return null;
    const ahead = std.fmt.parseUnsigned(usize, ahead_raw, 10) catch return null;

    return .{
        .upstream = try allocator.dupe(u8, upstream),
        .ahead = ahead,
        .behind = behind,
    };
}

pub fn parseRootGitStatusV2(status: *RootGitStatus, raw: []const u8) void {
    status.staged_paths = 0;
    status.unstaged_paths = 0;
    status.untracked_paths = 0;
    status.conflict_paths = 0;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;
        switch (line[0]) {
            '1', '2' => parseOrdinaryStatusRecord(status, line),
            'u' => status.conflict_paths += 1,
            '?' => status.untracked_paths += 1,
            else => {},
        }
    }
}

pub fn parseOrdinaryStatusRecord(status: *RootGitStatus, line: []const u8) void {
    if (line.len < 4 or line[1] != ' ') return;
    const index_status = line[2];
    const worktree_status = line[3];
    if (index_status != '.' and index_status != ' ') status.staged_paths += 1;
    if (worktree_status != '.' and worktree_status != ' ') status.unstaged_paths += 1;
}

pub fn loadRootDiffStats(allocator: Allocator, repo: Repo, status: *RootGitStatus) !void {
    const raw = try gitMaybe(allocator, repo, &.{ "diff", "--numstat", "HEAD", "--" }, git.max_git_output) orelse return;
    defer allocator.free(raw);
    parseRootDiffNumstat(status, raw);
}

pub fn parseRootDiffNumstat(status: *RootGitStatus, raw: []const u8) void {
    status.lines_added = 0;
    status.lines_removed = 0;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const added_raw = fields.next() orelse continue;
        const removed_raw = fields.next() orelse continue;
        if (std.mem.eql(u8, added_raw, "-") or std.mem.eql(u8, removed_raw, "-")) continue;
        const added = std.fmt.parseUnsigned(u64, added_raw, 10) catch continue;
        const removed = std.fmt.parseUnsigned(u64, removed_raw, 10) catch continue;
        status.lines_added +|= added;
        status.lines_removed +|= removed;
    }
}

pub fn loadWorktreeCount(allocator: Allocator, repo: Repo) !usize {
    const raw = try gitMaybe(allocator, repo, &.{ "worktree", "list", "--porcelain" }, git.max_git_output) orelse return 0;
    defer allocator.free(raw);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) count += 1;
    }
    return count;
}

pub fn loadWorktreeRefs(allocator: Allocator, repo: Repo) ![]WorktreeRef {
    const raw = try gitMaybe(allocator, repo, &.{ "worktree", "list", "--porcelain" }, git.max_git_output) orelse {
        return allocator.alloc(WorktreeRef, 0);
    };
    defer allocator.free(raw);

    var worktrees: std.ArrayList(WorktreeRef) = .empty;
    errdefer {
        for (worktrees.items) |worktree| worktree.deinit(allocator);
        worktrees.deinit(allocator);
    }

    var path: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var detached = false;
    var bare = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            try appendParsedWorktreeRef(allocator, &worktrees, path, branch, detached, bare);
            path = null;
            branch = null;
            detached = false;
            bare = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            branch = worktreeBranchLabel(line["branch ".len..]);
        } else if (std.mem.eql(u8, line, "detached")) {
            detached = true;
        } else if (std.mem.eql(u8, line, "bare")) {
            bare = true;
        }
    }
    try appendParsedWorktreeRef(allocator, &worktrees, path, branch, detached, bare);

    std.mem.sort(WorktreeRef, worktrees.items, {}, struct {
        pub fn lessThan(_: void, a: WorktreeRef, b: WorktreeRef) bool {
            return std.ascii.lessThanIgnoreCase(a.path, b.path);
        }
    }.lessThan);

    return worktrees.toOwnedSlice(allocator);
}

pub fn appendParsedWorktreeRef(
    allocator: Allocator,
    worktrees: *std.ArrayList(WorktreeRef),
    path_opt: ?[]const u8,
    branch_opt: ?[]const u8,
    detached: bool,
    bare: bool,
) !void {
    if (bare) return;
    const path = path_opt orelse return;
    if (path.len == 0) return;

    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);
    const value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ worktree_ref_prefix, path });
    errdefer allocator.free(value);
    const label_ref = branch_opt orelse if (detached) "detached" else "worktree";
    const label = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ path, label_ref });
    errdefer allocator.free(label);

    try worktrees.append(allocator, .{
        .path = path_owned,
        .value = value,
        .label = label,
    });
}

pub fn worktreeBranchLabel(ref: []const u8) []const u8 {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, heads_prefix)) return ref[heads_prefix.len..];
    return ref;
}

pub fn loadDiskSizeBytes(allocator: Allocator, repo: Repo) !?usize {
    var argv = [_][]const u8{ "du", "-sk", repo.root };
    var result = try runCommand(allocator, &argv, null, 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return null;

    var fields = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    const kibibytes_raw = fields.next() orelse return null;
    const kibibytes = std.fmt.parseUnsigned(usize, kibibytes_raw, 10) catch return null;
    const max = std.math.maxInt(usize);
    if (kibibytes > max / 1024) return max;
    return kibibytes * 1024;
}

pub fn loadTrackedFileSizeBytes(allocator: Allocator, repo: Repo) !?usize {
    const tracked = try gitMaybe(allocator, repo, &.{ "ls-files", "-z" }, max_git_path_output) orelse return null;
    defer allocator.free(tracked);

    var total: usize = 0;
    var entries = std.mem.splitScalar(u8, tracked, 0);
    while (entries.next()) |path| {
        if (path.len == 0) continue;
        const stat_opt = safeWorktreePathStat(allocator, repo.root, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const stat = stat_opt orelse continue;
        if (stat.kind != .file) continue;
        const max = std.math.maxInt(usize);
        if (stat.size > max - total) {
            total = max;
        } else {
            total += stat.size;
        }
    }
    return total;
}

pub fn loadRepositoryOperationState(allocator: Allocator, repo: Repo) !RepositoryOperationState {
    if (try gitPathExists(allocator, repo, "rebase-merge")) return .rebase;
    if (try gitPathExists(allocator, repo, "rebase-apply")) return .rebase;
    if (try gitPathExists(allocator, repo, "MERGE_HEAD")) return .merge;
    if (try gitPathExists(allocator, repo, "CHERRY_PICK_HEAD")) return .cherry_pick;
    if (try gitPathExists(allocator, repo, "REVERT_HEAD")) return .revert;
    return .clean;
}

pub fn gitPathExists(allocator: Allocator, repo: Repo, git_path: []const u8) !bool {
    const raw = try gitMaybe(allocator, repo, &.{ "rev-parse", "--path-format=absolute", "--git-path", git_path }, 1024) orelse return false;
    defer allocator.free(raw);
    const path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn countNonEmptyLines(raw: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len != 0) count += 1;
    }
    return count;
}

pub fn rootEntryCounts(entries: []const TreeEntry) RootEntryCounts {
    var counts = RootEntryCounts{};
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.kind, "tree")) {
            counts.directories += 1;
        } else {
            counts.files += 1;
        }
    }
    return counts;
}

pub fn loadRootEntryCounts(allocator: Allocator, repo: Repo, ref: []const u8) !?RootEntryCounts {
    if (isFilesystemRef(ref)) return loadWorktreeRootEntryCounts(allocator, repo, ref);

    const spec = try objectSpec(allocator, ref, "");
    defer allocator.free(spec);
    const raw = try gitMaybe(allocator, repo, &.{ "ls-tree", "-z", spec }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var counts = RootEntryCounts{};
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const meta = record[0..tab];
        var fields = std.mem.tokenizeScalar(u8, meta, ' ');
        _ = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        if (std.mem.eql(u8, kind, "tree")) {
            counts.directories += 1;
        } else {
            counts.files += 1;
        }
    }
    return counts;
}

fn loadWorktreeRootEntryCounts(allocator: Allocator, repo: Repo, ref: []const u8) !?RootEntryCounts {
    const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
    defer allocator.free(root);
    const raw = try listWorktreePaths(allocator, root) orelse return null;
    defer allocator.free(raw);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var counts = RootEntryCounts{};
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const child_name = directChildName("", record) orelse continue;
        if (seen.contains(child_name)) continue;
        try seen.put(child_name, {});

        const kind = worktreePathKind(root, child_name) catch null orelse continue;
        switch (kind) {
            .tree => counts.directories += 1,
            .blob => counts.files += 1,
        }
    }
    return counts;
}

pub fn loadReadmeSummaryOwned(allocator: Allocator, repo: Repo, ref: []const u8, entries: []const TreeEntry) !?[]u8 {
    const readme = findReadme(entries) orelse return null;
    const content = try loadBlobBytes(allocator, repo, ref, readme, 64 * 1024) orelse return null;
    defer allocator.free(content);
    if (containsNul(content)) return null;
    return try markdownSummaryOwned(allocator, content);
}

pub fn markdownSummaryOwned(allocator: Allocator, content: []const u8) !?[]u8 {
    var in_fence = false;
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (line.len == 0) {
            if (paragraph.items.len != 0) break;
            continue;
        }
        if (paragraph.items.len == 0 and shouldSkipSummaryLine(line)) continue;
        if (paragraph.items.len != 0) try paragraph.append(allocator, ' ');
        try appendCleanMarkdownText(&paragraph, allocator, line);
        if (paragraph.items.len >= 220) break;
    }

    const trimmed = std.mem.trim(u8, paragraph.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    const max_len = @min(trimmed.len, 220);
    return try allocator.dupe(u8, std.mem.trimRight(u8, trimmed[0..max_len], " \t\r\n.,;:"));
}

pub fn shouldSkipSummaryLine(line: []const u8) bool {
    return line[0] == '#' or
        line[0] == '!' or
        std.mem.startsWith(u8, line, "[!") or
        std.mem.startsWith(u8, line, "<p") or
        std.mem.startsWith(u8, line, "<div") or
        std.mem.startsWith(u8, line, "<img");
}

pub fn appendCleanMarkdownText(buf: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            '`', '*', '_', '~' => {},
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, ']') orelse {
                    try buf.append(allocator, c);
                    continue;
                };
                if (close + 1 < line.len and line[close + 1] == '(') {
                    try appendCleanMarkdownText(buf, allocator, line[i + 1 .. close]);
                    const link_end = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse close + 1;
                    i = link_end;
                    continue;
                }
                try buf.append(allocator, c);
            },
            '<' => {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, '>') orelse {
                    try buf.append(allocator, c);
                    continue;
                };
                i = close;
            },
            else => try buf.append(allocator, c),
        }
    }
}

pub fn appendRepositoryMarkdown(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    content: []const u8,
) !void {
    try shared.appendMarkdownSource(buf, allocator, content, .{
        .ref = ref,
        .path = path,
    });
}

pub fn physicalLineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var lines: usize = 0;
    for (content) |c| {
        if (c == '\n') lines += 1;
    }
    if (content[content.len - 1] != '\n') lines += 1;
    return lines;
}

pub fn loadTreeEntries(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]TreeEntry {
    if (isFilesystemRef(ref)) return loadWorktreeEntries(allocator, repo, ref, path);

    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const raw = try gitMaybe(allocator, repo, &.{ "ls-tree", "-z", "-l", spec }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var entries: std.ArrayList(TreeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const meta = record[0..tab];
        const name = record[tab + 1 ..];
        var fields = std.mem.tokenizeScalar(u8, meta, ' ');
        const mode = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        const oid = fields.next() orelse continue;
        const size = fields.next() orelse "";
        try entries.append(allocator, .{
            .mode = try allocator.dupe(u8, mode),
            .kind = try allocator.dupe(u8, kind),
            .oid = try allocator.dupe(u8, oid),
            .size = try allocator.dupe(u8, size),
            .name = try allocator.dupe(u8, name),
        });
    }
    std.mem.sort(TreeEntry, entries.items, {}, treeEntryLessThan);
    if (entries.items.len != 0) {
        loadTreeEntryCommits(allocator, repo, ref, path, entries.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn loadTreeEntryCommits(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, entries: []TreeEntry) !void {
    if (isFilesystemRef(ref)) return;

    var index_by_name = std.StringHashMap(usize).init(allocator);
    defer index_by_name.deinit();
    for (entries, 0..) |entry, i| {
        try index_by_name.put(entry.name, i);
    }

    var log_args = try treeEntryCommitLogArgs(allocator, ref, entries.len);
    defer log_args.deinit(allocator);
    const raw = try gitMaybe(allocator, repo, log_args.items[0..], max_tree_entry_commit_output);
    const text = raw orelse return;
    defer allocator.free(text);

    var commit: ?LogCommit = null;
    var filled: usize = 0;
    var records = std.mem.splitScalar(u8, text, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (parseLogCommitHeader(record)) |parsed| {
            commit = parsed;
            continue;
        }

        const changed_path = normalizeLogPathRecord(record);
        if (changed_path.len == 0) continue;
        const parsed_commit = commit orelse continue;
        const child_name = directChildName(path, changed_path) orelse continue;
        const entry_index = index_by_name.get(child_name) orelse continue;
        if (entries[entry_index].last_commit != null) continue;
        entries[entry_index].last_commit = try treeEntryCommitOwned(allocator, parsed_commit);
        filled += 1;
        if (filled == entries.len) break;
    }

    if (filled < entries.len) {
        try loadMissingTreeEntryCommits(allocator, repo.root, ref, path, entries);
    }
}

pub fn loadFilesystemTreeEntryCommits(allocator: Allocator, root: []const u8, path: []const u8, entries: []TreeEntry) !void {
    var index_by_name = std.StringHashMap(usize).init(allocator);
    defer index_by_name.deinit();
    for (entries, 0..) |entry, i| {
        try index_by_name.put(entry.name, i);
    }

    try markChangedFilesystemChildren(allocator, root, path, entries, &index_by_name);

    var log_args = try treeEntryCommitLogArgs(allocator, "HEAD", entries.len);
    defer log_args.deinit(allocator);
    const raw = try gitMaybeAt(allocator, root, log_args.items[0..], max_tree_entry_commit_output);
    const text = raw orelse return;
    defer allocator.free(text);

    var commit: ?LogCommit = null;
    var filled: usize = 0;
    for (entries) |entry| {
        if (entry.last_commit != null) filled += 1;
    }

    var records = std.mem.splitScalar(u8, text, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (parseLogCommitHeader(record)) |parsed| {
            commit = parsed;
            continue;
        }

        const changed_path = normalizeLogPathRecord(record);
        if (changed_path.len == 0) continue;
        const parsed_commit = commit orelse continue;
        const child_name = directChildName(path, changed_path) orelse continue;
        const entry_index = index_by_name.get(child_name) orelse continue;
        if (entries[entry_index].last_commit != null) continue;
        entries[entry_index].last_commit = try treeEntryCommitOwned(allocator, parsed_commit);
        filled += 1;
        if (filled == entries.len) break;
    }

    if (filled < entries.len) {
        try loadMissingTreeEntryCommits(allocator, root, "HEAD", path, entries);
    }
}

fn loadMissingTreeEntryCommits(
    allocator: Allocator,
    root: []const u8,
    ref: []const u8,
    path: []const u8,
    entries: []TreeEntry,
) !void {
    for (entries) |*entry| {
        if (entry.last_commit != null) continue;

        const entry_path = try childPath(allocator, path, entry.name);
        defer allocator.free(entry_path);

        const raw = try gitMaybeAt(allocator, root, &.{
            "log",
            "-1",
            tree_entry_commit_format,
            "-z",
            ref,
            "--",
            entry_path,
        }, max_tree_entry_commit_fallback_output) orelse continue;
        defer allocator.free(raw);

        var records = std.mem.splitScalar(u8, raw, 0);
        while (records.next()) |record| {
            if (parseLogCommitHeader(record)) |parsed| {
                entry.last_commit = try treeEntryCommitOwned(allocator, parsed);
                break;
            }
        }
    }
}

pub fn markChangedFilesystemChildren(
    allocator: Allocator,
    root: []const u8,
    path: []const u8,
    entries: []TreeEntry,
    index_by_name: *const std.StringHashMap(usize),
) !void {
    const raw = if (path.len == 0)
        try gitMaybeAt(allocator, root, &.{ "status", "--porcelain=v1", "-z" }, git.max_git_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybeAt(allocator, root, &.{ "status", "--porcelain=v1", "-z", "--", pathspec }, git.max_git_output);
    };
    const text = raw orelse return;
    defer allocator.free(text);

    var records = std.mem.splitScalar(u8, text, 0);
    while (records.next()) |record| {
        if (record.len < 4 or record[2] != ' ') continue;
        const state = changeStateFromStatus(record[0], record[1]);
        if (state == .none) continue;
        const changed_path = record[3..];
        const child_name = directChildName(path, changed_path) orelse continue;
        const entry_index = index_by_name.get(child_name) orelse continue;
        const existing_state = if (entries[entry_index].last_commit) |commit| commit.change_state else .none;
        const merged_state = mergeChangeStates(existing_state, state);
        if (entries[entry_index].last_commit) |commit| commit.deinit(allocator);
        entries[entry_index].last_commit = try syntheticTreeEntryCommitOwned(allocator, merged_state);
    }
}

pub fn changeStateFromStatus(index_status: u8, worktree_status: u8) ChangeState {
    const staged = index_status != ' ' and index_status != '?';
    const unstaged = worktree_status != ' ';
    if (staged and unstaged) return .staged_and_unstaged;
    if (staged) return .staged;
    if (unstaged) return .unstaged;
    return .none;
}

pub fn mergeChangeStates(a: ChangeState, b: ChangeState) ChangeState {
    if (a == .staged_and_unstaged or b == .staged_and_unstaged) return .staged_and_unstaged;
    if ((a == .staged and b == .unstaged) or (a == .unstaged and b == .staged)) return .staged_and_unstaged;
    if (a != .none) return a;
    return b;
}

pub fn changeStateSubject(state: ChangeState) []const u8 {
    return switch (state) {
        .none => "",
        .staged => "has staged changes",
        .unstaged => "has unstaged changes",
        .staged_and_unstaged => "has staged and unstaged changes",
    };
}

pub fn changeStateClass(state: ChangeState) []const u8 {
    return switch (state) {
        .none => "",
        .staged => "staged",
        .unstaged => "unstaged",
        .staged_and_unstaged => "staged-and-unstaged",
    };
}

pub fn treeEntryCommitOwned(allocator: Allocator, commit: LogCommit) !TreeEntryCommit {
    const full_hash = try allocator.dupe(u8, commit.full_hash);
    errdefer allocator.free(full_hash);
    const subject = try allocator.dupe(u8, commit.subject);
    errdefer allocator.free(subject);
    const relative = try allocator.dupe(u8, commit.relative);
    return .{
        .full_hash = full_hash,
        .subject = subject,
        .relative = relative,
    };
}

pub fn syntheticTreeEntryCommitOwned(allocator: Allocator, state: ChangeState) !TreeEntryCommit {
    const full_hash = try allocator.dupe(u8, "");
    errdefer allocator.free(full_hash);
    const subject = changeStateSubject(state);
    const subject_owned = try allocator.dupe(u8, subject);
    errdefer allocator.free(subject_owned);
    const relative = try allocator.dupe(u8, "");
    return .{
        .full_hash = full_hash,
        .subject = subject_owned,
        .relative = relative,
        .synthetic = true,
        .change_state = state,
    };
}

const TreeEntryCommitLogArgs = struct {
    max_count_arg: []u8,
    items: [7][]const u8,

    fn deinit(self: TreeEntryCommitLogArgs, allocator: Allocator) void {
        allocator.free(self.max_count_arg);
    }
};

fn treeEntryCommitLogArgs(allocator: Allocator, ref: []const u8, entry_count: usize) !TreeEntryCommitLogArgs {
    const max_count_arg = try std.fmt.allocPrint(allocator, "--max-count={d}", .{treeEntryCommitHistoryLimit(entry_count)});
    return .{
        .max_count_arg = max_count_arg,
        .items = .{ "log", max_count_arg, tree_entry_commit_format, "--name-only", "-z", ref, "--" },
    };
}

fn treeEntryCommitHistoryLimit(entry_count: usize) usize {
    if (entry_count == 0) return 0;
    const scaled = if (entry_count > max_tree_entry_commit_history / tree_entry_commit_history_per_entry)
        max_tree_entry_commit_history
    else
        entry_count * tree_entry_commit_history_per_entry;
    return @min(max_tree_entry_commit_history, @max(min_tree_entry_commit_history, scaled));
}

pub const LogCommit = struct {
    full_hash: []const u8,
    subject: []const u8,
    relative: []const u8,
};

pub fn parseLogCommitHeader(record: []const u8) ?LogCommit {
    if (record.len == 0 or record[0] != 0x1e) return null;
    const payload = record[1..];
    const tab = std.mem.indexOfScalar(u8, payload, '\t') orelse return null;
    const last_tab = std.mem.lastIndexOfScalar(u8, payload, '\t') orelse return null;
    if (tab == 0 or last_tab <= tab) return null;
    return .{
        .full_hash = payload[0..tab],
        .subject = payload[tab + 1 .. last_tab],
        .relative = payload[last_tab + 1 ..],
    };
}

pub fn normalizeLogPathRecord(record: []const u8) []const u8 {
    return std.mem.trimLeft(u8, record, "\r\n");
}

pub fn directChildName(parent: []const u8, changed_path: []const u8) ?[]const u8 {
    const rest = if (parent.len == 0)
        changed_path
    else blk: {
        if (!std.mem.startsWith(u8, changed_path, parent)) return null;
        if (changed_path.len <= parent.len or changed_path[parent.len] != '/') return null;
        break :blk changed_path[parent.len + 1 ..];
    };
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    return rest[0..slash];
}

pub fn loadBlameLines(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]BlameLine {
    if (isFilesystemRef(ref)) return null;

    const raw = try gitMaybe(allocator, repo, &.{
        "blame",
        "--line-porcelain",
        "--root",
        ref,
        "--",
        path,
    }, max_blame_display_bytes) orelse return null;
    defer allocator.free(raw);
    return try parseBlamePorcelain(allocator, raw);
}

pub fn parseBlamePorcelain(allocator: Allocator, raw: []const u8) ![]BlameLine {
    var lines: std.ArrayList(BlameLine) = .empty;
    errdefer {
        for (lines.items) |line| line.deinit(allocator);
        lines.deinit(allocator);
    }

    var header: ?BlameHeader = null;
    var author: []const u8 = "";
    var author_time: []const u8 = "";
    var author_tz: []const u8 = "";
    var summary: []const u8 = "";

    var raw_lines = std.mem.splitScalar(u8, raw, '\n');
    while (raw_lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len != 0 and line[0] == '\t') {
            if (header) |value| {
                try appendBlameRecord(&lines, allocator, value, author, author_time, author_tz, summary, line[1..]);
            }
            header = null;
            author = "";
            author_time = "";
            author_tz = "";
            summary = "";
            continue;
        }

        if (header == null) {
            header = parseBlameHeader(line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "author ")) {
            author = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "author-time ")) {
            author_time = line["author-time ".len..];
        } else if (std.mem.startsWith(u8, line, "author-tz ")) {
            author_tz = line["author-tz ".len..];
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            summary = line["summary ".len..];
        }
    }

    return try lines.toOwnedSlice(allocator);
}

pub fn parseBlameHeader(line: []const u8) ?BlameHeader {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const commit = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const final_line = fields.next() orelse return null;
    return .{
        .commit = commit,
        .line_no = std.fmt.parseUnsigned(usize, final_line, 10) catch return null,
    };
}

pub fn appendBlameRecord(
    lines: *std.ArrayList(BlameLine),
    allocator: Allocator,
    header: BlameHeader,
    author: []const u8,
    author_time: []const u8,
    author_tz: []const u8,
    summary: []const u8,
    content: []const u8,
) !void {
    var record = BlameLine{
        .commit = try allocator.dupe(u8, header.commit),
        .short_hash = try shortHashOwned(allocator, header.commit),
        .author = try allocator.dupe(u8, if (author.len == 0) "Unknown" else author),
        .date = try authorDateOwned(allocator, author_time, author_tz),
        .author_timestamp = parseAuthorTimestamp(author_time),
        .summary = try allocator.dupe(u8, summary),
        .line_no = header.line_no,
        .content = try allocator.dupe(u8, content),
    };
    errdefer record.deinit(allocator);
    try lines.append(allocator, record);
}

pub fn shortHashOwned(allocator: Allocator, hash: []const u8) ![]u8 {
    return allocator.dupe(u8, hash[0..@min(hash.len, 8)]);
}

pub fn authorDateOwned(allocator: Allocator, author_time: []const u8, author_tz: []const u8) ![]u8 {
    const adjusted = adjustedAuthorSeconds(author_time, author_tz) orelse return allocator.dupe(u8, "unknown");
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(adjusted) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    return std.fmt.allocPrint(
        allocator,
        "{d}-{s}{d}-{s}{d}",
        .{ year_day.year, if (month < 10) "0" else "", month, if (day < 10) "0" else "", day },
    );
}

fn adjustedAuthorSeconds(author_time: []const u8, author_tz: []const u8) ?i64 {
    const parsed = std.fmt.parseInt(i64, author_time, 10) catch return null;
    const adjusted = std.math.add(i64, parsed, parseTimezoneOffset(author_tz)) catch return null;
    if (adjusted < 0) return 0;
    if (adjusted > max_blame_display_epoch_seconds) return null;
    return adjusted;
}

pub fn parseAuthorTimestamp(author_time: []const u8) ?i64 {
    if (author_time.len == 0) return null;
    const parsed = std.fmt.parseInt(i64, author_time, 10) catch return null;
    if (parsed > max_blame_display_epoch_seconds) return null;
    return parsed;
}

pub fn blameAgeClass(author_timestamp: ?i64, now: i64) []const u8 {
    const timestamp = author_timestamp orelse return "age-unknown";
    if (timestamp >= now) return "age-now";

    const seconds_per_day = 24 * 60 * 60;
    const age_seconds = std.math.sub(i64, now, timestamp) catch return "age-unknown";
    const age_days = @divFloor(age_seconds, seconds_per_day);
    if (age_days <= 1) return "age-now";
    if (age_days <= 7) return "age-week";
    if (age_days <= 30) return "age-month";
    if (age_days <= 90) return "age-quarter";
    if (age_days <= 365) return "age-year";
    return "age-old";
}

pub fn relativeTimeOwned(allocator: Allocator, author_timestamp: ?i64, now: i64) ![]u8 {
    const timestamp = author_timestamp orelse return allocator.dupe(u8, "unknown");
    if (timestamp >= now) return allocator.dupe(u8, "now");

    const age_seconds = std.math.sub(i64, now, timestamp) catch return allocator.dupe(u8, "unknown");
    if (age_seconds < 60) return allocator.dupe(u8, "now");

    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;
    if (age_seconds < hour) {
        return relativeUnitOwned(allocator, @divFloor(age_seconds, minute), "minute");
    }
    if (age_seconds < day) {
        return relativeUnitOwned(allocator, @divFloor(age_seconds, hour), "hour");
    }

    const age_days = @divFloor(age_seconds, day);
    if (age_days < 30) {
        return relativeUnitOwned(allocator, age_days, "day");
    }

    const age_months = @divFloor(age_days, 30);
    if (age_months <= 24) {
        return relativeUnitOwned(allocator, age_months, "month");
    }

    const age_years = @max(@as(i64, 1), @divFloor(age_days, 365));
    return relativeUnitOwned(allocator, age_years, "year");
}

pub fn relativeUnitOwned(allocator: Allocator, value: i64, unit: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d} {s}{s} ago",
        .{ value, unit, if (value == 1) "" else "s" },
    );
}

pub fn parseTimezoneOffset(value: []const u8) i64 {
    if (value.len != 5) return 0;
    const sign: i64 = switch (value[0]) {
        '+' => 1,
        '-' => -1,
        else => return 0,
    };
    const hours = std.fmt.parseInt(i64, value[1..3], 10) catch return 0;
    const minutes = std.fmt.parseInt(i64, value[3..5], 10) catch return 0;
    return sign * ((hours * 60 * 60) + (minutes * 60));
}

pub fn loadCommitSummary(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?CommitSummary {
    if (isFilesystemRef(ref)) return null;

    const format = "--format=%H%x09%h%x09%an%x09%ae%x09%s%x09%cr";
    const raw = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "log", "-1", format, ref }, 1024 * 1024)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "log", "-1", format, ref, "--", pathspec }, 1024 * 1024);
    };
    const text = raw orelse return null;
    defer allocator.free(text);

    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;

    const full_end = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const hash_start = full_end + 1;
    const hash_end = std.mem.indexOfScalarPos(u8, line, hash_start, '\t') orelse return null;
    const author_start = hash_end + 1;
    const author_end = std.mem.indexOfScalarPos(u8, line, author_start, '\t') orelse return null;
    const email_start = author_end + 1;
    const email_end = std.mem.indexOfScalarPos(u8, line, email_start, '\t') orelse return null;
    const relative_start = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return null;
    if (relative_start <= email_end) return null;

    return .{
        .full_hash = try allocator.dupe(u8, line[0..full_end]),
        .hash = try allocator.dupe(u8, line[hash_start..hash_end]),
        .author = try allocator.dupe(u8, line[author_start..author_end]),
        .author_email = try allocator.dupe(u8, line[email_start..email_end]),
        .subject = try allocator.dupe(u8, line[email_end + 1 .. relative_start]),
        .relative = try allocator.dupe(u8, line[relative_start + 1 ..]),
    };
}

pub fn loadCommitCount(allocator: Allocator, repo: Repo, ref: []const u8) !?usize {
    if (isFilesystemRef(ref)) return null;

    const raw = try gitMaybe(allocator, repo, &.{ "rev-list", "--count", ref }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

pub fn loadRefCount(allocator: Allocator, repo: Repo, namespace: []const u8) !usize {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)", namespace }, git.max_git_output) orelse return 0;
    defer allocator.free(raw);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len != 0) count += 1;
    }
    return count;
}

pub fn loadTreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
    if (isFilesystemRef(ref)) return loadWorktreeNavEntries(allocator, repo, ref);

    const raw = try gitMaybe(allocator, repo, &.{ "ls-tree", "-z", "-r", "-t", ref }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var entries: std.ArrayList(TreeNavEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        const meta = record[0..tab];
        const path = record[tab + 1 ..];
        var fields = std.mem.tokenizeScalar(u8, meta, ' ');
        _ = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        try entries.append(allocator, .{
            .kind = try allocator.dupe(u8, kind),
            .path = try allocator.dupe(u8, path),
        });
    }
    std.mem.sort(TreeNavEntry, entries.items, {}, treeNavEntryLessThan);

    return try entries.toOwnedSlice(allocator);
}

pub fn loadWorktreeEntries(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]TreeEntry {
    const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
    defer allocator.free(root);
    const raw = try listWorktreePaths(allocator, root) orelse return null;
    defer allocator.free(raw);

    var entries: std.ArrayList(TreeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const child_name = directChildName(path, record) orelse continue;
        if (treeEntryIndexByName(entries.items, child_name) != null) continue;

        const child_path = try childPath(allocator, path, child_name);
        defer allocator.free(child_path);
        const direct = std.mem.eql(u8, child_path, record);
        const kind = if (direct) worktreePathKind(root, child_path) catch null else .tree;
        const entry_kind = kind orelse continue;
        const is_tree = entry_kind == .tree;
        const size = if (is_tree) null else worktreeBlobSize(root, child_path) catch null;

        try entries.append(allocator, try worktreeTreeEntryOwned(allocator, child_name, is_tree, size));
    }

    std.mem.sort(TreeEntry, entries.items, {}, treeEntryLessThan);
    if (entries.items.len != 0) {
        loadFilesystemTreeEntryCommits(allocator, root, path, entries.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }
    return try entries.toOwnedSlice(allocator);
}

pub fn loadWorktreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
    const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
    defer allocator.free(root);
    const raw = try listWorktreePaths(allocator, root) orelse return null;
    defer allocator.free(raw);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var entries: std.ArrayList(TreeNavEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (worktreePathKind(root, record) catch null == null) continue;

        var cursor: usize = 0;
        while (cursor < record.len) {
            const slash = std.mem.indexOfScalarPos(u8, record, cursor, '/');
            const end = slash orelse record.len;
            const entry_path = record[0..end];
            if (!seen.contains(entry_path)) {
                const is_tree = slash != null;
                const owned_path = try allocator.dupe(u8, entry_path);
                errdefer allocator.free(owned_path);
                try seen.put(owned_path, {});
                try entries.append(allocator, .{
                    .kind = try allocator.dupe(u8, if (is_tree) "tree" else "blob"),
                    .path = owned_path,
                });
            }
            if (slash == null) break;
            cursor = end + 1;
        }
    }

    std.mem.sort(TreeNavEntry, entries.items, {}, treeNavEntryLessThan);
    return try entries.toOwnedSlice(allocator);
}

pub fn listWorktreePaths(allocator: Allocator, root: []const u8) !?[]u8 {
    return gitMaybeAt(allocator, root, &.{ "ls-files", "-z", "-c", "-o", "--exclude-standard" }, git.max_git_output);
}

pub const WorktreePathKind = enum {
    blob,
    tree,
};

pub fn worktreePathKind(root: []const u8, path: []const u8) !?WorktreePathKind {
    if (path.len == 0) return .tree;
    const stat = try safeWorktreePathStat(std.heap.page_allocator, root, path) orelse return null;
    return switch (stat.kind) {
        .directory => .tree,
        .file => .blob,
        else => null,
    };
}

pub fn worktreeObjectType(allocator: Allocator, root: []const u8, path: []const u8) !?[]u8 {
    const kind = try worktreePathKind(root, path) orelse return null;
    return try allocator.dupe(u8, switch (kind) {
        .blob => "blob",
        .tree => "tree",
    });
}

pub fn worktreeBlobSize(root: []const u8, path: []const u8) !?usize {
    const stat = try safeWorktreePathStat(std.heap.page_allocator, root, path) orelse return null;
    if (stat.kind != .file) return null;
    return stat.size;
}

pub fn readWorktreeFile(allocator: Allocator, root: []const u8, path: []const u8, max_bytes: usize) !?[]u8 {
    const absolute_path = try safeWorktreeFilePath(allocator, root, path) orelse return null;
    defer allocator.free(absolute_path);
    return std.fs.cwd().readFileAlloc(allocator, absolute_path, max_bytes) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => return err,
    };
}

fn safeWorktreeFilePath(allocator: Allocator, root: []const u8, path: []const u8) !?[]u8 {
    const stat = try safeWorktreePathStat(allocator, root, path) orelse return null;
    if (stat.kind != .file) return null;
    return try absoluteWorktreePath(allocator, root, path);
}

fn safeWorktreePathStat(allocator: Allocator, root: []const u8, path: []const u8) !?std.fs.File.Stat {
    if (path.len == 0) return std.fs.cwd().statFile(root) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };

    var cursor: usize = 0;
    while (cursor < path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, cursor, '/');
        const end = slash orelse path.len;
        const prefix = path[0..end];
        const absolute_path = try absoluteWorktreePath(allocator, root, prefix);
        defer allocator.free(absolute_path);

        const stat = std.fs.cwd().statFile(absolute_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        if (stat.kind == .sym_link) return null;
        if (slash == null) return stat;
        if (stat.kind != .directory) return null;
        cursor = end + 1;
    }
    return null;
}

pub fn absoluteWorktreePath(allocator: Allocator, root: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, root);
    return std.fs.path.join(allocator, &.{ root, path });
}

pub fn worktreeTreeEntryOwned(allocator: Allocator, name: []const u8, is_tree: bool, size: ?usize) !TreeEntry {
    return .{
        .mode = try allocator.dupe(u8, if (is_tree) "040000" else "100644"),
        .kind = try allocator.dupe(u8, if (is_tree) "tree" else "blob"),
        .oid = try allocator.dupe(u8, ""),
        .size = if (size) |bytes| try std.fmt.allocPrint(allocator, "{d}", .{bytes}) else try allocator.dupe(u8, "-"),
        .name = try allocator.dupe(u8, name),
    };
}

pub fn treeEntryIndexByName(entries: []const TreeEntry, name: []const u8) ?usize {
    for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) return i;
    }
    return null;
}

pub fn loadBranchRefs(allocator: Allocator, repo: Repo) ![]BranchRef {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)%09%(refname:short)", "refs/heads", "refs/remotes" }, git.max_git_output) orelse {
        return allocator.alloc(BranchRef, 0);
    };
    defer allocator.free(raw);

    var pull_branch_activity = try loadPullBranchActivity(allocator, repo);
    defer pull_branch_activity.deinit();
    const current_branch = currentBranchNameOwned(allocator, repo) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    defer if (current_branch) |branch| allocator.free(branch);

    var branches: std.ArrayList(BranchRef) = .empty;
    errdefer {
        for (branches.items) |branch| branch.deinit(allocator);
        branches.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var cols = std.mem.splitScalar(u8, trimmed, '\t');
        const full_ref = cols.next() orelse continue;
        const name = cols.next() orelse continue;
        if (std.mem.endsWith(u8, full_ref, "/HEAD")) continue;
        const scope = branchScopeForFullRef(full_ref) orelse continue;
        if (pull_branch_activity.branchIsInactive(full_ref, name, current_branch)) continue;
        try branches.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .scope = scope,
        });
    }
    std.mem.sort(BranchRef, branches.items, {}, branchRefLessThan);
    try branches.insert(allocator, 0, .{
        .name = try allocator.dupe(u8, unstaged_ref),
        .scope = .unstaged,
    });
    return branches.toOwnedSlice(allocator);
}

const BranchSortGroup = enum {
    unstaged,
    main,
    master,
    other,
};

fn branchRefLessThan(_: void, a: BranchRef, b: BranchRef) bool {
    const a_group = branchSortGroup(a);
    const b_group = branchSortGroup(b);
    if (a_group != b_group) return @intFromEnum(a_group) < @intFromEnum(b_group);
    const a_sort_name = branchSortName(a);
    const b_sort_name = branchSortName(b);
    if (!std.ascii.eqlIgnoreCase(a_sort_name, b_sort_name)) return std.ascii.lessThanIgnoreCase(a_sort_name, b_sort_name);
    if (a.scope != b.scope) return @intFromEnum(a.scope) < @intFromEnum(b.scope);
    return std.mem.lessThan(u8, a.name, b.name);
}

fn branchSortGroup(branch: BranchRef) BranchSortGroup {
    if (branch.scope == .unstaged) return .unstaged;
    const sort_name = branchSortName(branch);
    if (std.ascii.eqlIgnoreCase(sort_name, "main")) return .main;
    if (std.ascii.eqlIgnoreCase(sort_name, "master")) return .master;
    return .other;
}

fn branchSortName(branch: BranchRef) []const u8 {
    if (branch.scope == .remote and std.mem.startsWith(u8, branch.name, "origin/")) {
        return branch.name["origin/".len..];
    }
    return branch.name;
}

const PullBranchActivity = struct {
    allocator: Allocator,
    open: std.StringHashMap(void),
    inactive: std.StringHashMap(void),

    fn init(allocator: Allocator) PullBranchActivity {
        return .{
            .allocator = allocator,
            .open = std.StringHashMap(void).init(allocator),
            .inactive = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *PullBranchActivity) void {
        freeStringSet(self.allocator, &self.open);
        freeStringSet(self.allocator, &self.inactive);
    }

    fn addOpenHeadRef(self: *PullBranchActivity, head_ref: []const u8) !void {
        try self.addHeadRef(&self.open, head_ref);
    }

    fn addInactiveHeadRef(self: *PullBranchActivity, head_ref: []const u8) !void {
        try self.addHeadRef(&self.inactive, head_ref);
    }

    fn addHeadRef(self: *PullBranchActivity, set: *std.StringHashMap(void), head_ref: []const u8) !void {
        const trimmed = std.mem.trim(u8, head_ref, " \t\r\n");
        if (trimmed.len == 0) return;
        try putStringSetValue(self.allocator, set, trimmed);

        if (std.mem.startsWith(u8, trimmed, "refs/heads/")) {
            try putStringSetValue(self.allocator, set, trimmed["refs/heads/".len..]);
            return;
        }

        if (remoteTrackingBranchName(trimmed)) |branch_name| {
            try putStringSetValue(self.allocator, set, branch_name);
            return;
        }

        if (remoteShortBranchName(trimmed)) |branch_name| {
            try putStringSetValue(self.allocator, set, branch_name);
        }
    }

    fn branchIsInactive(self: PullBranchActivity, full_ref: []const u8, short_name: []const u8, current_branch: ?[]const u8) bool {
        if (branchMatchesName(full_ref, short_name, current_branch)) return false;
        const branch_name = branchNameFromFullRef(full_ref) orelse short_name;
        if (branchNameInSet(&self.open, full_ref, short_name, branch_name)) return false;
        return branchNameInSet(&self.inactive, full_ref, short_name, branch_name);
    }
};

fn loadPullBranchActivity(allocator: Allocator, repo: Repo) !PullBranchActivity {
    var activity = PullBranchActivity.init(allocator);
    errdefer activity.deinit();

    var db = SqliteDb.open(allocator, repo.index_path, sqlite.SQLITE_OPEN_READONLY, true) catch return activity;
    defer db.deinit();

    var stmt = db.prepare(
        \\SELECT head_ref, state
        \\FROM pulls
        \\WHERE state IN ('open', 'merged', 'closed')
    ) catch return activity;
    defer stmt.deinit();

    while (stmt.step() catch return activity) {
        const head_ref = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(head_ref);
        const state = try stmt.columnTextDup(allocator, 1);
        defer allocator.free(state);
        if (std.mem.eql(u8, state, "open")) {
            try activity.addOpenHeadRef(head_ref);
        } else {
            try activity.addInactiveHeadRef(head_ref);
        }
    }

    return activity;
}

fn currentBranchNameOwned(allocator: Allocator, repo: Repo) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "branch", "--show-current" }, 512 * 1024) orelse return null;
    defer allocator.free(raw);
    const branch = std.mem.trim(u8, raw, " \t\r\n");
    if (branch.len == 0) return null;
    return try allocator.dupe(u8, branch);
}

fn putStringSetValue(allocator: Allocator, set: *std.StringHashMap(void), value: []const u8) !void {
    if (value.len == 0 or set.contains(value)) return;
    const key = try allocator.dupe(u8, value);
    errdefer allocator.free(key);
    const entry = try set.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
    }
    entry.value_ptr.* = {};
}

fn freeStringSet(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var keys = set.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    set.deinit();
}

fn branchNameInSet(set: *const std.StringHashMap(void), full_ref: []const u8, short_name: []const u8, branch_name: []const u8) bool {
    return set.contains(full_ref) or set.contains(short_name) or set.contains(branch_name);
}

fn branchMatchesName(full_ref: []const u8, short_name: []const u8, candidate_opt: ?[]const u8) bool {
    const candidate = candidate_opt orelse return false;
    const branch_name = branchNameFromFullRef(full_ref) orelse short_name;
    return std.mem.eql(u8, candidate, full_ref) or
        std.mem.eql(u8, candidate, short_name) or
        std.mem.eql(u8, candidate, branch_name);
}

fn branchNameFromFullRef(full_ref: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) return full_ref["refs/heads/".len..];
    return remoteTrackingBranchName(full_ref);
}

fn remoteShortBranchName(ref: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, ref, "refs/")) return null;
    const slash = std.mem.indexOfScalar(u8, ref, '/') orelse return null;
    if (slash + 1 >= ref.len) return null;
    const remote = ref[0..slash];
    if (std.mem.eql(u8, remote, "origin") or std.mem.eql(u8, remote, "upstream")) return ref[slash + 1 ..];
    return null;
}

pub fn branchScopeForFullRef(ref: []const u8) ?BranchScope {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) return .remote;
    return null;
}

pub fn branchScopeLabel(scope: BranchScope) []const u8 {
    return switch (scope) {
        .unstaged => "working tree",
        .local => "local",
        .remote => "remote",
    };
}

pub fn countRealBranches(branches: []const BranchRef) usize {
    var count: usize = 0;
    for (branches) |branch| {
        if (branch.scope != .unstaged) count += 1;
    }
    return count;
}

pub fn treeEntryLessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
    return entryNameLessThan(
        a.name,
        std.mem.eql(u8, a.kind, "tree"),
        b.name,
        std.mem.eql(u8, b.kind, "tree"),
    );
}

pub fn treeNavEntryLessThan(_: void, a: TreeNavEntry, b: TreeNavEntry) bool {
    return pathLessThan(
        a.path,
        std.mem.eql(u8, a.kind, "tree"),
        b.path,
        std.mem.eql(u8, b.kind, "tree"),
    );
}

pub fn pathLessThan(a_path: []const u8, a_is_tree: bool, b_path: []const u8, b_is_tree: bool) bool {
    var a_cursor: usize = 0;
    var b_cursor: usize = 0;
    while (true) {
        const a_segment = nextPathSegment(a_path, &a_cursor) orelse return b_cursor < b_path.len;
        const b_segment = nextPathSegment(b_path, &b_cursor) orelse return false;
        const a_segment_is_tree = !a_segment.terminal or a_is_tree;
        const b_segment_is_tree = !b_segment.terminal or b_is_tree;
        switch (entryNameOrder(a_segment.name, a_segment_is_tree, b_segment.name, b_segment_is_tree)) {
            .lt => return true,
            .gt => return false,
            .eq => continue,
        }
    }
}

pub const PathSegment = struct {
    name: []const u8,
    terminal: bool,
};

pub fn nextPathSegment(path: []const u8, cursor: *usize) ?PathSegment {
    if (cursor.* >= path.len) return null;
    const start = cursor.*;
    if (std.mem.indexOfScalar(u8, path[start..], '/')) |offset| {
        cursor.* = start + offset + 1;
        return .{
            .name = path[start .. start + offset],
            .terminal = false,
        };
    }
    cursor.* = path.len;
    return .{
        .name = path[start..],
        .terminal = true,
    };
}

pub fn entryNameLessThan(a_name: []const u8, a_is_tree: bool, b_name: []const u8, b_is_tree: bool) bool {
    return entryNameOrder(a_name, a_is_tree, b_name, b_is_tree) == .lt;
}

pub fn entryNameOrder(a_name: []const u8, a_is_tree: bool, b_name: []const u8, b_is_tree: bool) std.math.Order {
    const a_rank = entrySortRank(a_name, a_is_tree);
    const b_rank = entrySortRank(b_name, b_is_tree);
    if (a_rank < b_rank) return .lt;
    if (a_rank > b_rank) return .gt;
    return std.mem.order(u8, a_name, b_name);
}

pub fn entrySortRank(name: []const u8, is_tree: bool) u8 {
    const dot = name.len != 0 and name[0] == '.';
    if (is_tree) return if (dot) 0 else 1;
    return if (dot) 2 else 3;
}

pub fn objectType(allocator: Allocator, repo: Repo, spec: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-t", spec }, 1024) orelse return null;
    return try trimOwned(allocator, raw);
}

pub fn browseObjectType(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]u8 {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return worktreeObjectType(allocator, root, path);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return objectType(allocator, repo, spec);
}

pub fn blobSize(allocator: Allocator, repo: Repo, spec: []const u8) !?usize {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-s", spec }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

pub fn browseBlobSize(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?usize {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return worktreeBlobSize(root, path);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return blobSize(allocator, repo, spec);
}

pub fn loadBlobBytes(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, max_bytes: usize) !?[]u8 {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return readWorktreeFile(allocator, root, path, max_bytes);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return gitMaybe(allocator, repo, &.{ "show", "--end-of-options", spec }, max_bytes);
}

pub fn defaultRef(allocator: Allocator, repo: Repo) ![]u8 {
    const branch_raw = try gitMaybe(allocator, repo, &.{ "branch", "--show-current" }, 512 * 1024);
    if (branch_raw) |raw| {
        defer allocator.free(raw);
        const branch = std.mem.trim(u8, raw, " \t\r\n");
        if (branch.len != 0) return allocator.dupe(u8, branch);
    }
    return allocator.dupe(u8, "HEAD");
}

pub fn targetRefOwned(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_ref = try queryValueOwned(allocator, target, "ref");
    defer if (query_ref) |value| allocator.free(value);
    if (query_ref) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len != 0) return resolveBrowsableRefOwned(allocator, repo, trimmed);
    }
    return defaultRef(allocator, repo);
}

pub fn resolveBrowsableRefOwned(allocator: Allocator, repo: Repo, ref: []const u8) ![]u8 {
    if (isUnstagedRef(ref)) return allocator.dupe(u8, unstaged_ref);
    if (isWorktreeRef(ref)) {
        if (try worktreePathFromRefOwned(allocator, repo, ref)) |path| {
            defer allocator.free(path);
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ worktree_ref_prefix, path });
        }
        return allocator.dupe(u8, ref);
    }
    if (try refResolvesToObject(allocator, repo, ref)) return allocator.dupe(u8, ref);
    if (isBranchShorthand(ref)) {
        if (try remoteTrackingBranchShortNameOwned(allocator, repo, ref)) |remote_ref| return remote_ref;
    }
    return allocator.dupe(u8, ref);
}

pub fn isUnstagedRef(ref: []const u8) bool {
    return std.mem.eql(u8, ref, unstaged_ref);
}

pub fn isWorktreeRef(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, worktree_ref_prefix);
}

pub fn isFilesystemRef(ref: []const u8) bool {
    return isUnstagedRef(ref) or isWorktreeRef(ref);
}

pub fn worktreeRootOwned(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    if (isUnstagedRef(ref)) return try allocator.dupe(u8, repo.root);
    if (!isWorktreeRef(ref)) return null;
    return worktreePathFromRefOwned(allocator, repo, ref);
}

pub fn worktreePathFromRefOwned(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    if (!isWorktreeRef(ref)) return null;
    const wanted = ref[worktree_ref_prefix.len..];
    const worktrees = try loadWorktreeRefs(allocator, repo);
    defer freeWorktreeRefs(allocator, worktrees);
    for (worktrees) |worktree| {
        if (std.mem.eql(u8, worktree.path, wanted)) return try allocator.dupe(u8, worktree.path);
    }
    return null;
}

pub fn refResolvesToObject(allocator: Allocator, repo: Repo, ref: []const u8) !bool {
    const object_ref = try std.fmt.allocPrint(allocator, "{s}^{{object}}", .{ref});
    defer allocator.free(object_ref);
    const raw = try gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", object_ref }, 1024 * 1024) orelse return false;
    allocator.free(raw);
    return true;
}

pub fn remoteTrackingBranchShortNameOwned(allocator: Allocator, repo: Repo, branch_name: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)%09%(refname:short)", "refs/remotes" }, git.max_git_output) orelse return null;
    defer allocator.free(raw);

    var candidate: ?[]u8 = null;
    errdefer if (candidate) |value| allocator.free(value);
    var ambiguous = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var cols = std.mem.splitScalar(u8, trimmed, '\t');
        const full_ref = cols.next() orelse continue;
        const short_name = cols.next() orelse continue;
        if (std.mem.endsWith(u8, full_ref, "/HEAD")) continue;
        const remote_branch = remoteTrackingBranchName(full_ref) orelse continue;
        if (!std.mem.eql(u8, remote_branch, branch_name)) continue;

        if (std.mem.startsWith(u8, full_ref, "refs/remotes/origin/")) {
            if (candidate) |value| allocator.free(value);
            return try allocator.dupe(u8, short_name);
        }

        if (candidate == null) {
            candidate = try allocator.dupe(u8, short_name);
        } else {
            ambiguous = true;
        }
    }

    if (ambiguous) {
        if (candidate) |value| allocator.free(value);
        return null;
    }
    return candidate;
}

pub fn remoteTrackingBranchName(full_ref: []const u8) ?[]const u8 {
    const prefix = "refs/remotes/";
    if (!std.mem.startsWith(u8, full_ref, prefix)) return null;
    const rest = full_ref[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash + 1 >= rest.len) return null;
    return rest[slash + 1 ..];
}

pub fn isBranchShorthand(ref: []const u8) bool {
    if (ref.len == 0) return false;
    if (std.mem.startsWith(u8, ref, "refs/")) return false;
    if (std.mem.startsWith(u8, ref, "origin/")) return false;
    if (std.mem.startsWith(u8, ref, "-")) return false;
    if (std.mem.endsWith(u8, ref, ".lock")) return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    if (std.mem.indexOf(u8, ref, "@{") != null) return false;
    if (std.mem.indexOfAny(u8, ref, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

pub fn targetPathQueryOwned(allocator: Allocator, target: []const u8) !PathQuery {
    const query_path = (try queryValueOwned(allocator, target, "path")) orelse return .{ .ok = try allocator.dupe(u8, "") };
    errdefer allocator.free(query_path);

    const path = normalizedPathOwned(allocator, query_path) catch |err| switch (err) {
        error.InvalidPath => return .{ .invalid = query_path },
        else => return err,
    };
    allocator.free(query_path);
    return .{ .ok = path };
}

pub fn targetViewOwned(allocator: Allocator, target: []const u8) ![]u8 {
    const query_view = (try queryValueOwned(allocator, target, "view")) orelse return allocator.dupe(u8, "");
    defer allocator.free(query_view);
    return allocator.dupe(u8, std.mem.trim(u8, query_view, " \t\r\n"));
}

pub fn objectSpec(allocator: Allocator, ref: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, ref);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, path });
}

pub fn childPath(allocator: Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

pub fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

pub fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

pub fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

pub fn isAncestorPath(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0 or path.len <= parent.len) return false;
    return std.mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}

pub fn isAncestorOrSelfPath(parent: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, parent, path) or isAncestorPath(parent, path);
}

pub fn treeEntryInitiallyVisible(path: []const u8, active_path: []const u8) bool {
    const parent = parentPath(path);
    return parent.len == 0 or isAncestorOrSelfPath(parent, active_path);
}

pub fn freeTreeEntries(allocator: Allocator, entries: []TreeEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub fn freeTreeNavEntries(allocator: Allocator, entries: []TreeNavEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub fn freeBranchRefs(allocator: Allocator, branches: []BranchRef) void {
    for (branches) |branch| branch.deinit(allocator);
    allocator.free(branches);
}

pub fn freeWorktreeRefs(allocator: Allocator, worktrees: []WorktreeRef) void {
    for (worktrees) |worktree| worktree.deinit(allocator);
    allocator.free(worktrees);
}

pub fn freeBlameLines(allocator: Allocator, lines: []BlameLine) void {
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

test "web explorer rejects overflowing blame date timestamps" {
    const allocator = std.testing.allocator;

    const high = try authorDateOwned(allocator, "9223372036854775807", "+0200");
    defer allocator.free(high);
    try std.testing.expectEqualStrings("unknown", high);

    const low = try authorDateOwned(allocator, "-9223372036854775808", "-0200");
    defer allocator.free(low);
    try std.testing.expectEqualStrings("unknown", low);

    const max_supported = try authorDateOwned(allocator, "253402300799", "+0000");
    defer allocator.free(max_supported);
    try std.testing.expectEqualStrings("9999-12-31", max_supported);

    const beyond_supported = try authorDateOwned(allocator, "253402300800", "+0000");
    defer allocator.free(beyond_supported);
    try std.testing.expectEqualStrings("unknown", beyond_supported);
}

test "web explorer parses malicious blame timestamp as unknown date" {
    const raw =
        "0123456789abcdef0123456789abcdef01234567 1 1 1\n" ++
        "author Mallory\n" ++
        "author-time 9223372036854775807\n" ++
        "author-tz +0200\n" ++
        "summary Extreme date\n" ++
        "filename victim.txt\n" ++
        "\towned\n";
    const lines = try parseBlamePorcelain(std.testing.allocator, raw);
    defer freeBlameLines(std.testing.allocator, lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("unknown", lines[0].date);
    try std.testing.expectEqual(@as(?i64, null), lines[0].author_timestamp);
}

test "web explorer handles extreme blame relative timestamps" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqualStrings("age-unknown", blameAgeClass(std.math.minInt(i64), 0));
    try std.testing.expectEqualStrings("age-now", blameAgeClass(std.math.maxInt(i64), 0));

    const too_old = try relativeTimeOwned(allocator, std.math.minInt(i64), 0);
    defer allocator.free(too_old);
    try std.testing.expectEqualStrings("unknown", too_old);

    const future = try relativeTimeOwned(allocator, std.math.maxInt(i64), 0);
    defer allocator.free(future);
    try std.testing.expectEqualStrings("now", future);
}

test "web explorer sums tracked file sizes separately from untracked files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    try tmp.dir.makeDir("repo/src");
    try writeTestFile(tmp.dir, "repo/tracked.txt", "abcd");
    try writeTestFile(tmp.dir, "repo/src/lib.zig", "xyz");
    try writeTestFile(tmp.dir, "repo/untracked.log", "ignored");

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);

    try expectGitOk(allocator, repo_root, &.{ "init", "-q" });
    try expectGitOk(allocator, repo_root, &.{ "add", "tracked.txt", "src/lib.zig" });

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, repo_root),
        .git_dir = try allocator.dupe(u8, ""),
        .gitomi_dir = try allocator.dupe(u8, ""),
        .config_path = try allocator.dupe(u8, ""),
        .index_path = try allocator.dupe(u8, ""),
        .cursors_path = try allocator.dupe(u8, ""),
        .settings_path = try allocator.dupe(u8, ""),
    };
    defer repo.deinit();

    try std.testing.expectEqual(@as(?usize, 7), try loadTrackedFileSizeBytes(allocator, repo));
}

test "web explorer bounds tree entry commit history window" {
    try std.testing.expectEqual(@as(usize, 0), treeEntryCommitHistoryLimit(0));
    try std.testing.expectEqual(@as(usize, min_tree_entry_commit_history), treeEntryCommitHistoryLimit(1));
    try std.testing.expectEqual(@as(usize, min_tree_entry_commit_history), treeEntryCommitHistoryLimit(8));
    try std.testing.expectEqual(@as(usize, 40), treeEntryCommitHistoryLimit(10));
    try std.testing.expectEqual(@as(usize, max_tree_entry_commit_history), treeEntryCommitHistoryLimit(1000));
}

test "web explorer tree entry commit log args are bounded and pathless" {
    const allocator = std.testing.allocator;

    var args = try treeEntryCommitLogArgs(allocator, "HEAD", 1);
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), args.items.len);
    try std.testing.expectEqualStrings("log", args.items[0]);
    try std.testing.expectEqualStrings("--max-count=32", args.items[1]);
    try std.testing.expectEqualStrings(tree_entry_commit_format, args.items[2]);
    try std.testing.expectEqualStrings("--name-only", args.items[3]);
    try std.testing.expectEqualStrings("-z", args.items[4]);
    try std.testing.expectEqualStrings("HEAD", args.items[5]);
    try std.testing.expectEqualStrings("--", args.items[6]);
    try std.testing.expect(max_tree_entry_commit_output < git.max_git_output);
    for (args.items) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, ":(top)") == null);
    }
}

test "web explorer fills old tree entry commits outside recent history window" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    try writeTestFile(tmp.dir, "repo/.gitignore", "zig-cache/\n");

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);

    try expectGitOk(allocator, repo_root, &.{ "init", "-q" });
    try expectGitOk(allocator, repo_root, &.{ "config", "user.name", "Gitomi Test" });
    try expectGitOk(allocator, repo_root, &.{ "config", "user.email", "gitomi-test@example.invalid" });
    try expectGitOk(allocator, repo_root, &.{ "config", "commit.gpgsign", "false" });
    try expectGitOk(allocator, repo_root, &.{ "add", ".gitignore" });
    try expectGitOk(allocator, repo_root, &.{ "commit", "-q", "-m", "initial" });

    var i: usize = 0;
    while (i < min_tree_entry_commit_history + 1) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "{d}\n", .{i});
        defer allocator.free(content);
        try writeTestFile(tmp.dir, "repo/churn.txt", content);
        try expectGitOk(allocator, repo_root, &.{ "add", "churn.txt" });
        const message = try std.fmt.allocPrint(allocator, "churn {d}", .{i});
        defer allocator.free(message);
        try expectGitOk(allocator, repo_root, &.{ "commit", "-q", "-m", message });
    }

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, repo_root),
        .git_dir = try allocator.dupe(u8, ""),
        .gitomi_dir = try allocator.dupe(u8, ""),
        .config_path = try allocator.dupe(u8, ""),
        .index_path = try allocator.dupe(u8, ""),
        .cursors_path = try allocator.dupe(u8, ""),
        .settings_path = try allocator.dupe(u8, ""),
    };
    defer repo.deinit();

    const entries = (try loadTreeEntries(allocator, repo, "HEAD", "")) orelse {
        try std.testing.expect(false);
        return;
    };
    defer freeTreeEntries(allocator, entries);

    var found = false;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, ".gitignore")) continue;
        found = true;
        const commit = entry.last_commit orelse {
            try std.testing.expect(false);
            return;
        };
        try std.testing.expectEqualStrings("initial", commit.subject);
    }
    try std.testing.expect(found);
}

test "web explorer sorts branch refs for the root dropdown" {
    const allocator = std.testing.allocator;

    var branches = [_]BranchRef{
        try testBranchRef(allocator, "origin/feature", .remote),
        try testBranchRef(allocator, "feature/z", .local),
        try testBranchRef(allocator, "feature", .local),
        try testBranchRef(allocator, "beta", .local),
        try testBranchRef(allocator, "origin/master", .remote),
        try testBranchRef(allocator, "master", .local),
        try testBranchRef(allocator, "main", .local),
        try testBranchRef(allocator, unstaged_ref, .unstaged),
        try testBranchRef(allocator, "origin/main", .remote),
        try testBranchRef(allocator, "alpha", .local),
    };
    defer for (branches) |branch| branch.deinit(allocator);

    std.mem.sort(BranchRef, &branches, {}, branchRefLessThan);

    try std.testing.expectEqualStrings(unstaged_ref, branches[0].name);
    try std.testing.expectEqualStrings("main", branches[1].name);
    try std.testing.expectEqualStrings("origin/main", branches[2].name);
    try std.testing.expectEqualStrings("master", branches[3].name);
    try std.testing.expectEqualStrings("origin/master", branches[4].name);
    try std.testing.expectEqualStrings("alpha", branches[5].name);
    try std.testing.expectEqualStrings("beta", branches[6].name);
    try std.testing.expectEqualStrings("feature", branches[7].name);
    try std.testing.expectEqualStrings("origin/feature", branches[8].name);
    try std.testing.expectEqualStrings("feature/z", branches[9].name);
}

test "web explorer hides inactive pull request branches from picker data" {
    var activity = PullBranchActivity.init(std.testing.allocator);
    defer activity.deinit();

    try activity.addInactiveHeadRef("feature/merged");
    try std.testing.expect(activity.branchIsInactive("refs/heads/feature/merged", "feature/merged", null));
    try std.testing.expect(activity.branchIsInactive("refs/remotes/origin/feature/merged", "origin/feature/merged", null));
    try std.testing.expect(!activity.branchIsInactive("refs/heads/merged", "merged", null));
    try std.testing.expect(!activity.branchIsInactive("refs/heads/feature/merged", "feature/merged", "feature/merged"));

    try activity.addOpenHeadRef("feature/merged");
    try std.testing.expect(!activity.branchIsInactive("refs/heads/feature/merged", "feature/merged", null));
    try std.testing.expect(!activity.branchIsInactive("refs/remotes/origin/feature/merged", "origin/feature/merged", null));
}

test "web explorer normalizes pull head refs for branch activity" {
    var activity = PullBranchActivity.init(std.testing.allocator);
    defer activity.deinit();

    try activity.addInactiveHeadRef("refs/remotes/upstream/topic/stale");
    try std.testing.expect(activity.branchIsInactive("refs/remotes/origin/topic/stale", "origin/topic/stale", null));

    try activity.addInactiveHeadRef("origin/topic/closed");
    try std.testing.expect(activity.branchIsInactive("refs/heads/topic/closed", "topic/closed", null));
}

test "web explorer blob loading treats option-like refs as revisions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    {
        var readme = try tmp.dir.createFile("repo/README.md", .{});
        defer readme.close();
        try readme.writeAll("hello\n");
    }

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);
    const tmp_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    try expectGitOk(allocator, repo_root, &.{ "init", "-q" });
    try expectGitOk(allocator, repo_root, &.{ "add", "README.md" });
    try expectGitOk(allocator, repo_root, &.{
        "-c",
        "user.name=Gitomi Test",
        "-c",
        "user.email=gitomi-test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-q",
        "-m",
        "initial",
    });

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, repo_root),
        .git_dir = try allocator.dupe(u8, ""),
        .gitomi_dir = try allocator.dupe(u8, ""),
        .config_path = try allocator.dupe(u8, ""),
        .index_path = try allocator.dupe(u8, ""),
        .cursors_path = try allocator.dupe(u8, ""),
        .settings_path = try allocator.dupe(u8, ""),
    };
    defer repo.deinit();

    const output_base = try std.fs.path.join(allocator, &.{ tmp_root, "gitomi-poc" });
    defer allocator.free(output_base);
    const option_ref = try std.fmt.allocPrint(allocator, "--output={s}", .{output_base});
    defer allocator.free(option_ref);

    const content = try loadBlobBytes(allocator, repo, option_ref, "README.md", 64 * 1024);
    defer if (content) |bytes| allocator.free(bytes);

    try std.testing.expect(content == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("gitomi-poc:README.md", .{}));
}

fn writeTestFile(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn testBranchRef(allocator: Allocator, name: []const u8, scope: BranchScope) !BranchRef {
    return .{
        .name = try allocator.dupe(u8, name),
        .scope = scope,
    };
}

fn expectGitOk(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    const output = try gitMaybeAt(allocator, root, args, 1024 * 1024) orelse return error.GitCommandFailed;
    allocator.free(output);
}

pub fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    return gitMaybeAt(allocator, repo.root, git_args, max_output_bytes);
}

pub fn gitMaybeAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (git_args) |arg| try argv.append(allocator, arg);

    var result = try runCommand(allocator, argv.items, null, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }

    result.deinit();
    return null;
}
