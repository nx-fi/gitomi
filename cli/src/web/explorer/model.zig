const std = @import("std");
const source_stats = @import("../source_stats.zig");

const Allocator = std.mem.Allocator;

pub const RawBlob = struct {
    content_type: []const u8,
    body: []u8,

    pub fn deinit(self: RawBlob, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const MediaKind = enum {
    image,
    video,
};

pub const TreeEntry = struct {
    mode: []u8,
    kind: []u8,
    oid: []u8,
    size: []u8,
    name: []u8,
    last_commit: ?TreeEntryCommit = null,

    pub fn deinit(self: TreeEntry, allocator: Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.kind);
        allocator.free(self.oid);
        allocator.free(self.size);
        allocator.free(self.name);
        if (self.last_commit) |commit| commit.deinit(allocator);
    }
};

pub const TreeNavEntry = struct {
    kind: []u8,
    path: []u8,

    pub fn deinit(self: TreeNavEntry, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
    }
};

pub const BranchRef = struct {
    name: []u8,
    scope: BranchScope,

    pub fn deinit(self: BranchRef, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub const WorktreeRef = struct {
    path: []u8,
    value: []u8,
    label: []u8,

    pub fn deinit(self: WorktreeRef, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.value);
        allocator.free(self.label);
    }
};

pub const BranchScope = enum {
    unstaged,
    local,
    remote,
};

pub const TreeEntryCommit = struct {
    full_hash: []u8,
    subject: []u8,
    relative: []u8,
    synthetic: bool = false,
    change_state: ChangeState = .none,

    pub fn deinit(self: TreeEntryCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

pub const ChangeState = enum {
    none,
    staged,
    unstaged,
    staged_and_unstaged,
};

pub const CommitSummary = struct {
    full_hash: []u8,
    hash: []u8,
    author: []u8,
    subject: []u8,
    relative: []u8,

    pub fn deinit(self: CommitSummary, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.hash);
        allocator.free(self.author);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

pub const BlameLine = struct {
    commit: []u8,
    short_hash: []u8,
    author: []u8,
    date: []u8,
    author_timestamp: ?i64,
    summary: []u8,
    line_no: usize,
    content: []u8,

    pub fn deinit(self: BlameLine, allocator: Allocator) void {
        allocator.free(self.commit);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.date);
        allocator.free(self.summary);
        allocator.free(self.content);
    }
};

pub const BlameHeader = struct {
    commit: []const u8,
    line_no: usize,
};

pub const SlocCounts = source_stats.Counts;

pub const DeviconMapping = struct {
    key: []const u8,
    class: []const u8,
};

pub const RootEntryCounts = struct {
    files: usize = 0,
    directories: usize = 0,
};

pub const RepositoryOperationState = enum {
    clean,
    merge,
    rebase,
    cherry_pick,
    revert,
};

pub const RootGitStatus = struct {
    staged_paths: usize = 0,
    unstaged_paths: usize = 0,
    untracked_paths: usize = 0,
    conflict_paths: usize = 0,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,
    worktree_count: usize = 0,
    disk_size_bytes: ?usize = null,
    operation_state: RepositoryOperationState = .clean,
};

pub const BranchSyncStatus = struct {
    upstream: []u8,
    ahead: usize = 0,
    behind: usize = 0,

    pub fn deinit(self: BranchSyncStatus, allocator: Allocator) void {
        allocator.free(self.upstream);
    }
};

pub const RootMarkdownDoc = struct {
    id: []const u8,
    label: []const u8,
    path: []u8,
    content: []u8,

    pub fn deinit(self: RootMarkdownDoc, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const PathQuery = union(enum) {
    ok: []u8,
    invalid: []u8,

    pub fn deinit(self: PathQuery, allocator: Allocator) void {
        switch (self) {
            .ok, .invalid => |path| allocator.free(path),
        }
    }
};

pub const CodeSyncMode = enum {
    exchange,
    import,
    publish,
};

pub const CodeSyncFlashKind = enum {
    success,
    failure,
};

pub const CodeSyncFlash = struct {
    kind: CodeSyncFlashKind,
    message: []const u8,
};
