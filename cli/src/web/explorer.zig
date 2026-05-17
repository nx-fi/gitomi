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
const gitChecked = git.gitChecked;
const sendPlainResponse = shared.sendPlainResponse;
const sendRedirect = shared.sendRedirect;
const sendResponse = shared.sendResponse;

const max_blob_display_bytes = 512 * 1024;
const max_raw_blob_bytes = 128 * 1024 * 1024;
const root_partial_priority_repository = 30;
const root_partial_priority_branch = 30;
const root_partial_priority_commit_count = 35;
const root_partial_priority_stats = 40;
const root_partial_priority_search = 50;
const root_partial_timeout_fast_ms = 10_000;
const root_partial_timeout_git_ms = 12_000;
const root_partial_timeout_stats_ms = 20_000;
const root_readme_candidates = [_][]const u8{ "README.md", "README", "Readme.md", "readme.md" };
const root_license_candidates = [_][]const u8{ "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "COPYING.txt" };
const root_agents_candidates = [_][]const u8{"AGENTS.md"};

const explorer_model = @import("explorer/model.zig");
const explorer_data = @import("explorer/data.zig");
const file_info = @import("explorer/file_info.zig");

pub const RawBlob = explorer_model.RawBlob;
const MediaKind = explorer_model.MediaKind;
const TreeEntry = explorer_model.TreeEntry;
const TreeNavEntry = explorer_model.TreeNavEntry;
const BranchRef = explorer_model.BranchRef;
const WorktreeRef = explorer_model.WorktreeRef;
const BranchScope = explorer_model.BranchScope;
const TreeEntryCommit = explorer_model.TreeEntryCommit;
const ChangeState = explorer_model.ChangeState;
const CommitSummary = explorer_model.CommitSummary;
const BlameLine = explorer_model.BlameLine;
const BlameHeader = explorer_model.BlameHeader;
const SlocCounts = explorer_model.SlocCounts;
const RootEntryCounts = explorer_model.RootEntryCounts;
const RepositoryOperationState = explorer_model.RepositoryOperationState;
const RootGitStatus = explorer_model.RootGitStatus;
const BranchSyncStatus = explorer_model.BranchSyncStatus;
const RootMarkdownDoc = explorer_model.RootMarkdownDoc;
const PathQuery = explorer_model.PathQuery;
const CodeSyncMode = explorer_model.CodeSyncMode;
const CodeSyncFlashKind = explorer_model.CodeSyncFlashKind;
const CodeSyncFlash = explorer_model.CodeSyncFlash;
const unstaged_ref = explorer_data.unstaged_ref;
const worktree_ref_prefix = explorer_data.worktree_ref_prefix;
const root_about_fallback = "Browse this repository's files, documentation, and Gitomi records from the local checkout.";

const loadRootGitStatus = explorer_data.loadRootGitStatus;
const loadBranchSyncStatus = explorer_data.loadBranchSyncStatus;
const parseRootGitStatusV2 = explorer_data.parseRootGitStatusV2;
const parseRootDiffNumstat = explorer_data.parseRootDiffNumstat;
const countNonEmptyLines = explorer_data.countNonEmptyLines;
const loadRootEntryCounts = explorer_data.loadRootEntryCounts;
const markdownSummaryOwned = explorer_data.markdownSummaryOwned;
const appendRepositoryMarkdown = explorer_data.appendRepositoryMarkdown;
const physicalLineCount = explorer_data.physicalLineCount;
const loadTreeEntries = explorer_data.loadTreeEntries;
const loadBlameLines = explorer_data.loadBlameLines;
const loadCommitSummary = explorer_data.loadCommitSummary;
const loadCommitCount = explorer_data.loadCommitCount;
const loadRefCount = explorer_data.loadRefCount;
const loadTreeNavEntries = explorer_data.loadTreeNavEntries;
const loadWorktreeRefs = explorer_data.loadWorktreeRefs;
const loadBranchRefs = explorer_data.loadBranchRefs;
const branchScopeLabel = explorer_data.branchScopeLabel;
const changeStateClass = explorer_data.changeStateClass;
const countRealBranches = explorer_data.countRealBranches;
const pathLessThan = explorer_data.pathLessThan;
const parseLogCommitHeader = explorer_data.parseLogCommitHeader;
const normalizeLogPathRecord = explorer_data.normalizeLogPathRecord;
const directChildName = explorer_data.directChildName;
const parseBlamePorcelain = explorer_data.parseBlamePorcelain;
const freeBlameLines = explorer_data.freeBlameLines;
const blameAgeClass = explorer_data.blameAgeClass;
const relativeTimeOwned = explorer_data.relativeTimeOwned;
const remoteTrackingBranchName = explorer_data.remoteTrackingBranchName;
const isBranchShorthand = explorer_data.isBranchShorthand;
const targetPathQueryOwned = explorer_data.targetPathQueryOwned;
const targetViewOwned = explorer_data.targetViewOwned;
const childPath = explorer_data.childPath;
const parentPath = explorer_data.parentPath;
const baseName = explorer_data.baseName;
const pathDepth = explorer_data.pathDepth;
const isAncestorPath = explorer_data.isAncestorPath;
const isAncestorOrSelfPath = explorer_data.isAncestorOrSelfPath;
const treeEntryInitiallyVisible = explorer_data.treeEntryInitiallyVisible;
const browseObjectType = explorer_data.browseObjectType;
const browseBlobSize = explorer_data.browseBlobSize;
const loadBlobBytes = explorer_data.loadBlobBytes;
const defaultRef = explorer_data.defaultRef;
const targetRefOwned = explorer_data.targetRefOwned;
const resolveBrowsableRefOwned = explorer_data.resolveBrowsableRefOwned;
const isFilesystemRef = explorer_data.isFilesystemRef;
const freeTreeEntries = explorer_data.freeTreeEntries;
const freeTreeNavEntries = explorer_data.freeTreeNavEntries;
const freeBranchRefs = explorer_data.freeBranchRefs;
const freeWorktreeRefs = explorer_data.freeWorktreeRefs;

const appendFileIcon = file_info.appendFileIcon;
const deviconClassForPath = file_info.deviconClassForPath;
const fileIconClass = file_info.fileIconClass;
const findReadme = file_info.findReadme;
const findLicense = file_info.findLicense;
const findAgents = file_info.findAgents;
const licenseLabel = file_info.licenseLabel;
const isMarkdownPath = file_info.isMarkdownPath;
const isPdfPath = file_info.isPdfPath;
const isSvgPath = file_info.isSvgPath;
const mediaKindForPath = file_info.mediaKindForPath;
const contentTypeForPath = file_info.contentTypeForPath;
const languageForPath = file_info.languageForPath;
const normalizedPathOwned = file_info.normalizedPathOwned;
const queryValueOwned = file_info.queryValueOwned;
const formValueOwned = file_info.formValueOwned;
const percentDecode = file_info.percentDecode;
const appendSize = file_info.appendSize;
const appendByteSize = file_info.appendByteSize;
const containsNul = file_info.containsNul;
const trimOwned = file_info.trimOwned;
const hexValue = file_info.hexValue;
const endsWithIgnoreCase = file_info.endsWithIgnoreCase;

const BlobPreviewKind = enum {
    markdown,
    pdf,
    svg,
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

pub fn renderCodeRootComponent(allocator: Allocator, repo: Repo, target: []const u8, component: []const u8) !?[]u8 {
    const ref = try targetRefOwned(allocator, repo, target);
    defer allocator.free(ref);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (std.mem.eql(u8, component, "about")) {
        try appendRootAboutComponent(&buf, allocator, repo, ref);
    } else if (std.mem.eql(u8, component, "repository")) {
        try appendRootRepositoryComponent(&buf, allocator, repo);
    } else if (std.mem.eql(u8, component, "branch")) {
        try appendRootBranchComponent(&buf, allocator, repo, ref);
    } else if (std.mem.eql(u8, component, "stats")) {
        try appendRootStatsComponent(&buf, allocator, repo);
    } else if (std.mem.eql(u8, component, "docs")) {
        try appendRootDocsComponent(&buf, allocator, repo, ref);
    } else if (std.mem.eql(u8, component, "search")) {
        try appendRootSearchComponent(&buf, allocator, repo, ref);
    } else if (std.mem.eql(u8, component, "commit-count")) {
        try appendRootCommitCountComponent(&buf, allocator, repo, ref);
    } else {
        return null;
    }

    return try buf.toOwnedSlice(allocator);
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
        try sendCodeSyncFailure(allocator, repo, stream, ref_owned, mode, err);
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
        .prune_remote => {
            const pruned = try gitChecked(allocator, &.{ "fetch", "--prune", "origin" });
            allocator.free(pruned);
        },
    }
}

fn sendCodeSyncFailure(
    allocator: Allocator,
    repo: Repo,
    stream: std.net.Stream,
    ref: []const u8,
    mode: CodeSyncMode,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}: {s}.", .{ codeSyncFailurePrefix(mode), @errorName(err) });
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
    if (std.mem.eql(u8, value, "prune") or std.mem.eql(u8, value, "prune-remote") or std.mem.eql(u8, value, "prune_remote")) return .prune_remote;
    return null;
}

fn codeSyncModeQueryValue(mode: CodeSyncMode) []const u8 {
    return switch (mode) {
        .exchange => "exchange",
        .import => "import",
        .publish => "publish",
        .prune_remote => "prune",
    };
}

fn codeSyncSuccessMessage(mode: CodeSyncMode) []const u8 {
    return switch (mode) {
        .exchange => "Gitomi refs exchanged with origin.",
        .import => "Remote Gitomi refs imported from origin.",
        .publish => "Local Gitomi refs published to origin.",
        .prune_remote => "Deleted remote-tracking branches pruned from origin.",
    };
}

fn codeSyncFailurePrefix(mode: CodeSyncMode) []const u8 {
    return switch (mode) {
        .exchange => "Sync failed",
        .import => "Import failed",
        .publish => "Publish failed",
        .prune_remote => "Remote branch prune failed",
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
    var reference_resolver = shared.InternalReferenceResolver.init(allocator, repo);
    defer reference_resolver.deinit();

    try appendShellStart(&buf, allocator, repo, "Blame", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    try appendCodeLayoutStart(&buf, allocator, repo, ref, path);

    try appendCodePanelStart(&buf, allocator, repo, ref, path);
    try appendCodeBlameSwitch(&buf, allocator, ref, path, true);
    try appendFileActionsSpacer(&buf, allocator);
    try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
    try appendCodePanelToolbarEnd(&buf, allocator);
    try appendCommitBar(&buf, allocator, &reference_resolver, summary_opt);
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
    const content_type = if (mediaKindForPath(path) != null or isPdfPath(path))
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
    var reference_resolver = shared.InternalReferenceResolver.init(allocator, repo);
    defer reference_resolver.deinit();

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

            try appendRootPageGridStart(&buf, allocator);
            try appendRootCodeToolbar(&buf, allocator, ref, branches, worktrees, branch_count, tag_count, worktree_count);
            if (sync_flash) |flash| try appendCodeSyncFlash(&buf, allocator, flash);
            try appendRootCodePanelStart(&buf, allocator);
            try appendRootCommitBar(&buf, allocator, ref, summary_opt, null);
            try appendRootTreeListing(&buf, allocator, ref, entries);
            try appendCodePanelEnd(&buf, allocator);
        } else {
            try appendCodePanelStart(&buf, allocator, repo, ref, path);
            try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
            try appendCodePanelToolbarEnd(&buf, allocator);
            try appendCommitBar(&buf, allocator, &reference_resolver, summary_opt);
            try appendCodePanelHeadEnd(&buf, allocator);
            try appendTreeListing(&buf, allocator, &reference_resolver, ref, path, entries);
            try appendCodePanelEnd(&buf, allocator);
        }

        if (is_root) {
            try appendRootDocsComponent(&buf, allocator, repo, ref);
            try appendRootPageMainEnd(&buf, allocator);
            try appendRootSidebar(&buf, allocator, repo, ref);
            try appendRootPageGridEnd(&buf, allocator);
        } else {
            try appendReadmePreview(&buf, allocator, repo, ref, path, entries);
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
    var reference_resolver = shared.InternalReferenceResolver.init(allocator, repo);
    defer reference_resolver.deinit();

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    const size = try browseBlobSize(allocator, repo, ref, path);
    const media_kind = mediaKindForPath(path);
    const preview_kind = previewKindForPath(path);
    const source_selected = if (preview_kind) |kind| kind != .pdf and sourceViewSelected(view) else true;
    const render_markdown = if (preview_kind) |kind| kind == .markdown and !source_selected else false;
    const render_svg_preview = if (preview_kind) |kind| kind == .svg and !source_selected else false;
    const render_pdf_preview = if (preview_kind) |kind| kind == .pdf else false;
    const can_preview_media = media_kind != null and (size == null or size.? <= max_raw_blob_bytes);
    const can_preview_pdf = render_pdf_preview and (size == null or size.? <= max_raw_blob_bytes);
    const can_display_source = size != null and size.? <= max_blob_display_bytes;
    const should_load_content = can_display_source and !render_pdf_preview and (media_kind == null or preview_kind != null or !can_preview_media);
    const content = if (should_load_content)
        try loadBlobBytes(allocator, repo, ref, path, max_blob_display_bytes + 1)
    else
        null;
    defer if (content) |bytes| allocator.free(bytes);
    const summary_opt = try loadCommitSummary(allocator, repo, ref, path);
    defer if (summary_opt) |summary| summary.deinit(allocator);
    const text_content = if (content) |bytes| if (containsNul(bytes)) null else bytes else null;
    const sloc_counts = if (text_content) |bytes| source_stats.countBlob(path, bytes) else null;
    const show_symbols_panel = text_content != null and media_kind == null and !render_markdown and !render_pdf_preview and code_symbols.hasProvider(path);
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
    if (preview_kind) |kind| try appendPreviewViewTabs(&buf, allocator, ref, path, kind, source_selected);
    try appendBlobMetrics(&buf, allocator, size, text_content, sloc_counts);
    if (show_symbols_panel) try appendSymbolsToggleButton(&buf, allocator);
    if (show_markdown_outline) try appendMarkdownOutlineToggleButton(&buf, allocator);
    try appendCodeActionLink(&buf, allocator, "Raw", rawHref(ref, path), "icon-file-code");
    if (text_content != null) try appendCopyButton(&buf, allocator, ref, path);
    try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
    try appendCodePanelToolbarEnd(&buf, allocator);

    try appendCommitBar(&buf, allocator, &reference_resolver, summary_opt);
    try appendCodePanelHeadEnd(&buf, allocator);
    const permalink_ref = if (summary_opt) |summary| summary.full_hash else ref;
    try appendBlobContent(&buf, allocator, ref, permalink_ref, path, preview_kind, media_kind, can_preview_media, can_preview_pdf, content, render_markdown, render_svg_preview, render_pdf_preview);

    try appendCodePanelEnd(&buf, allocator);
    try appendCodeLayoutEndWithPanels(&buf, allocator, show_symbols_panel, symbol_items, show_markdown_outline);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn previewKindForPath(path: []const u8) ?BlobPreviewKind {
    if (isMarkdownPath(path)) return .markdown;
    if (isPdfPath(path)) return .pdf;
    if (isSvgPath(path)) return .svg;
    return null;
}

fn sourceViewSelected(view: []const u8) bool {
    return std.mem.eql(u8, view, "raw") or std.mem.eql(u8, view, "source");
}

fn appendBlobContent(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    permalink_ref: []const u8,
    path: []const u8,
    preview_kind: ?BlobPreviewKind,
    media_kind: ?MediaKind,
    can_preview_media: bool,
    can_preview_pdf: bool,
    content: ?[]const u8,
    render_markdown: bool,
    render_svg_preview: bool,
    render_pdf_preview: bool,
) !void {
    if (render_pdf_preview) {
        if (can_preview_pdf) {
            try appendPdfPreview(buf, allocator, ref, path);
        } else {
            try appendEmptyState(buf, allocator, "File too large to preview.", "Use Git locally to inspect this PDF.");
        }
        return;
    }

    if (media_kind) |kind| {
        if (preview_kind != null and !render_svg_preview) {
            // SVG can be rendered as image preview or read as source.
        } else if (can_preview_media) {
            try appendMediaPreview(buf, allocator, ref, path, kind);
            return;
        } else {
            try appendEmptyState(buf, allocator, "File too large to preview.", "Use Git locally to inspect this media blob.");
            return;
        }
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

fn appendPreviewViewTabs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
    kind: BlobPreviewKind,
    source_selected: bool,
) !void {
    try appendTemplate(buf, allocator,
        \\<nav class="view-tabs" aria-label="{aria_label}"><a{preview_class} href="{preview_href}">Preview</a><a{source_class} href="{source_href}">{source_label}</a></nav>
    , .{
        .aria_label = switch (kind) {
            .markdown => "Markdown view",
            .pdf => "PDF view",
            .svg => "SVG view",
        },
        .preview_class = shared.classAttr("", &.{shared.class("active", !source_selected)}),
        .preview_href = codeHrefWithView(ref, path, "preview"),
        .source_class = shared.classAttr("", &.{shared.class("active", source_selected)}),
        .source_href = switch (kind) {
            .markdown, .svg => codeHrefWithView(ref, path, "raw"),
            .pdf => rawHref(ref, path),
        },
        .source_label = switch (kind) {
            .markdown => "Raw",
            .pdf => "Raw",
            .svg => "Source",
        },
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
    reference_resolver: *shared.InternalReferenceResolver,
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
        try appendTreeEntryRow(buf, allocator, reference_resolver, ref, path, entry);
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
        \\    <a class="root-ref-link" href="/refs?type=branches"><span class="button-icon icon-branch" aria-hidden="true"></span><strong>{branch_count}</strong> {branch_label}</a>
        \\    <a class="root-ref-link" href="/refs?type=tags"><span class="button-icon icon-tag" aria-hidden="true"></span><strong>{tag_count}</strong> {tag_label}</a>
        \\    <a class="root-ref-link" href="/worktrees"><span class="button-icon icon-worktree" aria-hidden="true"></span><strong>{worktree_count}</strong> {worktree_label}</a>
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
    try appendRootSearchIndexSlot(buf, allocator, ref);
    try appendTemplate(buf, allocator,
        \\    </div>
        \\    <details class="root-action-menu root-sync-menu" data-popover-menu>
        \\      <summary class="button primary root-menu-button" title="Sync Gitomi refs with origin"><span class="button-icon icon-sync" aria-hidden="true"></span>Sync refs<span class="root-caret" aria-hidden="true"></span></summary>
        \\      <form class="root-action-popover root-sync-popover" method="post" action="/code/sync" role="menu">
        \\        <input type="hidden" name="ref" value="{ref}">
        \\        <button type="submit" name="action" value="exchange" role="menuitem">Exchange Gitomi refs</button>
        \\        <button type="submit" name="action" value="import" role="menuitem">Import remote Gitomi refs</button>
        \\        <button type="submit" name="action" value="publish" role="menuitem">Publish local Gitomi refs</button>
        \\        <button type="submit" name="action" value="prune" role="menuitem">Prune deleted remote branches</button>
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

fn appendRootSearchIndexSlot(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\      <div hidden data-root-partial-deferred="/code/root/search?ref=
    , .{});
    try shared.appendUrlEncoded(buf, allocator, ref);
    try appendTemplate(buf, allocator,
        \\" data-root-partial-label="File search index" data-root-partial-priority="{priority}" data-root-partial-timeout-ms="{timeout_ms}" data-root-partial-silent></div>
    , .{ .priority = root_partial_priority_search, .timeout_ms = root_partial_timeout_stats_ms });
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
        const commit_href = commitHref(summary.full_hash);
        try appendTemplate(buf, allocator,
            \\<div class="root-commit-main"><span class="root-commit-author">{author}</span><a class="root-commit-message" href="{href}" title="{subject}">{subject}</a></div>
            \\<div class="root-commit-meta"><a class="root-commit-hash" href="{href}">{hash}</a><span>{relative}</span></div>
        , .{
            .author = summary.author,
            .href = commit_href,
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
        try appendRootCommitCountLink(buf, allocator, ref, count);
    } else {
        try appendRootCommitCountSlot(buf, allocator, ref);
    }
    try appendTemplate(buf, allocator, "</div>", .{});
}

fn appendRootCommitCountSlot(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<span class="root-partial-slot root-commit-count-slot"
    , .{});
    try appendRootPartialAttrs(buf, allocator, ref, "commit-count", "Commit count", root_partial_priority_commit_count, root_partial_timeout_fast_ms);
    try appendTemplate(buf, allocator,
        \\ data-root-partial-silent></span>
    , .{});
}

fn appendRootCommitCountLink(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8, count: usize) !void {
    try appendTemplate(buf, allocator,
        \\<a class="root-commit-count" href="{href}"><span class="button-icon icon-history" aria-hidden="true"></span><strong>{count}</strong> {label}</a>
    , .{
        .href = commitsHref(ref, ""),
        .count = shared.groupedUnsigned(@intCast(count)),
        .label = if (count == 1) "Commit" else "Commits",
    });
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

fn appendRootTreeEntryRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    entry: TreeEntry,
) !void {
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
            const commit_href = commitHref(commit.full_hash);
            try appendTemplate(buf, allocator,
                \\<a class="root-file-commit" href="{href}" title="{subject}">{subject}</a><span class="root-file-time">{relative}</span>
            , .{
                .href = commit_href,
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

fn appendTreeEntryRow(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    reference_resolver: *shared.InternalReferenceResolver,
    ref: []const u8,
    parent: []const u8,
    entry: TreeEntry,
) !void {
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
    try appendTreeEntryCommit(buf, allocator, reference_resolver, entry.last_commit);
    try appendTemplate(buf, allocator,
        \\<span><code>{mode}</code></span><span class="file-size">
    , .{ .mode = entry.mode });
    if (std.mem.eql(u8, entry.kind, "blob")) {
        try appendSize(buf, allocator, entry.size);
    }
    try appendTemplate(buf, allocator, "</span></div>", .{});
}

fn appendTreeEntryCommit(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    reference_resolver: *shared.InternalReferenceResolver,
    commit_opt: ?TreeEntryCommit,
) !void {
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
            const commit_href = commitHref(commit.full_hash);
            try appendTemplate(buf, allocator,
                \\<span class="file-commit" title="{subject}">
            , .{ .subject = commit.subject });
            try shared.appendInternalReferenceLinkedTextWithDefaultHref(buf, allocator, reference_resolver, commit.subject, commit_href);
            try appendTemplate(buf, allocator, "</span>", .{});
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

fn appendCommitBar(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    reference_resolver: *shared.InternalReferenceResolver,
    summary_opt: ?CommitSummary,
) !void {
    try appendTemplate(buf, allocator, "<div class=\"commit-bar\">", .{});
    if (summary_opt) |summary| {
        try appendTemplate(buf, allocator,
            \\<a class="commit-hash" href="{href}"><code>{hash}</code></a><strong><span class="commit-bar-subject" title="{subject}">
        , .{
            .href = commitHref(summary.full_hash),
            .hash = summary.hash,
            .subject = summary.subject,
        });
        try shared.appendInternalReferenceLinkedTextWithDefaultHref(buf, allocator, reference_resolver, summary.subject, commitHref(summary.full_hash));
        try appendTemplate(buf, allocator,
            \\</span></strong><span>{relative}</span>
        , .{
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

fn appendPdfPreview(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    path: []const u8,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="pdf-preview" data-pdf-preview data-pdf-url="{href}">
        \\  <div class="pdf-preview-toolbar"><strong>{name}</strong><span data-pdf-status>Loading PDF...</span></div>
        \\  <div class="pdf-pages" data-pdf-pages></div>
        \\</div>
    , .{
        .href = rawHref(ref, path),
        .name = baseName(path),
    });
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
        const agents_doc_opt = try loadRootAgentsDoc(allocator, repo, ref, entries);
        defer if (agents_doc_opt) |doc| doc.deinit(allocator);

        try appendRootDocsPreview(buf, allocator, ref, readme_doc, license_doc_opt, agents_doc_opt);
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
    agents_doc_opt: ?RootMarkdownDoc,
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
    if (agents_doc_opt) |agents_doc| {
        try appendTemplate(buf, allocator,
            \\      <button class="root-doc-tab" type="button" data-root-doc-tab="agents" aria-selected="false"><span class="button-icon icon-users" aria-hidden="true"></span><span>{label}</span></button>
        , .{ .label = agents_doc.label });
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
    if (agents_doc_opt) |agents_doc| {
        try appendTemplate(buf, allocator,
            \\  <div class="root-doc-panel readme-body markdown-body" data-root-doc-panel="agents" data-markdown-document data-markdown-outline="menu" hidden>
        , .{});
        try appendRepositoryMarkdown(buf, allocator, ref, agents_doc.path, agents_doc.content);
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

fn loadRootAgentsDoc(allocator: Allocator, repo: Repo, ref: []const u8, entries: []const TreeEntry) !?RootMarkdownDoc {
    const agents = findAgents(entries) orelse return null;
    const content = try loadBlobBytes(allocator, repo, ref, agents, max_blob_display_bytes + 1) orelse return null;
    errdefer allocator.free(content);
    if (containsNul(content)) {
        allocator.free(content);
        return null;
    }
    return .{
        .id = "agents",
        .label = "AGENTS.md",
        .path = try allocator.dupe(u8, agents),
        .content = content,
    };
}

fn loadRootReadmeDoc(allocator: Allocator, repo: Repo, ref: []const u8, max_bytes: usize) !?RootMarkdownDoc {
    for (root_readme_candidates) |path| {
        const content = try loadRootDocumentContent(allocator, repo, ref, path, max_bytes) orelse continue;
        errdefer allocator.free(content);
        return .{
            .id = "readme",
            .label = "README",
            .path = try allocator.dupe(u8, path),
            .content = content,
        };
    }
    return null;
}

fn loadRootLicenseDocFast(allocator: Allocator, repo: Repo, ref: []const u8) !?RootMarkdownDoc {
    for (root_license_candidates) |path| {
        const content = try loadRootDocumentContent(allocator, repo, ref, path, max_blob_display_bytes + 1) orelse continue;
        errdefer allocator.free(content);
        return .{
            .id = "license",
            .label = licenseLabel(content),
            .path = try allocator.dupe(u8, path),
            .content = content,
        };
    }
    return null;
}

fn loadRootAgentsDocFast(allocator: Allocator, repo: Repo, ref: []const u8) !?RootMarkdownDoc {
    for (root_agents_candidates) |path| {
        const content = try loadRootDocumentContent(allocator, repo, ref, path, max_blob_display_bytes + 1) orelse continue;
        errdefer allocator.free(content);
        return .{
            .id = "agents",
            .label = "AGENTS.md",
            .path = try allocator.dupe(u8, path),
            .content = content,
        };
    }
    return null;
}

fn loadRootDocumentContent(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, max_bytes: usize) !?[]u8 {
    const content = loadBlobBytes(allocator, repo, ref, path, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const bytes = content orelse return null;
    if (containsNul(bytes)) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
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
) !void {
    try appendTemplate(buf, allocator,
        \\<aside class="root-sidebar" aria-label="Repository details">
        \\  <section class="panel root-sidebar-panel">
    , .{});
    try appendRootAboutComponent(buf, allocator, repo, ref);
    try appendRootSidebarSlot(buf, allocator, ref, "repository", "Repository", "Loading repository details...", root_partial_priority_repository, root_partial_timeout_git_ms);
    try appendRootSidebarSlot(buf, allocator, ref, "branch", "Branch", "Loading branch details...", root_partial_priority_branch, root_partial_timeout_git_ms);
    try appendRootStatsSlot(buf, allocator, ref);
    try appendTemplate(buf, allocator, "</section></aside>", .{});
}

fn appendRootSidebarSlot(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    component: []const u8,
    label: []const u8,
    loading_text: []const u8,
    priority: usize,
    timeout_ms: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-partial-slot"
    , .{});
    try appendRootPartialAttrs(buf, allocator, ref, component, label, priority, timeout_ms);
    try appendTemplate(buf, allocator,
        \\>
        \\  <div class="root-sidebar-section root-sidebar-loading" aria-busy="true">
        \\    <h2>{label}</h2>
        \\    <p class="root-sidebar-empty">{loading_text}</p>
        \\  </div>
        \\</div>
    , .{
        .label = label,
        .loading_text = loading_text,
    });
}

fn appendRootStatsSlot(buf: *std.ArrayList(u8), allocator: Allocator, ref: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-partial-slot"
    , .{});
    try appendRootPartialAttrs(buf, allocator, ref, "stats", "Source stats", root_partial_priority_stats, root_partial_timeout_stats_ms);
    try appendTemplate(buf, allocator,
        \\>
        \\  <div class="root-sidebar-section root-sidebar-loading" aria-busy="true">
        \\    <h2>Languages</h2>
        \\    <p class="root-sidebar-empty">Loading language stats...</p>
        \\  </div>
        \\  <div class="root-sidebar-section root-sidebar-loading" aria-busy="true">
        \\    <h2>SLOC</h2>
        \\    <p class="root-sidebar-empty">Loading source line counts...</p>
        \\  </div>
        \\</div>
    , .{});
}

fn appendRootPartialAttrs(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    component: []const u8,
    label: []const u8,
    priority: usize,
    timeout_ms: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\ data-root-partial="/code/root/{component}?ref=
    , .{ .component = component });
    try shared.appendUrlEncoded(buf, allocator, ref);
    try appendTemplate(buf, allocator,
        \\" data-root-partial-label="{label}" data-root-partial-priority="{priority}" data-root-partial-timeout-ms="{timeout_ms}" aria-live="polite"
    , .{ .label = label, .priority = priority, .timeout_ms = timeout_ms });
}

fn appendRootAboutComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    const readme_doc = try loadRootReadmeDoc(allocator, repo, ref, 64 * 1024);
    defer if (readme_doc) |doc| doc.deinit(allocator);
    const about_summary = if (readme_doc) |doc| markdownSummaryOwned(allocator, doc.content) catch null else null;
    defer if (about_summary) |summary| allocator.free(summary);
    try appendRootAboutSection(buf, allocator, about_summary orelse root_about_fallback);
}

fn appendRootRepositoryComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo) !void {
    const git_status = loadRootGitStatus(allocator, repo) catch null;
    try appendRootRepositorySection(buf, allocator, git_status);
}

fn appendRootBranchComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    const counts = (try loadRootEntryCounts(allocator, repo, ref)) orelse RootEntryCounts{};
    const git_status = loadRootGitStatus(allocator, repo) catch null;
    const branch_sync_status = loadBranchSyncStatus(allocator, repo, ref) catch null;
    defer if (branch_sync_status) |status| status.deinit(allocator);
    try appendRootBranchSection(buf, allocator, ref, counts, branch_sync_status, git_status);
}

fn appendRootStatsComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo) !void {
    var languages_opt = source_stats.loadRepositoryStats(allocator, repo) catch null;
    defer if (languages_opt) |*stats| stats.deinit(allocator);
    try appendRootLanguages(buf, allocator, languages_opt);
    try appendRootSloc(buf, allocator, languages_opt);
}

fn appendRootDocsComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    const readme_doc = try loadRootReadmeDoc(allocator, repo, ref, max_blob_display_bytes + 1) orelse return;
    defer readme_doc.deinit(allocator);
    const license_doc_opt = try loadRootLicenseDocFast(allocator, repo, ref);
    defer if (license_doc_opt) |doc| doc.deinit(allocator);
    const agents_doc_opt = try loadRootAgentsDocFast(allocator, repo, ref);
    defer if (agents_doc_opt) |doc| doc.deinit(allocator);
    try appendRootDocsPreview(buf, allocator, ref, readme_doc, license_doc_opt, agents_doc_opt);
}

fn appendRootSearchComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    const search_entries_opt = try loadTreeNavEntries(allocator, repo, ref);
    if (search_entries_opt) |search_entries| {
        defer freeTreeNavEntries(allocator, search_entries);
        try appendRootSearchIndex(buf, allocator, ref, search_entries);
    }
}

fn appendRootCommitCountComponent(buf: *std.ArrayList(u8), allocator: Allocator, repo: Repo, ref: []const u8) !void {
    const commit_count = loadCommitCount(allocator, repo, ref) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (commit_count) |count| try appendRootCommitCountLink(buf, allocator, ref, count);
}

fn appendRootAboutSection(buf: *std.ArrayList(u8), allocator: Allocator, about_text: []const u8) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>About</h2>
        \\  <p class="root-about-text">{about}</p>
        \\</div>
    , .{ .about = about_text });
}

fn appendRootRepositorySection(buf: *std.ArrayList(u8), allocator: Allocator, git_status: ?RootGitStatus) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>Repository</h2>
        \\  <dl class="root-meta-list">
    , .{});
    if (git_status) |status| {
        try appendRootRepositoryStats(buf, allocator, status);
    } else {
        try appendTemplate(buf, allocator,
            \\    <div><dt>Repository</dt><dd>Unavailable</dd></div>
        , .{});
    }
    try appendTemplate(buf, allocator,
        \\  </dl>
        \\</div>
    , .{});
}

fn appendRootBranchSection(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    ref: []const u8,
    counts: RootEntryCounts,
    branch_sync_status: ?BranchSyncStatus,
    git_status: ?RootGitStatus,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>Branch</h2>
        \\  <dl class="root-meta-list">
        \\    <div><dt>Ref</dt><dd><code>{ref}</code></dd></div>
        \\    <div><dt>Root</dt><dd>{files} {files_label}, {directories} {directories_label}</dd></div>
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
            \\    <div><dt>Sync</dt><dd>No upstream</dd></div>
        , .{});
    }
    if (git_status) |status| {
        try appendRootBranchStats(buf, allocator, status);
    } else {
        try appendTemplate(buf, allocator,
            \\    <div><dt>Checkout</dt><dd>Unavailable</dd></div>
        , .{});
    }
    try appendTemplate(buf, allocator,
        \\  </dl>
        \\</div>
    , .{});
}

fn appendRootRepositoryStats(buf: *std.ArrayList(u8), allocator: Allocator, status: RootGitStatus) !void {
    try appendTemplate(buf, allocator,
        \\        <div><dt>Worktrees</dt><dd>{worktrees}</dd></div>
        \\        <div><dt>Size</dt><dd>
    , .{
        .worktrees = shared.groupedUnsigned(@intCast(status.worktree_count)),
    });
    if (status.disk_size_bytes) |bytes| {
        try appendRepositoryDiskSize(buf, allocator, bytes);
    } else {
        try appendTemplate(buf, allocator, "Unknown", .{});
    }
    try appendTemplate(buf, allocator, "</dd></div>", .{});
}

fn appendRepositoryDiskSize(buf: *std.ArrayList(u8), allocator: Allocator, size: usize) !void {
    const mib: u128 = 1024 * 1024;
    const gib: u128 = 1024 * mib;
    const bytes = @as(u128, size);

    if (bytes >= gib) {
        const hundredths = bytes * 100 / gib;
        try appendFmt(buf, allocator, "{d}.{d:0>2} GB", .{ hundredths / 100, hundredths % 100 });
        return;
    }

    var megabytes = bytes / mib;
    if (megabytes == 0 and bytes != 0) megabytes = 1;
    try appendFmt(buf, allocator, "{d} MB", .{megabytes});
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
    , .{});
    const stats = stats_opt orelse {
        try appendTemplate(buf, allocator,
            \\<h2>SLOC</h2><p class="root-sidebar-empty">No SLOC data available.</p></div>
        , .{});
        return;
    };
    const total = stats.total();
    if (total == 0 or stats.rows.len == 0) {
        try appendTemplate(buf, allocator,
            \\<h2>SLOC</h2><p class="root-sidebar-empty">No source files counted.</p></div>
        , .{});
        return;
    }

    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-title-line"><h2>SLOC</h2><strong>{total} {lines_label}</strong></div><div class="root-sloc-breakdown" aria-label="Top source lines of code by language">
    , .{
        .total = shared.groupedUnsigned(total),
        .lines_label = if (total == 1) "line" else "lines",
    });
    for (stats.rows[0..@min(stats.rows.len, 3)]) |stat| {
        try appendTemplate(buf, allocator,
            \\<div class="root-sloc-row" style="--language-color: {color}; --share: {share};"><div class="root-sloc-row-head"><span class="root-sloc-bar" aria-hidden="true"></span><span class="root-sloc-language"><span class="language-dot"></span><span>{name}</span></span></div><span class="root-sloc-metrics"><span><strong>{code}</strong> code</span><span><strong>{test_count}</strong> test</span><span><strong>{comment}</strong> comments</span></span></div>
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

test "web explorer renders AGENTS markdown root doc tab" {
    const allocator = std.testing.allocator;
    const readme_doc = RootMarkdownDoc{
        .id = "readme",
        .label = "README",
        .path = try allocator.dupe(u8, "README.md"),
        .content = try allocator.dupe(u8, "# Repo\n"),
    };
    defer readme_doc.deinit(allocator);
    const agents_doc = RootMarkdownDoc{
        .id = "agents",
        .label = "AGENTS.md",
        .path = try allocator.dupe(u8, "AGENTS.md"),
        .content = try allocator.dupe(u8, "# Agent instructions\n"),
    };
    defer agents_doc.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendRootDocsPreview(&buf, allocator, "HEAD", readme_doc, null, agents_doc);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-root-doc-tab=\"agents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-root-doc-panel=\"agents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-markdown-path=\"AGENTS.md\"") != null);
}

test "web explorer maps file paths to highlight languages" {
    try std.testing.expectEqualStrings("zig", languageForPath("src/main.zig"));
    try std.testing.expectEqualStrings("markdown", languageForPath("README.md"));
    try std.testing.expectEqualStrings("xml", languageForPath("assets/logo.svg"));
    try std.testing.expectEqualStrings("solidity", languageForPath("contracts/Token.sol"));
    try std.testing.expectEqualStrings("tla", languageForPath("spec/Consensus.tla"));
    try std.testing.expectEqualStrings("plaintext", languageForPath("LICENSE"));
}

test "web explorer maps source preview paths" {
    try std.testing.expectEqual(@as(?BlobPreviewKind, .markdown), previewKindForPath("README.md"));
    try std.testing.expectEqual(@as(?BlobPreviewKind, .pdf), previewKindForPath("docs/spec.PDF"));
    try std.testing.expectEqual(@as(?BlobPreviewKind, .svg), previewKindForPath("assets/logo.SVG"));
    try std.testing.expectEqual(@as(?BlobPreviewKind, null), previewKindForPath("assets/logo.png"));
    try std.testing.expect(sourceViewSelected("raw"));
    try std.testing.expect(sourceViewSelected("source"));
    try std.testing.expect(!sourceViewSelected("preview"));
}

test "web explorer renders SVG preview source tabs" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendPreviewViewTabs(&buf, std.testing.allocator, "HEAD", "assets/logo.svg", .svg, false);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "aria-label=\"SVG view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Preview</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Source</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "view=raw") != null);
}

test "web explorer renders PDF preview raw tabs" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendPreviewViewTabs(&buf, std.testing.allocator, "HEAD", "docs/spec.pdf", .pdf, false);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "aria-label=\"PDF view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Preview</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, ">Raw</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "/raw?ref=HEAD&amp;path=docs/spec.pdf") != null);
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
    try std.testing.expectEqual(CodeSyncMode.prune_remote, parseCodeSyncMode("prune").?);
    try std.testing.expectEqual(CodeSyncMode.prune_remote, parseCodeSyncMode("prune-remote").?);
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

test "web explorer formats repository disk size as MB then GB" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendRepositoryDiskSize(&buf, std.testing.allocator, 123 * 1024 * 1024);
    try std.testing.expectEqualStrings("123 MB", buf.items);

    buf.clearRetainingCapacity();
    try appendRepositoryDiskSize(&buf, std.testing.allocator, 1536 * 1024 * 1024);
    try std.testing.expectEqualStrings("1.50 GB", buf.items);
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
    try std.testing.expectEqual(@as(?MediaKind, null), mediaKindForPath("docs/spec.pdf"));
    try std.testing.expectEqualStrings("application/pdf", contentTypeForPath("docs/spec.pdf"));
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
