const std = @import("std");
const errors = @import("errors.zig");
const index = @import("index.zig");
const index_query = @import("index/query.zig");
const io = @import("io.zig");
const json_writer = @import("json_writer.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");
const work_items = @import("work_items.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;

pub const CommandRepo = struct {
    allocator: Allocator,
    repo_cache: ?repo_mod.Repo = null,
    index_ready: bool = false,

    pub fn init(allocator: Allocator) CommandRepo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandRepo) void {
        if (self.repo_cache) |*cached_repo| {
            cached_repo.deinit();
        }
        self.repo_cache = null;
        self.index_ready = false;
    }

    pub fn repo(self: *CommandRepo) !repo_mod.Repo {
        if (self.repo_cache == null) {
            self.repo_cache = try repo_mod.discoverRepo(self.allocator);
        }
        return self.repo_cache.?;
    }

    pub fn indexedRepo(self: *CommandRepo) !repo_mod.Repo {
        const cached_repo = try self.repo();
        if (!self.index_ready) {
            try index.ensureIndex(self.allocator, cached_repo);
            self.index_ready = true;
        }
        return cached_repo;
    }

    pub fn resolveIssueId(self: *CommandRepo, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index_query.resolveIssueId(self.allocator, cached_repo, raw_ref);
    }

    pub fn resolveProjectId(self: *CommandRepo, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.resolveProjectId(self.allocator, cached_repo, raw_ref);
    }

    pub fn resolveMilestoneId(self: *CommandRepo, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.resolveMilestoneId(self.allocator, cached_repo, raw_ref);
    }

    pub fn projectName(self: *CommandRepo, project_id: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.projectNameForId(self.allocator, cached_repo, project_id);
    }

    pub fn resolveProjectColumn(self: *CommandRepo, project_id: []const u8, raw_ref: []const u8) !index.ProjectColumnRef {
        const cached_repo = try self.indexedRepo();
        return try index.resolveProjectColumnRef(self.allocator, cached_repo, project_id, raw_ref);
    }

    pub fn resolveProjectFieldId(self: *CommandRepo, project_id: []const u8, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.resolveProjectFieldId(self.allocator, cached_repo, project_id, raw_ref);
    }

    pub fn resolveProjectFieldOptionId(self: *CommandRepo, project_id: []const u8, field_id: []const u8, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.resolveProjectFieldOptionId(self.allocator, cached_repo, project_id, field_id, raw_ref);
    }

    pub fn resolveProjectViewId(self: *CommandRepo, project_id: []const u8, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index.resolveProjectViewId(self.allocator, cached_repo, project_id, raw_ref);
    }

    pub fn resolvePullId(self: *CommandRepo, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index_query.resolvePullId(self.allocator, cached_repo, raw_ref);
    }

    pub fn resolveCommentId(self: *CommandRepo, raw_ref: []const u8) ![]u8 {
        const cached_repo = try self.indexedRepo();
        return try index_query.resolveCommentId(self.allocator, cached_repo, raw_ref);
    }

    pub fn commentParent(self: *CommandRepo, comment_id: []const u8) !index.CommentParentInfo {
        const cached_repo = try self.indexedRepo();
        return try index_query.commentParentInfo(self.allocator, cached_repo, comment_id);
    }
};

pub fn resolveIssueIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveIssueId(raw_ref);
}

pub fn resolveProjectIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveProjectId(raw_ref);
}

pub fn resolveMilestoneIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveMilestoneId(raw_ref);
}

pub fn projectNameForCommand(allocator: Allocator, project_id: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.projectName(project_id);
}

pub fn resolveProjectColumnForCommand(allocator: Allocator, project_id: []const u8, raw_ref: []const u8) !index.ProjectColumnRef {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveProjectColumn(project_id, raw_ref);
}

pub fn resolveProjectFieldIdForCommand(allocator: Allocator, project_id: []const u8, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveProjectFieldId(project_id, raw_ref);
}

pub fn resolveProjectFieldOptionIdForCommand(allocator: Allocator, project_id: []const u8, field_id: []const u8, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveProjectFieldOptionId(project_id, field_id, raw_ref);
}

pub fn resolveProjectViewIdForCommand(allocator: Allocator, project_id: []const u8, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveProjectViewId(project_id, raw_ref);
}

pub fn resolvePullIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolvePullId(raw_ref);
}

pub fn resolveCommentIdForCommand(allocator: Allocator, raw_ref: []const u8) ![]u8 {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.resolveCommentId(raw_ref);
}

pub fn commentParentForCommand(allocator: Allocator, comment_id: []const u8) !index.CommentParentInfo {
    var command_repo = CommandRepo.init(allocator);
    defer command_repo.deinit();
    return try command_repo.commentParent(comment_id);
}

pub fn requireNonEmptyOption(context: []const u8, option: []const u8, value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len != 0) return;
    try io.eprint("{s}: {s} must not be empty\n", .{ context, option });
    return CliError.UserError;
}

pub const BodyReplyOptions = struct {
    body: ?[]const u8 = null,
    reply_ref: ?[]const u8 = null,
};

pub fn parseBodyReplyOptions(context: []const u8, args: []const []const u8, start: usize) !BodyReplyOptions {
    var options = BodyReplyOptions{};
    var i: usize = start;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "-b")) {
            options.body = try util.requireValue(args, &i, "--body");
        } else if (std.mem.eql(u8, arg, "--reply")) {
            options.reply_ref = try util.requireValue(args, &i, "--reply");
        } else {
            try io.eprint("{s}: unknown option '{s}'\n", .{ context, arg });
            return CliError.UserError;
        }
    }
    return options;
}

pub fn requireBodyOption(context: []const u8, body: ?[]const u8) ![]const u8 {
    if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
        try io.eprint("{s}: --body is required\n", .{context});
        return CliError.UserError;
    }
    return body.?;
}

pub fn dupeNonEmptyOption(allocator: Allocator, context: []const u8, option: []const u8, value: []const u8) ![]u8 {
    try requireNonEmptyOption(context, option, value);
    return try allocator.dupe(u8, std.mem.trim(u8, value, " \t\r\n"));
}

pub fn parsePositiveIntegerOption(context: []const u8, option: []const u8, raw: []const u8) !usize {
    return parsePositiveOption(context, option, raw, "integer");
}

fn parsePositiveOption(context: []const u8, option: []const u8, raw: []const u8, label: []const u8) !usize {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch {
        try io.eprint("{s}: {s} must be a positive {s}\n", .{ context, option, label });
        return CliError.UserError;
    };
    if (parsed == 0) {
        try io.eprint("{s}: {s} must be a positive {s}\n", .{ context, option, label });
        return CliError.UserError;
    }
    return parsed;
}

pub fn parseNonNegativeIntegerOption(context: []const u8, option: []const u8, raw: []const u8) !i64 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const parsed = std.fmt.parseInt(i64, value, 10) catch {
        try io.eprint("{s}: {s} must be a non-negative integer\n", .{ context, option });
        return CliError.UserError;
    };
    if (parsed < 0) {
        try io.eprint("{s}: {s} must be a non-negative integer\n", .{ context, option });
        return CliError.UserError;
    }
    return parsed;
}

pub fn parseBoolOption(context: []const u8, option: []const u8, raw: []const u8) !bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    try io.eprint("{s}: {s} must be true or false\n", .{ context, option });
    return CliError.UserError;
}

pub fn validateJsonArgument(allocator: Allocator, context: []const u8, option: []const u8, raw_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch {
        try io.eprint("{s}: {s} must be valid JSON\n", .{ context, option });
        return CliError.UserError;
    };
    defer parsed.deinit();
}

pub fn jsonStringArgument(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try json_writer.appendJsonString(&buf, allocator, value);
    return try buf.toOwnedSlice(allocator);
}

pub const PullDiffCommentOptions = struct {
    file: ?[]const u8 = null,
    side: ?[]const u8 = null,
    line: ?usize = null,
    start_line: ?usize = null,
    end_line: ?usize = null,
    line_option_seen: bool = false,
    start_line_option_seen: bool = false,
    end_line_option_seen: bool = false,

    pub fn hasAny(self: PullDiffCommentOptions) bool {
        return self.file != null or
            self.side != null or
            self.line_option_seen or
            self.start_line_option_seen or
            self.end_line_option_seen;
    }
};

pub fn parsePositiveLineOption(context: []const u8, option: []const u8, raw: []const u8) !usize {
    return parsePositiveOption(context, option, raw, "line number");
}

pub fn formatPullDiffCommentBodyFromOptions(
    allocator: Allocator,
    context: []const u8,
    body: []const u8,
    options: PullDiffCommentOptions,
) !?[]u8 {
    if (!options.hasAny()) return null;
    if (options.file == null or options.side == null) {
        try io.eprint("{s}: diff comments require --file and --side\n", .{context});
        return CliError.UserError;
    }

    const file = std.mem.trim(u8, options.file.?, " \t\r\n");
    if (!work_items.validateDiffCommentPath(file)) {
        try io.eprint("{s}: --file must be a non-empty single-line path\n", .{context});
        return CliError.UserError;
    }

    const side = std.mem.trim(u8, options.side.?, " \t\r\n");
    if (!std.mem.eql(u8, side, "old") and !std.mem.eql(u8, side, "new")) {
        try io.eprint("{s}: --side must be old or new\n", .{context});
        return CliError.UserError;
    }

    var start_line: usize = 0;
    var end_line: usize = 0;
    if (options.line_option_seen) {
        if (options.start_line_option_seen or options.end_line_option_seen) {
            try io.eprint("{s}: --line cannot be combined with --start-line or --end-line\n", .{context});
            return CliError.UserError;
        }
        start_line = options.line.?;
        end_line = options.line.?;
    } else {
        if (!options.start_line_option_seen) {
            try io.eprint("{s}: diff comments require --line or --start-line\n", .{context});
            return CliError.UserError;
        }
        start_line = options.start_line.?;
        end_line = if (options.end_line_option_seen) options.end_line.? else start_line;
    }

    if (end_line < start_line) {
        try io.eprint("{s}: --end-line must be greater than or equal to --start-line\n", .{context});
        return CliError.UserError;
    }

    return try work_items.formatDiffCommentBody(allocator, .{
        .file = file,
        .side = if (std.mem.eql(u8, side, "old")) .old else .new,
        .start_line = start_line,
        .end_line = end_line,
    }, body);
}

pub fn appendCollectionOptionValues(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    context: []const u8,
    option: []const u8,
    value: []const u8,
) !void {
    var fields = try util.splitCommaFields(allocator, value);
    defer fields.deinit(allocator);
    if (fields.items.len == 0) {
        try io.eprint("{s}: {s} must not be empty\n", .{ context, option });
        return CliError.UserError;
    }
    for (fields.items) |field| try list.append(allocator, field);
}

pub const CollectionMutation = struct {
    object_ref: []const u8,
    op: []const u8,
};

pub fn parseCollectionMutation(context: []const u8, collection: []const u8, first: []const u8, second: []const u8) !CollectionMutation {
    if (std.mem.eql(u8, second, "add") or std.mem.eql(u8, second, "remove")) {
        return .{ .object_ref = first, .op = second };
    }
    if (std.mem.eql(u8, first, "add") or std.mem.eql(u8, first, "remove")) {
        return .{ .object_ref = second, .op = first };
    }
    try io.eprint("{s} {s}: expected add or remove\n", .{ context, collection });
    return CliError.UserError;
}

pub fn isIssueState(value: []const u8) bool {
    return std.mem.eql(u8, value, "open") or std.mem.eql(u8, value, "closed");
}

pub fn isIssuePriority(value: []const u8) bool {
    return std.mem.eql(u8, value, "P0") or
        std.mem.eql(u8, value, "P1") or
        std.mem.eql(u8, value, "P2") or
        std.mem.eql(u8, value, "P3");
}

pub fn isIssueStatus(value: []const u8) bool {
    return std.mem.eql(u8, value, "Draft") or
        std.mem.eql(u8, value, "Pending") or
        std.mem.eql(u8, value, "WIP") or
        std.mem.eql(u8, value, "Review") or
        std.mem.eql(u8, value, "Done") or
        std.mem.eql(u8, value, "Failed");
}

pub fn isProjectState(value: []const u8) bool {
    return std.mem.eql(u8, value, "open") or std.mem.eql(u8, value, "closed");
}

pub fn isProjectItemState(value: []const u8) bool {
    return std.mem.eql(u8, value, "active") or std.mem.eql(u8, value, "removed");
}

pub fn isProjectFieldType(value: []const u8) bool {
    return std.mem.eql(u8, value, "text") or
        std.mem.eql(u8, value, "number") or
        std.mem.eql(u8, value, "date") or
        std.mem.eql(u8, value, "boolean") or
        std.mem.eql(u8, value, "single_select") or
        std.mem.eql(u8, value, "multi_select") or
        std.mem.eql(u8, value, "user") or
        std.mem.eql(u8, value, "issue_ref");
}

pub fn isProjectViewLayout(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or
        std.mem.eql(u8, value, "board") or
        std.mem.eql(u8, value, "roadmap");
}
