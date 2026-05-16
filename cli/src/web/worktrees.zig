const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const explorer_data = @import("explorer/data.zig");
const explorer_model = @import("explorer/model.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const RootGitStatus = explorer_model.RootGitStatus;
const RepositoryOperationState = explorer_model.RepositoryOperationState;
const appendEmptyState = shared.appendEmptyState;
const appendHref = shared.appendHref;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;

const WorktreeSyncStatus = struct {
    upstream: []u8,
    ahead: usize = 0,
    behind: usize = 0,

    fn deinit(self: WorktreeSyncStatus, allocator: Allocator) void {
        allocator.free(self.upstream);
    }
};

const WorktreeCommit = struct {
    full_hash: []u8,
    hash: []u8,
    author: []u8,
    subject: []u8,
    relative: []u8,

    fn deinit(self: WorktreeCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.hash);
        allocator.free(self.author);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

const WorktreeSummary = struct {
    path: []u8,
    code_ref: []u8,
    head: []u8,
    branch: ?[]u8 = null,
    detached: bool = false,
    is_current: bool = false,
    locked: ?[]u8 = null,
    prunable: ?[]u8 = null,
    status: ?RootGitStatus = null,
    sync: ?WorktreeSyncStatus = null,
    commit: ?WorktreeCommit = null,

    fn deinit(self: WorktreeSummary, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.code_ref);
        allocator.free(self.head);
        if (self.branch) |branch| allocator.free(branch);
        if (self.locked) |locked| allocator.free(locked);
        if (self.prunable) |prunable| allocator.free(prunable);
        if (self.sync) |sync| sync.deinit(allocator);
        if (self.commit) |commit| commit.deinit(allocator);
    }
};

const WorktreeTotals = struct {
    total: usize = 0,
    changed: usize = 0,
    conflicts: usize = 0,
    locked: usize = 0,
    prunable: usize = 0,
};

pub fn renderWorktreesPage(allocator: Allocator, repo: Repo) ![]u8 {
    const worktrees = try loadWorktreeSummaries(allocator, repo);
    defer freeWorktreeSummaries(allocator, worktrees);
    const totals = worktreeTotals(worktrees);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Worktrees", "code");
    try appendTemplate(&buf, allocator,
        \\<section class="panel worktrees-panel">
        \\  <div class="section-head worktrees-head">
        \\    <div>
        \\      <p class="eyebrow">Git worktrees</p>
        \\      <h1>Worktree Summary</h1>
        \\    </div>
        \\    <a class="button secondary" href="/"><span class="button-icon icon-code" aria-hidden="true"></span><span>Code</span></a>
        \\  </div>
    , .{});
    try appendWorktreeTotals(&buf, allocator, totals);
    if (worktrees.len == 0) {
        try appendEmptyState(&buf, allocator, "No worktrees found.", "Git did not report any non-bare worktrees for this repository.");
    } else {
        try appendWorktreeTable(&buf, allocator, worktrees);
    }
    try appendTemplate(&buf, allocator, "</section>", .{});
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn loadWorktreeSummaries(allocator: Allocator, repo: Repo) ![]WorktreeSummary {
    const raw = try explorer_data.gitMaybe(allocator, repo, &.{ "worktree", "list", "--porcelain" }, git.max_git_output) orelse {
        return allocator.alloc(WorktreeSummary, 0);
    };
    defer allocator.free(raw);

    const worktrees = try parseWorktreeSummaries(allocator, repo.root, raw);
    errdefer freeWorktreeSummaries(allocator, worktrees);

    for (worktrees) |*worktree| {
        worktree.status = loadWorktreeStatus(allocator, worktree.path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        worktree.sync = loadWorktreeSyncStatus(allocator, worktree.path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        worktree.commit = loadWorktreeCommit(allocator, worktree.path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
    }

    return worktrees;
}

fn parseWorktreeSummaries(allocator: Allocator, repo_root: []const u8, raw: []const u8) ![]WorktreeSummary {
    var worktrees: std.ArrayList(WorktreeSummary) = .empty;
    errdefer {
        for (worktrees.items) |worktree| worktree.deinit(allocator);
        worktrees.deinit(allocator);
    }

    var path: ?[]const u8 = null;
    var head: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var detached = false;
    var bare = false;
    var locked: ?[]const u8 = null;
    var prunable: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) {
            try appendParsedWorktreeSummary(allocator, &worktrees, repo_root, path, head, branch, detached, bare, locked, prunable);
            path = null;
            head = null;
            branch = null;
            detached = false;
            bare = false;
            locked = null;
            prunable = null;
            continue;
        }

        if (std.mem.startsWith(u8, line, "worktree ")) {
            path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            head = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            branch = explorer_data.worktreeBranchLabel(line["branch ".len..]);
        } else if (std.mem.eql(u8, line, "detached")) {
            detached = true;
        } else if (std.mem.eql(u8, line, "bare")) {
            bare = true;
        } else if (std.mem.eql(u8, line, "locked")) {
            locked = "";
        } else if (std.mem.startsWith(u8, line, "locked ")) {
            locked = line["locked ".len..];
        } else if (std.mem.eql(u8, line, "prunable")) {
            prunable = "";
        } else if (std.mem.startsWith(u8, line, "prunable ")) {
            prunable = line["prunable ".len..];
        }
    }
    try appendParsedWorktreeSummary(allocator, &worktrees, repo_root, path, head, branch, detached, bare, locked, prunable);

    std.mem.sort(WorktreeSummary, worktrees.items, {}, struct {
        fn lessThan(_: void, a: WorktreeSummary, b: WorktreeSummary) bool {
            if (a.is_current != b.is_current) return a.is_current;
            return std.ascii.lessThanIgnoreCase(a.path, b.path);
        }
    }.lessThan);

    return worktrees.toOwnedSlice(allocator);
}

fn appendParsedWorktreeSummary(
    allocator: Allocator,
    worktrees: *std.ArrayList(WorktreeSummary),
    repo_root: []const u8,
    path_opt: ?[]const u8,
    head_opt: ?[]const u8,
    branch_opt: ?[]const u8,
    detached: bool,
    bare: bool,
    locked_opt: ?[]const u8,
    prunable_opt: ?[]const u8,
) !void {
    if (bare) return;
    const path = path_opt orelse return;
    if (path.len == 0) return;

    const path_owned = try allocator.dupe(u8, path);
    errdefer allocator.free(path_owned);
    const code_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ explorer_data.worktree_ref_prefix, path });
    errdefer allocator.free(code_ref);
    const head_owned = try allocator.dupe(u8, head_opt orelse "");
    errdefer allocator.free(head_owned);
    const branch_owned = if (branch_opt) |branch| try allocator.dupe(u8, branch) else null;
    errdefer if (branch_owned) |branch| allocator.free(branch);
    const locked_owned = if (locked_opt) |reason| try allocator.dupe(u8, reason) else null;
    errdefer if (locked_owned) |reason| allocator.free(reason);
    const prunable_owned = if (prunable_opt) |reason| try allocator.dupe(u8, reason) else null;
    errdefer if (prunable_owned) |reason| allocator.free(reason);

    try worktrees.append(allocator, .{
        .path = path_owned,
        .code_ref = code_ref,
        .head = head_owned,
        .branch = branch_owned,
        .detached = detached,
        .is_current = std.mem.eql(u8, path, repo_root),
        .locked = locked_owned,
        .prunable = prunable_owned,
    });
}

fn loadWorktreeStatus(allocator: Allocator, root: []const u8) !?RootGitStatus {
    var status = RootGitStatus{};

    const raw_status = try explorer_data.gitMaybeAt(allocator, root, &.{ "status", "--porcelain=v2" }, git.max_git_output) orelse return null;
    defer allocator.free(raw_status);
    explorer_data.parseRootGitStatusV2(&status, raw_status);

    if (try explorer_data.gitMaybeAt(allocator, root, &.{ "diff", "--numstat", "HEAD", "--" }, git.max_git_output)) |raw_diff| {
        defer allocator.free(raw_diff);
        explorer_data.parseRootDiffNumstat(&status, raw_diff);
    }
    status.operation_state = loadWorktreeOperationState(allocator, root) catch .clean;

    return status;
}

fn loadWorktreeOperationState(allocator: Allocator, root: []const u8) !RepositoryOperationState {
    if (try gitPathExistsAt(allocator, root, "rebase-merge")) return .rebase;
    if (try gitPathExistsAt(allocator, root, "rebase-apply")) return .rebase;
    if (try gitPathExistsAt(allocator, root, "MERGE_HEAD")) return .merge;
    if (try gitPathExistsAt(allocator, root, "CHERRY_PICK_HEAD")) return .cherry_pick;
    if (try gitPathExistsAt(allocator, root, "REVERT_HEAD")) return .revert;
    return .clean;
}

fn gitPathExistsAt(allocator: Allocator, root: []const u8, git_path: []const u8) !bool {
    const raw = try explorer_data.gitMaybeAt(allocator, root, &.{ "rev-parse", "--path-format=absolute", "--git-path", git_path }, 1024) orelse return false;
    defer allocator.free(raw);
    const path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn loadWorktreeSyncStatus(allocator: Allocator, root: []const u8) !?WorktreeSyncStatus {
    const upstream_raw = try explorer_data.gitMaybeAt(allocator, root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "HEAD@{upstream}" }, 4096) orelse return null;
    defer allocator.free(upstream_raw);
    const upstream = std.mem.trim(u8, upstream_raw, " \t\r\n");
    if (upstream.len == 0) return null;

    const counts_raw = try explorer_data.gitMaybeAt(allocator, root, &.{ "rev-list", "--left-right", "--count", "HEAD@{upstream}...HEAD" }, 4096) orelse return null;
    defer allocator.free(counts_raw);
    var fields = std.mem.tokenizeAny(u8, counts_raw, " \t\r\n");
    const behind_raw = fields.next() orelse return null;
    const ahead_raw = fields.next() orelse return null;

    return .{
        .upstream = try allocator.dupe(u8, upstream),
        .behind = std.fmt.parseUnsigned(usize, behind_raw, 10) catch return null,
        .ahead = std.fmt.parseUnsigned(usize, ahead_raw, 10) catch return null,
    };
}

fn loadWorktreeCommit(allocator: Allocator, root: []const u8) !?WorktreeCommit {
    const format = "--format=%H%x09%h%x09%an%x09%s%x09%cr";
    const raw = try explorer_data.gitMaybeAt(allocator, root, &.{ "log", "-1", format }, 1024 * 1024) orelse return null;
    defer allocator.free(raw);
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return null;

    const full_end = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const hash_start = full_end + 1;
    const hash_end = std.mem.indexOfScalarPos(u8, line, hash_start, '\t') orelse return null;
    const author_start = hash_end + 1;
    const author_end = std.mem.indexOfScalarPos(u8, line, author_start, '\t') orelse return null;
    const relative_start = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return null;
    if (relative_start <= author_end) return null;

    return .{
        .full_hash = try allocator.dupe(u8, line[0..full_end]),
        .hash = try allocator.dupe(u8, line[hash_start..hash_end]),
        .author = try allocator.dupe(u8, line[author_start..author_end]),
        .subject = try allocator.dupe(u8, line[author_end + 1 .. relative_start]),
        .relative = try allocator.dupe(u8, line[relative_start + 1 ..]),
    };
}

fn appendWorktreeTotals(buf: *std.ArrayList(u8), allocator: Allocator, totals: WorktreeTotals) !void {
    try appendTemplate(buf, allocator,
        \\<div class="worktrees-summary" aria-label="Worktree totals">
        \\  <span><strong>{total}</strong> {total_label}</span>
        \\  <span><strong>{changed}</strong> changed</span>
        \\  <span><strong>{conflicts}</strong> {conflict_label}</span>
        \\  <span><strong>{locked}</strong> locked</span>
        \\  <span><strong>{prunable}</strong> prunable</span>
        \\</div>
    , .{
        .total = shared.groupedUnsigned(@intCast(totals.total)),
        .total_label = if (totals.total == 1) "worktree" else "worktrees",
        .changed = shared.groupedUnsigned(@intCast(totals.changed)),
        .conflicts = shared.groupedUnsigned(@intCast(totals.conflicts)),
        .conflict_label = if (totals.conflicts == 1) "conflict" else "conflicts",
        .locked = shared.groupedUnsigned(@intCast(totals.locked)),
        .prunable = shared.groupedUnsigned(@intCast(totals.prunable)),
    });
}

fn appendWorktreeTable(buf: *std.ArrayList(u8), allocator: Allocator, worktrees: []const WorktreeSummary) !void {
    try appendTemplate(buf, allocator,
        \\<div class="table-wrap worktrees-table-wrap">
        \\  <table class="worktrees-table">
        \\    <thead><tr><th>Worktree</th><th>Ref</th><th>Status</th><th>Sync</th><th>Head</th><th></th></tr></thead>
        \\    <tbody>
    , .{});
    for (worktrees) |worktree| {
        try appendWorktreeRow(buf, allocator, worktree);
    }
    try appendTemplate(buf, allocator,
        \\    </tbody>
        \\  </table>
        \\</div>
    , .{});
}

fn appendWorktreeRow(buf: *std.ArrayList(u8), allocator: Allocator, worktree: WorktreeSummary) !void {
    try appendTemplate(buf, allocator,
        \\<tr>
        \\  <td class="worktree-path-cell">
        \\    <div class="worktree-path-main"><span class="button-icon icon-worktree" aria-hidden="true"></span><strong>{name}</strong>
    , .{ .name = std.fs.path.basename(worktree.path) });
    try appendWorktreeBadges(buf, allocator, worktree);
    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <code>{path}</code>
        \\  </td>
        \\  <td class="worktree-ref-cell">
    , .{ .path = worktree.path });
    try appendWorktreeRef(buf, allocator, worktree);
    try appendTemplate(buf, allocator,
        \\  </td>
        \\  <td class="worktree-status-cell">
    , .{});
    try appendWorktreeStatus(buf, allocator, worktree.status);
    try appendTemplate(buf, allocator,
        \\  </td>
        \\  <td class="worktree-sync-cell">
    , .{});
    try appendWorktreeSync(buf, allocator, worktree);
    try appendTemplate(buf, allocator,
        \\  </td>
        \\  <td class="worktree-head-cell">
    , .{});
    try appendWorktreeCommit(buf, allocator, worktree);
    try appendTemplate(buf, allocator,
        \\  </td>
        \\  <td class="worktree-actions-cell"><a class="button secondary worktree-row-action" href="
    , .{});
    try appendHref(buf, allocator, shared.codeHref(worktree.code_ref, ""));
    try appendTemplate(buf, allocator,
        \\" title="Browse worktree"><span class="button-icon icon-code" aria-hidden="true"></span><span>Browse</span></a></td>
        \\</tr>
    , .{});
}

fn appendWorktreeBadges(buf: *std.ArrayList(u8), allocator: Allocator, worktree: WorktreeSummary) !void {
    if (worktree.is_current) {
        try appendTemplate(buf, allocator, "<span class=\"worktree-badge current\">current</span>", .{});
    }
    if (worktree.locked) |reason| {
        try appendTemplate(buf, allocator, "<span class=\"worktree-badge locked\" title=\"{reason}\">locked</span>", .{ .reason = reason });
    }
    if (worktree.prunable) |reason| {
        try appendTemplate(buf, allocator, "<span class=\"worktree-badge prunable\" title=\"{reason}\">prunable</span>", .{ .reason = reason });
    }
}

fn appendWorktreeRef(buf: *std.ArrayList(u8), allocator: Allocator, worktree: WorktreeSummary) !void {
    if (worktree.branch) |branch| {
        try appendTemplate(buf, allocator,
            \\<span class="worktree-ref-kind"><span class="button-icon icon-branch" aria-hidden="true"></span>branch</span><code>{branch}</code>
        , .{ .branch = branch });
        return;
    }
    if (worktree.detached) {
        try appendTemplate(buf, allocator,
            \\<span class="worktree-ref-kind detached">detached</span><code>{head}</code>
        , .{ .head = shortOid(worktree.head) });
        return;
    }
    try appendTemplate(buf, allocator, "<span class=\"worktree-muted\">unknown</span>", .{});
}

fn appendWorktreeStatus(buf: *std.ArrayList(u8), allocator: Allocator, status_opt: ?RootGitStatus) !void {
    const status = status_opt orelse {
        try appendTemplate(buf, allocator, "<span class=\"worktree-muted\">Unavailable</span>", .{});
        return;
    };
    if (!worktreeHasChanges(status)) {
        try appendTemplate(buf, allocator, "<span class=\"worktree-clean\">Clean</span>", .{});
        return;
    }

    try appendTemplate(buf, allocator, "<div class=\"worktree-status-pills\">", .{});
    if (status.conflict_paths != 0) try appendWorktreeStatusPill(buf, allocator, "conflicts", status.conflict_paths, "conflict");
    if (status.staged_paths != 0) try appendWorktreeStatusPill(buf, allocator, "staged", status.staged_paths, "staged");
    if (status.unstaged_paths != 0) try appendWorktreeStatusPill(buf, allocator, "modified", status.unstaged_paths, "modified");
    if (status.untracked_paths != 0) try appendWorktreeStatusPill(buf, allocator, "untracked", status.untracked_paths, "untracked");
    if (status.operation_state != .clean) {
        try appendTemplate(buf, allocator,
            \\<span class="worktree-status-pill operation">{operation}</span>
        , .{ .operation = repositoryOperationLabel(status.operation_state) });
    }
    if (status.lines_added != 0 or status.lines_removed != 0) {
        try appendTemplate(buf, allocator,
            \\<span class="worktree-diffstat"><span class="root-diffstat-added">+{added}</span><span class="root-diffstat-removed">-{removed}</span></span>
        , .{
            .added = shared.groupedUnsigned(status.lines_added),
            .removed = shared.groupedUnsigned(status.lines_removed),
        });
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendWorktreeStatusPill(buf: *std.ArrayList(u8), allocator: Allocator, class: []const u8, count: usize, label: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="worktree-status-pill {class}"><strong>{count}</strong> {label}</span>
    , .{
        .class = class,
        .count = shared.groupedUnsigned(@intCast(count)),
        .label = label,
    });
}

fn appendWorktreeSync(buf: *std.ArrayList(u8), allocator: Allocator, worktree: WorktreeSummary) !void {
    if (worktree.sync) |sync| {
        try appendTemplate(buf, allocator,
            \\<div class="worktree-sync"><span>{ahead} ahead, {behind} behind</span><code>{upstream}</code></div>
        , .{
            .ahead = shared.groupedUnsigned(@intCast(sync.ahead)),
            .behind = shared.groupedUnsigned(@intCast(sync.behind)),
            .upstream = sync.upstream,
        });
        return;
    }
    try appendTemplate(buf, allocator, "<span class=\"worktree-muted\">{label}</span>", .{
        .label = if (worktree.detached) "Detached" else "No upstream",
    });
}

fn appendWorktreeCommit(buf: *std.ArrayList(u8), allocator: Allocator, worktree: WorktreeSummary) !void {
    const commit = worktree.commit orelse {
        if (worktree.head.len != 0) {
            try appendTemplate(buf, allocator, "<code>{head}</code>", .{ .head = shortOid(worktree.head) });
        } else {
            try appendTemplate(buf, allocator, "<span class=\"worktree-muted\">No HEAD</span>", .{});
        }
        return;
    };
    try appendTemplate(buf, allocator,
        \\<div class="worktree-commit"><a href="
    , .{});
    try appendHref(buf, allocator, shared.commitHref(commit.full_hash));
    try appendTemplate(buf, allocator,
        \\"><code>{hash}</code></a><strong title="{subject}">{subject}</strong><span>{relative}</span></div>
    , .{
        .hash = commit.hash,
        .subject = commit.subject,
        .relative = commit.relative,
    });
}

fn worktreeTotals(worktrees: []const WorktreeSummary) WorktreeTotals {
    var totals = WorktreeTotals{ .total = worktrees.len };
    for (worktrees) |worktree| {
        if (worktree.locked != null) totals.locked += 1;
        if (worktree.prunable != null) totals.prunable += 1;
        if (worktree.status) |status| {
            if (worktreeHasChanges(status)) totals.changed += 1;
            if (status.conflict_paths != 0) totals.conflicts += 1;
        }
    }
    return totals;
}

fn worktreeHasChanges(status: RootGitStatus) bool {
    return status.staged_paths != 0 or
        status.unstaged_paths != 0 or
        status.untracked_paths != 0 or
        status.conflict_paths != 0 or
        status.operation_state != .clean;
}

fn repositoryOperationLabel(state: RepositoryOperationState) []const u8 {
    return switch (state) {
        .clean => "clean",
        .merge => "merge in progress",
        .rebase => "rebase in progress",
        .cherry_pick => "cherry-pick in progress",
        .revert => "revert in progress",
    };
}

fn shortOid(oid: []const u8) []const u8 {
    return oid[0..@min(oid.len, 8)];
}

fn freeWorktreeSummaries(allocator: Allocator, worktrees: []WorktreeSummary) void {
    for (worktrees) |worktree| worktree.deinit(allocator);
    allocator.free(worktrees);
}

test "web worktrees parses porcelain records" {
    const raw =
        "worktree /repo/main\n" ++
        "HEAD 0123456789abcdef\n" ++
        "branch refs/heads/main\n" ++
        "\n" ++
        "worktree /repo/feature\n" ++
        "HEAD fedcba9876543210\n" ++
        "detached\n" ++
        "locked testing\n" ++
        "\n" ++
        "worktree /repo/bare\n" ++
        "bare\n" ++
        "\n";

    const worktrees = try parseWorktreeSummaries(std.testing.allocator, "/repo/main", raw);
    defer freeWorktreeSummaries(std.testing.allocator, worktrees);

    try std.testing.expectEqual(@as(usize, 2), worktrees.len);
    try std.testing.expect(worktrees[0].is_current);
    try std.testing.expectEqualStrings("/repo/main", worktrees[0].path);
    try std.testing.expectEqualStrings("main", worktrees[0].branch.?);
    try std.testing.expectEqualStrings("worktree:/repo/main", worktrees[0].code_ref);
    try std.testing.expect(worktrees[1].detached);
    try std.testing.expectEqualStrings("testing", worktrees[1].locked.?);
}
