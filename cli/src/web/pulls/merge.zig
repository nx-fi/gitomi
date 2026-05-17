const std = @import("std");
const git = @import("../../git.zig");
const repo_mod = @import("../../repo.zig");
const work_items = @import("../../work_items.zig");
const merge_editor = @import("merge_editor.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const PullDetail = work_items.PullDetail;
const runCommand = git.runCommand;

const max_pull_diff_bytes = work_items.max_pull_diff_bytes;

const PullMergeMethod = merge_editor.PullMergeMethod;
const PullMergeResult = merge_editor.PullMergeResult;
const PullMergeSnapshot = merge_editor.PullMergeSnapshot;
const PullMergeStatus = merge_editor.PullMergeStatus;
const RemoteBranchTarget = merge_editor.RemoteBranchTarget;
const ResolvedConflictFile = merge_editor.ResolvedConflictFile;
const isRegularGitMode = merge_editor.isRegularGitMode;
const isSafeMergePath = merge_editor.isSafeMergePath;
const tempPath = merge_editor.tempPath;
const writeFileBytes = merge_editor.writeFileBytes;

pub fn loadStatus(allocator: Allocator, repo: Repo, detail: PullDetail) !PullMergeStatus {
    if (!std.mem.eql(u8, detail.state, "open")) return .{ .kind = .unavailable };

    const snapshot = (loadSnapshot(allocator, repo, detail) catch |err| switch (err) {
        error.RemoteFetchFailed => return .{ .kind = .unavailable },
        else => return err,
    }) orelse return .{ .kind = .unavailable };
    errdefer snapshot.deinit(allocator);

    const merge_base = try work_items.loadMergeBase(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid);
    defer if (merge_base) |value| allocator.free(value);
    if (merge_base == null) {
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "git",
        "-C",
        repo.root,
        "merge-tree",
        "--write-tree",
        "--name-only",
        "--no-messages",
        "-z",
        snapshot.expected_base_oid,
        snapshot.expected_head_oid,
    });

    var result = try runCommand(allocator, argv.items, null, max_pull_diff_bytes);
    defer result.deinit();
    if (result.exitCode() == 0) return .{ .kind = .clean, .snapshot = snapshot };
    if (result.exitCode() != 1) {
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }

    const conflict_files = try parseMergeTreeConflictFiles(allocator, result.stdout);
    errdefer freeConflictFiles(allocator, conflict_files);
    if (conflict_files.len == 0) {
        freeConflictFiles(allocator, conflict_files);
        snapshot.deinit(allocator);
        return .{ .kind = .unavailable };
    }
    return .{
        .kind = .conflicts,
        .conflict_files = conflict_files,
        .snapshot = snapshot,
    };
}

fn loadSnapshot(allocator: Allocator, repo: Repo, detail: PullDetail) !?PullMergeSnapshot {
    var base_target = (try remoteBranchTargetForPullRef(allocator, repo, detail.base_ref)) orelse return null;
    var base_target_owned = true;
    defer if (base_target_owned) base_target.deinit(allocator);

    try fetchRemoteBranches(allocator, repo, base_target.remote);

    const head_target = try remoteBranchTargetForPullRef(allocator, repo, detail.head_ref);
    var head_target_owned = head_target != null;
    defer if (head_target_owned) if (head_target) |target| target.deinit(allocator);

    if (head_target) |target| {
        if (!std.mem.eql(u8, target.remote, base_target.remote)) {
            try fetchRemoteBranches(allocator, repo, target.remote);
        }
    }

    const base_oid = (try resolveGitCommit(allocator, repo, base_target.tracking_ref)) orelse return null;
    errdefer allocator.free(base_oid);

    const head_oid = (try resolvePullHeadForMergeSnapshot(allocator, repo, detail, &head_target, &head_target_owned)) orelse {
        allocator.free(base_oid);
        return null;
    };
    errdefer allocator.free(head_oid);

    const snapshot = PullMergeSnapshot{
        .expected_base_oid = base_oid,
        .expected_head_oid = head_oid,
        .base_target = base_target,
        .head_target = head_target,
    };
    base_target_owned = false;
    head_target_owned = false;
    return snapshot;
}

fn resolvePullHeadForMergeSnapshot(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    head_target: *?RemoteBranchTarget,
    head_target_owned: *bool,
) !?[]u8 {
    if (detail.legacy_number > 0) {
        if (try resolveGithubPullHeadCommit(allocator, repo, detail.legacy_number)) |oid| {
            if (head_target_owned.*) {
                if (head_target.*) |target| target.deinit(allocator);
                head_target.* = null;
                head_target_owned.* = false;
            }
            return oid;
        }
    }
    if (head_target.*) |target| {
        return try resolveGitCommit(allocator, repo, target.tracking_ref);
    }
    if (try localHeadRefName(allocator, detail.head_ref)) |local_head| {
        allocator.free(local_head);
        return null;
    }
    return try resolveGitCommit(allocator, repo, detail.head_ref);
}

fn resolveGithubPullHeadCommit(allocator: Allocator, repo: Repo, number: i64) !?[]u8 {
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pr/{d}", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/remotes/origin/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/pull/{d}/head", number)) |oid| return oid;
    if (try resolveFormattedGithubPullRef(allocator, repo, "refs/gitomi/github/pull/{d}/head", number)) |oid| return oid;
    return null;
}

fn resolveFormattedGithubPullRef(allocator: Allocator, repo: Repo, comptime pattern: []const u8, number: i64) !?[]u8 {
    const ref = try std.fmt.allocPrint(allocator, pattern, .{number});
    defer allocator.free(ref);
    return try resolveGitCommit(allocator, repo, ref);
}

fn resolveGitCommit(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", commit_ref }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn remoteBranchTargetForPullRef(allocator: Allocator, repo: Repo, ref: []const u8) !?RemoteBranchTarget {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, heads_prefix)) {
        return try remoteBranchTargetForBranch(allocator, repo, null, ref[heads_prefix.len..]);
    }

    const remotes_prefix = "refs/remotes/";
    if (std.mem.startsWith(u8, ref, remotes_prefix)) {
        const rest = ref[remotes_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        return try remoteBranchTargetForBranch(allocator, repo, rest[0..slash], rest[slash + 1 ..]);
    }

    if (std.mem.indexOfScalar(u8, ref, '/')) |slash| {
        const maybe_remote = ref[0..slash];
        const maybe_branch = ref[slash + 1 ..];
        if (try remoteExists(allocator, repo, maybe_remote)) {
            return try remoteBranchTargetForBranch(allocator, repo, maybe_remote, maybe_branch);
        }
    }

    if (!isBranchShorthand(ref)) return null;
    return try remoteBranchTargetForBranch(allocator, repo, null, ref);
}

fn remoteBranchTargetForBranch(allocator: Allocator, repo: Repo, remote_hint: ?[]const u8, branch: []const u8) !?RemoteBranchTarget {
    if (!isSafeLocalBranchName(branch)) return null;

    const remote = if (remote_hint) |hint|
        try configuredRemoteName(allocator, repo, hint)
    else
        try defaultRemoteForBranch(allocator, repo, branch);
    const owned_remote = remote orelse return null;
    errdefer allocator.free(owned_remote);

    const owned_branch = try allocator.dupe(u8, branch);
    errdefer allocator.free(owned_branch);
    const remote_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
    errdefer allocator.free(remote_ref);
    const tracking_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ owned_remote, branch });
    errdefer allocator.free(tracking_ref);

    return .{
        .remote = owned_remote,
        .branch = owned_branch,
        .remote_ref = remote_ref,
        .tracking_ref = tracking_ref,
    };
}

fn defaultRemoteForBranch(allocator: Allocator, repo: Repo, branch: []const u8) !?[]u8 {
    const config_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch});
    defer allocator.free(config_key);
    if (try gitConfigValueAt(allocator, repo, config_key)) |remote| {
        errdefer allocator.free(remote);
        if (try remoteExists(allocator, repo, remote)) return remote;
        allocator.free(remote);
    }
    if (try remoteExists(allocator, repo, "origin")) return try allocator.dupe(u8, "origin");
    return try singleConfiguredRemote(allocator, repo);
}

fn configuredRemoteName(allocator: Allocator, repo: Repo, remote: []const u8) !?[]u8 {
    if (!isSafeRemoteName(remote)) return null;
    if (!(try remoteExists(allocator, repo, remote))) return null;
    return try allocator.dupe(u8, remote);
}

fn remoteExists(allocator: Allocator, repo: Repo, remote: []const u8) !bool {
    if (!isSafeRemoteName(remote)) return false;
    var result = try gitRunAt(allocator, repo.root, &.{ "remote", "get-url", "--push", remote }, 1024 * 1024);
    defer result.deinit();
    return result.exitCode() == 0 and std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn singleConfiguredRemote(allocator: Allocator, repo: Repo) !?[]u8 {
    const raw = try gitCheckedAt(allocator, repo.root, &.{"remote"}, 1024 * 1024);
    defer allocator.free(raw);

    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const remote = std.mem.trim(u8, raw_line, " \t\r\n");
        if (!isSafeRemoteName(remote)) continue;
        if (found != null) return null;
        found = remote;
    }
    return if (found) |remote| try allocator.dupe(u8, remote) else null;
}

fn isSafeRemoteName(remote: []const u8) bool {
    if (remote.len == 0 or std.mem.eql(u8, remote, ".")) return false;
    if (std.mem.startsWith(u8, remote, "-")) return false;
    if (std.mem.indexOf(u8, remote, "..") != null) return false;
    if (std.mem.indexOfAny(u8, remote, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

fn gitConfigValueAt(allocator: Allocator, repo: Repo, key: []const u8) !?[]u8 {
    var result = try gitRunAt(allocator, repo.root, &.{ "config", "--get", key }, 512 * 1024);
    defer result.deinit();
    if (result.exitCode() != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn fetchRemoteBranches(allocator: Allocator, repo: Repo, remote: []const u8) !void {
    var result = try gitRunAt(allocator, repo.root, &.{ "fetch", "--no-tags", remote }, git.max_git_output);
    defer result.deinit();
    if (result.exitCode() != 0) return error.RemoteFetchFailed;
}

fn parseMergeTreeConflictFiles(allocator: Allocator, raw: []const u8) ![][]u8 {
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    var parts = std.mem.splitScalar(u8, raw, 0);
    _ = parts.next();
    while (parts.next()) |raw_path| {
        const path = std.mem.trim(u8, raw_path, " \t\r\n");
        if (path.len == 0 or conflictFileAlreadyListed(files.items, path)) continue;
        const owned = try allocator.dupe(u8, path);
        files.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return try files.toOwnedSlice(allocator);
}

fn conflictFileAlreadyListed(files: []const []const u8, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, path)) return true;
    }
    return false;
}

fn freeConflictFiles(allocator: Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
}

pub fn appendLocalMergeCheck(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, detail: PullDetail) !void {
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

pub fn methodFromValue(value: []const u8) ?PullMergeMethod {
    if (std.mem.eql(u8, value, "merge") or std.mem.eql(u8, value, "merge_commit")) return .merge_commit;
    if (std.mem.eql(u8, value, "squash")) return .squash;
    if (std.mem.eql(u8, value, "rebase")) return .rebase;
    return null;
}

pub fn mergeIntoBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    snapshot: PullMergeSnapshot,
    method: PullMergeMethod,
) !PullMergeResult {
    if (!(try mergeWouldBeClean(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid))) return error.MergeConflicts;

    const result = switch (method) {
        .merge_commit => try createMergeCommitOnBase(allocator, repo, detail, raw_ref, snapshot.expected_base_oid, snapshot.expected_head_oid),
        .squash => try createSquashCommitOnBase(allocator, repo, detail, raw_ref, snapshot.expected_base_oid, snapshot.expected_head_oid),
        .rebase => try rebasePullOntoBase(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid),
    };
    errdefer result.deinit(allocator);

    const target = result.merge_oid orelse result.target_oid orelse return error.MergeCommitFailed;
    if (!(try commitIsAncestorAt(allocator, repo, snapshot.expected_base_oid, target))) return error.NonFastForwardResult;
    try pushRemoteBranchWithLease(allocator, repo, snapshot.base_target, target, snapshot.expected_base_oid);
    return result;
}

fn mergeWouldBeClean(allocator: Allocator, repo: Repo, base_commit: []const u8, head_commit: []const u8) !bool {
    var result = try gitRunAt(allocator, repo.root, &.{ "merge-tree", "--write-tree", "--no-messages", base_commit, head_commit }, max_pull_diff_bytes);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return error.MergeStatusUnavailable;
}

fn createMergeCommitOnBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const tmp_worktree = try tempPath(allocator, "gitomi-pr-merge");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, old_base }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    const message = try std.fmt.allocPrint(allocator, "Merge pull request #{s} from {s}", .{ raw_ref, detail.head_ref });
    defer allocator.free(message);
    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--no-ff", "-m", message, head_commit }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0) return error.MergeFailed;
    } else {
        return error.MergeFailed;
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    if (std.mem.eql(u8, commit_oid, old_base)) {
        return .{ .target_oid = commit_oid };
    }
    return .{ .merge_oid = commit_oid };
}

fn createSquashCommitOnBase(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    raw_ref: []const u8,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const tmp_worktree = try tempPath(allocator, "gitomi-pr-squash");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, old_base }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--squash", "--no-commit", head_commit }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0) return error.MergeFailed;
    } else {
        return error.MergeFailed;
    }

    if (try worktreeHasStagedChanges(allocator, tmp_worktree)) {
        const message = try std.fmt.allocPrint(allocator, "Squash merge pull request #{s} from {s}", .{ raw_ref, detail.head_ref });
        defer allocator.free(message);
        const commit_output = try gitCheckedAt(allocator, tmp_worktree, &.{ "commit", "-m", message }, git.max_git_output);
        allocator.free(commit_output);
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    return .{ .target_oid = commit_oid };
}

fn rebasePullOntoBase(
    allocator: Allocator,
    repo: Repo,
    old_base: []const u8,
    head_commit: []const u8,
) !PullMergeResult {
    const merge_base = try work_items.loadMergeBase(allocator, repo, old_base, head_commit);
    defer if (merge_base) |value| allocator.free(value);
    const base = merge_base orelse return error.MergeStatusUnavailable;

    const tmp_worktree = try tempPath(allocator, "gitomi-pr-rebase");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer cleanupTempWorktree(allocator, repo.root, tmp_worktree, &worktree_created);

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, head_commit }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var rebase_result = try gitRunAt(allocator, tmp_worktree, &.{ "rebase", "--onto", old_base, base }, git.max_git_output);
    defer rebase_result.deinit();
    if (rebase_result.exitCode()) |code| {
        if (code != 0) return error.RebaseFailed;
    } else {
        return error.RebaseFailed;
    }

    const commit_oid = try tempWorktreeHead(allocator, tmp_worktree);
    errdefer allocator.free(commit_oid);
    return .{ .target_oid = commit_oid };
}

fn tempWorktreeHead(allocator: Allocator, tmp_worktree: []const u8) ![]u8 {
    const raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "rev-parse", "HEAD" }, 1024 * 1024);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.MergeCommitFailed;
    return try allocator.dupe(u8, trimmed);
}

fn worktreeHasStagedChanges(allocator: Allocator, tmp_worktree: []const u8) !bool {
    var diff_result = try gitRunAt(allocator, tmp_worktree, &.{ "diff", "--cached", "--quiet" }, 1024 * 1024);
    defer diff_result.deinit();
    if (diff_result.exitCode()) |code| {
        if (code == 0) return false;
        if (code == 1) return true;
    }
    return error.GitFailed;
}

fn commitIsAncestorAt(allocator: Allocator, repo: Repo, ancestor: []const u8, descendant: []const u8) !bool {
    var result = try gitRunAt(allocator, repo.root, &.{ "merge-base", "--is-ancestor", ancestor, descendant }, git.max_git_output);
    defer result.deinit();
    if (result.exitCode()) |code| {
        if (code == 0) return true;
        if (code == 1) return false;
    }
    return error.GitFailed;
}

fn pushRemoteBranchWithLease(allocator: Allocator, repo: Repo, target: RemoteBranchTarget, new_oid: []const u8, expected_oid: []const u8) !void {
    const lease = try std.fmt.allocPrint(allocator, "--force-with-lease={s}:{s}", .{ target.remote_ref, expected_oid });
    defer allocator.free(lease);
    const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ new_oid, target.remote_ref });
    defer allocator.free(refspec);
    const push_output = gitCheckedAt(allocator, repo.root, &.{ "push", target.remote, lease, refspec }, git.max_git_output) catch |err| switch (err) {
        error.GitFailed => return error.RemoteBranchUpdateFailed,
        else => return err,
    };
    allocator.free(push_output);
}

fn cleanupTempWorktree(allocator: Allocator, repo_root: []const u8, tmp_worktree: []const u8, worktree_created: *bool) void {
    if (worktree_created.*) {
        var remove_result = gitRunAt(allocator, repo_root, &.{ "worktree", "remove", "--force", tmp_worktree }, 1024 * 1024) catch null;
        if (remove_result) |*result| result.deinit();
    }
    std.fs.deleteTreeAbsolute(tmp_worktree) catch {};
}

pub fn mergeErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoLocalBaseBranch => "The pull request base must be available on a configured remote before the web UI can merge it.",
        error.NoPullHeadCommit => "The pull request head commit is not available in the local repository.",
        error.MergeStatusUnavailable => "The local repository could not verify mergeability for this pull request.",
        error.MergeConflicts => "This pull request has conflicts with the current base branch.",
        error.MergeFailed => "Git could not merge this pull request into a temporary worktree.",
        error.RebaseFailed => "Git could not rebase this pull request onto the base branch.",
        error.MergeCommitFailed => "Git could not identify the merged target commit.",
        error.NonFastForwardResult => "The selected merge method did not produce a fast-forward result for the confirmed base.",
        error.BaseUpdateFailed, error.RemoteBranchUpdateFailed => "Git could not update the remote base branch. It may have changed while the merge was running.",
        error.GitFailed => "Git could not complete the merge. Check the repository state and commit signing configuration.",
        else => null,
    };
}

pub fn commitConflictResolution(
    allocator: Allocator,
    repo: Repo,
    snapshot: PullMergeSnapshot,
    raw_ref: []const u8,
    resolved_files: []const ResolvedConflictFile,
) ![]u8 {
    if (resolved_files.len == 0) return error.NoConflictResolutions;
    const head_target = snapshot.head_target orelse return error.NoRemoteHeadBranch;

    const tmp_worktree = try tempPath(allocator, "gitomi-merge-worktree");
    defer allocator.free(tmp_worktree);
    var worktree_created = false;
    defer {
        if (worktree_created) {
            var remove_result = gitRunAt(allocator, repo.root, &.{ "worktree", "remove", "--force", tmp_worktree }, 1024 * 1024) catch null;
            if (remove_result) |*result| result.deinit();
        }
        std.fs.deleteTreeAbsolute(tmp_worktree) catch {};
    }

    const worktree_add_raw = try gitCheckedAt(allocator, repo.root, &.{ "worktree", "add", "--detach", tmp_worktree, snapshot.expected_head_oid }, git.max_git_output);
    allocator.free(worktree_add_raw);
    worktree_created = true;

    var merge_result = try gitRunAt(allocator, tmp_worktree, &.{ "merge", "--no-ff", "--no-commit", snapshot.expected_base_oid }, git.max_git_output);
    defer merge_result.deinit();
    if (merge_result.exitCode()) |code| {
        if (code != 0 and code != 1) return error.MergePreparationFailed;
    } else {
        return error.MergePreparationFailed;
    }

    for (resolved_files) |file| {
        if (!isSafeMergePath(file.path)) return error.UnsafeConflictPath;
        const conflict_path_is_regular = try worktreeConflictPathIsRegularFile(allocator, tmp_worktree, file.path);
        if (!conflict_path_is_regular) return error.UnsafeConflictPath;
        const absolute_path = try std.fs.path.join(allocator, &.{ tmp_worktree, file.path });
        defer allocator.free(absolute_path);
        try writeFileBytes(absolute_path, file.content);
        const add_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "add", "--", file.path }, git.max_git_output);
        allocator.free(add_raw);
    }

    const unmerged_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "diff", "--name-only", "--diff-filter=U" }, git.max_git_output);
    defer allocator.free(unmerged_raw);
    if (std.mem.trim(u8, unmerged_raw, " \t\r\n").len != 0) return error.UnresolvedConflicts;

    const message = try std.fmt.allocPrint(allocator, "Resolve merge conflicts for PR {s}", .{raw_ref});
    defer allocator.free(message);
    const commit_output = try gitCheckedAt(allocator, tmp_worktree, &.{ "commit", "-m", message }, git.max_git_output);
    allocator.free(commit_output);

    const commit_raw = try gitCheckedAt(allocator, tmp_worktree, &.{ "rev-parse", "HEAD" }, 1024 * 1024);
    defer allocator.free(commit_raw);
    const commit_oid = try allocator.dupe(u8, std.mem.trim(u8, commit_raw, " \t\r\n"));
    errdefer allocator.free(commit_oid);
    if (commit_oid.len == 0) return error.MergeCommitFailed;

    try pushRemoteBranchWithLease(allocator, repo, head_target, commit_oid, snapshot.expected_head_oid);
    return commit_oid;
}

fn worktreeConflictPathIsRegularFile(allocator: Allocator, worktree: []const u8, path: []const u8) !bool {
    const raw = try gitCheckedAt(allocator, worktree, &.{ "ls-files", "-s", "-z", "--", path }, git.max_git_output);
    defer allocator.free(raw);
    return lsFilesStagesAreRegularFile(raw, path);
}

fn lsFilesStagesAreRegularFile(raw: []const u8, path: []const u8) bool {
    var found = false;
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return false;
        if (!std.mem.eql(u8, record[tab + 1 ..], path)) return false;
        const space = std.mem.indexOfScalar(u8, record[0..tab], ' ') orelse return false;
        if (!isRegularGitMode(record[0..space])) return false;
        found = true;
    }
    return found;
}

fn localHeadRefName(allocator: Allocator, head_ref: []const u8) !?[]u8 {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, head_ref, heads_prefix)) {
        const branch_name = head_ref[heads_prefix.len..];
        if (!isSafeLocalBranchName(branch_name)) return null;
        return try allocator.dupe(u8, head_ref);
    }
    if (!isBranchShorthand(head_ref)) return null;
    return try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{head_ref});
}

fn isBranchShorthand(ref: []const u8) bool {
    if (std.mem.startsWith(u8, ref, "refs/")) return false;
    if (std.mem.startsWith(u8, ref, "origin/")) return false;
    if (std.mem.eql(u8, ref, "HEAD")) return false;
    return isSafeLocalBranchName(ref);
}

fn isSafeLocalBranchName(ref: []const u8) bool {
    if (ref.len == 0) return false;
    if (std.mem.startsWith(u8, ref, "-")) return false;
    if (std.mem.endsWith(u8, ref, ".lock")) return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    if (std.mem.indexOf(u8, ref, "@{") != null) return false;
    if (std.mem.indexOfAny(u8, ref, " \t\r\n\x00:^~?*[\\") != null) return false;
    return true;
}

pub fn commitErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoLocalHeadBranch, error.NoRemoteHeadBranch => "The pull request head must be a writable branch on the configured remote before the web resolver can update it.",
        error.NoConflictResolutions => "No conflict resolutions were submitted.",
        error.PullHeadChanged => "The local pull request head no longer matches the conflicts shown by the web resolver. Refresh the page and try again.",
        error.UnsafeConflictPath => "A conflicting path is not safe to write from the web resolver.",
        error.MergePreparationFailed => "Git could not prepare a merge worktree for this pull request.",
        error.UnresolvedConflicts => "Git still reports unresolved conflicts after applying the submitted files.",
        error.MergeCommitFailed => "Git could not create the merge-resolution commit.",
        error.RemoteBranchUpdateFailed => "Git could not update the remote pull request branch. It may have changed while the resolution was being committed.",
        error.GitFailed => "Git could not commit the resolution. Check the repository state and signing configuration.",
        else => null,
    };
}

fn gitRunAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) !git.RunOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (git_args) |arg| try argv.append(allocator, arg);
    return runCommand(allocator, argv.items, null, max_output_bytes);
}

fn gitCheckedAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) ![]u8 {
    var result = try gitRunAt(allocator, root, git_args, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return error.GitFailed;
}

test "parse merge-tree conflict file names" {
    const raw = "b8424e5199eed14e5e0c4fa9a3668f146ef44ae9\x00cli/src/github.zig\x00cli/src/sync.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("cli/src/github.zig", files[0]);
    try std.testing.expectEqualStrings("cli/src/sync.zig", files[1]);
}

test "parse merge-tree conflict file names skips duplicates and empty records" {
    const raw = "tree\x00a.zig\x00\x00a.zig\x00b.zig\x00";
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, raw);
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("a.zig", files[0]);
    try std.testing.expectEqualStrings("b.zig", files[1]);
}

test "parse merge-tree conflict file names returns empty for git errors without paths" {
    const files = try parseMergeTreeConflictFiles(std.testing.allocator, "");
    defer freeConflictFiles(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "pull merge method parser" {
    try std.testing.expectEqual(PullMergeMethod.merge_commit, methodFromValue("merge").?);
    try std.testing.expectEqual(PullMergeMethod.merge_commit, methodFromValue("merge_commit").?);
    try std.testing.expectEqual(PullMergeMethod.squash, methodFromValue("squash").?);
    try std.testing.expectEqual(PullMergeMethod.rebase, methodFromValue("rebase").?);
    try std.testing.expect(methodFromValue("fast-forward") == null);
}

test "merge editor rejects symlink conflict index stages" {
    try std.testing.expect(lsFilesStagesAreRegularFile(
        "100644 abcdef 1\tconflict.txt\x00100755 abcdef 2\tconflict.txt\x00100644 abcdef 3\tconflict.txt\x00",
        "conflict.txt",
    ));
    try std.testing.expect(!lsFilesStagesAreRegularFile(
        "100644 abcdef 1\tconflict.txt\x00120000 abcdef 2\tconflict.txt\x00100644 abcdef 3\tconflict.txt\x00",
        "conflict.txt",
    ));
    try std.testing.expect(!lsFilesStagesAreRegularFile("", "conflict.txt"));
}

test "merge resolver derives local head refs only from safe branch names" {
    const shorthand = (try localHeadRefName(std.testing.allocator, "feature/conflict-fix")).?;
    defer std.testing.allocator.free(shorthand);
    try std.testing.expectEqualStrings("refs/heads/feature/conflict-fix", shorthand);

    const full = (try localHeadRefName(std.testing.allocator, "refs/heads/origin/feature")).?;
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("refs/heads/origin/feature", full);

    try std.testing.expect((try localHeadRefName(std.testing.allocator, "origin/feature")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "refs/remotes/origin/feature")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "HEAD")) == null);
    try std.testing.expect((try localHeadRefName(std.testing.allocator, "feature^{commit}")) == null);
}

test "legacy GitHub pull refs are not treated as writable branch targets" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("seed");
    try tmp.dir.makeDir("client");
    try tmp.dir.makeDir("remote.git");

    const seed_root = try tmp.dir.realpathAlloc(allocator, "seed");
    defer allocator.free(seed_root);
    const client_root = try tmp.dir.realpathAlloc(allocator, "client");
    defer allocator.free(client_root);
    const remote_root = try tmp.dir.realpathAlloc(allocator, "remote.git");
    defer allocator.free(remote_root);

    try expectGitOkAt(allocator, seed_root, &.{ "init", "-q" });
    try expectGitOkAt(allocator, seed_root, &.{ "checkout", "-q", "-b", "main" });
    try expectGitOkAt(allocator, seed_root, &.{ "config", "user.name", "Gitomi Test" });
    try expectGitOkAt(allocator, seed_root, &.{ "config", "user.email", "gitomi-test@example.invalid" });
    try expectGitOkAt(allocator, seed_root, &.{ "config", "commit.gpgsign", "false" });
    try writeTmpFile(tmp.dir, "seed/conflict.txt", "initial\n");
    try expectGitOkAt(allocator, seed_root, &.{ "add", "conflict.txt" });
    try expectGitOkAt(allocator, seed_root, &.{ "commit", "-q", "-m", "initial" });
    try expectGitOkAt(allocator, seed_root, &.{ "branch", "target" });

    try writeTmpFile(tmp.dir, "seed/conflict.txt", "pull head\n");
    try expectGitOkAt(allocator, seed_root, &.{ "commit", "-q", "-am", "pull head" });
    const head_oid = try gitTrimmedAt(allocator, seed_root, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_oid);

    try expectGitOkAt(allocator, seed_root, &.{ "checkout", "-q", "target" });
    try writeTmpFile(tmp.dir, "seed/conflict.txt", "base\n");
    try expectGitOkAt(allocator, seed_root, &.{ "commit", "-q", "-am", "base" });

    try expectGitOkAt(allocator, remote_root, &.{ "init", "--bare", "-q" });
    try expectGitOkAt(allocator, seed_root, &.{ "remote", "add", "origin", remote_root });
    try expectGitOkAt(allocator, seed_root, &.{ "push", "-q", "origin", "main", "target" });

    try expectGitOkAt(allocator, client_root, &.{ "init", "-q" });
    try expectGitOkAt(allocator, client_root, &.{ "remote", "add", "origin", remote_root });
    try expectGitOkAt(allocator, client_root, &.{ "fetch", "-q", "origin" });
    try expectGitOkAt(allocator, client_root, &.{ "update-ref", "refs/remotes/origin/pr/123", head_oid });

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, client_root),
        .git_dir = try allocator.dupe(u8, ""),
        .gitomi_dir = try allocator.dupe(u8, ""),
        .config_path = try allocator.dupe(u8, ""),
        .index_path = try allocator.dupe(u8, ""),
        .cursors_path = try allocator.dupe(u8, ""),
    };
    defer repo.deinit();

    var detail = try testPullDetail(allocator, "target", "main", 123);
    defer detail.deinit(allocator);

    const snapshot = (try loadSnapshot(allocator, repo, detail)).?;
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings(head_oid, snapshot.expected_head_oid);
    try std.testing.expect(snapshot.head_target == null);
}

fn testPullDetail(allocator: Allocator, base_ref: []const u8, head_ref: []const u8, legacy_number: i64) !PullDetail {
    return .{
        .id = try allocator.dupe(u8, "pull-id"),
        .title = try allocator.dupe(u8, "Pull"),
        .state = try allocator.dupe(u8, "open"),
        .author_principal = try allocator.dupe(u8, "alice"),
        .author_device = try allocator.dupe(u8, "laptop"),
        .source_author = try allocator.dupe(u8, "alice"),
        .opened_at = try allocator.dupe(u8, "2026-01-01T00:00:00Z"),
        .state_occurred_at = try allocator.dupe(u8, "2026-01-01T00:00:00Z"),
        .state_actor_principal = try allocator.dupe(u8, "alice"),
        .body = try allocator.dupe(u8, ""),
        .base_ref = try allocator.dupe(u8, base_ref),
        .head_ref = try allocator.dupe(u8, head_ref),
        .draft = false,
        .merge_oid = try allocator.dupe(u8, ""),
        .target_oid = try allocator.dupe(u8, ""),
        .legacy_number = legacy_number,
        .commit_count = null,
        .changed_files = null,
        .additions = null,
        .deletions = null,
    };
}

fn writeTmpFile(dir: std.fs.Dir, path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn expectGitOkAt(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    const output = try gitCheckedAt(allocator, root, args, git.max_git_output);
    allocator.free(output);
}

fn gitTrimmedAt(allocator: Allocator, root: []const u8, args: []const []const u8) ![]u8 {
    const raw = try gitCheckedAt(allocator, root, args, 1024 * 1024);
    defer allocator.free(raw);
    return try allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}
