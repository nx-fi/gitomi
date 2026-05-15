const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const code_symbols = @import("symbols.zig");
const source_stats = @import("source_stats.zig");
const sync = @import("../sync.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const Href = shared.Href;
const appendEmptyState = shared.appendEmptyState;
const appendFmt = shared.appendFmt;
const appendHref = shared.appendHref;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const blameHref = shared.blameHref;
const codeHref = shared.codeHref;
const codeHrefWithView = shared.codeHrefWithView;
const commitHref = shared.commitHref;
const commitsHref = shared.commitsHref;
const rawHref = shared.rawHref;
const runCommand = git.runCommand;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;

const max_blob_display_bytes = 512 * 1024;
const max_blame_display_bytes = 16 * 1024 * 1024;
const max_raw_blob_bytes = git.max_git_output;
const unstaged_ref = "working tree";
const worktree_ref_prefix = "worktree:";

pub const RawBlob = struct {
    content_type: []const u8,
    body: []u8,

    pub fn deinit(self: RawBlob, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

const MediaKind = enum {
    image,
    video,
};

const TreeEntry = struct {
    mode: []u8,
    kind: []u8,
    oid: []u8,
    size: []u8,
    name: []u8,
    last_commit: ?TreeEntryCommit = null,

    fn deinit(self: TreeEntry, allocator: Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.kind);
        allocator.free(self.oid);
        allocator.free(self.size);
        allocator.free(self.name);
        if (self.last_commit) |commit| commit.deinit(allocator);
    }
};

const TreeNavEntry = struct {
    kind: []u8,
    path: []u8,

    fn deinit(self: TreeNavEntry, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
    }
};

const BranchRef = struct {
    name: []u8,
    scope: BranchScope,

    fn deinit(self: BranchRef, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const WorktreeRef = struct {
    path: []u8,
    value: []u8,
    label: []u8,

    fn deinit(self: WorktreeRef, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.value);
        allocator.free(self.label);
    }
};

const BranchScope = enum {
    unstaged,
    local,
    remote,
};

const TreeEntryCommit = struct {
    full_hash: []u8,
    subject: []u8,
    relative: []u8,
    synthetic: bool = false,
    change_state: ChangeState = .none,

    fn deinit(self: TreeEntryCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

const ChangeState = enum {
    none,
    staged,
    unstaged,
    staged_and_unstaged,
};

const CommitSummary = struct {
    full_hash: []u8,
    hash: []u8,
    author: []u8,
    subject: []u8,
    relative: []u8,

    fn deinit(self: CommitSummary, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.hash);
        allocator.free(self.author);
        allocator.free(self.subject);
        allocator.free(self.relative);
    }
};

const BlameLine = struct {
    commit: []u8,
    short_hash: []u8,
    author: []u8,
    date: []u8,
    author_timestamp: ?i64,
    summary: []u8,
    line_no: usize,
    content: []u8,

    fn deinit(self: BlameLine, allocator: Allocator) void {
        allocator.free(self.commit);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.date);
        allocator.free(self.summary);
        allocator.free(self.content);
    }
};

const BlameHeader = struct {
    commit: []const u8,
    line_no: usize,
};

const SlocCounts = source_stats.Counts;

const DeviconMapping = struct {
    key: []const u8,
    class: []const u8,
};

const RootEntryCounts = struct {
    files: usize = 0,
    directories: usize = 0,
};

const RepositoryOperationState = enum {
    clean,
    merge,
    rebase,
    cherry_pick,
    revert,
};

const RootGitStatus = struct {
    staged_paths: usize = 0,
    unstaged_paths: usize = 0,
    untracked_paths: usize = 0,
    conflict_paths: usize = 0,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,
    worktree_count: usize = 0,
    stash_count: usize = 0,
    disk_size_bytes: ?usize = null,
    operation_state: RepositoryOperationState = .clean,
};

const BranchSyncStatus = struct {
    upstream: []u8,
    ahead: usize = 0,
    behind: usize = 0,

    fn deinit(self: BranchSyncStatus, allocator: Allocator) void {
        allocator.free(self.upstream);
    }
};

const RootMarkdownDoc = struct {
    id: []const u8,
    label: []const u8,
    path: []u8,
    content: []u8,

    fn deinit(self: RootMarkdownDoc, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

const PathQuery = union(enum) {
    ok: []u8,
    invalid: []u8,

    fn deinit(self: PathQuery, allocator: Allocator) void {
        switch (self) {
            .ok, .invalid => |path| allocator.free(path),
        }
    }
};

const CodeSyncMode = enum {
    exchange,
    import,
    publish,
};

const CodeSyncFlashKind = enum {
    success,
    failure,
};

const CodeSyncFlash = struct {
    kind: CodeSyncFlashKind,
    message: []const u8,
};

pub fn renderCodePage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const ref = try targetRefOwned(allocator, repo, target);
    defer allocator.free(ref);

    var path_query = try targetPathQueryOwned(allocator, target);
    defer path_query.deinit(allocator);
    const path = switch (path_query) {
        .ok => |value| value,
        .invalid => |value| return renderMissingPathPage(allocator, repo, ref, value),
    };

    if (path.len == 0) {
        const sync_flash = try codeSyncFlashFromTarget(allocator, target);
        return renderTreePage(allocator, repo, ref, path, sync_flash);
    }

    const kind_owned = try browseObjectType(allocator, repo, ref, path);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return renderMissingPathPage(allocator, repo, ref, path);

    if (std.mem.eql(u8, kind, "blob")) {
        const view = try targetViewOwned(allocator, target);
        defer allocator.free(view);
        return renderBlobPage(allocator, repo, ref, path, view);
    }
    if (std.mem.eql(u8, kind, "tree")) {
        return renderTreePage(allocator, repo, ref, path, null);
    }
    return renderMissingPathPage(allocator, repo, ref, path);
}

pub fn handleCodeSyncPost(allocator: Allocator, repo: Repo, stream: std.net.Stream, form_body: []const u8) !void {
    const action_owned = (try formValueOwned(allocator, form_body, "action")) orelse try allocator.dupe(u8, "exchange");
    defer allocator.free(action_owned);
    const ref_owned = (try formValueOwned(allocator, form_body, "ref")) orelse try defaultRef(allocator, repo);
    defer allocator.free(ref_owned);

    const action = std.mem.trim(u8, action_owned, " \t\r\n");
    const mode = parseCodeSyncMode(action) orelse {
        try sendPlainResponse(allocator, stream, 400, "Bad Request", "Unknown sync action\n");
        return;
    };

    runCodeSync(allocator, mode) catch |err| {
        try sendCodeSyncFailure(allocator, repo, stream, ref_owned, err);
        return;
    };

    const location = try codeSyncRedirectOwned(allocator, ref_owned, mode);
    defer allocator.free(location);
    try sendRedirect(allocator, stream, location);
}

fn runCodeSync(allocator: Allocator, mode: CodeSyncMode) !void {
    switch (mode) {
        .exchange => {
            try sync.syncPull(allocator, "origin");
            try sync.syncPush(allocator, "origin");
        },
        .import => try sync.syncPull(allocator, "origin"),
        .publish => try sync.syncPush(allocator, "origin"),
    }
}

fn sendCodeSyncFailure(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    ref: []const u8,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(allocator, "Sync failed: {s}. Check that origin is reachable and the Gitomi refs are valid.", .{@errorName(err)});
    defer allocator.free(message);
    const body = try renderTreePage(allocator, repo, ref, "", .{ .kind = .failure, .message = message });
    defer allocator.free(body);
    try sendResponse(allocator, stream, 500, "Internal Server Error", "text/html", body, null);
}

fn codeSyncRedirectOwned(allocator: Allocator, ref: []const u8, mode: CodeSyncMode) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "/code?ref=");
    try shared.appendUrlEncoded(&buf, allocator, ref);
    try buf.appendSlice(allocator, "&sync=");
    try shared.appendUrlEncoded(&buf, allocator, codeSyncModeQueryValue(mode));
    return buf.toOwnedSlice(allocator);
}

fn codeSyncFlashFromTarget(allocator: Allocator, target: []const u8) !?CodeSyncFlash {
    const sync_value = try queryValueOwned(allocator, target, "sync");
    defer if (sync_value) |value| allocator.free(value);
    const value = sync_value orelse return null;
    const mode = parseCodeSyncMode(std.mem.trim(u8, value, " \t\r\n")) orelse return null;
    return .{ .kind = .success, .message = codeSyncSuccessMessage(mode) };
}

fn parseCodeSyncMode(value: []const u8) ?CodeSyncMode {
    if (std.mem.eql(u8, value, "exchange") or std.mem.eql(u8, value, "both") or std.mem.eql(u8, value, "sync") or std.mem.eql(u8, value, "ok")) return .exchange;
    if (std.mem.eql(u8, value, "import") or std.mem.eql(u8, value, "receive") or std.mem.eql(u8, value, "pull")) return .import;
    if (std.mem.eql(u8, value, "publish") or std.mem.eql(u8, value, "export") or std.mem.eql(u8, value, "push")) return .publish;
    return null;
}

fn codeSyncModeQueryValue(mode: CodeSyncMode) []const u8 {
    return switch (mode) {
        .exchange => "exchange",
        .import => "import",
        .publish => "publish",
    };
}

fn codeSyncSuccessMessage(mode: CodeSyncMode) []const u8 {
    return switch (mode) {
        .exchange => "Gitomi refs exchanged with origin.",
        .import => "Remote Gitomi refs imported from origin.",
        .publish => "Local Gitomi refs published to origin.",
    };
}

pub fn renderBlamePage(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const ref = try targetRefOwned(allocator, repo, target);
    defer allocator.free(ref);

    var path_query = try targetPathQueryOwned(allocator, target);
    defer path_query.deinit(allocator);
    const path = switch (path_query) {
        .ok => |value| value,
        .invalid => |value| return renderMissingPathPage(allocator, repo, ref, value),
    };

    if (path.len == 0) return renderMissingPathPage(allocator, repo, ref, path);

    const kind_owned = try browseObjectType(allocator, repo, ref, path);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return renderMissingPathPage(allocator, repo, ref, path);
    if (!std.mem.eql(u8, kind, "blob")) return renderMissingPathPage(allocator, repo, ref, path);

    const summary_opt = try loadCommitSummary(allocator, repo, ref, path);
    defer if (summary_opt) |summary| summary.deinit(allocator);
    const blame_opt = try loadBlameLines(allocator, repo, ref, path);
    defer if (blame_opt) |lines| freeBlameLines(allocator, lines);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Blame", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);

    try appendCodePanelStart(&buf, allocator, repo, ref, path);
    try appendCodeBlameSwitch(&buf, allocator, ref, path, true);
    try appendFileActionsSpacer(&buf, allocator);
    try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
    try appendCodePanelToolbarEnd(&buf, allocator);
    try appendCommitBar(&buf, allocator, summary_opt);
    try appendCodePanelHeadEnd(&buf, allocator);

    if (blame_opt) |lines| {
        if (lines.len == 0) {
            try appendEmptyState(&buf, allocator, "Empty file.", "This blob has no lines to blame.");
        } else {
            try appendBlameLines(&buf, allocator, path, lines);
        }
    } else {
        try appendEmptyState(&buf, allocator, "Blame not available.", "Git could not render blame data for this file.");
    }

    try appendCodePanelEnd(&buf, allocator);
    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

pub fn loadRawBlob(allocator: Allocator, repo: Repo, target: []const u8) !?RawBlob {
    const ref = try targetRefOwned(allocator, repo, target);
    defer allocator.free(ref);

    var path_query = try targetPathQueryOwned(allocator, target);
    defer path_query.deinit(allocator);
    const path = switch (path_query) {
        .ok => |value| value,
        .invalid => return null,
    };
    if (path.len == 0) return null;

    const kind_owned = try browseObjectType(allocator, repo, ref, path);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return null;
    if (!std.mem.eql(u8, kind, "blob")) return null;

    const size = try browseBlobSize(allocator, repo, ref, path);
    if (size != null and size.? > max_raw_blob_bytes) return error.BlobTooLarge;

    const body = try loadBlobBytes(allocator, repo, ref, path, max_raw_blob_bytes) orelse return null;
    const content_type = if (mediaKindForPath(path) != null)
        contentTypeForPath(path)
    else if (containsNul(body))
        "application/octet-stream"
    else
        "text/plain; charset=utf-8";
    return .{
        .content_type = content_type,
        .body = body,
    };
}

fn renderTreePage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, sync_flash: ?CodeSyncFlash) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);

    const entries_opt = try loadTreeEntries(allocator, repo, ref, path);
    if (entries_opt) |entries| {
        defer freeTreeEntries(allocator, entries);
        const summary_opt = try loadCommitSummary(allocator, repo, ref, path);
        defer if (summary_opt) |summary| summary.deinit(allocator);
        const is_root = path.len == 0;

        if (is_root) {
            const branches = try loadBranchRefs(allocator, repo);
            defer freeBranchRefs(allocator, branches);
            const worktrees = try loadWorktreeRefs(allocator, repo);
            defer freeWorktreeRefs(allocator, worktrees);
            const branch_count = countRealBranches(branches);
            const tag_count = loadRefCount(allocator, repo, "refs/tags") catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => 0,
            };
            const worktree_count = worktrees.len;
            const commit_count = loadCommitCount(allocator, repo, ref) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            const search_entries_opt = try loadTreeNavEntries(allocator, repo, ref);
            defer if (search_entries_opt) |search_entries| freeTreeNavEntries(allocator, search_entries);

            try appendRootPageGridStart(&buf, allocator);
            try appendRootCodeToolbar(&buf, allocator, ref, branches, worktrees, branch_count, tag_count, worktree_count, search_entries_opt);
            if (sync_flash) |flash| try appendCodeSyncFlash(&buf, allocator, flash);
            try appendRootCodePanelStart(&buf, allocator);
            try appendRootCommitBar(&buf, allocator, ref, summary_opt, commit_count);
            try appendRootTreeListing(&buf, allocator, ref, entries);
            try appendCodePanelEnd(&buf, allocator);
        } else {
            try appendCodePanelStart(&buf, allocator, repo, ref, path);
            try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
            try appendCodePanelToolbarEnd(&buf, allocator);
            try appendCommitBar(&buf, allocator, summary_opt);
            try appendCodePanelHeadEnd(&buf, allocator);
            try appendTreeListing(&buf, allocator, ref, path, entries);
            try appendCodePanelEnd(&buf, allocator);
        }

        try appendReadmePreview(&buf, allocator, repo, ref, path, entries);
        if (is_root) {
            try appendRootPageMainEnd(&buf, allocator);
            try appendRootSidebar(&buf, allocator, repo, ref, entries);
            try appendRootPageGridEnd(&buf, allocator);
        }
    } else {
        try appendEmptyState(&buf, allocator, "No committed files found.", "The selected ref does not point at a readable tree yet.");
    }

    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderBlobPage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, view: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    const size = try browseBlobSize(allocator, repo, ref, path);
    const media_kind = mediaKindForPath(path);
    const can_preview_media = media_kind != null and (size == null or size.? <= max_raw_blob_bytes);
    const content = if (!can_preview_media and size != null and size.? <= max_blob_display_bytes)
        try loadBlobBytes(allocator, repo, ref, path, max_blob_display_bytes + 1)
    else
        null;
    defer if (content) |bytes| allocator.free(bytes);
    const summary_opt = try loadCommitSummary(allocator, repo, ref, path);
    defer if (summary_opt) |summary| summary.deinit(allocator);
    const text_content = if (content) |bytes| if (containsNul(bytes)) null else bytes else null;
    const sloc_counts = if (text_content) |bytes| source_stats.countBlob(path, bytes) else null;
    const markdown = isMarkdownPath(path);
    const raw_selected = !markdown or std.mem.eql(u8, view, "raw");
    const render_markdown = markdown and !raw_selected;
    const show_symbols_panel = text_content != null and media_kind == null and !render_markdown and code_symbols.hasProvider(path);
    const show_markdown_outline = render_markdown;
    const symbol_items = if (text_content) |bytes|
        if (show_symbols_panel)
            try code_symbols.extract(allocator, repo.root, path, bytes)
        else
            try allocator.alloc(code_symbols.Symbol, 0)
    else
        try allocator.alloc(code_symbols.Symbol, 0);
    defer code_symbols.free(allocator, symbol_items);

    try appendCodeLayoutStartWithPanels(&buf, allocator, repo, ref, path, show_symbols_panel, show_markdown_outline);

    try appendCodePanelStart(&buf, allocator, repo, ref, path);
    try appendCodeBlameSwitch(&buf, allocator, ref, path, false);
    if (markdown) try appendMarkdownViewTabs(&buf, allocator, ref, path, raw_selected);
    try appendBlobMetrics(&buf, allocator, size, text_content, sloc_counts);
    if (show_symbols_panel) try appendSymbolsToggleButton(&buf, allocator);
    if (show_markdown_outline) try appendMarkdownOutlineToggleButton(&buf, allocator);
    try appendCodeActionLink(&buf, allocator, "Raw", rawHref(ref, path), "icon-file-code");
    if (text_content != null) try appendCopyButton(&buf, allocator, ref, path);
    try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
    try appendCodePanelToolbarEnd(&buf, allocator);

    try appendCommitBar(&buf, allocator, summary_opt);
    try appendCodePanelHeadEnd(&buf, allocator);
    const permalink_ref = if (summary_opt) |summary| summary.full_hash else ref;
    try appendBlobContent(&buf, allocator, ref, permalink_ref, path, media_kind, can_preview_media, content, render_markdown);

    try appendCodePanelEnd(&buf, allocator);
    try appendCodeLayoutEndWithPanels(&buf, allocator, show_symbols_panel, symbol_items, show_markdown_outline);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendBlobContent(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    permalink_ref: []const u8,
    path: []const u8,
    media_kind: ?MediaKind,
    can_preview_media: bool,
    content: ?[]const u8,
    render_markdown: bool,
) !void {
    if (media_kind) |kind| {
        if (can_preview_media) {
            try appendMediaPreview(buf, allocator, ref, path, kind);
        } else {
            try appendEmptyState(buf, allocator, "File too large to preview.", "Use Git locally to inspect this media blob.");
        }
        return;
    }

    const bytes = content orelse {
        try appendEmptyState(buf, allocator, "File too large to display.", "Use Git locally to inspect this blob.");
        return;
    };
    if (containsNul(bytes)) {
        try appendEmptyState(buf, allocator, "Binary file not displayed.", "This blob contains NUL bytes.");
    } else if (render_markdown) {
        try appendTemplate(buf, allocator,
            \\<div id="markdown-document" class="readme-body markdown-body markdown-preview" data-markdown-document data-markdown-outline="panel">
        , .{});
        try appendRepositoryMarkdown(buf, allocator, ref, path, bytes);
        try appendTemplate(buf, allocator, "</div>", .{});
    } else {
        try appendBlobLines(buf, allocator, ref, permalink_ref, path, bytes);
    }
}

fn appendMarkdownViewTabs(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8, raw_selected: bool) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="view-tabs" aria-label="Markdown view"><a{preview_class} href="{preview_href}">Preview</a><a{raw_class} href="{raw_href}">Raw</a></nav>
    , .{
        .preview_class = shared.classAttr("", &.{shared.class("active", !raw_selected)}),
        .preview_href = codeHrefWithView(ref, path, "preview"),
        .raw_class = shared.classAttr("", &.{shared.class("active", raw_selected)}),
        .raw_href = codeHrefWithView(ref, path, "raw"),
    });
}

fn appendCodeBlameSwitch(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8, blame_selected: bool) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="code-view-switch" aria-label="Code view"><a{code_class} href="{code_href}"><span class="button-icon icon-code" aria-hidden="true"></span><span>Code</span></a><a{blame_class} href="{blame_href}"><span class="button-icon icon-blame" aria-hidden="true"></span><span>Blame</span></a></nav>
    , .{
        .code_class = shared.classAttr("", &.{shared.class("active", !blame_selected)}),
        .code_href = codeHref(ref, path),
        .blame_class = shared.classAttr("", &.{shared.class("active", blame_selected)}),
        .blame_href = blameHref(ref, path),
    });
}

fn appendFileActionsSpacer(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator, "<span class=\"file-actions-spacer\" aria-hidden=\"true\"></span>", .{});
}

fn appendBlobMetrics(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    size: ?usize,
    text_content: ?[]const u8,
    sloc_counts: ?SlocCounts,
) !void {
    try appendTemplate(buf, allocator, "<span class=\"file-metrics\">", .{});
    if (text_content) |bytes| {
        const lines = physicalLineCount(bytes);
        try appendTemplate(buf, allocator,
            \\<span>{count} {label}</span>
        , .{
            .count = shared.groupedUnsigned(@intCast(lines)),
            .label = if (lines == 1) "line" else "lines",
        });
    }
    if (sloc_counts) |counts| {
        if (counts.total() > 0) {
            try appendTemplate(buf, allocator,
                \\<span>{code} code</span><span>{test_count} test</span><span>{comment} comment</span>
            , .{
                .code = shared.groupedUnsigned(counts.code),
                .test_count = shared.groupedUnsigned(counts.test_count),
                .comment = shared.groupedUnsigned(counts.comment),
            });
        }
    }
    if (size) |bytes| {
        try appendTemplate(buf, allocator, "<span>", .{});
        try appendByteSize(buf, allocator, bytes);
        try appendTemplate(buf, allocator, "</span>", .{});
    }
    try appendTemplate(buf, allocator, "</span>", .{});
}

fn appendCopyButton(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<button class="button secondary code-action copy-button" type="button" data-copy-raw="{href}" title="Copy" aria-label="Copy"><span class="button-icon icon-copy" aria-hidden="true"></span><span class="button-label" data-button-label>Copy</span></button>
    , .{ .href = rawHref(ref, path) });
}

fn appendSymbolsToggleButton(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\<button class="button secondary code-action symbols-toggle" type="button" data-symbols-toggle aria-controls="code-symbols-sidebar" aria-expanded="true" title="Hide symbols panel" aria-label="Hide symbols panel"><span class="button-icon icon-symbols" aria-hidden="true"></span><span class="button-label" data-button-label>Hide symbols</span></button>
    , .{});
}

fn appendMarkdownOutlineToggleButton(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\<button class="button secondary code-action markdown-outline-toggle" type="button" data-markdown-outline-toggle aria-controls="markdown-outline-sidebar" aria-expanded="true" title="Hide outline" aria-label="Hide outline"><span class="button-icon icon-outline" aria-hidden="true"></span><span class="button-label" data-button-label>Outline</span></button>
    , .{});
}

fn appendCodeActionLink(buf: *std.ArrayList(u8), allocator: Allocator, label: []const u8, href: Href, icon: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<a class="button secondary code-action" href="{href}" title="{label}" aria-label="{label}"><span class="button-icon {icon}" aria-hidden="true"></span><span class="button-label">{label}</span></a>
    , .{
        .href = href,
        .label = label,
        .icon = icon,
    });
}

fn renderMissingPathPage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);
    try appendEmptyState(&buf, allocator, "Path not found.", path);
    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn appendRepoHeader(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    _ = ref;
    const repo_name = std.fs.path.basename(repo.root);
    const owner_name = if (std.fs.path.dirname(repo.root)) |parent| std.fs.path.basename(parent) else "local";
    try appendTemplate(buf, allocator,
        \\<section class="repo-head">
        \\  <div>
        \\    <h1><span class="repo-owner">{owner_name}</span><span class="repo-separator">/</span>{repo_name}</h1>
        \\  </div>
        \\</section>
    , .{
        .owner_name = owner_name,
        .repo_name = repo_name,
    });
}

fn appendCodeLayoutStart(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, active_path: []const u8) !void {
    try appendCodeLayoutStartWithSymbols(buf, allocator, repo, ref, active_path, false);
}

fn appendCodeLayoutStartWithSymbols(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    active_path: []const u8,
    has_symbols: bool,
) !void {
    try appendCodeLayoutStartWithPanels(buf, allocator, repo, ref, active_path, has_symbols, false);
}

fn appendCodeLayoutStartWithPanels(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    active_path: []const u8,
    has_symbols: bool,
    has_markdown_outline: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<div{class_attr}>
    , .{
        .class_attr = shared.classAttr("code-layout", &.{
            shared.class("no-sidebar", active_path.len == 0),
            shared.class("has-symbols", has_symbols),
            shared.class("has-markdown-outline", has_markdown_outline),
        }),
    });
    if (active_path.len != 0) {
        try appendTreeSidebar(buf, allocator, repo, ref, active_path);
    }
    try appendTemplate(buf, allocator,
        \\<div class="code-main">
    , .{});
}

fn appendCodeLayoutEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendCodeLayoutEndWithSymbols(buf, allocator, false, &.{});
}

fn appendCodeLayoutEndWithSymbols(buf: *std.ArrayList(u8), allocator: Allocator, show_symbols_panel: bool, symbols: []const code_symbols.Symbol) !void {
    try appendCodeLayoutEndWithPanels(buf, allocator, show_symbols_panel, symbols, false);
}

fn appendCodeLayoutEndWithPanels(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    show_symbols_panel: bool,
    symbols: []const code_symbols.Symbol,
    show_markdown_outline: bool,
) !void {
    try appendTemplate(buf, allocator, "</div>", .{});
    if (show_symbols_panel) try appendCodeSymbolsSidebar(buf, allocator, symbols);
    if (show_markdown_outline) try appendMarkdownOutlineSidebar(buf, allocator);
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendCodePanelStart(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel code-panel">
        \\  <div class="code-panel-head">
        \\    <div class="code-pathbar">
    , .{});
    try appendBreadcrumbs(buf, allocator, repo, ref, path);
    try appendTemplate(buf, allocator,
        \\      <button class="path-copy-button" type="button" data-copy-path="{path}" aria-label="Copy path" title="Copy path"><span class="button-icon icon-copy" aria-hidden="true"></span></button>
        \\    </div>
        \\    <div class="code-toolbar">
        \\      <div class="file-actions">
    , .{ .path = path });
}

fn appendCodePanelToolbarEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\      </div>
        \\    </div>
    , .{});
}

fn appendCodePanelHeadEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator, "  </div>", .{});
}

fn appendCodePanelEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator, "</section>", .{});
}

fn appendCodeSymbolsSidebar(buf: *std.ArrayList(u8), allocator: Allocator, symbols: []const code_symbols.Symbol) !void {
    try appendTemplate(buf, allocator,
        \\<aside id="code-symbols-sidebar" class="panel symbols-sidebar" aria-label="Symbols" data-symbols-sidebar>
        \\  <div class="symbols-head">Symbols</div>
        \\  <nav class="symbols-nav">
    , .{});
    if (symbols.len == 0) {
        try appendTemplate(buf, allocator,
            \\<div class="symbols-empty">No symbols found</div>
        , .{});
    } else {
        for (symbols) |symbol| {
            try appendCodeSymbolLink(buf, allocator, symbol);
        }
    }
    try appendTemplate(buf, allocator,
        \\  </nav>
        \\  <div class="symbols-resizer" data-symbols-resizer aria-hidden="true"></div>
        \\</aside>
    , .{});
}

fn appendMarkdownOutlineSidebar(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\<aside id="markdown-outline-sidebar" class="panel markdown-outline-sidebar" aria-label="Outline" data-markdown-outline-panel>
        \\  <div class="markdown-outline-head"><h2>Outline</h2><button class="markdown-outline-close" type="button" data-markdown-outline-close aria-label="Hide outline">&times;</button></div>
        \\  <label class="markdown-outline-search" aria-label="Filter headings"><span class="button-icon icon-filter" aria-hidden="true"></span><input type="search" data-markdown-outline-filter placeholder="Filter headings" autocomplete="off" spellcheck="false"></label>
        \\  <nav class="markdown-outline-nav" data-markdown-outline-list></nav>
        \\  <div class="markdown-outline-resizer" data-markdown-outline-resizer aria-hidden="true"></div>
        \\</aside>
    , .{});
}

fn appendCodeSymbolLink(buf: *std.ArrayList(u8), allocator: Allocator, symbol: code_symbols.Symbol) !void {
    try appendTemplate(buf, allocator,
        \\<a class="symbol-link" href="#L{line_no}" title="{name}" style="--depth: {depth}">
        \\  <span class="symbol-kind">{kind}</span><span class="symbol-name">{name}</span><span class="symbol-line">L{line_no}</span>
        \\</a>
    , .{
        .line_no = symbol.line_no,
        .name = symbol.name,
        .depth = symbol.depth,
        .kind = symbol.kind.label(),
    });
}

fn appendTreeSidebar(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, active_path: []const u8) !void {
    const entries_opt = try loadTreeNavEntries(allocator, repo, ref);
    defer if (entries_opt) |entries| freeTreeNavEntries(allocator, entries);
    const branches = try loadBranchRefs(allocator, repo);
    defer freeBranchRefs(allocator, branches);
    const worktrees = try loadWorktreeRefs(allocator, repo);
    defer freeWorktreeRefs(allocator, worktrees);

    try appendTemplate(buf, allocator,
        \\<aside class="panel tree-sidebar" data-tree-sidebar>
        \\  <div class="tree-sidebar-head"><span class="tree-sidebar-title">Files</span><button class="tree-icon-button tree-collapse-button" type="button" data-tree-collapse aria-label="Collapse files panel" title="Collapse files panel"></button></div>
        \\  <div class="tree-sidebar-controls">
        \\    <label class="tree-branch-label"><span>Branch</span><select class="tree-branch-select" data-branch-switcher data-active-path="{active_path}">
    , .{ .active_path = active_path });
    try appendBranchOptions(buf, allocator, branches, worktrees, ref);
    try appendTemplate(buf, allocator,
        \\    </select></label>
        \\    <div class="tree-search-wrap"><label class="tree-search-label"><span>File search</span><input class="tree-search-input" type="search" data-tree-search placeholder="Go to file" autocomplete="off" spellcheck="false"></label></div>
        \\  </div>
        \\  <nav class="tree-nav" data-tree-nav>
    , .{});
    try appendTreeRootNode(buf, allocator, repo, ref, active_path);

    if (entries_opt) |entries| {
        for (entries) |entry| {
            try appendTreeNavEntry(buf, allocator, ref, active_path, entry);
        }
    } else {
        try appendTemplate(buf, allocator,
            \\<p class="tree-note">No files to show.</p>
        , .{});
    }

    try appendTemplate(buf, allocator,
        \\  </nav>
        \\  <div class="tree-resizer" data-tree-resizer aria-hidden="true"></div>
        \\</aside>
    , .{});
}

fn appendBranchOptions(buf: *std.ArrayList(u8), allocator: Allocator, branches: []const BranchRef, worktrees: []const WorktreeRef, selected_ref: []const u8) !void {
    var found_selected = false;
    for (branches) |branch| {
        const selected = std.mem.eql(u8, branch.name, selected_ref);
        found_selected = found_selected or selected;
        if (branch.scope == .unstaged) {
            try appendTemplate(buf, allocator,
                \\<option value="{name}"{selected_attr}>{name}</option>
            , .{
                .name = branch.name,
                .selected_attr = shared.trustedHtml(if (selected) " selected" else ""),
            });
        } else {
            try appendTemplate(buf, allocator,
                \\<option value="{name}"{selected_attr}>{name} ({scope})</option>
            , .{
                .name = branch.name,
                .scope = branchScopeLabel(branch.scope),
                .selected_attr = shared.trustedHtml(if (selected) " selected" else ""),
            });
        }
    }
    if (worktrees.len != 0) {
        try appendTemplate(buf, allocator,
            \\<option disabled>-------- Worktrees --------</option>
        , .{});
        for (worktrees) |worktree| {
            const selected = std.mem.eql(u8, worktree.value, selected_ref);
            found_selected = found_selected or selected;
            try appendTemplate(buf, allocator,
                \\<option value="{value}"{selected_attr}>{label}</option>
            , .{
                .value = worktree.value,
                .label = worktree.label,
                .selected_attr = shared.trustedHtml(if (selected) " selected" else ""),
            });
        }
    }
    if (!found_selected) {
        try appendTemplate(buf, allocator,
            \\<option value="{name}" selected>{name} (selected ref)</option>
        , .{ .name = selected_ref });
    }
}

fn appendTreeRootNode(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, active_path: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="tree-node expanded" data-tree-path="" data-tree-depth="0" data-tree-kind="tree">
        \\  <button class="tree-toggle" type="button" aria-label="Collapse repository" aria-expanded="true" data-tree-toggle></button>
        \\  <a class="{classes}" href="{href}">
    , .{
        .classes = shared.classes("tree-link", &.{shared.class("active", active_path.len == 0)}),
        .href = codeHref(ref, ""),
    });
    try appendFileIcon(buf, allocator, "", "tree");
    try appendTemplate(buf, allocator,
        \\<span class="tree-name">{repo_name}</span></a></div>
    , .{ .repo_name = std.fs.path.basename(repo.root) });
}

fn appendTreeNavEntry(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, active_path: []const u8, entry: TreeNavEntry) !void {
    const depth = pathDepth(entry.path) + 1;
    const active = std.mem.eql(u8, active_path, entry.path);
    const is_tree = std.mem.eql(u8, entry.kind, "tree");
    const ancestor = is_tree and isAncestorPath(entry.path, active_path);
    const expanded = is_tree and isAncestorOrSelfPath(entry.path, active_path);

    try appendTemplate(buf, allocator,
        \\<div class="{classes}" data-tree-path="{path}" data-tree-parent="{parent_path}" data-tree-depth="{depth}" data-tree-kind="{kind}" style="--depth: {depth}">
    , .{
        .classes = shared.classes("tree-node", &.{
            shared.class("active", active),
            shared.class("ancestor", ancestor),
            shared.class("expanded", expanded),
            shared.class("collapsed-child", !treeEntryInitiallyVisible(entry.path, active_path)),
        }),
        .path = entry.path,
        .parent_path = parentPath(entry.path),
        .depth = depth,
        .kind = entry.kind,
    });

    try appendTreeToggle(buf, allocator, is_tree, expanded);
    try appendTemplate(buf, allocator,
        \\<a class="{classes}" href="{href}">
    , .{
        .classes = shared.classes("tree-link", &.{
            shared.class("active", active),
            shared.class("ancestor", ancestor),
        }),
        .href = codeHref(ref, entry.path),
    });
    try appendFileIcon(buf, allocator, entry.path, entry.kind);
    try appendTemplate(buf, allocator,
        \\<span class="tree-name">{name}</span></a></div>
    , .{ .name = baseName(entry.path) });
}

fn appendTreeToggle(buf: *std.ArrayList(u8), allocator: Allocator, is_tree: bool, expanded: bool) !void {
    if (!is_tree) {
        try appendTemplate(buf, allocator,
            \\<span class="tree-toggle-spacer" aria-hidden="true"></span>
        , .{});
        return;
    }
    try appendTemplate(buf, allocator,
        \\<button class="tree-toggle" type="button" aria-label="{label}" aria-expanded="{expanded}" data-tree-toggle></button>
    , .{
        .label = if (expanded) "Collapse folder" else "Expand folder",
        .expanded = if (expanded) "true" else "false",
    });
}

fn appendTreeListing(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    entries: []const TreeEntry,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="file-list">
        \\  <div class="file-row file-row-head"><span>Name</span><span>Last commit</span><span>Mode</span><span>Size</span></div>
    , .{});

    if (path.len != 0) {
        try appendParentDirectoryRow(buf, allocator, ref, path);
    }

    for (entries) |entry| {
        try appendTreeEntryRow(buf, allocator, ref, path, entry);
    }

    if (entries.len == 0) {
        try appendEmptyState(buf, allocator, "Empty directory.", "This tree has no entries.");
    }

    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootCodeToolbar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    branches: []const BranchRef,
    worktrees: []const WorktreeRef,
    branch_count: usize,
    tag_count: usize,
    worktree_count: usize,
    search_entries_opt: ?[]const TreeNavEntry,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-code-toolbar">
        \\  <div class="root-code-toolbar-left">
        \\    <label class="root-branch-select-wrap" aria-label="Branch">
        \\      <span class="button-icon icon-branch" aria-hidden="true"></span>
        \\      <select class="root-branch-select" data-branch-switcher data-active-path="">
    , .{});
    try appendBranchOptions(buf, allocator, branches, worktrees, ref);
    try appendTemplate(buf, allocator,
        \\      </select>
        \\      <span class="root-caret" aria-hidden="true"></span>
        \\    </label>
        \\    <a class="root-ref-link" href="/refs"><span class="button-icon icon-branch" aria-hidden="true"></span><strong>{branch_count}</strong> {branch_label}</a>
        \\    <a class="root-ref-link" href="/refs"><span class="button-icon icon-tag" aria-hidden="true"></span><strong>{tag_count}</strong> {tag_label}</a>
        \\    <span class="root-ref-link"><span class="button-icon icon-worktree" aria-hidden="true"></span><strong>{worktree_count}</strong> {worktree_label}</span>
        \\  </div>
        \\  <div class="root-code-toolbar-right">
        \\    <div class="root-file-search-wrap">
        \\      <label class="root-file-search" aria-label="Go to file">
        \\        <span class="button-icon icon-search" aria-hidden="true"></span>
        \\        <input type="search" data-root-file-search placeholder="Go to file" autocomplete="off" spellcheck="false">
        \\        <kbd>T</kbd>
        \\      </label>
    , .{
        .branch_count = shared.groupedUnsigned(@intCast(branch_count)),
        .branch_label = if (branch_count == 1) "Branch" else "Branches",
        .tag_count = shared.groupedUnsigned(@intCast(tag_count)),
        .tag_label = if (tag_count == 1) "Tag" else "Tags",
        .worktree_count = shared.groupedUnsigned(@intCast(worktree_count)),
        .worktree_label = if (worktree_count == 1) "Worktree" else "Worktrees",
    });
    if (search_entries_opt) |search_entries| {
        try appendRootSearchIndex(buf, allocator, ref, search_entries);
    }
    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <details class="root-action-menu root-sync-menu" data-popover-menu>
        \\      <summary class="button primary root-menu-button" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span>Sync refs<span class="root-caret" aria-hidden="true"></span></summary>
        \\      <form class="root-action-popover root-sync-popover" method="post" action="/code/sync" role="menu">
        \\        <input type="hidden" name="ref" value="{ref}">
        \\        <button type="submit" name="action" value="exchange" role="menuitem">Exchange Gitomi refs</button>
        \\        <button type="submit" name="action" value="import" role="menuitem">Import remote Gitomi refs</button>
        \\        <button type="submit" name="action" value="publish" role="menuitem">Publish local Gitomi refs</button>
        \\      </form>
        \\    </details>
        \\  </div>
        \\</div>
    , .{ .ref = ref });
}

fn appendCodeSyncFlash(buf: *std.ArrayList(u8), allocator: Allocator, flash: CodeSyncFlash) !void {
    try appendTemplate(buf, allocator,
        \\<div class="flash {kind}">{message}</div>
    , .{
        .kind = switch (flash.kind) {
            .success => "success",
            .failure => "error",
        },
        .message = flash.message,
    });
}

fn appendRootSearchIndex(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, entries: []const TreeNavEntry) !void {
    try appendTemplate(buf, allocator,
        \\      <div class="root-file-search-index" data-root-file-search-index hidden>
    , .{});
    for (entries) |entry| {
        try appendTemplate(buf, allocator,
            \\        <a data-root-file-search-item data-root-file-path="{path}" data-root-file-name="{name}" data-root-file-kind="{kind}" href="{href}"></a>
        , .{
            .path = entry.path,
            .name = baseName(entry.path),
            .kind = entry.kind,
            .href = codeHref(ref, entry.path),
        });
    }
    try appendTemplate(buf, allocator,
        \\      </div>
    , .{});
}

fn appendRootCodePanelStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel code-panel root-code-panel">
    , .{});
}

fn appendRootCommitBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    summary_opt: ?CommitSummary,
    commit_count: ?usize,
) !void {
    try appendTemplate(buf, allocator, "<div class=\"root-commit-row\">", .{});
    if (summary_opt) |summary| {
        try shared.appendAvatar(buf, allocator, summary.author, "root-commit-avatar");
        try appendTemplate(buf, allocator,
            \\<div class="root-commit-main"><span class="root-commit-author">{author}</span><a class="root-commit-message" href="{href}">{subject}</a></div>
            \\<div class="root-commit-meta"><a class="root-commit-hash" href="{href}">{hash}</a><span>{relative}</span></div>
        , .{
            .author = summary.author,
            .href = commitHref(summary.full_hash),
            .subject = summary.subject,
            .hash = summary.hash,
            .relative = summary.relative,
        });
    } else {
        try shared.appendAvatar(buf, allocator, "No commits yet", "root-commit-avatar");
        try appendTemplate(buf, allocator,
            \\<div class="root-commit-main"><span class="root-commit-author">No commits yet</span><span class="root-commit-message muted">This ref has no history to summarize.</span></div>
        , .{});
    }
    if (commit_count) |count| {
        try appendTemplate(buf, allocator,
            \\<a class="root-commit-count" href="{href}"><span class="button-icon icon-history" aria-hidden="true"></span><strong>{count}</strong> {label}</a>
        , .{
            .href = commitsHref(ref, ""),
            .count = shared.groupedUnsigned(@intCast(count)),
            .label = if (count == 1) "Commit" else "Commits",
        });
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootTreeListing(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    entries: []const TreeEntry,
) !void {
    try appendTemplate(buf, allocator, "<div class=\"root-file-list\" data-root-file-list>", .{});
    for (entries) |entry| {
        try appendRootTreeEntryRow(buf, allocator, ref, entry);
    }

    if (entries.len == 0) {
        try appendEmptyState(buf, allocator, "Empty repository.", "This tree has no entries.");
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootTreeEntryRow(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, entry: TreeEntry) !void {
    const child_path = try childPath(allocator, "", entry.name);
    defer allocator.free(child_path);

    try appendTemplate(buf, allocator,
        \\<div class="root-file-row" data-root-file-row data-root-file-path="{path}" data-root-file-name="{name}" data-root-file-kind="{kind}">
        \\  <a class="file-name root-file-name" href="{href}">
    , .{
        .path = child_path,
        .name = entry.name,
        .kind = entry.kind,
        .href = codeHref(ref, child_path),
    });
    try appendFileIcon(buf, allocator, child_path, entry.kind);
    try appendTemplate(buf, allocator,
        \\{name}</a>
    , .{ .name = entry.name });

    if (entry.last_commit) |commit| {
        if (commit.synthetic) {
            const change_class = changeStateClass(commit.change_state);
            try appendTemplate(buf, allocator,
                \\<span class="root-file-commit worktree-change {change_class}" title="{subject}">
            , .{
                .change_class = change_class,
                .subject = commit.subject,
            });
            try appendWorktreeChangeLabel(buf, allocator, commit.change_state);
            try appendTemplate(buf, allocator,
                \\</span><span class="root-file-time">{relative}</span>
            , .{ .relative = commit.relative });
        } else {
            try appendTemplate(buf, allocator,
                \\<a class="root-file-commit" href="{href}" title="{subject}">{subject}</a><span class="root-file-time">{relative}</span>
            , .{
                .href = commitHref(commit.full_hash),
                .subject = commit.subject,
                .relative = commit.relative,
            });
        }
    } else {
        try appendTemplate(buf, allocator,
            \\<span class="root-file-commit empty">No commit</span><span class="root-file-time"></span>
        , .{});
    }

    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendParentDirectoryRow(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, path: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="file-row"><a class="file-name" href="{href}">
    , .{ .href = codeHref(ref, parentPath(path)) });
    try appendFileIcon(buf, allocator, "", "tree");
    try appendTemplate(buf, allocator, "..</a><span></span><span></span><span></span></div>", .{});
}

fn appendTreeEntryRow(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, parent: []const u8, entry: TreeEntry) !void {
    const child_path = try childPath(allocator, parent, entry.name);
    defer allocator.free(child_path);

    try appendTemplate(buf, allocator,
        \\<div class="file-row"><a class="file-name" href="{href}">
    , .{ .href = codeHref(ref, child_path) });
    try appendFileIcon(buf, allocator, child_path, entry.kind);
    try appendTemplate(buf, allocator,
        \\{name}</a>
    , .{
        .name = entry.name,
    });
    try appendTreeEntryCommit(buf, allocator, entry.last_commit);
    try appendTemplate(buf, allocator,
        \\<span><code>{mode}</code></span><span class="file-size">
    , .{ .mode = entry.mode });
    if (std.mem.eql(u8, entry.kind, "blob")) {
        try appendSize(buf, allocator, entry.size);
    }
    try appendTemplate(buf, allocator, "</span></div>", .{});
}

fn appendTreeEntryCommit(buf: *std.ArrayList(u8), allocator: Allocator, commit_opt: ?TreeEntryCommit) !void {
    if (commit_opt) |commit| {
        if (commit.synthetic) {
            const change_class = changeStateClass(commit.change_state);
            try appendTemplate(buf, allocator,
                \\<span class="file-commit worktree-change {change_class}" title="{subject}">
            , .{
                .change_class = change_class,
                .subject = commit.subject,
            });
            try appendWorktreeChangeLabel(buf, allocator, commit.change_state);
            try appendTemplate(buf, allocator, "</span>", .{});
        } else {
            try appendTemplate(buf, allocator,
                \\<span class="file-commit" title="{subject}"><a href="{href}">{subject}</a></span>
            , .{
                .href = commitHref(commit.full_hash),
                .subject = commit.subject,
            });
        }
    } else {
        try appendTemplate(buf, allocator, "<span class=\"file-commit empty\">No commit</span>", .{});
    }
}

fn appendWorktreeChangeLabel(buf: *std.ArrayList(u8), allocator: Allocator, state: ChangeState) !void {
    switch (state) {
        .none => {},
        .staged => try appendTemplate(buf, allocator, "has <span class=\"change-word staged\">staged</span> changes", .{}),
        .unstaged => try appendTemplate(buf, allocator, "has <span class=\"change-word unstaged\">unstaged</span> changes", .{}),
        .staged_and_unstaged => try appendTemplate(buf, allocator, "has <span class=\"change-word staged\">staged</span> and <span class=\"change-word unstaged\">unstaged</span> changes", .{}),
    }
}

fn appendCommitBar(buf: *std.ArrayList(u8), allocator: Allocator, summary_opt: ?CommitSummary) !void {
    try appendTemplate(buf, allocator, "<div class=\"commit-bar\">", .{});
    if (summary_opt) |summary| {
        try appendTemplate(buf, allocator,
            \\<a class="commit-hash" href="{href}"><code>{hash}</code></a><strong><a href="{href}">{subject}</a></strong><span>{relative}</span>
        , .{
            .href = commitHref(summary.full_hash),
            .hash = summary.hash,
            .subject = summary.subject,
            .relative = summary.relative,
        });
    } else {
        try appendTemplate(buf, allocator, "<strong>No commits yet</strong><span>This ref has no history to summarize.</span>", .{});
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendBreadcrumbs(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="breadcrumbs"><a href="{href}">{repo_name}</a>
    , .{
        .href = codeHref(ref, ""),
        .repo_name = std.fs.path.basename(repo.root),
    });

    if (path.len != 0) {
        var built: std.ArrayList(u8) = .empty;
        defer built.deinit(allocator);
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (built.items.len != 0) try built.append(allocator, '/');
            try built.appendSlice(allocator, part);
            try appendTemplate(buf, allocator, "<span>/</span>", .{});
            if (built.items.len == path.len) {
                try appendTemplate(buf, allocator, "<strong>{part}</strong>", .{ .part = part });
            } else {
                try appendTemplate(buf, allocator,
                    \\<a href="{href}">{part}</a>
                , .{
                    .href = codeHref(ref, built.items),
                    .part = part,
                });
            }
        }
    }

    try appendTemplate(buf, allocator, "</nav>", .{});
}

fn appendBlobLines(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, permalink_ref: []const u8, path: []const u8, content: []const u8) !void {
    const language = languageForPath(path);
    try appendTemplate(buf, allocator,
        \\<ol class="blob-lines" data-code-lines data-path="{path}" data-code-href="{code_href}" data-permalink-href="{permalink_href}" data-blame-href="{blame_href}">
    , .{
        .path = path,
        .code_href = codeHref(ref, path),
        .permalink_href = codeHref(permalink_ref, path),
        .blame_href = blameHref(ref, path),
    });
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        try appendBlobLine(buf, allocator, language, line_no, line);
    }
    if (content.len == 0) {
        try appendBlobLine(buf, allocator, language, 1, "");
    }
    try appendTemplate(buf, allocator, "</ol>", .{});
}

fn appendBlobLine(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, line_no: usize, line: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<li class="blob-row" id="L{line_no}" data-line-row data-line-number="{line_no}"><button class="line-menu-button" type="button" data-line-menu-button aria-label="Line {line_no} actions" aria-expanded="false" tabindex="-1"></button><a class="line-num" href="#L{line_no}">{line_no}</a><code class="language-{language}">{line}</code></li>
    , .{
        .line_no = line_no,
        .language = language,
        .line = line,
    });
}

fn appendMediaPreview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    kind: MediaKind,
) !void {
    try appendTemplate(buf, allocator, "<div class=\"media-preview\">", .{});
    switch (kind) {
        .image => {
            try appendTemplate(buf, allocator,
                \\<a class="media-preview-link" href="{href}"><img src="{href}" alt="{alt}" loading="lazy" decoding="async"></a>
            , .{
                .href = rawHref(ref, path),
                .alt = baseName(path),
            });
        },
        .video => {
            try appendTemplate(buf, allocator,
                \\<video controls preload="metadata"><source src="{href}" type="{content_type}">{name}</video>
            , .{
                .href = rawHref(ref, path),
                .content_type = contentTypeForPath(path),
                .name = baseName(path),
            });
        },
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendBlameLines(buf: *std.ArrayList(u8), allocator: Allocator, path: []const u8, lines: []const BlameLine) !void {
    const language = languageForPath(path);
    const now = std.time.timestamp();
    try appendTemplate(buf, allocator, "<ol class=\"blame-lines\">", .{});
    for (lines) |line| {
        try appendBlameLine(buf, allocator, language, now, line);
    }
    try appendTemplate(buf, allocator, "</ol>", .{});
}

fn appendBlameLine(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, now: i64, line: BlameLine) !void {
    const relative_date = try relativeTimeOwned(allocator, line.author_timestamp, now);
    defer allocator.free(relative_date);
    try appendTemplate(buf, allocator,
        \\<li class="blame-row {age_class}" id="L{line_no}"><span class="blame-meta" title="{summary}"><a class="blame-hash" href="{href}">{short_hash}</a><span class="blame-author">{author}</span><span class="blame-date" title="{date}">{relative_date}</span></span><a class="line-num" href="#L{line_no}">{line_no}</a><code class="blame-code language-{language}">{content}</code></li>
    , .{
        .age_class = blameAgeClass(line.author_timestamp, now),
        .line_no = line.line_no,
        .summary = line.summary,
        .href = commitHref(line.commit),
        .short_hash = line.short_hash,
        .author = line.author,
        .date = line.date,
        .relative_date = relative_date,
        .language = language,
        .content = line.content,
    });
}

fn appendReadmePreview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    path: []const u8,
    entries: []const TreeEntry,
) !void {
    const readme = findReadme(entries) orelse return;
    const readme_path = try childPath(allocator, path, readme);
    defer allocator.free(readme_path);
    const content = try loadBlobBytes(allocator, repo, ref, readme_path, max_blob_display_bytes + 1) orelse return;
    defer allocator.free(content);
    if (containsNul(content)) return;

    if (path.len == 0) {
        const readme_doc = RootMarkdownDoc{
            .id = "readme",
            .label = "README",
            .path = try allocator.dupe(u8, readme_path),
            .content = try allocator.dupe(u8, content),
        };
        defer readme_doc.deinit(allocator);

        const license_doc_opt = try loadRootLicenseDoc(allocator, repo, ref, entries);
        defer if (license_doc_opt) |doc| doc.deinit(allocator);

        try appendRootDocsPreview(buf, allocator, ref, readme_doc, license_doc_opt);
        return;
    }

    try appendTemplate(buf, allocator,
        \\<section class="panel readme-panel">
        \\  <div class="section-head readme-head"><h2>{readme}</h2></div><div class="readme-body markdown-body">
    , .{
        .readme = readme,
    });
    try appendRepositoryMarkdown(buf, allocator, ref, readme_path, content);
    try appendTemplate(buf, allocator, "</div></section>", .{});
}

fn appendRootDocsPreview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    readme_doc: RootMarkdownDoc,
    license_doc_opt: ?RootMarkdownDoc,
) !void {
    try appendTemplate(buf, allocator,
        \\<section class="panel readme-panel root-docs-panel" data-root-docs>
        \\  <div class="section-head readme-head root-docs-head">
        \\    <nav class="root-doc-tabs" aria-label="Repository documents">
        \\      <button class="root-doc-tab active" type="button" data-root-doc-tab="readme" aria-selected="true"><span class="button-icon icon-book" aria-hidden="true"></span><span>README</span></button>
    , .{});
    if (license_doc_opt) |license_doc| {
        try appendTemplate(buf, allocator,
            \\      <button class="root-doc-tab" type="button" data-root-doc-tab="license" aria-selected="false"><span class="button-icon icon-scale" aria-hidden="true"></span><span>{label}</span></button>
        , .{ .label = license_doc.label });
    }
    try appendTemplate(buf, allocator,
        \\    </nav>
        \\    <details class="markdown-toc-menu" data-popover-menu data-markdown-toc-menu hidden>
        \\      <summary aria-label="Table of contents" title="Table of contents"><span class="button-icon icon-outline" aria-hidden="true"></span></summary>
        \\      <div class="markdown-toc-popover"><nav class="markdown-toc-list" data-markdown-toc-list></nav></div>
        \\    </details>
        \\  </div>
        \\  <div class="root-doc-panel readme-body markdown-body" data-root-doc-panel="readme" data-markdown-document data-markdown-outline="menu">
    , .{});
    try appendRepositoryMarkdown(buf, allocator, ref, readme_doc.path, readme_doc.content);
    try appendTemplate(buf, allocator, "</div>", .{});
    if (license_doc_opt) |license_doc| {
        try appendTemplate(buf, allocator,
            \\  <div class="root-doc-panel readme-body markdown-body" data-root-doc-panel="license" data-markdown-document data-markdown-outline="menu" hidden>
        , .{});
        try appendRepositoryMarkdown(buf, allocator, ref, license_doc.path, license_doc.content);
        try appendTemplate(buf, allocator, "</div>", .{});
    }
    try appendTemplate(buf, allocator, "</section>", .{});
}

fn loadRootLicenseDoc(allocator: Allocator, repo: Repo, ref: []const u8, entries: []const TreeEntry) !?RootMarkdownDoc {
    const license = findLicense(entries) orelse return null;
    const content = try loadBlobBytes(allocator, repo, ref, license, max_blob_display_bytes + 1) orelse return null;
    errdefer allocator.free(content);
    if (containsNul(content)) {
        allocator.free(content);
        return null;
    }
    const label = licenseLabel(content);
    return .{
        .id = "license",
        .label = label,
        .path = try allocator.dupe(u8, license),
        .content = content,
    };
}

fn appendRootPageGridStart(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-page-grid"><div class="root-page-main">
    , .{});
}

fn appendRootPageMainEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootPageGridEnd(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootSidebar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    repo: Repo,
    ref: []const u8,
    entries: []const TreeEntry,
) !void {
    const counts = rootEntryCounts(entries);
    const git_status = loadRootGitStatus(allocator, repo) catch null;
    const branch_sync_status = loadBranchSyncStatus(allocator, repo, ref) catch null;
    defer if (branch_sync_status) |status| status.deinit(allocator);
    const about_summary = loadReadmeSummaryOwned(allocator, repo, ref, entries) catch null;
    defer if (about_summary) |summary| allocator.free(summary);
    var languages_opt = source_stats.loadRepositoryStats(allocator, repo) catch null;
    defer if (languages_opt) |*stats| stats.deinit(allocator);
    const about_text = about_summary orelse "Browse this repository's files, documentation, and Gitomi records from the local checkout.";

    try appendTemplate(buf, allocator,
        \\<aside class="root-sidebar" aria-label="Repository details">
        \\  <section class="panel root-sidebar-panel">
        \\    <div class="root-sidebar-section">
        \\      <h2>About</h2>
        \\      <p class="root-about-text">{about}</p>
    , .{ .about = about_text });

    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <div class="root-sidebar-section">
        \\      <h2>Repository</h2>
        \\      <dl class="root-meta-list">
    , .{});
    if (git_status) |status| {
        try appendRootRepositoryStats(buf, allocator, status);
    } else {
        try appendTemplate(buf, allocator,
            \\        <div><dt>Repository</dt><dd>Unavailable</dd></div>
        , .{});
    }
    try appendTemplate(buf, allocator,
        \\      </dl>
        \\    </div>
        \\    <div class="root-sidebar-section">
        \\      <h2>Branch</h2>
        \\      <dl class="root-meta-list">
        \\        <div><dt>Ref</dt><dd><code>{ref}</code></dd></div>
        \\        <div><dt>Root</dt><dd>{files} {files_label}, {directories} {directories_label}</dd></div>
    , .{
        .ref = ref,
        .files = counts.files,
        .files_label = if (counts.files == 1) "file" else "files",
        .directories = counts.directories,
        .directories_label = if (counts.directories == 1) "folder" else "folders",
    });
    if (branch_sync_status) |status| {
        try appendRootBranchSyncStatus(buf, allocator, status);
    } else {
        try appendTemplate(buf, allocator,
            \\        <div><dt>Sync</dt><dd>No upstream</dd></div>
        , .{});
    }
    if (git_status) |status| {
        try appendRootBranchStats(buf, allocator, status);
    } else {
        try appendTemplate(buf, allocator,
            \\        <div><dt>Checkout</dt><dd>Unavailable</dd></div>
        , .{});
    }
    try appendTemplate(buf, allocator,
        \\      </dl>
        \\    </div>
    , .{});

    try appendRootLanguages(buf, allocator, languages_opt);
    try appendRootSloc(buf, allocator, languages_opt);
    try appendTemplate(buf, allocator, "</section></aside>", .{});
}

fn appendRootRepositoryStats(buf: *std.ArrayList(u8), allocator: Allocator, status: RootGitStatus) !void {
    try appendTemplate(buf, allocator,
        \\        <div><dt>Worktrees</dt><dd>{worktrees}</dd></div>
        \\        <div><dt>Stashes</dt><dd>{stashes}</dd></div>
        \\        <div><dt>Size</dt><dd>
    , .{
        .worktrees = shared.groupedUnsigned(@intCast(status.worktree_count)),
        .stashes = shared.groupedUnsigned(@intCast(status.stash_count)),
    });
    if (status.disk_size_bytes) |bytes| {
        try appendByteSize(buf, allocator, bytes);
    } else {
        try appendTemplate(buf, allocator, "Unknown", .{});
    }
    try appendTemplate(buf, allocator, "</dd></div>", .{});
}

fn appendRootBranchSyncStatus(buf: *std.ArrayList(u8), allocator: Allocator, status: BranchSyncStatus) !void {
    try appendTemplate(buf, allocator,
        \\        <div><dt>Sync</dt><dd>{ahead} ahead, {behind} behind <code>{upstream}</code></dd></div>
    , .{
        .ahead = shared.groupedUnsigned(@intCast(status.ahead)),
        .behind = shared.groupedUnsigned(@intCast(status.behind)),
        .upstream = status.upstream,
    });
}

fn appendRootBranchStats(buf: *std.ArrayList(u8), allocator: Allocator, status: RootGitStatus) !void {
    try appendTemplate(buf, allocator,
        \\        <div><dt>Changes</dt><dd>{staged} staged, {modified} modified, {untracked} untracked</dd></div>
        \\        <div><dt>Diff</dt><dd><span class="root-diffstat"><span class="root-diffstat-added">+{added}</span><span class="root-diffstat-removed">-{removed}</span></span></dd></div>
        \\        <div><dt>State</dt><dd>
    , .{
        .staged = shared.groupedUnsigned(@intCast(status.staged_paths)),
        .modified = shared.groupedUnsigned(@intCast(status.unstaged_paths)),
        .untracked = shared.groupedUnsigned(@intCast(status.untracked_paths)),
        .added = shared.groupedUnsigned(status.lines_added),
        .removed = shared.groupedUnsigned(status.lines_removed),
    });
    try appendRootRepositoryState(buf, allocator, status);
    try appendTemplate(buf, allocator,
        \\</dd></div>
    , .{});
}

fn appendRootRepositoryState(buf: *std.ArrayList(u8), allocator: Allocator, status: RootGitStatus) !void {
    if (status.conflict_paths != 0) {
        try appendTemplate(buf, allocator, "{conflicts} {label}", .{
            .conflicts = shared.groupedUnsigned(@intCast(status.conflict_paths)),
            .label = if (status.conflict_paths == 1) "conflict" else "conflicts",
        });
        if (status.operation_state != .clean) {
            try appendTemplate(buf, allocator, ", {operation}", .{
                .operation = repositoryOperationLabel(status.operation_state),
            });
        }
        return;
    }
    try appendTemplate(buf, allocator, "{state}", .{
        .state = if (status.operation_state == .clean) "clean" else repositoryOperationLabel(status.operation_state),
    });
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

fn loadRootGitStatus(allocator: Allocator, repo: Repo) !RootGitStatus {
    var status = RootGitStatus{};

    if (try gitMaybe(allocator, repo, &.{ "status", "--porcelain=v2" }, git.max_git_output)) |raw| {
        defer allocator.free(raw);
        parseRootGitStatusV2(&status, raw);
    }
    try loadRootDiffStats(allocator, repo, &status);
    status.worktree_count = loadWorktreeCount(allocator, repo) catch 1;
    if (status.worktree_count == 0) status.worktree_count = 1;
    status.stash_count = loadStashCount(allocator, repo) catch 0;
    status.disk_size_bytes = loadDiskSizeBytes(allocator, repo) catch null;
    status.operation_state = loadRepositoryOperationState(allocator, repo) catch .clean;

    return status;
}

fn loadBranchSyncStatus(allocator: Allocator, repo: Repo, ref: []const u8) !?BranchSyncStatus {
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

fn parseRootGitStatusV2(status: *RootGitStatus, raw: []const u8) void {
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

fn parseOrdinaryStatusRecord(status: *RootGitStatus, line: []const u8) void {
    if (line.len < 4 or line[1] != ' ') return;
    const index_status = line[2];
    const worktree_status = line[3];
    if (index_status != '.' and index_status != ' ') status.staged_paths += 1;
    if (worktree_status != '.' and worktree_status != ' ') status.unstaged_paths += 1;
}

fn loadRootDiffStats(allocator: Allocator, repo: Repo, status: *RootGitStatus) !void {
    const raw = try gitMaybe(allocator, repo, &.{ "diff", "--numstat", "HEAD", "--" }, git.max_git_output) orelse return;
    defer allocator.free(raw);
    parseRootDiffNumstat(status, raw);
}

fn parseRootDiffNumstat(status: *RootGitStatus, raw: []const u8) void {
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

fn loadWorktreeCount(allocator: Allocator, repo: Repo) !usize {
    const raw = try gitMaybe(allocator, repo, &.{ "worktree", "list", "--porcelain" }, git.max_git_output) orelse return 0;
    defer allocator.free(raw);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) count += 1;
    }
    return count;
}

fn loadWorktreeRefs(allocator: Allocator, repo: Repo) ![]WorktreeRef {
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
        fn lessThan(_: void, a: WorktreeRef, b: WorktreeRef) bool {
            return std.ascii.lessThanIgnoreCase(a.path, b.path);
        }
    }.lessThan);

    return worktrees.toOwnedSlice(allocator);
}

fn appendParsedWorktreeRef(
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

fn worktreeBranchLabel(ref: []const u8) []const u8 {
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref, heads_prefix)) return ref[heads_prefix.len..];
    return ref;
}

fn loadStashCount(allocator: Allocator, repo: Repo) !usize {
    const raw = try gitMaybe(allocator, repo, &.{ "stash", "list" }, git.max_git_output) orelse return 0;
    defer allocator.free(raw);
    return countNonEmptyLines(raw);
}

fn loadDiskSizeBytes(allocator: Allocator, repo: Repo) !?usize {
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

fn loadRepositoryOperationState(allocator: Allocator, repo: Repo) !RepositoryOperationState {
    if (try gitPathExists(allocator, repo, "rebase-merge")) return .rebase;
    if (try gitPathExists(allocator, repo, "rebase-apply")) return .rebase;
    if (try gitPathExists(allocator, repo, "MERGE_HEAD")) return .merge;
    if (try gitPathExists(allocator, repo, "CHERRY_PICK_HEAD")) return .cherry_pick;
    if (try gitPathExists(allocator, repo, "REVERT_HEAD")) return .revert;
    return .clean;
}

fn gitPathExists(allocator: Allocator, repo: Repo, git_path: []const u8) !bool {
    const raw = try gitMaybe(allocator, repo, &.{ "rev-parse", "--path-format=absolute", "--git-path", git_path }, 1024) orelse return false;
    defer allocator.free(raw);
    const path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn countNonEmptyLines(raw: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len != 0) count += 1;
    }
    return count;
}

fn appendRootLanguages(buf: *std.ArrayList(u8), allocator: Allocator, stats_opt: ?source_stats.Stats) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>Languages</h2>
    , .{});
    const stats = stats_opt orelse {
        try appendTemplate(buf, allocator,
            \\<p class="root-sidebar-empty">No language data available.</p></div>
        , .{});
        return;
    };
    const total = stats.total();
    if (total == 0 or stats.rows.len == 0) {
        try appendTemplate(buf, allocator,
            \\<p class="root-sidebar-empty">No source files counted.</p></div>
        , .{});
        return;
    }

    try appendTemplate(buf, allocator,
        \\<div class="root-language-bar" aria-hidden="true">
    , .{});
    for (stats.rows) |stat| {
        try appendTemplate(buf, allocator,
            \\<span style="--share: {share}; --language-color: {color};"></span>
        , .{
            .share = shared.percent(stat.total(), total),
            .color = source_stats.languageColor(stat.language),
        });
    }
    try appendTemplate(buf, allocator, "</div>", .{});
    try appendTemplate(buf, allocator,
        \\<ul class="root-language-list">
    , .{});
    for (stats.rows) |stat| {
        try appendTemplate(buf, allocator,
            \\<li><span class="language-dot" style="--language-color: {color};"></span><span class="root-language-name">{name}</span><strong>{share}</strong></li>
        , .{
            .color = source_stats.languageColor(stat.language),
            .name = source_stats.languageDisplayName(stat.language),
            .share = shared.percent(stat.total(), total),
        });
    }
    try appendTemplate(buf, allocator,
        \\</ul></div>
    , .{});
}

fn appendRootSloc(buf: *std.ArrayList(u8), allocator: Allocator, stats_opt: ?source_stats.Stats) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>SLOC</h2>
    , .{});
    const stats = stats_opt orelse {
        try appendTemplate(buf, allocator,
            \\<p class="root-sidebar-empty">No SLOC data available.</p></div>
        , .{});
        return;
    };
    const total = stats.total();
    if (total == 0 or stats.rows.len == 0) {
        try appendTemplate(buf, allocator,
            \\<p class="root-sidebar-empty">No source files counted.</p></div>
        , .{});
        return;
    }

    try appendTemplate(buf, allocator,
        \\<div class="root-sloc-total" aria-label="Total source lines of code"><span>Total SLOC</span><strong>{total} {lines_label}</strong></div><div class="root-sloc-breakdown" aria-label="Top source lines of code by language">
    , .{
        .total = shared.groupedUnsigned(total),
        .lines_label = if (total == 1) "line" else "lines",
    });
    for (stats.rows[0..@min(stats.rows.len, 3)]) |stat| {
        try appendTemplate(buf, allocator,
            \\<div class="root-sloc-row" style="--language-color: {color}; --share: {share};"><span class="root-sloc-language"><span class="language-dot"></span><span>{name}</span></span><span class="root-sloc-metrics"><span><strong>{code}</strong> code</span><span><strong>{test_count}</strong> test</span><span><strong>{comment}</strong> comments</span></span></div>
        , .{
            .color = source_stats.languageColor(stat.language),
            .share = shared.percent(stat.total(), total),
            .name = source_stats.languageDisplayName(stat.language),
            .code = shared.groupedUnsigned(stat.code),
            .test_count = shared.groupedUnsigned(stat.test_count),
            .comment = shared.groupedUnsigned(stat.comment),
        });
    }
    try appendTemplate(buf, allocator, "</div></div>", .{});
}

fn rootEntryCounts(entries: []const TreeEntry) RootEntryCounts {
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

fn loadReadmeSummaryOwned(allocator: Allocator, repo: Repo, ref: []const u8, entries: []const TreeEntry) !?[]u8 {
    const readme = findReadme(entries) orelse return null;
    const content = try loadBlobBytes(allocator, repo, ref, readme, 64 * 1024) orelse return null;
    defer allocator.free(content);
    if (containsNul(content)) return null;
    return try markdownSummaryOwned(allocator, content);
}

fn markdownSummaryOwned(allocator: Allocator, content: []const u8) !?[]u8 {
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

fn shouldSkipSummaryLine(line: []const u8) bool {
    return line[0] == '#' or
        line[0] == '!' or
        std.mem.startsWith(u8, line, "[!") or
        std.mem.startsWith(u8, line, "<p") or
        std.mem.startsWith(u8, line, "<div") or
        std.mem.startsWith(u8, line, "<img");
}

fn appendCleanMarkdownText(buf: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !void {
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

fn appendRepositoryMarkdown(
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

fn physicalLineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    var lines: usize = 0;
    for (content) |c| {
        if (c == '\n') lines += 1;
    }
    if (content[content.len - 1] != '\n') lines += 1;
    return lines;
}

fn loadTreeEntries(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]TreeEntry {
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

fn loadTreeEntryCommits(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, entries: []TreeEntry) !void {
    if (isFilesystemRef(ref)) return;

    var index_by_name = std.StringHashMap(usize).init(allocator);
    defer index_by_name.deinit();
    for (entries, 0..) |entry, i| {
        try index_by_name.put(entry.name, i);
    }

    const format = "--format=%x1e%H%x09%s%x09%cr";
    const raw = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "log", format, "--name-only", "-z", ref, "--" }, git.max_git_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "log", format, "--name-only", "-z", ref, "--", pathspec }, git.max_git_output);
    };
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
}

fn loadFilesystemTreeEntryCommits(allocator: Allocator, root: []const u8, path: []const u8, entries: []TreeEntry) !void {
    var index_by_name = std.StringHashMap(usize).init(allocator);
    defer index_by_name.deinit();
    for (entries, 0..) |entry, i| {
        try index_by_name.put(entry.name, i);
    }

    try markChangedFilesystemChildren(allocator, root, path, entries, &index_by_name);

    const format = "--format=%x1e%H%x09%s%x09%cr";
    const raw = if (path.len == 0)
        try gitMaybeAt(allocator, root, &.{ "log", format, "--name-only", "-z", "HEAD", "--" }, git.max_git_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybeAt(allocator, root, &.{ "log", format, "--name-only", "-z", "HEAD", "--", pathspec }, git.max_git_output);
    };
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
}

fn markChangedFilesystemChildren(
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

fn changeStateFromStatus(index_status: u8, worktree_status: u8) ChangeState {
    const staged = index_status != ' ' and index_status != '?';
    const unstaged = worktree_status != ' ';
    if (staged and unstaged) return .staged_and_unstaged;
    if (staged) return .staged;
    if (unstaged) return .unstaged;
    return .none;
}

fn mergeChangeStates(a: ChangeState, b: ChangeState) ChangeState {
    if (a == .staged_and_unstaged or b == .staged_and_unstaged) return .staged_and_unstaged;
    if ((a == .staged and b == .unstaged) or (a == .unstaged and b == .staged)) return .staged_and_unstaged;
    if (a != .none) return a;
    return b;
}

fn changeStateSubject(state: ChangeState) []const u8 {
    return switch (state) {
        .none => "",
        .staged => "has staged changes",
        .unstaged => "has unstaged changes",
        .staged_and_unstaged => "has staged and unstaged changes",
    };
}

fn changeStateClass(state: ChangeState) []const u8 {
    return switch (state) {
        .none => "",
        .staged => "staged",
        .unstaged => "unstaged",
        .staged_and_unstaged => "staged-and-unstaged",
    };
}

fn treeEntryCommitOwned(allocator: Allocator, commit: LogCommit) !TreeEntryCommit {
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

fn syntheticTreeEntryCommitOwned(allocator: Allocator, state: ChangeState) !TreeEntryCommit {
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

const LogCommit = struct {
    full_hash: []const u8,
    subject: []const u8,
    relative: []const u8,
};

fn parseLogCommitHeader(record: []const u8) ?LogCommit {
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

fn normalizeLogPathRecord(record: []const u8) []const u8 {
    return std.mem.trimLeft(u8, record, "\r\n");
}

fn directChildName(parent: []const u8, changed_path: []const u8) ?[]const u8 {
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

fn loadBlameLines(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]BlameLine {
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

fn parseBlamePorcelain(allocator: Allocator, raw: []const u8) ![]BlameLine {
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

fn parseBlameHeader(line: []const u8) ?BlameHeader {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const commit = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const final_line = fields.next() orelse return null;
    return .{
        .commit = commit,
        .line_no = std.fmt.parseUnsigned(usize, final_line, 10) catch return null,
    };
}

fn appendBlameRecord(
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

fn shortHashOwned(allocator: Allocator, hash: []const u8) ![]u8 {
    return allocator.dupe(u8, hash[0..@min(hash.len, 8)]);
}

fn authorDateOwned(allocator: Allocator, author_time: []const u8, author_tz: []const u8) ![]u8 {
    const parsed = std.fmt.parseInt(i64, author_time, 10) catch return allocator.dupe(u8, "unknown");
    const adjusted = parsed + parseTimezoneOffset(author_tz);
    const safe_seconds: u64 = if (adjusted < 0) 0 else @intCast(adjusted);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = safe_seconds };
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

fn parseAuthorTimestamp(author_time: []const u8) ?i64 {
    if (author_time.len == 0) return null;
    return std.fmt.parseInt(i64, author_time, 10) catch null;
}

fn blameAgeClass(author_timestamp: ?i64, now: i64) []const u8 {
    const timestamp = author_timestamp orelse return "age-unknown";
    if (timestamp >= now) return "age-now";

    const seconds_per_day = 24 * 60 * 60;
    const age_days = @divFloor(now - timestamp, seconds_per_day);
    if (age_days <= 1) return "age-now";
    if (age_days <= 7) return "age-week";
    if (age_days <= 30) return "age-month";
    if (age_days <= 90) return "age-quarter";
    if (age_days <= 365) return "age-year";
    return "age-old";
}

fn relativeTimeOwned(allocator: Allocator, author_timestamp: ?i64, now: i64) ![]u8 {
    const timestamp = author_timestamp orelse return allocator.dupe(u8, "unknown");
    const age_seconds = now - timestamp;
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

fn relativeUnitOwned(allocator: Allocator, value: i64, unit: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d} {s}{s} ago",
        .{ value, unit, if (value == 1) "" else "s" },
    );
}

fn parseTimezoneOffset(value: []const u8) i64 {
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

fn loadCommitSummary(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?CommitSummary {
    if (isFilesystemRef(ref)) return null;

    const format = "--format=%H%x09%h%x09%an%x09%s%x09%cr";
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

fn loadCommitCount(allocator: Allocator, repo: Repo, ref: []const u8) !?usize {
    if (isFilesystemRef(ref)) return null;

    const raw = try gitMaybe(allocator, repo, &.{ "rev-list", "--count", ref }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn loadRefCount(allocator: Allocator, repo: Repo, namespace: []const u8) !usize {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)", namespace }, git.max_git_output) orelse return 0;
    defer allocator.free(raw);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len != 0) count += 1;
    }
    return count;
}

fn loadTreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
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

fn loadWorktreeEntries(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]TreeEntry {
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

fn loadWorktreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
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

fn listWorktreePaths(allocator: Allocator, root: []const u8) !?[]u8 {
    return gitMaybeAt(allocator, root, &.{ "ls-files", "-z", "-c", "-o", "--exclude-standard" }, git.max_git_output);
}

const WorktreePathKind = enum {
    blob,
    tree,
};

fn worktreePathKind(root: []const u8, path: []const u8) !?WorktreePathKind {
    if (path.len == 0) return .tree;
    const absolute_path = try absoluteWorktreePath(std.heap.page_allocator, root, path);
    defer std.heap.page_allocator.free(absolute_path);
    const stat = std.fs.cwd().statFile(absolute_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return switch (stat.kind) {
        .directory => .tree,
        .file, .sym_link => .blob,
        else => null,
    };
}

fn worktreeObjectType(allocator: Allocator, root: []const u8, path: []const u8) !?[]u8 {
    const kind = try worktreePathKind(root, path) orelse return null;
    return try allocator.dupe(u8, switch (kind) {
        .blob => "blob",
        .tree => "tree",
    });
}

fn worktreeBlobSize(root: []const u8, path: []const u8) !?usize {
    const absolute_path = try absoluteWorktreePath(std.heap.page_allocator, root, path);
    defer std.heap.page_allocator.free(absolute_path);
    const stat = std.fs.cwd().statFile(absolute_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    if (stat.kind != .file and stat.kind != .sym_link) return null;
    return stat.size;
}

fn readWorktreeFile(allocator: Allocator, root: []const u8, path: []const u8, max_bytes: usize) !?[]u8 {
    const absolute_path = try absoluteWorktreePath(allocator, root, path);
    defer allocator.free(absolute_path);
    return std.fs.cwd().readFileAlloc(allocator, absolute_path, max_bytes) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => return err,
    };
}

fn absoluteWorktreePath(allocator: Allocator, root: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, root);
    return std.fs.path.join(allocator, &.{ root, path });
}

fn worktreeTreeEntryOwned(allocator: Allocator, name: []const u8, is_tree: bool, size: ?usize) !TreeEntry {
    return .{
        .mode = try allocator.dupe(u8, if (is_tree) "040000" else "100644"),
        .kind = try allocator.dupe(u8, if (is_tree) "tree" else "blob"),
        .oid = try allocator.dupe(u8, ""),
        .size = if (size) |bytes| try std.fmt.allocPrint(allocator, "{d}", .{bytes}) else try allocator.dupe(u8, "-"),
        .name = try allocator.dupe(u8, name),
    };
}

fn treeEntryIndexByName(entries: []const TreeEntry, name: []const u8) ?usize {
    for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) return i;
    }
    return null;
}

fn loadBranchRefs(allocator: Allocator, repo: Repo) ![]BranchRef {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname)%09%(refname:short)", "refs/heads", "refs/remotes" }, git.max_git_output) orelse {
        return allocator.alloc(BranchRef, 0);
    };
    defer allocator.free(raw);

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
        try branches.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .scope = scope,
        });
    }
    std.mem.sort(BranchRef, branches.items, {}, struct {
        fn lessThan(_: void, a: BranchRef, b: BranchRef) bool {
            if (a.scope != b.scope) return @intFromEnum(a.scope) < @intFromEnum(b.scope);
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    try branches.insert(allocator, 0, .{
        .name = try allocator.dupe(u8, unstaged_ref),
        .scope = .unstaged,
    });
    return branches.toOwnedSlice(allocator);
}

fn branchScopeForFullRef(ref: []const u8) ?BranchScope {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) return .local;
    if (std.mem.startsWith(u8, ref, "refs/remotes/")) return .remote;
    return null;
}

fn branchScopeLabel(scope: BranchScope) []const u8 {
    return switch (scope) {
        .unstaged => "working tree",
        .local => "local",
        .remote => "remote",
    };
}

fn countRealBranches(branches: []const BranchRef) usize {
    var count: usize = 0;
    for (branches) |branch| {
        if (branch.scope != .unstaged) count += 1;
    }
    return count;
}

fn treeEntryLessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
    return entryNameLessThan(
        a.name,
        std.mem.eql(u8, a.kind, "tree"),
        b.name,
        std.mem.eql(u8, b.kind, "tree"),
    );
}

fn treeNavEntryLessThan(_: void, a: TreeNavEntry, b: TreeNavEntry) bool {
    return pathLessThan(
        a.path,
        std.mem.eql(u8, a.kind, "tree"),
        b.path,
        std.mem.eql(u8, b.kind, "tree"),
    );
}

fn pathLessThan(a_path: []const u8, a_is_tree: bool, b_path: []const u8, b_is_tree: bool) bool {
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

const PathSegment = struct {
    name: []const u8,
    terminal: bool,
};

fn nextPathSegment(path: []const u8, cursor: *usize) ?PathSegment {
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

fn entryNameLessThan(a_name: []const u8, a_is_tree: bool, b_name: []const u8, b_is_tree: bool) bool {
    return entryNameOrder(a_name, a_is_tree, b_name, b_is_tree) == .lt;
}

fn entryNameOrder(a_name: []const u8, a_is_tree: bool, b_name: []const u8, b_is_tree: bool) std.math.Order {
    const a_rank = entrySortRank(a_name, a_is_tree);
    const b_rank = entrySortRank(b_name, b_is_tree);
    if (a_rank < b_rank) return .lt;
    if (a_rank > b_rank) return .gt;
    return std.mem.order(u8, a_name, b_name);
}

fn entrySortRank(name: []const u8, is_tree: bool) u8 {
    const dot = name.len != 0 and name[0] == '.';
    if (is_tree) return if (dot) 0 else 1;
    return if (dot) 2 else 3;
}

fn objectType(allocator: Allocator, repo: Repo, spec: []const u8) !?[]u8 {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-t", spec }, 1024) orelse return null;
    return try trimOwned(allocator, raw);
}

fn browseObjectType(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]u8 {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return worktreeObjectType(allocator, root, path);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return objectType(allocator, repo, spec);
}

fn blobSize(allocator: Allocator, repo: Repo, spec: []const u8) !?usize {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-s", spec }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn browseBlobSize(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?usize {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return worktreeBlobSize(root, path);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return blobSize(allocator, repo, spec);
}

fn loadBlobBytes(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, max_bytes: usize) !?[]u8 {
    if (isFilesystemRef(ref)) {
        const root = try worktreeRootOwned(allocator, repo, ref) orelse return null;
        defer allocator.free(root);
        return readWorktreeFile(allocator, root, path, max_bytes);
    }
    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    return gitMaybe(allocator, repo, &.{ "show", spec }, max_bytes);
}

fn defaultRef(allocator: Allocator, repo: Repo) ![]u8 {
    const branch_raw = try gitMaybe(allocator, repo, &.{ "branch", "--show-current" }, 512 * 1024);
    if (branch_raw) |raw| {
        defer allocator.free(raw);
        const branch = std.mem.trim(u8, raw, " \t\r\n");
        if (branch.len != 0) return allocator.dupe(u8, branch);
    }
    return allocator.dupe(u8, "HEAD");
}

fn targetRefOwned(allocator: Allocator, repo: Repo, target: []const u8) ![]u8 {
    const query_ref = try queryValueOwned(allocator, target, "ref");
    defer if (query_ref) |value| allocator.free(value);
    if (query_ref) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len != 0) return resolveBrowsableRefOwned(allocator, repo, trimmed);
    }
    return defaultRef(allocator, repo);
}

fn resolveBrowsableRefOwned(allocator: Allocator, repo: Repo, ref: []const u8) ![]u8 {
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

fn isUnstagedRef(ref: []const u8) bool {
    return std.mem.eql(u8, ref, unstaged_ref);
}

fn isWorktreeRef(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, worktree_ref_prefix);
}

fn isFilesystemRef(ref: []const u8) bool {
    return isUnstagedRef(ref) or isWorktreeRef(ref);
}

fn worktreeRootOwned(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    if (isUnstagedRef(ref)) return try allocator.dupe(u8, repo.root);
    if (!isWorktreeRef(ref)) return null;
    return worktreePathFromRefOwned(allocator, repo, ref);
}

fn worktreePathFromRefOwned(allocator: Allocator, repo: Repo, ref: []const u8) !?[]u8 {
    if (!isWorktreeRef(ref)) return null;
    const wanted = ref[worktree_ref_prefix.len..];
    const worktrees = try loadWorktreeRefs(allocator, repo);
    defer freeWorktreeRefs(allocator, worktrees);
    for (worktrees) |worktree| {
        if (std.mem.eql(u8, worktree.path, wanted)) return try allocator.dupe(u8, worktree.path);
    }
    return null;
}

fn refResolvesToObject(allocator: Allocator, repo: Repo, ref: []const u8) !bool {
    const object_ref = try std.fmt.allocPrint(allocator, "{s}^{{object}}", .{ref});
    defer allocator.free(object_ref);
    const raw = try gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", object_ref }, 1024 * 1024) orelse return false;
    allocator.free(raw);
    return true;
}

fn remoteTrackingBranchShortNameOwned(allocator: Allocator, repo: Repo, branch_name: []const u8) !?[]u8 {
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

fn remoteTrackingBranchName(full_ref: []const u8) ?[]const u8 {
    const prefix = "refs/remotes/";
    if (!std.mem.startsWith(u8, full_ref, prefix)) return null;
    const rest = full_ref[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash + 1 >= rest.len) return null;
    return rest[slash + 1 ..];
}

fn isBranchShorthand(ref: []const u8) bool {
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

fn targetPathQueryOwned(allocator: Allocator, target: []const u8) !PathQuery {
    const query_path = (try queryValueOwned(allocator, target, "path")) orelse return .{ .ok = try allocator.dupe(u8, "") };
    errdefer allocator.free(query_path);

    const path = normalizedPathOwned(allocator, query_path) catch |err| switch (err) {
        error.InvalidPath => return .{ .invalid = query_path },
        else => return err,
    };
    allocator.free(query_path);
    return .{ .ok = path };
}

fn targetViewOwned(allocator: Allocator, target: []const u8) ![]u8 {
    const query_view = (try queryValueOwned(allocator, target, "view")) orelse return allocator.dupe(u8, "");
    defer allocator.free(query_view);
    return allocator.dupe(u8, std.mem.trim(u8, query_view, " \t\r\n"));
}

fn objectSpec(allocator: Allocator, ref: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, ref);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, path });
}

fn childPath(allocator: Allocator, parent: []const u8, name: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn pathDepth(path: []const u8) usize {
    var depth: usize = 0;
    for (path) |c| {
        if (c == '/') depth += 1;
    }
    return depth;
}

fn isAncestorPath(parent: []const u8, path: []const u8) bool {
    if (parent.len == 0 or path.len <= parent.len) return false;
    return std.mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}

fn isAncestorOrSelfPath(parent: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, parent, path) or isAncestorPath(parent, path);
}

fn treeEntryInitiallyVisible(path: []const u8, active_path: []const u8) bool {
    const parent = parentPath(path);
    return parent.len == 0 or isAncestorOrSelfPath(parent, active_path);
}

const exact_file_devicons = [_]DeviconMapping{
    .{ .key = ".babelrc", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.cjs", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.js", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.json", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.mjs", .class = "devicon-babel-plain" },
    .{ .key = ".dockerignore", .class = "devicon-docker-plain" },
    .{ .key = ".eslintignore", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.cjs", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.js", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.json", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.mjs", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.yaml", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.yml", .class = "devicon-eslint-plain" },
    .{ .key = ".firebaserc", .class = "devicon-firebase-plain" },
    .{ .key = ".git-blame-ignore-revs", .class = "devicon-git-plain" },
    .{ .key = ".gitattributes", .class = "devicon-git-plain" },
    .{ .key = ".gitconfig", .class = "devicon-git-plain" },
    .{ .key = ".gitignore", .class = "devicon-git-plain" },
    .{ .key = ".gitkeep", .class = "devicon-git-plain" },
    .{ .key = ".gitmodules", .class = "devicon-git-plain" },
    .{ .key = ".mailmap", .class = "devicon-git-plain" },
    .{ .key = ".node-version", .class = "devicon-nodejs-plain" },
    .{ .key = ".npmignore", .class = "devicon-npm-plain" },
    .{ .key = ".npmrc", .class = "devicon-npm-plain" },
    .{ .key = ".nvmrc", .class = "devicon-nodejs-plain" },
    .{ .key = ".pnpmfile.cjs", .class = "devicon-pnpm-plain" },
    .{ .key = ".postcssrc", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.cjs", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.js", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.json", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.mjs", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.yaml", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.yml", .class = "devicon-postcss-original" },
    .{ .key = ".python-version", .class = "devicon-python-plain" },
    .{ .key = ".ruby-gemset", .class = "devicon-ruby-plain" },
    .{ .key = ".ruby-version", .class = "devicon-ruby-plain" },
    .{ .key = ".terraform.lock.hcl", .class = "devicon-terraform-plain" },
    .{ .key = ".terraformrc", .class = "devicon-terraform-plain" },
    .{ .key = ".travis.yml", .class = "devicon-travis-plain" },
    .{ .key = ".yarnrc", .class = "devicon-yarn-original" },
    .{ .key = ".yarnrc.yml", .class = "devicon-yarn-original" },
    .{ .key = "angular.json", .class = "devicon-angular-plain" },
    .{ .key = "ansible.cfg", .class = "devicon-ansible-plain" },
    .{ .key = "artisan", .class = "devicon-laravel-original" },
    .{ .key = "azure-pipelines.yaml", .class = "devicon-azuredevops-plain" },
    .{ .key = "azure-pipelines.yml", .class = "devicon-azuredevops-plain" },
    .{ .key = "biome.json", .class = "devicon-biome-original" },
    .{ .key = "biome.jsonc", .class = "devicon-biome-original" },
    .{ .key = "bitbucket-pipelines.yml", .class = "devicon-bitbucket-original" },
    .{ .key = "build.gradle", .class = "devicon-gradle-original" },
    .{ .key = "build.gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = "build.sbt", .class = "devicon-scala-plain" },
    .{ .key = "bun.lock", .class = "devicon-bun-plain" },
    .{ .key = "bun.lockb", .class = "devicon-bun-plain" },
    .{ .key = "bunfig.toml", .class = "devicon-bun-plain" },
    .{ .key = "cabal.project", .class = "devicon-haskell-plain" },
    .{ .key = "cargo.lock", .class = "devicon-rust-original" },
    .{ .key = "cargo.toml", .class = "devicon-rust-original" },
    .{ .key = "chart.lock", .class = "devicon-helm-original" },
    .{ .key = "chart.yaml", .class = "devicon-helm-original" },
    .{ .key = "circle.yml", .class = "devicon-circleci-plain" },
    .{ .key = "cloudbuild.yaml", .class = "devicon-googlecloud-plain" },
    .{ .key = "cloudbuild.yml", .class = "devicon-googlecloud-plain" },
    .{ .key = "cmakelists.txt", .class = "devicon-cmake-plain" },
    .{ .key = "cmakepresets.json", .class = "devicon-cmake-plain" },
    .{ .key = "cmakeuserpresets.json", .class = "devicon-cmake-plain" },
    .{ .key = "codeowners", .class = "devicon-github-original" },
    .{ .key = "compose.yaml", .class = "devicon-docker-plain" },
    .{ .key = "compose.yml", .class = "devicon-docker-plain" },
    .{ .key = "composer.json", .class = "devicon-composer-line" },
    .{ .key = "composer.lock", .class = "devicon-composer-line" },
    .{ .key = "constraints.txt", .class = "devicon-python-plain" },
    .{ .key = "docker-compose.yaml", .class = "devicon-docker-plain" },
    .{ .key = "docker-compose.yml", .class = "devicon-docker-plain" },
    .{ .key = "docker-bake.hcl", .class = "devicon-docker-plain" },
    .{ .key = "dockerfile", .class = "devicon-docker-plain" },
    .{ .key = "deno.json", .class = "devicon-denojs-original" },
    .{ .key = "deno.jsonc", .class = "devicon-denojs-original" },
    .{ .key = "deno.lock", .class = "devicon-denojs-original" },
    .{ .key = "dependabot.yaml", .class = "devicon-github-original" },
    .{ .key = "dependabot.yml", .class = "devicon-github-original" },
    .{ .key = "elm.json", .class = "devicon-elm-plain" },
    .{ .key = "ember-cli-build.js", .class = "devicon-ember-plain" },
    .{ .key = "environment.yaml", .class = "devicon-anaconda-original" },
    .{ .key = "environment.yml", .class = "devicon-anaconda-original" },
    .{ .key = "firebase.json", .class = "devicon-firebase-plain" },
    .{ .key = "flake.lock", .class = "devicon-nixos-plain" },
    .{ .key = "funding.yml", .class = "devicon-github-original" },
    .{ .key = "gemfile", .class = "devicon-ruby-plain" },
    .{ .key = "gemfile.lock", .class = "devicon-ruby-plain" },
    .{ .key = "go.mod", .class = "devicon-go-plain" },
    .{ .key = "go.sum", .class = "devicon-go-plain" },
    .{ .key = "go.work", .class = "devicon-go-plain" },
    .{ .key = "go.work.sum", .class = "devicon-go-plain" },
    .{ .key = "gradle.properties", .class = "devicon-gradle-original" },
    .{ .key = "gradlew", .class = "devicon-gradle-original" },
    .{ .key = "gradlew.bat", .class = "devicon-gradle-original" },
    .{ .key = "helmfile.yaml", .class = "devicon-helm-original" },
    .{ .key = "helmfile.yml", .class = "devicon-helm-original" },
    .{ .key = "httpd.conf", .class = "devicon-apache-plain" },
    .{ .key = "jenkinsfile", .class = "devicon-jenkins-plain" },
    .{ .key = "jsconfig.json", .class = "devicon-javascript-plain" },
    .{ .key = "kustomization.yaml", .class = "devicon-kubernetes-plain" },
    .{ .key = "kustomization.yml", .class = "devicon-kubernetes-plain" },
    .{ .key = "manage.py", .class = "devicon-django-plain" },
    .{ .key = "mix.exs", .class = "devicon-elixir-plain" },
    .{ .key = "mix.lock", .class = "devicon-elixir-plain" },
    .{ .key = "mvnw", .class = "devicon-maven-plain" },
    .{ .key = "mvnw.cmd", .class = "devicon-maven-plain" },
    .{ .key = "netlify.toml", .class = "devicon-netlify-plain" },
    .{ .key = "nginx.conf", .class = "devicon-nginx-original" },
    .{ .key = "npm-shrinkwrap.json", .class = "devicon-npm-plain" },
    .{ .key = "package-lock.json", .class = "devicon-npm-plain" },
    .{ .key = "package.json", .class = "devicon-npm-plain" },
    .{ .key = "package.swift", .class = "devicon-swift-plain" },
    .{ .key = "pipfile", .class = "devicon-python-plain" },
    .{ .key = "pipfile.lock", .class = "devicon-python-plain" },
    .{ .key = "pnpm-lock.yaml", .class = "devicon-pnpm-plain" },
    .{ .key = "pnpm-workspace.yaml", .class = "devicon-pnpm-plain" },
    .{ .key = "podfile", .class = "devicon-xcode-plain" },
    .{ .key = "podfile.lock", .class = "devicon-xcode-plain" },
    .{ .key = "poetry.lock", .class = "devicon-poetry-plain" },
    .{ .key = "pom.xml", .class = "devicon-maven-plain" },
    .{ .key = "procfile", .class = "devicon-heroku-original" },
    .{ .key = "pubspec.lock", .class = "devicon-dart-plain" },
    .{ .key = "pubspec.yaml", .class = "devicon-dart-plain" },
    .{ .key = "pulumi.yaml", .class = "devicon-pulumi-plain" },
    .{ .key = "pulumi.yml", .class = "devicon-pulumi-plain" },
    .{ .key = "pyproject.toml", .class = "devicon-python-plain" },
    .{ .key = "pytest.ini", .class = "devicon-pytest-plain" },
    .{ .key = "rakefile", .class = "devicon-ruby-plain" },
    .{ .key = "rebar.config", .class = "devicon-erlang-plain" },
    .{ .key = "rebar.lock", .class = "devicon-erlang-plain" },
    .{ .key = "requirements.txt", .class = "devicon-python-plain" },
    .{ .key = "rust-toolchain", .class = "devicon-rust-original" },
    .{ .key = "rust-toolchain.toml", .class = "devicon-rust-original" },
    .{ .key = "rustfmt.toml", .class = "devicon-rust-original" },
    .{ .key = "schema.prisma", .class = "devicon-prisma-original" },
    .{ .key = "settings.gradle", .class = "devicon-gradle-original" },
    .{ .key = "settings.gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = "setup.cfg", .class = "devicon-python-plain" },
    .{ .key = "setup.py", .class = "devicon-python-plain" },
    .{ .key = "stack.yaml", .class = "devicon-haskell-plain" },
    .{ .key = "symfony.lock", .class = "devicon-symfony-original" },
    .{ .key = "terraform.rc", .class = "devicon-terraform-plain" },
    .{ .key = "tox.ini", .class = "devicon-python-plain" },
    .{ .key = "tsconfig.base.json", .class = "devicon-typescript-plain" },
    .{ .key = "tsconfig.json", .class = "devicon-typescript-plain" },
    .{ .key = "uv.lock", .class = "devicon-python-plain" },
    .{ .key = "vagrantfile", .class = "devicon-vagrant-plain" },
    .{ .key = "vercel.json", .class = "devicon-vercel-original" },
    .{ .key = "wrangler.toml", .class = "devicon-cloudflareworkers-plain" },
    .{ .key = "yarn.lock", .class = "devicon-yarn-original" },
};

const base_prefix_devicons = [_]DeviconMapping{
    .{ .key = ".babelrc.", .class = "devicon-babel-plain" },
    .{ .key = ".eslintrc.", .class = "devicon-eslint-plain" },
    .{ .key = ".postcssrc.", .class = "devicon-postcss-original" },
    .{ .key = "astro.config.", .class = "devicon-astro-plain" },
    .{ .key = "babel.config.", .class = "devicon-babel-plain" },
    .{ .key = "cypress.config.", .class = "devicon-cypressio-plain" },
    .{ .key = "dockerfile.", .class = "devicon-docker-plain" },
    .{ .key = "eslint.config.", .class = "devicon-eslint-plain" },
    .{ .key = "gatsby-browser.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-config.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-node.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-ssr.", .class = "devicon-gatsby-original" },
    .{ .key = "jest.config.", .class = "devicon-jest-plain" },
    .{ .key = "jest.setup.", .class = "devicon-jest-plain" },
    .{ .key = "karma.conf.", .class = "devicon-karma-plain" },
    .{ .key = "knexfile.", .class = "devicon-knexjs-original" },
    .{ .key = "next.config.", .class = "devicon-nextjs-plain" },
    .{ .key = "nuxt.config.", .class = "devicon-nuxt-original" },
    .{ .key = "openapi.", .class = "devicon-openapi-plain" },
    .{ .key = "playwright.config.", .class = "devicon-playwright-plain" },
    .{ .key = "postcss.config.", .class = "devicon-postcss-original" },
    .{ .key = "pulumi.", .class = "devicon-pulumi-plain" },
    .{ .key = "remix.config.", .class = "devicon-remix-original" },
    .{ .key = "rollup.config.", .class = "devicon-rollup-plain" },
    .{ .key = "sequelize.config.", .class = "devicon-sequelize-plain" },
    .{ .key = "svelte.config.", .class = "devicon-svelte-plain" },
    .{ .key = "swagger.", .class = "devicon-swagger-plain" },
    .{ .key = "tailwind.config.", .class = "devicon-tailwindcss-original" },
    .{ .key = "vite.config.", .class = "devicon-vite-original" },
    .{ .key = "vitest.config.", .class = "devicon-vitest-plain" },
    .{ .key = "vue.config.", .class = "devicon-vuejs-plain" },
    .{ .key = "webpack.config.", .class = "devicon-webpack-plain" },
};

const base_suffix_devicons = [_]DeviconMapping{
    .{ .key = ".astro", .class = "devicon-astro-plain" },
    .{ .key = ".bazel", .class = "devicon-bazel-plain" },
    .{ .key = ".bzl", .class = "devicon-bazel-plain" },
    .{ .key = ".cabal", .class = "devicon-haskell-plain" },
    .{ .key = ".csproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".fsproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".gradle", .class = "devicon-gradle-original" },
    .{ .key = ".gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = ".ipynb", .class = "devicon-jupyter-plain" },
    .{ .key = ".nomad", .class = "devicon-nomad-original" },
    .{ .key = ".nomad.hcl", .class = "devicon-nomad-original" },
    .{ .key = ".pbxproj", .class = "devicon-xcode-plain" },
    .{ .key = ".pkr.hcl", .class = "devicon-packer-plain" },
    .{ .key = ".prisma", .class = "devicon-prisma-original" },
    .{ .key = ".razor", .class = "devicon-blazor-original" },
    .{ .key = ".rproj", .class = "devicon-rstudio-plain" },
    .{ .key = ".sln", .class = "devicon-visualstudio-plain" },
    .{ .key = ".tf", .class = "devicon-terraform-plain" },
    .{ .key = ".tfstate", .class = "devicon-terraform-plain" },
    .{ .key = ".tfvars", .class = "devicon-terraform-plain" },
    .{ .key = ".vbproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".vue", .class = "devicon-vuejs-plain" },
    .{ .key = ".xcconfig", .class = "devicon-xcode-plain" },
    .{ .key = ".zig.zon", .class = "devicon-zig-original" },
};

const language_devicons = [_]DeviconMapping{
    .{ .key = "apache", .class = "devicon-apache-plain" },
    .{ .key = "arduino", .class = "devicon-arduino-plain" },
    .{ .key = "awk", .class = "devicon-awk-plain-wordmark" },
    .{ .key = "bash", .class = "devicon-bash-plain" },
    .{ .key = "c", .class = "devicon-c-original" },
    .{ .key = "ceylon", .class = "devicon-ceylon-plain" },
    .{ .key = "clojure", .class = "devicon-clojure-plain" },
    .{ .key = "cmake", .class = "devicon-cmake-plain" },
    .{ .key = "coffeescript", .class = "devicon-coffeescript-original" },
    .{ .key = "cpp", .class = "devicon-cplusplus-plain" },
    .{ .key = "crystal", .class = "devicon-crystal-original" },
    .{ .key = "csharp", .class = "devicon-csharp-plain" },
    .{ .key = "css", .class = "devicon-css3-plain" },
    .{ .key = "dart", .class = "devicon-dart-plain" },
    .{ .key = "delphi", .class = "devicon-delphi-plain" },
    .{ .key = "django", .class = "devicon-django-plain" },
    .{ .key = "dockerfile", .class = "devicon-docker-plain" },
    .{ .key = "dos", .class = "devicon-msdos-plain" },
    .{ .key = "elixir", .class = "devicon-elixir-plain" },
    .{ .key = "elm", .class = "devicon-elm-plain" },
    .{ .key = "erlang", .class = "devicon-erlang-plain" },
    .{ .key = "fortran", .class = "devicon-fortran-original" },
    .{ .key = "fsharp", .class = "devicon-fsharp-plain" },
    .{ .key = "gherkin", .class = "devicon-cucumber-plain" },
    .{ .key = "go", .class = "devicon-go-plain" },
    .{ .key = "gradle", .class = "devicon-gradle-original" },
    .{ .key = "graphql", .class = "devicon-graphql-plain" },
    .{ .key = "groovy", .class = "devicon-groovy-plain" },
    .{ .key = "handlebars", .class = "devicon-handlebars-original" },
    .{ .key = "haskell", .class = "devicon-haskell-plain" },
    .{ .key = "haxe", .class = "devicon-haxe-plain" },
    .{ .key = "html", .class = "devicon-html5-plain" },
    .{ .key = "java", .class = "devicon-java-plain" },
    .{ .key = "javascript", .class = "devicon-javascript-plain" },
    .{ .key = "json", .class = "devicon-json-plain" },
    .{ .key = "julia", .class = "devicon-julia-plain" },
    .{ .key = "kotlin", .class = "devicon-kotlin-plain" },
    .{ .key = "latex", .class = "devicon-latex-original" },
    .{ .key = "less", .class = "devicon-less-plain-wordmark" },
    .{ .key = "llvm", .class = "devicon-llvm-plain" },
    .{ .key = "lua", .class = "devicon-lua-plain" },
    .{ .key = "markdown", .class = "devicon-markdown-original" },
    .{ .key = "matlab", .class = "devicon-matlab-plain" },
    .{ .key = "nginx", .class = "devicon-nginx-original" },
    .{ .key = "nim", .class = "devicon-nim-plain" },
    .{ .key = "nix", .class = "devicon-nixos-plain" },
    .{ .key = "objectivec", .class = "devicon-objectivec-plain" },
    .{ .key = "ocaml", .class = "devicon-ocaml-plain" },
    .{ .key = "perl", .class = "devicon-perl-plain" },
    .{ .key = "pgsql", .class = "devicon-postgresql-plain" },
    .{ .key = "php", .class = "devicon-php-plain" },
    .{ .key = "powershell", .class = "devicon-powershell-plain" },
    .{ .key = "processing", .class = "devicon-processing-plain" },
    .{ .key = "prolog", .class = "devicon-prolog-plain" },
    .{ .key = "python", .class = "devicon-python-plain" },
    .{ .key = "r", .class = "devicon-r-plain" },
    .{ .key = "ruby", .class = "devicon-ruby-plain" },
    .{ .key = "rust", .class = "devicon-rust-original" },
    .{ .key = "scala", .class = "devicon-scala-plain" },
    .{ .key = "scss", .class = "devicon-sass-original" },
    .{ .key = "shell", .class = "devicon-bash-plain" },
    .{ .key = "solidity", .class = "devicon-solidity-plain" },
    .{ .key = "stata", .class = "devicon-stata-original-wordmark" },
    .{ .key = "stylus", .class = "devicon-stylus-original" },
    .{ .key = "svelte", .class = "devicon-svelte-plain" },
    .{ .key = "swift", .class = "devicon-swift-plain" },
    .{ .key = "typescript", .class = "devicon-typescript-plain" },
    .{ .key = "vala", .class = "devicon-vala-plain" },
    .{ .key = "vbnet", .class = "devicon-visualbasic-plain" },
    .{ .key = "vim", .class = "devicon-vim-plain" },
    .{ .key = "wasm", .class = "devicon-wasm-original" },
    .{ .key = "xml", .class = "devicon-xml-plain" },
    .{ .key = "yaml", .class = "devicon-yaml-plain" },
    .{ .key = "zig", .class = "devicon-zig-original" },
};

fn appendFileIcon(buf: *std.ArrayList(u8), allocator: Allocator, path: []const u8, kind: []const u8) !void {
    if (deviconClassForPath(path, kind)) |class| {
        try appendTemplate(buf, allocator,
            \\<i class="file-icon devicon-icon {class}" aria-hidden="true"></i>
        , .{ .class = class });
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span class="file-icon {class}" aria-hidden="true"></span>
    , .{ .class = fileIconClass(path, kind) });
}

fn deviconClassForPath(path: []const u8, kind: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, kind, "blob")) return null;
    if (mediaKindForPath(path) != null) return null;

    const base = baseName(path);
    if (deviconClassForExactBase(base)) |class| return class;
    if (deviconClassForPathPattern(path, base)) |class| return class;
    if (deviconClassForBasePrefix(base)) |class| return class;
    if (deviconClassForBaseSuffix(base)) |class| return class;

    const language = languageForPath(path);
    return deviconClassForLanguage(language);
}

fn deviconClassForExactBase(base: []const u8) ?[]const u8 {
    return deviconClassFromMappings(base, &exact_file_devicons);
}

fn deviconClassForPathPattern(path: []const u8, base: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(path, ".github/workflows/") and isYamlPath(path)) return "devicon-githubactions-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".github/")) return "devicon-github-original";
    if (std.ascii.startsWithIgnoreCase(path, ".gitlab/")) return "devicon-gitlab-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".circleci/")) return "devicon-circleci-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".devcontainer/")) return "devicon-docker-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".vscode/")) return "devicon-vscode-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".mvn/")) return "devicon-maven-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".cargo/")) return "devicon-rust-original";
    if (std.ascii.startsWithIgnoreCase(path, ".gradle/")) return "devicon-gradle-original";
    if (std.ascii.startsWithIgnoreCase(path, ".yarn/")) return "devicon-yarn-original";
    if (std.ascii.startsWithIgnoreCase(path, ".storybook/")) return "devicon-storybook-plain";
    if (std.ascii.startsWithIgnoreCase(path, "charts/") and std.ascii.eqlIgnoreCase(base, "values.yaml")) return "devicon-helm-original";
    if (std.ascii.startsWithIgnoreCase(path, "charts/") and std.ascii.eqlIgnoreCase(base, "values.yml")) return "devicon-helm-original";
    return null;
}

fn deviconClassForBasePrefix(base: []const u8) ?[]const u8 {
    for (base_prefix_devicons) |mapping| {
        if (std.ascii.startsWithIgnoreCase(base, mapping.key)) return mapping.class;
    }
    return null;
}

fn deviconClassForBaseSuffix(base: []const u8) ?[]const u8 {
    for (base_suffix_devicons) |mapping| {
        if (endsWithIgnoreCase(base, mapping.key)) return mapping.class;
    }
    return null;
}

fn deviconClassForLanguage(language: []const u8) ?[]const u8 {
    return deviconClassFromMappings(language, &language_devicons);
}

fn deviconClassFromMappings(value: []const u8, mappings: []const DeviconMapping) ?[]const u8 {
    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(value, mapping.key)) return mapping.class;
    }
    return null;
}

fn isYamlPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".yaml") or endsWithIgnoreCase(path, ".yml");
}

fn fileIconClass(path: []const u8, kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "tree")) return "dir";
    if (mediaKindForPath(path)) |media_kind| {
        return switch (media_kind) {
            .image => "file lang-img",
            .video => "file lang-video",
        };
    }
    const language = languageForPath(path);
    if (std.mem.eql(u8, language, "zig")) return "file lang-zig";
    if (std.mem.eql(u8, language, "javascript")) return "file lang-js";
    if (std.mem.eql(u8, language, "typescript")) return "file lang-ts";
    if (std.mem.eql(u8, language, "bash")) return "file lang-sh";
    if (std.mem.eql(u8, language, "json")) return "file lang-json";
    if (std.mem.eql(u8, language, "toml")) return "file lang-toml";
    if (std.mem.eql(u8, language, "yaml")) return "file lang-yaml";
    if (std.mem.eql(u8, language, "css")) return "file lang-css";
    if (std.mem.eql(u8, language, "html")) return "file lang-html";
    if (std.mem.eql(u8, language, "xml")) return "file lang-xml";
    if (std.mem.eql(u8, language, "sql")) return "file lang-sql";
    if (std.mem.eql(u8, language, "solidity")) return "file lang-sol";
    if (std.mem.eql(u8, language, "tla")) return "file lang-tla";
    if (std.mem.eql(u8, language, "rust")) return "file lang-rs";
    if (std.mem.eql(u8, language, "python")) return "file lang-py";
    if (std.mem.eql(u8, language, "markdown")) return "file lang-md";
    return "file";
}

fn findReadme(entries: []const TreeEntry) ?[]const u8 {
    const names = [_][]const u8{ "README.md", "README", "Readme.md", "readme.md" };
    for (names) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.kind, "blob") and std.mem.eql(u8, entry.name, wanted)) return entry.name;
        }
    }
    return null;
}

fn findLicense(entries: []const TreeEntry) ?[]const u8 {
    const names = [_][]const u8{ "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "COPYING.txt" };
    for (names) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.kind, "blob") and std.ascii.eqlIgnoreCase(entry.name, wanted)) return entry.name;
        }
    }
    return null;
}

fn licenseLabel(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(line, "MIT License")) return "MIT license";
        if (std.ascii.eqlIgnoreCase(line, "Apache License")) return "Apache license";
        if (line.len <= 80 and endsWithIgnoreCase(line, "License")) return line;
        break;
    }
    return "License";
}

fn isMarkdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".markdown") or
        std.ascii.eqlIgnoreCase(baseName(path), "README");
}

fn mediaKindForPath(path: []const u8) ?MediaKind {
    if (isImagePath(path)) return .image;
    if (isVideoPath(path)) return .video;
    return null;
}

fn isImagePath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".svg") or
        endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".png") or
        endsWithIgnoreCase(path, ".gif") or
        endsWithIgnoreCase(path, ".webp") or
        endsWithIgnoreCase(path, ".bmp") or
        endsWithIgnoreCase(path, ".ico");
}

fn isVideoPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".mp4") or
        endsWithIgnoreCase(path, ".m4v") or
        endsWithIgnoreCase(path, ".webm") or
        endsWithIgnoreCase(path, ".ogv") or
        endsWithIgnoreCase(path, ".ogg") or
        endsWithIgnoreCase(path, ".mov");
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (endsWithIgnoreCase(path, ".svg")) return "image/svg+xml";
    if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (endsWithIgnoreCase(path, ".png")) return "image/png";
    if (endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (endsWithIgnoreCase(path, ".webp")) return "image/webp";
    if (endsWithIgnoreCase(path, ".bmp")) return "image/bmp";
    if (endsWithIgnoreCase(path, ".ico")) return "image/x-icon";
    if (endsWithIgnoreCase(path, ".mp4") or endsWithIgnoreCase(path, ".m4v")) return "video/mp4";
    if (endsWithIgnoreCase(path, ".webm")) return "video/webm";
    if (endsWithIgnoreCase(path, ".ogv") or endsWithIgnoreCase(path, ".ogg")) return "video/ogg";
    if (endsWithIgnoreCase(path, ".mov")) return "video/quicktime";
    return "application/octet-stream";
}

fn languageForPath(path: []const u8) []const u8 {
    return source_stats.languageForPath(path);
}

fn normalizedPathOwned(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (out.items.len != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecode(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecode(allocator, raw_value);
    }
    return null;
}

fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecode(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecode(allocator, raw_value);
    }
    return null;
}

fn percentDecode(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidUrlEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidUrlEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidUrlEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn appendSize(buf: *std.ArrayList(u8), allocator: Allocator, raw: []const u8) !void {
    const size = std.fmt.parseUnsigned(usize, raw, 10) catch {
        try appendTemplate(buf, allocator, "{raw}", .{ .raw = raw });
        return;
    };
    try appendByteSize(buf, allocator, size);
}

fn appendByteSize(buf: *std.ArrayList(u8), allocator: Allocator, size: usize) !void {
    if (size >= 1024 * 1024) {
        const whole = size / (1024 * 1024);
        const tenth = (size % (1024 * 1024)) * 10 / (1024 * 1024);
        try appendFmt(buf, allocator, "{d}.{d} MB", .{ whole, tenth });
    } else if (size >= 1024) {
        const whole = size / 1024;
        const tenth = (size % 1024) * 10 / 1024;
        try appendFmt(buf, allocator, "{d}.{d} KB", .{ whole, tenth });
    } else {
        try appendFmt(buf, allocator, "{d} B", .{size});
    }
}

fn containsNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

fn trimOwned(allocator: Allocator, raw: []u8) ![]u8 {
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn freeTreeEntries(allocator: Allocator, entries: []TreeEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn freeTreeNavEntries(allocator: Allocator, entries: []TreeNavEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn freeBranchRefs(allocator: Allocator, branches: []BranchRef) void {
    for (branches) |branch| branch.deinit(allocator);
    allocator.free(branches);
}

fn freeWorktreeRefs(allocator: Allocator, worktrees: []WorktreeRef) void {
    for (worktrees) |worktree| worktree.deinit(allocator);
    allocator.free(worktrees);
}

fn freeBlameLines(allocator: Allocator, lines: []BlameLine) void {
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    return gitMaybeAt(allocator, repo.root, git_args, max_output_bytes);
}

fn gitMaybeAt(allocator: Allocator, root: []const u8, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
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

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "web explorer normalizes paths" {
    const path = try normalizedPathOwned(std.testing.allocator, "/src//main.zig/");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("src/main.zig", path);
    try std.testing.expectError(error.InvalidPath, normalizedPathOwned(std.testing.allocator, "../secret"));
}

test "web explorer encodes code links" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendHref(&buf, std.testing.allocator, codeHref("feature/test", "src/a b.zig"));
    try std.testing.expectEqualStrings("/code?ref=feature/test&amp;path=src/a%20b.zig", buf.items);
}

test "web explorer maps file paths to highlight languages" {
    try std.testing.expectEqualStrings("zig", languageForPath("src/main.zig"));
    try std.testing.expectEqualStrings("markdown", languageForPath("README.md"));
    try std.testing.expectEqualStrings("solidity", languageForPath("contracts/Token.sol"));
    try std.testing.expectEqualStrings("tla", languageForPath("spec/Consensus.tla"));
    try std.testing.expectEqualStrings("plaintext", languageForPath("LICENSE"));
}

test "web explorer maps supported file paths to devicon classes" {
    try std.testing.expectEqualStrings("devicon-git-plain", deviconClassForPath(".gitignore", "blob").?);
    try std.testing.expectEqualStrings("devicon-docker-plain", deviconClassForPath("Dockerfile", "blob").?);
    try std.testing.expectEqualStrings("devicon-docker-plain", deviconClassForPath("docker/Dockerfile.web", "blob").?);
    try std.testing.expectEqualStrings("devicon-nixos-plain", deviconClassForPath("flake.nix", "blob").?);
    try std.testing.expectEqualStrings("devicon-nixos-plain", deviconClassForPath("flake.lock", "blob").?);
    try std.testing.expectEqualStrings("devicon-zig-original", deviconClassForPath("src/main.zig", "blob").?);
    try std.testing.expectEqualStrings("devicon-zig-original", deviconClassForPath("build.zig.zon", "blob").?);
    try std.testing.expectEqualStrings("devicon-html5-plain", deviconClassForPath("index.html", "blob").?);
    try std.testing.expectEqualStrings("devicon-markdown-original", deviconClassForPath("README.md", "blob").?);
    try std.testing.expectEqualStrings("devicon-npm-plain", deviconClassForPath("package.json", "blob").?);
    try std.testing.expectEqualStrings("devicon-githubactions-plain", deviconClassForPath(".github/workflows/test.yml", "blob").?);
    try std.testing.expectEqualStrings("devicon-terraform-plain", deviconClassForPath("main.tf", "blob").?);
    try std.testing.expectEqualStrings("devicon-vuejs-plain", deviconClassForPath("src/App.vue", "blob").?);
    try std.testing.expectEqualStrings("devicon-prisma-original", deviconClassForPath("schema.prisma", "blob").?);
    try std.testing.expectEqual(@as(?[]const u8, null), deviconClassForPath("assets/logo.svg", "blob"));
    try std.testing.expectEqual(@as(?[]const u8, null), deviconClassForPath("src", "tree"));
}

test "web explorer sorts paths as dot dirs dirs dot files files" {
    const SortProbe = struct {
        path: []const u8,
        kind: []const u8,
    };

    var entries = [_]SortProbe{
        .{ .path = "README.md", .kind = "blob" },
        .{ .path = "src/main.zig", .kind = "blob" },
        .{ .path = ".env", .kind = "blob" },
        .{ .path = "src", .kind = "tree" },
        .{ .path = ".github/workflows", .kind = "tree" },
        .{ .path = "src/lib", .kind = "tree" },
        .{ .path = "src/.env", .kind = "blob" },
        .{ .path = ".github", .kind = "tree" },
        .{ .path = "src/.config", .kind = "tree" },
        .{ .path = "src/build.zig", .kind = "blob" },
    };
    std.mem.sort(SortProbe, &entries, {}, struct {
        fn lessThan(_: void, a: SortProbe, b: SortProbe) bool {
            return pathLessThan(
                a.path,
                std.mem.eql(u8, a.kind, "tree"),
                b.path,
                std.mem.eql(u8, b.kind, "tree"),
            );
        }
    }.lessThan);

    const expected = [_][]const u8{
        ".github",
        ".github/workflows",
        "src",
        "src/.config",
        "src/lib",
        "src/.env",
        "src/build.zig",
        "src/main.zig",
        ".env",
        "README.md",
    };
    for (expected, 0..) |path, i| {
        try std.testing.expectEqualStrings(path, entries[i].path);
    }
}

test "web explorer parses git log commit headers" {
    const parsed = parseLogCommitHeader("\x1e0123456789abcdef\tfix: path\twith tab\t2 hours ago").?;
    try std.testing.expectEqualStrings("0123456789abcdef", parsed.full_hash);
    try std.testing.expectEqualStrings("fix: path\twith tab", parsed.subject);
    try std.testing.expectEqualStrings("2 hours ago", parsed.relative);
    try std.testing.expect(parseLogCommitHeader("src/main.zig") == null);
}

test "web explorer labels branch dropdown options by scope" {
    const worktree_name = try std.testing.allocator.dupe(u8, "working tree");
    defer std.testing.allocator.free(worktree_name);
    const local_name = try std.testing.allocator.dupe(u8, "main");
    defer std.testing.allocator.free(local_name);
    const remote_name = try std.testing.allocator.dupe(u8, "origin/main");
    defer std.testing.allocator.free(remote_name);
    const branches = [_]BranchRef{
        .{ .name = worktree_name, .scope = .unstaged },
        .{ .name = local_name, .scope = .local },
        .{ .name = remote_name, .scope = .remote },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendBranchOptions(&buf, std.testing.allocator, &branches, &.{}, "main");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">working tree</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">working tree (working tree)</option>") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">main (local)</option>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">origin/main (remote)</option>") != null);
}

test "web explorer parses remote-tracking branch names" {
    try std.testing.expectEqualStrings("main", remoteTrackingBranchName("refs/remotes/origin/main").?);
    try std.testing.expectEqualStrings("fix/sync-bootstrap-flow", remoteTrackingBranchName("refs/remotes/origin/fix/sync-bootstrap-flow").?);
    try std.testing.expect(remoteTrackingBranchName("refs/heads/main") == null);
    try std.testing.expect(remoteTrackingBranchName("refs/remotes/origin") == null);
}

test "web explorer parses code sync modes" {
    try std.testing.expectEqual(CodeSyncMode.exchange, parseCodeSyncMode("exchange").?);
    try std.testing.expectEqual(CodeSyncMode.exchange, parseCodeSyncMode("both").?);
    try std.testing.expectEqual(CodeSyncMode.exchange, parseCodeSyncMode("ok").?);
    try std.testing.expectEqual(CodeSyncMode.import, parseCodeSyncMode("import").?);
    try std.testing.expectEqual(CodeSyncMode.import, parseCodeSyncMode("pull").?);
    try std.testing.expectEqual(CodeSyncMode.publish, parseCodeSyncMode("publish").?);
    try std.testing.expectEqual(CodeSyncMode.publish, parseCodeSyncMode("push").?);
    try std.testing.expect(parseCodeSyncMode("clone") == null);
}

test "web explorer parses prompt-style repository status" {
    var status = RootGitStatus{};

    parseRootGitStatusV2(&status,
        \\# branch.oid 0123456789abcdef
        \\# branch.head main
        \\# branch.upstream origin/main
        \\# branch.ab +2 -1
        \\1 M. N... 100644 100644 100644 a b cli/src/web.zig
        \\1 .M N... 100644 100644 100644 a b README.md
        \\? scratch.txt
        \\u UU N... 100644 100644 100644 100644 a b c d conflict.txt
        \\
    );
    parseRootDiffNumstat(&status, "24\t16\tcli/src/web.zig\n-\t-\tassets/logo.png\n");

    try std.testing.expectEqual(@as(usize, 1), status.staged_paths);
    try std.testing.expectEqual(@as(usize, 1), status.unstaged_paths);
    try std.testing.expectEqual(@as(usize, 1), status.untracked_paths);
    try std.testing.expectEqual(@as(usize, 1), status.conflict_paths);
    try std.testing.expectEqual(@as(u64, 24), status.lines_added);
    try std.testing.expectEqual(@as(u64, 16), status.lines_removed);
}

test "web explorer only falls back to remote tracking for branch shorthands" {
    try std.testing.expect(isBranchShorthand("fix/sync-bootstrap-flow"));
    try std.testing.expect(isBranchShorthand("dev/hewm/markdown"));
    try std.testing.expect(!isBranchShorthand("origin/fix/sync-bootstrap-flow"));
    try std.testing.expect(!isBranchShorthand("refs/heads/fix/sync-bootstrap-flow"));
    try std.testing.expect(!isBranchShorthand("fix/sync-bootstrap-flow^{commit}"));
    try std.testing.expect(!isBranchShorthand("fix/../sync-bootstrap-flow"));
}

test "web explorer maps changed paths to direct children" {
    try std.testing.expectEqualStrings("src", directChildName("", "src/main.zig").?);
    try std.testing.expectEqualStrings("main.zig", directChildName("src", "src/main.zig").?);
    try std.testing.expectEqualStrings("web", directChildName("cli/src", "cli/src/web/explorer.zig").?);
    try std.testing.expectEqualStrings("code.js", directChildName("cli/src/web", normalizeLogPathRecord("\ncli/src/web/code.js")).?);
    try std.testing.expect(directChildName("src", "src") == null);
    try std.testing.expect(directChildName("src", "src-old/main.zig") == null);
}

test "web explorer maps media paths to preview metadata" {
    try std.testing.expectEqual(@as(?MediaKind, .image), mediaKindForPath("assets/logo.SVG"));
    try std.testing.expectEqual(@as(?MediaKind, .image), mediaKindForPath("photo.jpeg"));
    try std.testing.expectEqual(@as(?MediaKind, .video), mediaKindForPath("demo.webm"));
    try std.testing.expectEqualStrings("image/svg+xml", contentTypeForPath("assets/logo.SVG"));
    try std.testing.expectEqualStrings("image/jpeg", contentTypeForPath("photo.jpeg"));
    try std.testing.expectEqualStrings("image/gif", contentTypeForPath("animation.gif"));
    try std.testing.expectEqualStrings("image/webp", contentTypeForPath("image.webp"));
    try std.testing.expectEqualStrings("video/mp4", contentTypeForPath("demo.m4v"));
}

test "web explorer counts physical lines" {
    try std.testing.expectEqual(@as(usize, 0), physicalLineCount(""));
    try std.testing.expectEqual(@as(usize, 1), physicalLineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), physicalLineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), physicalLineCount("one\ntwo"));
}

test "web explorer parses blame porcelain" {
    const raw =
        "0123456789abcdef0123456789abcdef01234567 4 7 1\n" ++
        "author Alice Example\n" ++
        "author-time 1700000000\n" ++
        "author-tz +0200\n" ++
        "summary Touch code\n" ++
        "filename src/main.zig\n" ++
        "\tconst x = 1;\n";
    const lines = try parseBlamePorcelain(std.testing.allocator, raw);
    defer freeBlameLines(std.testing.allocator, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", lines[0].commit);
    try std.testing.expectEqualStrings("01234567", lines[0].short_hash);
    try std.testing.expectEqualStrings("Alice Example", lines[0].author);
    try std.testing.expectEqualStrings("2023-11-15", lines[0].date);
    try std.testing.expectEqual(@as(?i64, 1700000000), lines[0].author_timestamp);
    try std.testing.expectEqual(@as(usize, 7), lines[0].line_no);
    try std.testing.expectEqualStrings("const x = 1;", lines[0].content);
}

test "web explorer maps blame timestamps to age classes" {
    const day = 24 * 60 * 60;
    try std.testing.expectEqualStrings("age-unknown", blameAgeClass(null, 10_000));
    try std.testing.expectEqualStrings("age-now", blameAgeClass(10_000, 10_000));
    try std.testing.expectEqualStrings("age-week", blameAgeClass(10_000 - 3 * day, 10_000));
    try std.testing.expectEqualStrings("age-month", blameAgeClass(10_000 - 20 * day, 10_000));
    try std.testing.expectEqualStrings("age-quarter", blameAgeClass(10_000 - 60 * day, 10_000));
    try std.testing.expectEqualStrings("age-year", blameAgeClass(10_000 - 200 * day, 10_000));
    try std.testing.expectEqualStrings("age-old", blameAgeClass(10_000 - 700 * day, 10_000));
}

test "web explorer formats blame relative dates" {
    const allocator = std.testing.allocator;
    const now: i64 = 2_000_000;
    const minute = 60;
    const hour = 60 * minute;
    const day = 24 * hour;

    const unknown = try relativeTimeOwned(allocator, null, now);
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("unknown", unknown);

    const current = try relativeTimeOwned(allocator, now - 12, now);
    defer allocator.free(current);
    try std.testing.expectEqualStrings("now", current);

    const minutes = try relativeTimeOwned(allocator, now - 5 * minute, now);
    defer allocator.free(minutes);
    try std.testing.expectEqualStrings("5 minutes ago", minutes);

    const hours = try relativeTimeOwned(allocator, now - 3 * hour, now);
    defer allocator.free(hours);
    try std.testing.expectEqualStrings("3 hours ago", hours);

    const days = try relativeTimeOwned(allocator, now - 9 * day, now);
    defer allocator.free(days);
    try std.testing.expectEqualStrings("9 days ago", days);

    const months = try relativeTimeOwned(allocator, now - 24 * 30 * day, now);
    defer allocator.free(months);
    try std.testing.expectEqualStrings("24 months ago", months);

    const years = try relativeTimeOwned(allocator, now - 25 * 30 * day, now);
    defer allocator.free(years);
    try std.testing.expectEqualStrings("2 years ago", years);
}
