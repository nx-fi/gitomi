const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;
const discoverRepo = repo_mod.discoverRepo;
const writeConfig = repo_mod.writeConfig;
const inboxRef = repo_mod.inboxRef;
const gitChecked = git.gitChecked;
const emptyTreeOid = git.emptyTreeOid;
const prepareEventParents = git.prepareEventParents;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const trimOwned = util.trimOwned;

pub fn createCommentAddedEvent(
    allocator: Allocator,
    parent_kind: []const u8,
    parent_id: []const u8,
    body: []const u8,
) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfigForWrite(allocator, repo) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt comment: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);
    const comment_id = try newUuidV7(allocator);
    defer allocator.free(comment_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    var prepared_parents = try prepareEventParents(allocator, inbox_ref);
    defer prepared_parents.deinit();
    const event_parents = event_mod.EventParents{
        .log = prepared_parents.old_head,
        .causal = prepared_parents.causal_heads,
        .related = if (prepared_parents.old_head) |head| &.{head} else &.{},
    };

    const next_seq = cfg.seq + 1;
    const event_body = try event_mod.buildCommentAddedJson(
        allocator,
        cfg,
        next_seq,
        comment_id,
        event_uuid,
        idem,
        occurred_at,
        event_parents,
        parent_kind,
        parent_id,
        body,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "comment.added #{s}", .{comment_id[0..7]});
    defer allocator.free(subject);
    const commit_oid = try writeSignedCommentEvent(allocator, inbox_ref, subject, event_body, prepared_parents.old_head, prepared_parents.causal_heads);
    defer allocator.free(commit_oid);

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("added comment #{s}\n", .{comment_id[0..7]});
    try out("  id:     {s}\n", .{comment_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
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
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfigForWrite(allocator, repo) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt comment: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);
    var prepared_parents = try prepareEventParents(allocator, inbox_ref);
    defer prepared_parents.deinit();
    const event_parents = event_mod.EventParents{
        .log = prepared_parents.old_head,
        .causal = prepared_parents.causal_heads,
        .related = if (prepared_parents.old_head) |head| &.{head} else &.{},
    };

    const next_seq = cfg.seq + 1;
    const event_body = switch (kind) {
        .body_set => try event_mod.buildCommentBodySetJson(allocator, cfg, next_seq, comment_id, event_uuid, idem, occurred_at, event_parents, body),
        .redacted => try event_mod.buildCommentRedactedJson(allocator, cfg, next_seq, comment_id, event_uuid, idem, occurred_at, event_parents, reason),
    };
    defer allocator.free(event_body);

    const event_type: []const u8 = switch (kind) {
        .body_set => "comment.body_set",
        .redacted => "comment.redacted",
    };
    const subject = try std.fmt.allocPrint(allocator, "{s} #{s}", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    defer allocator.free(subject);
    const commit_oid = try writeSignedCommentEvent(allocator, inbox_ref, subject, event_body, prepared_parents.old_head, prepared_parents.causal_heads);
    defer allocator.free(commit_oid);

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("{s} #{s}\n", .{ event_type, comment_id[0..@min(comment_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
}

fn writeSignedCommentEvent(
    allocator: Allocator,
    inbox_ref: []const u8,
    subject: []const u8,
    event_body: []const u8,
    old_head: ?[]const u8,
    causal_heads: []const []const u8,
) ![]u8 {
    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    var commit_args: std.ArrayList([]const u8) = .empty;
    defer commit_args.deinit(allocator);
    try commit_args.append(allocator, "commit-tree");
    try commit_args.append(allocator, "-S");
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, subject);
    try commit_args.append(allocator, "-m");
    try commit_args.append(allocator, event_body);
    try commit_args.append(allocator, empty_tree);

    if (old_head) |head| {
        try commit_args.append(allocator, "-p");
        try commit_args.append(allocator, head);
        for (causal_heads) |known_head| {
            try commit_args.append(allocator, "-p");
            try commit_args.append(allocator, known_head);
        }
    }

    const commit_raw = gitChecked(allocator, commit_args.items) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt comment: failed to create signed event commit; check Git commit signing configuration\n", .{});
        }
        return err;
    };
    const commit_oid = try trimOwned(allocator, commit_raw);
    errdefer allocator.free(commit_oid);

    if (old_head) |head| {
        const updated = try gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, head });
        defer allocator.free(updated);
    } else {
        const updated = try gitChecked(allocator, &.{ "update-ref", inbox_ref, commit_oid, "" });
        defer allocator.free(updated);
    }
    return commit_oid;
}
