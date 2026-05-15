const std = @import("std");
const cmd_common = @import("cmd_common.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const event_writer_mod = @import("event_writer.zig");
const git = @import("git.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const reaction = @import("reaction.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const comment = @This();
const out = io.out;
const eprint = io.eprint;
const EventWriter = event_writer_mod.EventWriter;
const commentParentForCommand = cmd_common.commentParentForCommand;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const resolveCommentIdForCommand = cmd_common.resolveCommentIdForCommand;
const resolveIssueIdForCommand = cmd_common.resolveIssueIdForCommand;
const resolvePullIdForCommand = cmd_common.resolvePullIdForCommand;
const shortObjectRef = util.shortObjectRef;
const short_object_ref_len = util.short_object_ref_len;

pub fn createCommentAddedEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) !void {
    try createCommentAddedEventWithMetadata(allocator, parent_kind, parent_id, body, .{});
}

pub fn createCommentReplyEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    reply_parent_id: []const u8,
    reply_parent_hash: []const u8,
    body: []const u8,
) !void {
    try createCommentAddedEventWithMetadata(allocator, parent_kind, parent_id, body, .{
        .reply_parent_id = if (reply_parent_id.len == 0) null else reply_parent_id,
        .reply_parent_hash = if (reply_parent_hash.len == 0) null else reply_parent_hash,
    });
}

pub fn createCommentAddedEventWithMetadata(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
    metadata: event_mod.CommentAddedMetadata,
) !void {
    var writer = try EventWriter.init(allocator, "gt comment");
    defer writer.deinit();

    const comment_id = try newUuidV7(allocator);
    defer allocator.free(comment_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    var related: std.ArrayList([]const u8) = .empty;
    defer related.deinit(allocator);
    try related.appendSlice(allocator, writer.related_heads);
    if (metadata.reply_parent_hash) |hash| {
        if (hash.len != 0 and !git.containsString(related.items, hash)) try related.append(allocator, hash);
    }
    const event_parents = event_mod.EventParents{
        .log = writer.prepared_parents.old_head,
        .causal = writer.prepared_parents.causal_heads,
        .related = related.items,
    };

    const event_body = try event_mod.buildCommentAddedJsonWithMetadata(
        allocator,
        writer.cfg,
        writer.nextSeq(),
        comment_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        parent_kind,
        parent_id,
        body,
        metadata,
    );
    defer allocator.free(event_body);

    var comment_ref_buf: [short_object_ref_len]u8 = undefined;
    const comment_ref = shortObjectRef(&comment_ref_buf, comment_id);
    const subject = try std.fmt.allocPrint(allocator, "comment.added comment:{s}", .{comment_ref});
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt comment", subject, event_body);
    defer allocator.free(commit_oid);

    try out("added comment comment:{s}\n", .{comment_ref});
    try out("  id:     {s}\n", .{comment_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createCommentBodySetEvent(allocator: Allocator, comment_id: []const u8, body: []const u8) !void {
    try createCommentUpdateEvent(allocator, comment_id, body, null, .body_set);
}

pub fn createCommentRedactedEvent(allocator: Allocator, comment_id: []const u8, reason: ?[]const u8) !void {
    try createCommentUpdateEvent(allocator, comment_id, "", reason, .redacted);
}

const CommentUpdateKind = enum {
    body_set,
    redacted,
};

fn createCommentUpdateEvent(
    allocator: Allocator,
    comment_id: []const u8,
    body: []const u8,
    reason: ?[]const u8,
    kind: CommentUpdateKind,
) !void {
    var writer = try EventWriter.init(allocator, "gt comment");
    defer writer.deinit();

    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    const event_parents = writer.eventParents();

    const event_body = switch (kind) {
        .body_set => try event_mod.buildCommentBodySetJson(allocator, writer.cfg, writer.nextSeq(), comment_id, event_uuid, idem, occurred_at, event_parents, body),
        .redacted => try event_mod.buildCommentRedactedJson(allocator, writer.cfg, writer.nextSeq(), comment_id, event_uuid, idem, occurred_at, event_parents, reason),
    };
    defer allocator.free(event_body);

    const event_type: []const u8 = switch (kind) {
        .body_set => "comment.body_set",
        .redacted => "comment.redacted",
    };
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writer.write("gt comment", subject, event_body);
    defer allocator.free(commit_oid);

    try out("{s} #{s}\n", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{writer.inbox_ref});
}

pub fn createCommentForParentCommand(
    allocator: Allocator,
    context: []const u8,
    parent_kind: []const u8,
    parent_label: []const u8,
    parent_id: []const u8,
    body: []const u8,
    reply_ref: ?[]const u8,
) !void {
    if (reply_ref) |raw_ref| {
        const reply_target = std.mem.trim(u8, raw_ref, " \t\r\n");
        if (reply_target.len == 0) {
            try io.eprint("{s}: --reply must not be empty\n", .{context});
            return CliError.UserError;
        }
        const reply_parent_id = try resolveCommentIdForCommand(allocator, reply_target);
        defer allocator.free(reply_parent_id);
        var reply_parent = try commentParentForCommand(allocator, reply_parent_id);
        defer reply_parent.deinit();
        if (!std.mem.eql(u8, reply_parent.parent_kind, parent_kind) or !std.mem.eql(u8, reply_parent.parent_id, parent_id)) {
            try io.eprint("{s}: reply target is not in this {s}\n", .{ context, parent_label });
            return CliError.UserError;
        }
        try comment.createCommentReplyEvent(allocator, parent_kind, parent_id, reply_parent_id, reply_parent.add_hash, body);
        return;
    }

    try comment.createCommentAddedEvent(allocator, parent_kind, parent_id, body);
}

fn isCommentParentKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "issue") or std.mem.eql(u8, value, "pr") or std.mem.eql(u8, value, "pull");
}

fn canonicalCommentParentKind(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "pr")) "pull" else value;
}

pub fn cmdComment(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try io.eprint("gt comment: expected subcommand 'list', 'add', 'reply', 'edit', 'redact', 'react', or 'unreact'\n", .{});
        return CliError.UserError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len < 3 or (!isCommentParentKind(args[1]))) {
            try io.eprint("gt comment list: expected issue ISSUE or pr PR [--json]\n", .{});
            return CliError.UserError;
        }
        const parent_kind = canonicalCommentParentKind(args[1]);
        var json = false;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--json")) {
                json = true;
            } else {
                try io.eprint("gt comment list: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const parent_id = if (std.mem.eql(u8, parent_kind, "issue"))
            try resolveIssueIdForCommand(allocator, args[2])
        else
            try resolvePullIdForCommand(allocator, args[2]);
        defer allocator.free(parent_id);
        var repo = try repo_mod.discoverRepo(allocator);
        defer repo.deinit();
        try index.ensureIndex(allocator, repo);
        try index.listCommentsFromIndex(allocator, repo, parent_kind, parent_id, json);
        return;
    }

    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 3 or (!isCommentParentKind(args[1]))) {
            try io.eprint("gt comment add: expected issue ISSUE or pr PR --body BODY\n", .{});
            return CliError.UserError;
        }
        const parent_kind = canonicalCommentParentKind(args[1]);
        var body: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt comment add: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("gt comment add: --body is required\n", .{});
            return CliError.UserError;
        }
        const parent_id = if (std.mem.eql(u8, parent_kind, "issue"))
            try resolveIssueIdForCommand(allocator, args[2])
        else
            try resolvePullIdForCommand(allocator, args[2]);
        defer allocator.free(parent_id);
        try comment.createCommentAddedEvent(allocator, parent_kind, parent_id, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "reply")) {
        if (args.len < 2) {
            try io.eprint("gt comment reply: COMMENT is required\n", .{});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt comment reply: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("gt comment reply: --body is required\n", .{});
            return CliError.UserError;
        }
        const reply_parent_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(reply_parent_id);
        var reply_parent = try commentParentForCommand(allocator, reply_parent_id);
        defer reply_parent.deinit();
        try comment.createCommentReplyEvent(allocator, reply_parent.parent_kind, reply_parent.parent_id, reply_parent_id, reply_parent.add_hash, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "edit")) {
        if (args.len < 2) {
            try io.eprint("gt comment edit: COMMENT is required\n", .{});
            return CliError.UserError;
        }
        var body: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
                body = try util.requireValue(args, &i, "--body");
            } else {
                try io.eprint("gt comment edit: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        if (body == null or std.mem.trim(u8, body.?, " \t\r\n").len == 0) {
            try io.eprint("gt comment edit: --body is required\n", .{});
            return CliError.UserError;
        }
        const comment_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(comment_id);
        try comment.createCommentBodySetEvent(allocator, comment_id, body.?);
        return;
    }

    if (std.mem.eql(u8, args[0], "redact")) {
        if (args.len < 2) {
            try io.eprint("gt comment redact: COMMENT is required\n", .{});
            return CliError.UserError;
        }
        var reason: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--reason")) {
                reason = try util.requireValue(args, &i, "--reason");
            } else {
                try io.eprint("gt comment redact: unknown option '{s}'\n", .{args[i]});
                return CliError.UserError;
            }
        }
        const comment_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(comment_id);
        try comment.createCommentRedactedEvent(allocator, comment_id, reason);
        return;
    }

    if (std.mem.eql(u8, args[0], "react") or std.mem.eql(u8, args[0], "unreact")) {
        if (args.len != 3) {
            try io.eprint("gt comment {s}: expected COMMENT EMOJI\n", .{args[0]});
            return CliError.UserError;
        }
        const comment_id = try resolveCommentIdForCommand(allocator, args[1]);
        defer allocator.free(comment_id);
        try reaction.createReactionEvent(allocator, "comment", comment_id, args[2], std.mem.eql(u8, args[0], "react"));
        return;
    }

    try io.eprint("gt comment: expected subcommand 'list', 'add', 'reply', 'edit', 'redact', 'react', or 'unreact'\n", .{});
    return CliError.UserError;
}
