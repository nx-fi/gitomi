const std = @import("std");
const git = @import("../git.zig");
const markdown_render = @import("markdown_render.zig");
const repo_mod = @import("../repo.zig");
const shared = @import("shared.zig");
const code_symbols = @import("symbols.zig");
const source_stats = @import("source_stats.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const Href = shared.Href;
const appendEmptyState = shared.appendEmptyState;
const appendFmt = shared.appendFmt;
const appendHref = shared.appendHref;
const appendRepoHeaderShared = shared.appendRepoHeader;
const appendShellEnd = shared.appendShellEnd;
const appendShellStart = shared.appendShellStart;
const appendTemplate = shared.appendTemplate;
const blameHref = shared.blameHref;
const codeHref = shared.codeHref;
const codeHrefWithView = shared.codeHrefWithView;
const commitHref = shared.commitHref;
const commitsHref = shared.commitsHref;
const literalHref = shared.literalHref;
const rawHref = shared.rawHref;
const runCommand = git.runCommand;

const max_blob_display_bytes = 512 * 1024;
const max_blame_display_bytes = 16 * 1024 * 1024;
const max_raw_blob_bytes = git.max_git_output;

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

    fn deinit(self: BranchRef, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const TreeEntryCommit = struct {
    full_hash: []u8,
    subject: []u8,

    fn deinit(self: TreeEntryCommit, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.subject);
    }
};

const CommitSummary = struct {
    full_hash: []u8,
    hash: []u8,
    subject: []u8,
    relative: []u8,

    fn deinit(self: CommitSummary, allocator: Allocator) void {
        allocator.free(self.full_hash);
        allocator.free(self.hash);
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

const RootEntryCounts = struct {
    files: usize = 0,
    directories: usize = 0,
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
        return renderTreePage(allocator, repo, ref, path);
    }

    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const kind_owned = try objectType(allocator, repo, spec);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return renderMissingPathPage(allocator, repo, ref, path);

    if (std.mem.eql(u8, kind, "blob")) {
        const view = try targetViewOwned(allocator, target);
        defer allocator.free(view);
        return renderBlobPage(allocator, repo, ref, path, spec, view);
    }
    if (std.mem.eql(u8, kind, "tree")) {
        return renderTreePage(allocator, repo, ref, path);
    }
    return renderMissingPathPage(allocator, repo, ref, path);
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

    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const kind_owned = try objectType(allocator, repo, spec);
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

    const spec = try objectSpec(allocator, ref, path);
    defer allocator.free(spec);
    const kind_owned = try objectType(allocator, repo, spec);
    defer if (kind_owned) |kind| allocator.free(kind);
    const kind = kind_owned orelse return null;
    if (!std.mem.eql(u8, kind, "blob")) return null;

    const size = try blobSize(allocator, repo, spec);
    if (size != null and size.? > max_raw_blob_bytes) return error.BlobTooLarge;

    const body = try gitMaybe(allocator, repo, &.{ "show", spec }, max_raw_blob_bytes) orelse return null;
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

fn renderTreePage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) ![]u8 {
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

        if (is_root) try appendRootPageGridStart(&buf, allocator);
        try appendCodePanelStart(&buf, allocator, repo, ref, path);
        try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
        try appendCodePanelToolbarEnd(&buf, allocator);
        try appendCommitBar(&buf, allocator, summary_opt);
        try appendCodePanelHeadEnd(&buf, allocator);
        try appendTreeListing(&buf, allocator, ref, path, entries);
        try appendCodePanelEnd(&buf, allocator);

        try appendReadmePreview(&buf, allocator, repo, ref, path, entries);
        if (is_root) {
            try appendRootPageMainEnd(&buf, allocator);
            try appendRootSidebar(&buf, allocator, repo, ref, entries, summary_opt);
            try appendRootPageGridEnd(&buf, allocator);
        }
    } else {
        try appendEmptyState(&buf, allocator, "No committed files found.", "The selected ref does not point at a readable tree yet.");
    }

    try appendCodeLayoutEnd(&buf, allocator);
    try appendShellEnd(&buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn renderBlobPage(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8, spec: []const u8, view: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendShellStart(&buf, allocator, repo, "Code", "code");
    try appendRepoHeader(&buf, allocator, repo, ref);
    const size = try blobSize(allocator, repo, spec);
    const media_kind = mediaKindForPath(path);
    const can_preview_media = media_kind != null and (size == null or size.? <= max_raw_blob_bytes);
    const content = if (!can_preview_media and size != null and size.? <= max_blob_display_bytes)
        try gitMaybe(allocator, repo, &.{ "show", spec }, max_blob_display_bytes + 1)
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
    const symbol_items = if (text_content) |bytes|
        if (show_symbols_panel)
            try code_symbols.extract(allocator, repo.root, path, bytes)
        else
            try allocator.alloc(code_symbols.Symbol, 0)
    else
        try allocator.alloc(code_symbols.Symbol, 0);
    defer code_symbols.free(allocator, symbol_items);

    try appendCodeLayoutStartWithSymbols(&buf, allocator, repo, ref, path, show_symbols_panel);

    try appendCodePanelStart(&buf, allocator, repo, ref, path);
    try appendCodeBlameSwitch(&buf, allocator, ref, path, false);
    if (markdown) try appendMarkdownViewTabs(&buf, allocator, ref, path, raw_selected);
    try appendBlobMetrics(&buf, allocator, size, text_content, sloc_counts);
    if (show_symbols_panel) try appendSymbolsToggleButton(&buf, allocator);
    try appendCodeActionLink(&buf, allocator, "Raw", rawHref(ref, path), "icon-file-code");
    if (text_content != null) try appendCopyButton(&buf, allocator, ref, path);
    try appendCodeActionLink(&buf, allocator, "History", commitsHref(ref, path), "icon-history");
    try appendCodePanelToolbarEnd(&buf, allocator);

    try appendCommitBar(&buf, allocator, summary_opt);
    try appendCodePanelHeadEnd(&buf, allocator);
    const permalink_ref = if (summary_opt) |summary| summary.full_hash else ref;
    try appendBlobContent(&buf, allocator, ref, permalink_ref, path, media_kind, can_preview_media, content, render_markdown);

    try appendCodePanelEnd(&buf, allocator);
    try appendCodeLayoutEndWithSymbols(&buf, allocator, show_symbols_panel, symbol_items);
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
            \\<div class="readme-body markdown-body markdown-preview">
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
    try appendRepoHeaderShared(buf, allocator, repo, ref, &.{
        .{ .label = "Commits", .href = literalHref("/commits") },
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
    try appendTemplate(buf, allocator,
        \\<div{class_attr}>
    , .{
        .class_attr = shared.classAttr("code-layout", &.{
            shared.class("no-sidebar", active_path.len == 0),
            shared.class("has-symbols", has_symbols),
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
    try appendTemplate(buf, allocator, "</div>", .{});
    if (show_symbols_panel) try appendCodeSymbolsSidebar(buf, allocator, symbols);
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
    try appendTemplate(buf, allocator, "</nav></aside>", .{});
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

    try appendTemplate(buf, allocator,
        \\<aside class="panel tree-sidebar" data-tree-sidebar>
        \\  <div class="tree-sidebar-head"><span class="tree-sidebar-title">Files</span><button class="tree-icon-button tree-collapse-button" type="button" data-tree-collapse aria-label="Collapse files panel" title="Collapse files panel"></button></div>
        \\  <div class="tree-sidebar-controls">
        \\    <label class="tree-branch-label"><span>Branch</span><select class="tree-branch-select" data-branch-switcher data-active-path="{active_path}">
    , .{ .active_path = active_path });
    try appendBranchOptions(buf, allocator, branches, ref);
    try appendTemplate(buf, allocator,
        \\    </select></label>
        \\    <label class="tree-search-label"><span>File search</span><input class="tree-search-input" type="search" data-tree-search placeholder="Go to file" autocomplete="off" spellcheck="false"></label>
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

fn appendBranchOptions(buf: *std.ArrayList(u8), allocator: Allocator, branches: []const BranchRef, selected_ref: []const u8) !void {
    var found_selected = false;
    for (branches) |branch| {
        const selected = std.mem.eql(u8, branch.name, selected_ref);
        found_selected = found_selected or selected;
        try appendTemplate(buf, allocator,
            \\<option value="{name}"{selected_attr}>{name}</option>
        , .{
            .name = branch.name,
            .selected_attr = shared.trustedHtml(if (selected) " selected" else ""),
        });
    }
    if (!found_selected) {
        try appendTemplate(buf, allocator,
            \\<option value="{name}" selected>{name}</option>
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
        try appendTemplate(buf, allocator,
            \\<span class="file-commit" title="{subject}"><a href="{href}">{subject}</a></span>
        , .{
            .href = commitHref(commit.full_hash),
            .subject = commit.subject,
        });
    } else {
        try appendTemplate(buf, allocator, "<span class=\"file-commit empty\">No commit</span>", .{});
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
    const spec = try objectSpec(allocator, ref, readme_path);
    defer allocator.free(spec);
    const content = try gitMaybe(allocator, repo, &.{ "show", spec }, max_blob_display_bytes + 1) orelse return;
    defer allocator.free(content);
    if (containsNul(content)) return;

    try appendTemplate(buf, allocator,
        \\<section class="panel readme-panel">
        \\  <div class="section-head readme-head"><div><p class="eyebrow">Documentation</p><h2>{readme}</h2></div><a class="button secondary" href="{href}">Open file</a></div><div class="readme-body markdown-body">
    , .{
        .readme = readme,
        .href = codeHrefWithView(ref, readme_path, "preview"),
    });
    try appendRepositoryMarkdown(buf, allocator, ref, readme_path, content);
    try appendTemplate(buf, allocator, "</div></section>", .{});
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
    summary_opt: ?CommitSummary,
) !void {
    const counts = rootEntryCounts(entries);
    const readme_name = findReadme(entries);
    const changes = git.workingTreeChangeCount(allocator) catch 0;
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
        \\      <div class="root-link-list">
    , .{ .about = about_text });

    if (readme_name) |name| {
        try appendTemplate(buf, allocator,
            \\<a href="{href}">README</a>
        , .{ .href = codeHrefWithView(ref, name, "preview") });
    }
    try appendTemplate(buf, allocator,
        \\        <a href="/commits">Commits</a>
        \\        <a href="/issues">Issues</a>
        \\        <a href="/projects">Projects</a>
        \\      </div>
        \\    </div>
        \\    <div class="root-sidebar-section">
        \\      <h2>Repository</h2>
        \\      <dl class="root-meta-list">
        \\        <div><dt>Ref</dt><dd><code>{ref}</code></dd></div>
        \\        <div><dt>Root</dt><dd>{files} {files_label}, {directories} {directories_label}</dd></div>
        \\        <div><dt>Working tree</dt><dd>{changes} {changes_label}</dd></div>
        \\      </dl>
        \\    </div>
    , .{
        .ref = ref,
        .files = counts.files,
        .files_label = if (counts.files == 1) "file" else "files",
        .directories = counts.directories,
        .directories_label = if (counts.directories == 1) "folder" else "folders",
        .changes = changes,
        .changes_label = if (changes == 1) "change" else "changes",
    });

    try appendRootLatestCommit(buf, allocator, summary_opt);
    try appendRootLanguages(buf, allocator, languages_opt);
    try appendTemplate(buf, allocator, "</section></aside>", .{});
}

fn appendRootLatestCommit(buf: *std.ArrayList(u8), allocator: Allocator, summary_opt: ?CommitSummary) !void {
    try appendTemplate(buf, allocator,
        \\<div class="root-sidebar-section">
        \\  <h2>Latest commit</h2>
    , .{});
    if (summary_opt) |summary| {
        try appendTemplate(buf, allocator,
            \\<a class="root-latest-commit" href="{href}"><strong>{subject}</strong><small><code>{hash}</code>{relative}</small></a>
        , .{
            .href = commitHref(summary.full_hash),
            .subject = summary.subject,
            .hash = summary.hash,
            .relative = summary.relative,
        });
    } else {
        try appendTemplate(buf, allocator,
            \\<p class="root-sidebar-empty">No commits found for this ref.</p>
        , .{});
    }
    try appendTemplate(buf, allocator, "</div>", .{});
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
    try appendTemplate(buf, allocator,
        \\</div><ul class="root-language-list">
    , .{});
    for (stats.rows, 0..) |stat, idx| {
        if (idx < 3) {
            try appendTemplate(buf, allocator,
                \\<li><span class="language-dot" style="--language-color: {color};"></span><span class="root-language-name">{name}</span><strong>{share}</strong><span class="root-language-sloc">{sloc} SLOC</span></li>
            , .{
                .color = source_stats.languageColor(stat.language),
                .name = source_stats.languageDisplayName(stat.language),
                .share = shared.percent(stat.total(), total),
                .sloc = shared.groupedUnsigned(stat.total()),
            });
        } else {
            try appendTemplate(buf, allocator,
                \\<li><span class="language-dot" style="--language-color: {color};"></span><span class="root-language-name">{name}</span><strong>{share}</strong></li>
            , .{
                .color = source_stats.languageColor(stat.language),
                .name = source_stats.languageDisplayName(stat.language),
                .share = shared.percent(stat.total(), total),
            });
        }
    }
    try appendTemplate(buf, allocator, "</ul></div>", .{});
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
    const spec = try objectSpec(allocator, ref, readme);
    defer allocator.free(spec);
    const content = try gitMaybe(allocator, repo, &.{ "show", spec }, 64 * 1024) orelse return null;
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
    try markdown_render.appendMarkdownWithOptions(buf, allocator, content, .{
        .link_context = .{
            .ref = ref,
            .current_path = path,
        },
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
    var index_by_name = std.StringHashMap(usize).init(allocator);
    defer index_by_name.deinit();
    for (entries, 0..) |entry, i| {
        try index_by_name.put(entry.name, i);
    }

    const format = "--format=%x1e%H%x09%s";
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

fn treeEntryCommitOwned(allocator: Allocator, commit: LogCommit) !TreeEntryCommit {
    const full_hash = try allocator.dupe(u8, commit.full_hash);
    errdefer allocator.free(full_hash);
    const subject = try allocator.dupe(u8, commit.subject);
    return .{
        .full_hash = full_hash,
        .subject = subject,
    };
}

const LogCommit = struct {
    full_hash: []const u8,
    subject: []const u8,
};

fn parseLogCommitHeader(record: []const u8) ?LogCommit {
    if (record.len == 0 or record[0] != 0x1e) return null;
    const payload = record[1..];
    const tab = std.mem.indexOfScalar(u8, payload, '\t') orelse return null;
    if (tab == 0) return null;
    return .{
        .full_hash = payload[0..tab],
        .subject = payload[tab + 1 ..],
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
    const format = "--format=%H%x09%h%x09%s%x09%cr";
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
    var cols = std.mem.splitScalar(u8, line, '\t');
    return .{
        .full_hash = try allocator.dupe(u8, cols.next() orelse ""),
        .hash = try allocator.dupe(u8, cols.next() orelse ""),
        .subject = try allocator.dupe(u8, cols.next() orelse ""),
        .relative = try allocator.dupe(u8, cols.next() orelse ""),
    };
}

fn loadTreeNavEntries(allocator: Allocator, repo: Repo, ref: []const u8) !?[]TreeNavEntry {
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

fn loadBranchRefs(allocator: Allocator, repo: Repo) ![]BranchRef {
    const raw = try gitMaybe(allocator, repo, &.{ "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }, git.max_git_output) orelse {
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
        const name = std.mem.trim(u8, line, " \t\r\n");
        if (name.len == 0) continue;
        if (std.mem.endsWith(u8, name, "/HEAD")) continue;
        try branches.append(allocator, .{ .name = try allocator.dupe(u8, name) });
    }
    std.mem.sort(BranchRef, branches.items, {}, struct {
        fn lessThan(_: void, a: BranchRef, b: BranchRef) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    return branches.toOwnedSlice(allocator);
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

fn blobSize(allocator: Allocator, repo: Repo, spec: []const u8) !?usize {
    const raw = try gitMaybe(allocator, repo, &.{ "cat-file", "-s", spec }, 1024) orelse return null;
    defer allocator.free(raw);
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
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
        if (trimmed.len != 0) return allocator.dupe(u8, trimmed);
    }
    return defaultRef(allocator, repo);
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

    const language = languageForPath(path);
    if (std.mem.eql(u8, language, "zig")) return "devicon-zig-original";
    if (std.mem.eql(u8, language, "javascript")) return "devicon-javascript-plain";
    if (std.mem.eql(u8, language, "typescript")) return "devicon-typescript-plain";
    if (std.mem.eql(u8, language, "bash")) return "devicon-bash-plain";
    if (std.mem.eql(u8, language, "yaml")) return "devicon-yaml-plain";
    if (std.mem.eql(u8, language, "css")) return "devicon-css3-plain";
    if (std.mem.eql(u8, language, "html")) return "devicon-html5-plain";
    if (std.mem.eql(u8, language, "xml")) return "devicon-xml-plain";
    if (std.mem.eql(u8, language, "solidity")) return "devicon-solidity-plain";
    if (std.mem.eql(u8, language, "rust")) return "devicon-rust-plain";
    if (std.mem.eql(u8, language, "python")) return "devicon-python-plain";
    if (std.mem.eql(u8, language, "markdown")) return "devicon-markdown-original";
    return null;
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

fn freeBlameLines(allocator: Allocator, lines: []BlameLine) void {
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo.root);
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
    try std.testing.expectEqualStrings("devicon-zig-original", deviconClassForPath("src/main.zig", "blob").?);
    try std.testing.expectEqualStrings("devicon-html5-plain", deviconClassForPath("index.html", "blob").?);
    try std.testing.expectEqualStrings("devicon-markdown-original", deviconClassForPath("README.md", "blob").?);
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
    const parsed = parseLogCommitHeader("\x1e0123456789abcdef\tfix: path\twith tab").?;
    try std.testing.expectEqualStrings("0123456789abcdef", parsed.full_hash);
    try std.testing.expectEqualStrings("fix: path\twith tab", parsed.subject);
    try std.testing.expect(parseLogCommitHeader("src/main.zig") == null);
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
