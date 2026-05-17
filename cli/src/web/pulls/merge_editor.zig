const std = @import("std");
const git = @import("../../git.zig");
const repo_mod = @import("../../repo.zig");
const util = @import("../../util.zig");
const work_items = @import("../../work_items.zig");
const shared = @import("../shared.zig");
const source_stats = @import("../source_stats.zig");
const zwf = @import("../../zwf.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const PullDetail = work_items.PullDetail;
const appendEmptyState = shared.appendEmptyState;
const appendTemplate = shared.appendTemplate;
const runCommand = git.runCommand;

const max_merge_blob_bytes = 2 * 1024 * 1024;
const merge_context_radius = 15;

pub const RemoteBranchTarget = struct {
    remote: []u8,
    branch: []u8,
    remote_ref: []u8,
    tracking_ref: []u8,

    pub fn deinit(self: RemoteBranchTarget, allocator: Allocator) void {
        allocator.free(self.remote);
        allocator.free(self.branch);
        allocator.free(self.remote_ref);
        allocator.free(self.tracking_ref);
    }
};

pub const PullMergeSnapshot = struct {
    expected_base_oid: []u8,
    expected_head_oid: []u8,
    base_target: RemoteBranchTarget,
    head_target: ?RemoteBranchTarget = null,

    pub fn deinit(self: PullMergeSnapshot, allocator: Allocator) void {
        allocator.free(self.expected_base_oid);
        allocator.free(self.expected_head_oid);
        self.base_target.deinit(allocator);
        if (self.head_target) |target| target.deinit(allocator);
    }
};

pub const PullMergeStatusKind = enum {
    unavailable,
    clean,
    conflicts,
};

pub const PullMergeStatus = struct {
    kind: PullMergeStatusKind = .unavailable,
    conflict_files: ?[][]u8 = null,
    snapshot: ?PullMergeSnapshot = null,

    pub fn deinit(self: PullMergeStatus, allocator: Allocator) void {
        if (self.conflict_files) |files| freeMergeTreeConflictFiles(allocator, files);
        if (self.snapshot) |snapshot| snapshot.deinit(allocator);
    }

    pub fn hasConflicts(self: PullMergeStatus) bool {
        return self.kind == .conflicts;
    }
};

pub const PullMergeMethod = enum {
    merge_commit,
    squash,
    rebase,
};

pub const PullMergeResult = struct {
    merge_oid: ?[]u8 = null,
    target_oid: ?[]u8 = null,

    pub fn deinit(self: PullMergeResult, allocator: Allocator) void {
        if (self.merge_oid) |value| allocator.free(value);
        if (self.target_oid) |value| allocator.free(value);
    }
};

pub const ResolvedConflictFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const MergeConflictFile = struct {
    path: []u8,
    content: ?[]u8 = null,
    message: ?[]u8 = null,

    fn deinit(self: MergeConflictFile, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.content) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
    }

    fn editable(self: MergeConflictFile) bool {
        return self.content != null;
    }
};

const MergeRenderLine = struct {
    line_number: usize,
    text: []const u8,
    group_id: usize = 0,
    kind: []const u8 = "line",
    side: []const u8 = "",
    editable: bool = true,
    visible: bool = false,
};

pub fn appendEmptyConflictState(buf: *std.ArrayList(u8), allocator: Allocator, raw_ref: []const u8, title: []const u8, detail: []const u8) !void {
    try buf.appendSlice(allocator, "<section class=\"panel merge-editor-empty\">");
    try appendEmptyState(buf, allocator, title, detail);
    try buf.appendSlice(allocator, "<div class=\"form-actions\"><a class=\"button secondary\" href=\"/pulls/");
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try buf.appendSlice(allocator, "\">Back to pull request</a></div></section>");
}

pub fn appendEditor(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    detail: PullDetail,
    raw_ref: []const u8,
    pull_ref: []const u8,
    csrf_token: []const u8,
    snapshot: PullMergeSnapshot,
    files: []const MergeConflictFile,
    error_message: ?[]const u8,
) !void {
    const writable_head = snapshot.head_target != null;
    const editable = writable_head and mergeEditorEditable(files);
    const total_conflicts = mergeEditorConflictCount(files);
    try appendTemplate(buf, allocator,
        \\<form class="merge-editor" data-merge-editor data-merge-unsupported="{unsupported}" data-merge-total-conflicts="{total_conflicts}" method="post" action="/pulls/
    , .{
        .unsupported = !editable,
        .total_conflicts = total_conflicts,
    });
    try shared.appendUrlEncoded(buf, allocator, raw_ref);
    try appendTemplate(buf, allocator,
        \\/conflicts">
        \\  <header class="merge-editor-head">
        \\    <div class="merge-editor-title">
        \\      <a class="merge-editor-back" href="/pulls/{pull_ref}" aria-label="Back to pull request"></a>
        \\      <div>
        \\        <h1>Resolving conflicts between <code>{head_ref}</code> and <code>{base_ref}</code></h1>
        \\        <p>Committing changes to <code>{head_ref}</code></p>
        \\      </div>
        \\    </div>
        \\    <div class="merge-editor-actions">
        \\      <div class="merge-editor-progress" aria-live="polite">
        \\        <span class="merge-editor-count" data-merge-progress>0 of {total_conflicts} conflicts resolved</span>
        \\        <span class="merge-editor-progress-bar" aria-hidden="true"><span data-merge-progress-bar></span></span>
        \\      </div>
        \\      <button class="button secondary merge-editor-step" type="button" data-merge-prev><span class="button-icon icon-chevron-up" aria-hidden="true"></span><span>Previous</span></button>
        \\      <button class="button secondary merge-editor-step" type="button" data-merge-next><span class="button-icon icon-chevron-down" aria-hidden="true"></span><span>Next</span></button>
        \\      <button class="button primary merge-editor-submit" type="submit" data-merge-submit disabled><span class="button-icon icon-check" aria-hidden="true"></span><span data-merge-submit-label>Commit resolution</span></button>
        \\    </div>
        \\  </header>
    , .{
        .pull_ref = pull_ref,
        .head_ref = detail.head_ref,
        .base_ref = detail.base_ref,
        .file_count = files.len,
        .file_word = if (files.len == 1) "conflicting file" else "conflicting files",
        .total_conflicts = total_conflicts,
    });

    if (error_message) |message| {
        try appendTemplate(buf, allocator, "<div class=\"flash error merge-editor-flash\">{message}</div>", .{ .message = message });
    }

    if (!writable_head) {
        try buf.appendSlice(allocator, "<div class=\"flash warning merge-editor-flash\">This pull request head is not a writable branch in the configured remotes. Resolve these conflicts from the command line.</div>");
    } else if (!editable) {
        try buf.appendSlice(allocator, "<div class=\"flash warning merge-editor-flash\">At least one conflict cannot be edited in the web resolver. Resolve unsupported conflicts from the command line.</div>");
    }

    try appendTemplate(buf, allocator,
        \\  <input type="hidden" name="file_count" value="{file_count}">
        \\  <input type="hidden" name="{csrf_field}" value="{csrf}">
        \\  <input type="hidden" name="expected_base_oid" value="{expected_base_oid}">
        \\  <input type="hidden" name="expected_head_oid" value="{expected_head_oid}">
        \\  <div class="merge-editor-layout">
        \\    <aside class="merge-editor-sidebar">
        \\      <strong>{file_count} {file_word}</strong>
        \\      <nav aria-label="Conflicting files">
    , .{
        .file_count = files.len,
        .file_word = if (files.len == 1) "file" else "files",
        .csrf_field = zwf.csrf.field_name,
        .csrf = csrf_token,
        .expected_base_oid = snapshot.expected_base_oid,
        .expected_head_oid = snapshot.expected_head_oid,
    });
    for (files, 0..) |file, index_value| {
        try appendTemplate(buf, allocator,
            \\<a class="{classes}" href="#merge-file-{index}" data-merge-file-link data-file-index="{index}"><span class="pull-conflict-file-icon" aria-hidden="true"></span><span class="merge-editor-file-name">{path}</span><span class="merge-editor-file-meta" data-merge-link-status>
        , .{
            .classes = shared.classes("merge-editor-file-link", &.{shared.class("is-unsupported", !file.editable())}),
            .index = index_value,
            .path = file.path,
        });
        try appendMergeFileNavStatus(buf, allocator, file);
        try buf.appendSlice(allocator, "</span></a>");
    }
    try buf.appendSlice(allocator,
        \\      </nav>
        \\    </aside>
        \\    <div class="merge-editor-files">
    );
    for (files, 0..) |file, index_value| {
        try appendMergeEditorFile(buf, allocator, file, index_value);
    }
    try buf.appendSlice(allocator, "</div></div></form>");
}

fn mergeEditorEditable(files: []const MergeConflictFile) bool {
    if (files.len == 0) return false;
    for (files) |file| {
        if (!file.editable()) return false;
    }
    return true;
}

fn mergeEditorConflictCount(files: []const MergeConflictFile) usize {
    var count: usize = 0;
    for (files) |file| count += mergeFileConflictCount(file);
    return count;
}

fn mergeFileConflictCount(file: MergeConflictFile) usize {
    const content = file.content orelse return 0;
    return countConflictGroups(content);
}

fn countConflictGroups(content: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<<")) count += 1;
    }
    return count;
}

fn appendMergeFileNavStatus(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile) !void {
    if (!file.editable()) {
        try buf.appendSlice(allocator, "Unsupported");
        return;
    }
    const count = mergeFileConflictCount(file);
    try appendTemplate(buf, allocator, "{count} {label}", .{
        .count = count,
        .label = if (count == 1) "conflict" else "conflicts",
    });
}

fn appendMergeFileStatus(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile) !void {
    if (!file.editable()) {
        try buf.appendSlice(allocator, "Unsupported");
        return;
    }
    const count = mergeFileConflictCount(file);
    if (count == 0) {
        try buf.appendSlice(allocator, "Resolved");
        return;
    }
    try appendTemplate(buf, allocator, "{count} unresolved", .{ .count = count });
}

fn appendMergeEditorFile(buf: *std.ArrayList(u8), allocator: Allocator, file: MergeConflictFile, index_value: usize) !void {
    const language = source_stats.languageForPath(file.path);
    try appendTemplate(buf, allocator,
        \\<section class="{classes}" id="merge-file-{index}" data-merge-file data-file-index="{index}">
        \\  <header class="merge-file-head">
        \\    <div><span class="pull-conflict-file-icon" aria-hidden="true"></span><strong>{path}</strong></div>
        \\    <span class="merge-file-status" data-merge-file-status>
    , .{
        .classes = shared.classes("panel merge-file-editor", &.{shared.class("is-unsupported", !file.editable())}),
        .index = index_value,
        .path = file.path,
    });
    try appendMergeFileStatus(buf, allocator, file);
    try appendTemplate(buf, allocator,
        \\</span>
        \\  </header>
        \\  <input type="hidden" name="path_{index}" value="{path}">
    , .{
        .index = index_value,
        .path = file.path,
    });

    if (file.content) |content| {
        try appendTemplate(buf, allocator,
            \\  <textarea class="merge-content-field" name="content_{index}" data-merge-content>{content}</textarea>
            \\  <div class="merge-code" data-merge-code data-merge-language="{language}">
        , .{
            .index = index_value,
            .content = content,
            .language = language,
        });
        try appendMergeConflictContent(buf, allocator, language, content);
        try buf.appendSlice(allocator, "</div>");
    } else {
        try appendTemplate(buf, allocator,
            \\<div class="merge-unsupported-message"><strong>This conflict is not editable in the web resolver.</strong><p>{message}</p></div>
        , .{ .message = file.message orelse "The file could not be loaded as a text conflict." });
    }
    try buf.appendSlice(allocator, "</section>");
}

fn appendMergeConflictContent(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, content: []const u8) !void {
    var render_lines: std.ArrayList(MergeRenderLine) = .empty;
    defer render_lines.deinit(allocator);

    var line_number: usize = 1;
    var group_id: usize = 0;
    var side: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<<")) {
            group_id += 1;
            side = "current";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "current", .editable = false });
        } else if (std.mem.startsWith(u8, line, "|||||||")) {
            side = "base";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "base", .editable = false });
        } else if (std.mem.startsWith(u8, line, "=======")) {
            side = "incoming";
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "incoming", .editable = false });
        } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "marker", .side = "incoming", .editable = false });
            side = "";
        } else {
            try render_lines.append(allocator, .{ .line_number = line_number, .text = line, .group_id = group_id, .kind = "line", .side = side, .editable = true });
        }
        line_number += 1;
    }

    markMergeLineVisibility(render_lines.items);
    try appendMergeRenderLines(buf, allocator, language, render_lines.items);
}

fn markMergeLineVisibility(lines: []MergeRenderLine) void {
    var has_conflicts = false;
    for (lines, 0..) |line, index_value| {
        if (line.group_id == 0) continue;
        has_conflicts = true;
        const start = index_value -| merge_context_radius;
        const end = @min(lines.len, index_value + merge_context_radius + 1);
        for (lines[start..end]) |*visible_line| visible_line.visible = true;
    }
    if (!has_conflicts) {
        for (lines) |*line| line.visible = true;
    }
}

fn appendMergeRenderLines(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, lines: []const MergeRenderLine) !void {
    var index_value: usize = 0;
    var fold_id: usize = 0;
    while (index_value < lines.len) {
        const line = lines[index_value];
        if (!line.visible) {
            const start = index_value;
            while (index_value < lines.len and !lines[index_value].visible) : (index_value += 1) {}
            fold_id += 1;
            try appendMergeFoldControl(buf, allocator, fold_id, index_value - start);
            for (lines[start..index_value]) |hidden_line| {
                try appendMergeRenderLine(buf, allocator, language, hidden_line, fold_id);
            }
            continue;
        }

        try appendMergeRenderLine(buf, allocator, language, line, 0);
        index_value += 1;
    }
}

fn appendMergeRenderLine(buf: *std.ArrayList(u8), allocator: Allocator, language: []const u8, line: MergeRenderLine, fold_id: usize) !void {
    if (line.group_id != 0 and std.mem.eql(u8, line.kind, "marker") and std.mem.eql(u8, line.side, "current")) {
        try appendMergeConflictActions(buf, allocator, line.group_id);
    }
    try appendMergeLine(buf, allocator, language, line, fold_id);
}

fn appendMergeFoldControl(buf: *std.ArrayList(u8), allocator: Allocator, fold_id: usize, count: usize) !void {
    try appendTemplate(buf, allocator,
        \\<div class="merge-fold" data-merge-fold="{fold_id}"><span class="merge-line-number"></span><button type="button" data-merge-fold-toggle data-merge-fold-target="{fold_id}" data-merge-fold-count="{count}" aria-expanded="false">Show {count} unchanged {label}</button></div>
    , .{
        .fold_id = fold_id,
        .count = count,
        .label = if (count == 1) "line" else "lines",
    });
}

fn appendMergeConflictActions(buf: *std.ArrayList(u8), allocator: Allocator, group_id: usize) !void {
    try appendTemplate(buf, allocator,
        \\<div class="merge-conflict-actions" data-conflict-group="{group_id}" data-conflict-actions>
        \\  <span class="merge-conflict-label">Conflict {group_id}</span>
        \\  <span class="merge-conflict-buttons">
        \\    <button class="merge-action-current" type="button" data-merge-action="current">Use current</button>
        \\    <button class="merge-action-incoming" type="button" data-merge-action="incoming">Use incoming</button>
        \\    <button class="merge-action-both" type="button" data-merge-action="both">Use both</button>
        \\  </span>
        \\</div>
    , .{ .group_id = group_id });
}

fn appendMergeLine(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    language: []const u8,
    line: MergeRenderLine,
    fold_id: usize,
) !void {
    try appendTemplate(buf, allocator,
        \\<div class="{classes}" data-merge-line
    , .{ .classes = shared.classes("merge-line", &.{
        shared.class("merge-marker", std.mem.eql(u8, line.kind, "marker")),
        shared.class("merge-current", std.mem.eql(u8, line.side, "current")),
        shared.class("merge-incoming", std.mem.eql(u8, line.side, "incoming")),
        shared.class("merge-base", std.mem.eql(u8, line.side, "base")),
        shared.class("merge-context", line.group_id == 0 and std.mem.eql(u8, line.kind, "line")),
        shared.class("merge-line-folded", !line.visible),
    }) });
    if (!line.visible) try appendTemplate(buf, allocator, " hidden data-merge-fold-id=\"{fold_id}\"", .{ .fold_id = fold_id });
    if (line.group_id != 0) try appendTemplate(buf, allocator, " data-conflict-group=\"{group_id}\"", .{ .group_id = line.group_id });
    if (line.side.len != 0 and !std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " data-conflict-side=\"{side}\"", .{ .side = line.side });
    try appendTemplate(buf, allocator,
        \\><span class="merge-line-number">{line_number}</span><code
    , .{ .line_number = line.line_number });
    if (!std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " class=\"language-{language}\"", .{ .language = language });
    try buf.appendSlice(allocator, " data-merge-line-text");
    if (!std.mem.eql(u8, line.kind, "marker")) try appendTemplate(buf, allocator, " data-original-text=\"{original}\"", .{ .original = line.text });
    if (line.editable and !std.mem.eql(u8, line.kind, "marker")) {
        try buf.appendSlice(allocator, " contenteditable=\"true\" spellcheck=\"false\" role=\"textbox\" aria-label=\"Editable merge line\"");
    }
    try appendTemplate(buf, allocator, ">{line}</code></div>", .{ .line = line.text });
}

pub fn loadConflictFiles(allocator: Allocator, repo: Repo, detail: PullDetail, snapshot: PullMergeSnapshot, conflict_paths: []const []const u8) ![]MergeConflictFile {
    var files: std.ArrayList(MergeConflictFile) = .empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    const merge_base = try work_items.loadMergeBase(allocator, repo, snapshot.expected_base_oid, snapshot.expected_head_oid);
    defer if (merge_base) |value| allocator.free(value);

    for (conflict_paths) |path| {
        try files.append(allocator, try loadMergeConflictFile(allocator, repo, detail, snapshot.expected_base_oid, snapshot.expected_head_oid, merge_base, path));
    }
    return try files.toOwnedSlice(allocator);
}

fn loadMergeConflictFile(
    allocator: Allocator,
    repo: Repo,
    detail: PullDetail,
    base_commit: []const u8,
    head_commit: []const u8,
    merge_base: ?[]const u8,
    path: []const u8,
) !MergeConflictFile {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    if (!isSafeMergePath(path)) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "The path is not a safe repository-relative file path."),
        };
    }

    const base_oid = merge_base orelse {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "The local repository could not find a merge base for this pull request."),
        };
    };

    const current_is_regular = try treePathIsRegularFile(allocator, repo, head_commit, path);
    const ancestor_is_regular = try treePathIsRegularFile(allocator, repo, base_oid, path);
    const incoming_is_regular = try treePathIsRegularFile(allocator, repo, base_commit, path);
    if (!current_is_regular or !ancestor_is_regular or !incoming_is_regular) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Only regular-file conflicts are editable in the web resolver."),
        };
    }

    const current = try loadBlobAtRef(allocator, repo, head_commit, path);
    defer if (current) |value| allocator.free(value);
    const ancestor = try loadBlobAtRef(allocator, repo, base_oid, path);
    defer if (ancestor) |value| allocator.free(value);
    const incoming = try loadBlobAtRef(allocator, repo, base_commit, path);
    defer if (incoming) |value| allocator.free(value);

    if (current == null or ancestor == null or incoming == null) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Deleted-file conflicts are not editable in the web resolver yet."),
        };
    }

    if (containsNul(current.?) or containsNul(ancestor.?) or containsNul(incoming.?)) {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Binary conflicts are not editable in the web resolver."),
        };
    }

    const content = (try mergeFileConflictContent(allocator, detail, current.?, ancestor.?, incoming.?)) orelse {
        return .{
            .path = owned_path,
            .message = try allocator.dupe(u8, "Git could not generate a text conflict for this file."),
        };
    };

    return .{
        .path = owned_path,
        .content = content,
    };
}

pub fn freeConflictFiles(allocator: Allocator, files: []MergeConflictFile) void {
    for (files) |file| file.deinit(allocator);
    allocator.free(files);
}

fn loadBlobAtRef(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !?[]u8 {
    const object = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, path });
    defer allocator.free(object);
    return work_items.gitMaybe(allocator, repo, &.{ "show", "--end-of-options", object }, max_merge_blob_bytes);
}

fn treePathIsRegularFile(allocator: Allocator, repo: Repo, ref: []const u8, path: []const u8) !bool {
    const raw = try work_items.gitMaybe(allocator, repo, &.{ "ls-tree", "-z", ref, "--", path }, 1024 * 1024) orelse return false;
    defer allocator.free(raw);
    return lsTreeRecordIsRegularFile(raw, path);
}

fn lsTreeRecordIsRegularFile(raw: []const u8, path: []const u8) bool {
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        if (!std.mem.eql(u8, record[tab + 1 ..], path)) continue;
        const space = std.mem.indexOfScalar(u8, record[0..tab], ' ') orelse return false;
        return isRegularGitMode(record[0..space]);
    }
    return false;
}

pub fn isRegularGitMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "100644") or
        std.mem.eql(u8, mode, "100755");
}

fn mergeFileConflictContent(
    allocator: Allocator,
    detail: PullDetail,
    current: []const u8,
    ancestor: []const u8,
    incoming: []const u8,
) !?[]u8 {
    const tmp_dir = try tempPath(allocator, "gitomi-merge-file");
    defer allocator.free(tmp_dir);
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const current_path = try std.fs.path.join(allocator, &.{ tmp_dir, "current" });
    defer allocator.free(current_path);
    const ancestor_path = try std.fs.path.join(allocator, &.{ tmp_dir, "ancestor" });
    defer allocator.free(ancestor_path);
    const incoming_path = try std.fs.path.join(allocator, &.{ tmp_dir, "incoming" });
    defer allocator.free(incoming_path);

    try writeFileBytes(current_path, current);
    try writeFileBytes(ancestor_path, ancestor);
    try writeFileBytes(incoming_path, incoming);

    const current_label = try std.fmt.allocPrint(allocator, "{s} (Current change)", .{detail.head_ref});
    defer allocator.free(current_label);
    const incoming_label = try std.fmt.allocPrint(allocator, "{s} (Incoming change)", .{detail.base_ref});
    defer allocator.free(incoming_label);

    var result = try runCommand(allocator, &.{
        "git",
        "merge-file",
        "-p",
        "-L",
        current_label,
        "-L",
        "merge base",
        "-L",
        incoming_label,
        current_path,
        ancestor_path,
        incoming_path,
    }, null, max_merge_blob_bytes * 3);
    if (result.exitCode()) |code| {
        if (mergeFileProducedContent(code)) {
            const stdout = result.stdout;
            allocator.free(result.stderr);
            return stdout;
        }
    }
    result.deinit();
    return null;
}

fn mergeFileProducedContent(exit_code: u8) bool {
    // git merge-file returns the conflict count on successful text merges, capped at 127.
    return exit_code <= 127;
}

fn containsNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

pub fn isSafeMergePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return false;
    }
    return true;
}

pub fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    const id = try util.newUuidV7(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, id });
}

pub fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn contentHasConflictMarkers(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "<<<<<<<")) return true;
        if (std.mem.startsWith(u8, trimmed, "|||||||")) return true;
        if (std.mem.eql(u8, trimmed, "=======")) return true;
        if (std.mem.startsWith(u8, trimmed, ">>>>>>>")) return true;
    }
    return false;
}

pub fn freeMergeTreeConflictFiles(allocator: Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
}

test "content conflict marker detection" {
    try std.testing.expect(contentHasConflictMarkers("a\n<<<<<<< head\nb\n=======\nc\n>>>>>>> main\n"));
    try std.testing.expect(!contentHasConflictMarkers("const divider = \"=======\";\n"));
}

test "merge editor counts conflict groups" {
    try std.testing.expectEqual(@as(usize, 2), countConflictGroups(
        \\<<<<<<< ours
        \\a
        \\=======
        \\b
        \\>>>>>>> theirs
        \\ok
        \\<<<<<<< ours
        \\c
        \\=======
        \\d
        \\>>>>>>> theirs
    ));
    try std.testing.expectEqual(@as(usize, 0), countConflictGroups("const divider = \"=======\";\n"));
}

test "merge editor visibility keeps radius around conflicts" {
    var lines: [40]MergeRenderLine = undefined;
    for (&lines, 0..) |*line, index_value| {
        line.* = .{ .line_number = index_value + 1, .text = "" };
    }
    lines[20].group_id = 1;

    markMergeLineVisibility(&lines);

    try std.testing.expect(!lines[4].visible);
    try std.testing.expect(lines[5].visible);
    try std.testing.expect(lines[20].visible);
    try std.testing.expect(lines[35].visible);
    try std.testing.expect(!lines[36].visible);
}

test "merge editor renders distant context folded" {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (0..20) |index_value| {
        try std.fmt.format(content.writer(std.testing.allocator), "before {d}\n", .{index_value});
    }
    try content.appendSlice(std.testing.allocator,
        \\<<<<<<< ours
        \\current
        \\=======
        \\incoming
        \\>>>>>>> theirs
        \\
    );
    for (0..20) |index_value| {
        try std.fmt.format(content.writer(std.testing.allocator), "after {d}\n", .{index_value});
    }

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(std.testing.allocator);
    try appendMergeConflictContent(&html, std.testing.allocator, "zig", content.items);

    try std.testing.expect(std.mem.indexOf(u8, html.items, "data-merge-fold-toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.items, "hidden data-merge-fold-id") != null);
}

test "merge-file conflict counts are treated as generated content" {
    try std.testing.expect(mergeFileProducedContent(0));
    try std.testing.expect(mergeFileProducedContent(1));
    try std.testing.expect(mergeFileProducedContent(2));
    try std.testing.expect(mergeFileProducedContent(127));
    try std.testing.expect(!mergeFileProducedContent(128));
    try std.testing.expect(!mergeFileProducedContent(255));
}

test "merge editor path safety" {
    try std.testing.expect(isSafeMergePath("src/main.zig"));
    try std.testing.expect(!isSafeMergePath("../main.zig"));
    try std.testing.expect(!isSafeMergePath("/tmp/main.zig"));
    try std.testing.expect(!isSafeMergePath("src/.git/config"));
}

test "merge editor accepts only regular git modes" {
    try std.testing.expect(isRegularGitMode("100644"));
    try std.testing.expect(isRegularGitMode("100755"));
    try std.testing.expect(!isRegularGitMode("120000"));
    try std.testing.expect(!isRegularGitMode("040000"));
}

test "merge conflict editor form includes csrf token and expected oids" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var detail = PullDetail{
        .id = try allocator.dupe(u8, "pull-id"),
        .title = try allocator.dupe(u8, "Pull"),
        .state = try allocator.dupe(u8, "open"),
        .author_principal = try allocator.dupe(u8, "alice"),
        .author_device = try allocator.dupe(u8, "laptop"),
        .source_author = try allocator.dupe(u8, "alice"),
        .display_author = try allocator.dupe(u8, "alice"),
        .source_avatar_url = try allocator.dupe(u8, ""),
        .opened_at = try allocator.dupe(u8, "2026-01-01T00:00:00Z"),
        .state_occurred_at = try allocator.dupe(u8, "2026-01-01T00:00:00Z"),
        .state_actor_principal = try allocator.dupe(u8, "alice"),
        .body = try allocator.dupe(u8, ""),
        .base_ref = try allocator.dupe(u8, "target"),
        .head_ref = try allocator.dupe(u8, "feature"),
        .draft = false,
        .merge_oid = try allocator.dupe(u8, ""),
        .target_oid = try allocator.dupe(u8, ""),
        .legacy_number = 0,
        .commit_count = null,
        .changed_files = null,
        .additions = null,
        .deletions = null,
    };
    defer detail.deinit(allocator);

    var snapshot = PullMergeSnapshot{
        .expected_base_oid = try allocator.dupe(u8, "1111111111111111111111111111111111111111"),
        .expected_head_oid = try allocator.dupe(u8, "2222222222222222222222222222222222222222"),
        .base_target = .{
            .remote = try allocator.dupe(u8, "origin"),
            .branch = try allocator.dupe(u8, "target"),
            .remote_ref = try allocator.dupe(u8, "refs/heads/target"),
            .tracking_ref = try allocator.dupe(u8, "refs/remotes/origin/target"),
        },
        .head_target = .{
            .remote = try allocator.dupe(u8, "origin"),
            .branch = try allocator.dupe(u8, "feature"),
            .remote_ref = try allocator.dupe(u8, "refs/heads/feature"),
            .tracking_ref = try allocator.dupe(u8, "refs/remotes/origin/feature"),
        },
    };
    defer snapshot.deinit(allocator);

    var file = MergeConflictFile{
        .path = try allocator.dupe(u8, "conflict.txt"),
        .content = try allocator.dupe(u8, "resolved\n"),
    };
    defer file.deinit(allocator);

    try appendEditor(&buf, allocator, detail, "1", "1", "token-123", snapshot, &.{file}, null);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"_csrf\" value=\"token-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"expected_base_oid\" value=\"1111111111111111111111111111111111111111\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "name=\"expected_head_oid\" value=\"2222222222222222222222222222222222222222\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "action=\"/pulls/1/conflicts\"") != null);
}

test "merge editor rejects symlink tree entries" {
    try std.testing.expect(lsTreeRecordIsRegularFile("100644 blob abcdef\tconflict.txt\x00", "conflict.txt"));
    try std.testing.expect(!lsTreeRecordIsRegularFile("120000 blob abcdef\tconflict.txt\x00", "conflict.txt"));
    try std.testing.expect(!lsTreeRecordIsRegularFile("100644 blob abcdef\tother.txt\x00", "conflict.txt"));
}
