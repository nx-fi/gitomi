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
const loadConfig = repo_mod.loadConfig;
const writeConfig = repo_mod.writeConfig;
const inboxRef = repo_mod.inboxRef;
const gitChecked = git.gitChecked;
const emptyTreeOid = git.emptyTreeOid;
const resolveOptionalRef = git.resolveOptionalRef;
const inboxHeads = git.inboxHeads;
const freeStringList = git.freeStringList;
const newUuidV7 = util.newUuidV7;
const rfc3339Now = util.rfc3339Now;
const trimOwned = util.trimOwned;

pub fn createPullOpenedEvent(
    allocator: Allocator,
    title: []const u8,
    body: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    draft: bool,
) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt pull open: Gitomi is not initialized; run `gt init`\n", .{});
            return CliError.UserError;
        },
        else => return err,
    };
    defer cfg.deinit();

    const inbox_ref = try inboxRef(allocator, cfg);
    defer allocator.free(inbox_ref);
    const pull_id = try newUuidV7(allocator);
    defer allocator.free(pull_id);
    const event_uuid = try newUuidV7(allocator);
    defer allocator.free(event_uuid);
    const idem = try newUuidV7(allocator);
    defer allocator.free(idem);
    const occurred_at = try rfc3339Now(allocator);
    defer allocator.free(occurred_at);

    const next_seq = cfg.seq + 1;
    const event_body = try event_mod.buildPullOpenedJson(
        allocator,
        cfg,
        next_seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        title,
        body,
        base_ref,
        head_ref,
        draft,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "pull.opened #{s} {s}", .{ pull_id[0..7], title });
    defer allocator.free(subject);
    const commit_oid = try writeSignedPullEvent(allocator, inbox_ref, subject, event_body);
    defer allocator.free(commit_oid);

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("opened pull #{s}\n", .{pull_id[0..7]});
    try out("  id:     {s}\n", .{pull_id});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
}

pub fn createPullStringEvent(
    allocator: Allocator,
    pull_id: []const u8,
    event_type: []const u8,
    payload_key: []const u8,
    payload_value: []const u8,
) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt pull: Gitomi is not initialized; run `gt init`\n", .{});
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

    const next_seq = cfg.seq + 1;
    const event_body = try event_mod.buildPullStringPayloadJson(
        allocator,
        cfg,
        next_seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        event_type,
        payload_key,
        payload_value,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "{s} #{s} {s}", .{ event_type, pull_id[0..@min(pull_id.len, 7)], payload_value });
    defer allocator.free(subject);
    const commit_oid = try writeSignedPullEvent(allocator, inbox_ref, subject, event_body);
    defer allocator.free(commit_oid);

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("{s} #{s}\n", .{ event_type, pull_id[0..@min(pull_id.len, 7)] });
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
}

pub fn createPullMergedEvent(
    allocator: Allocator,
    pull_id: []const u8,
    merge_oid: ?[]const u8,
    target_oid: ?[]const u8,
) !void {
    var repo = try discoverRepo(allocator);
    defer repo.deinit();

    var cfg = loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            try eprint("gt pull: Gitomi is not initialized; run `gt init`\n", .{});
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

    const next_seq = cfg.seq + 1;
    const event_body = try event_mod.buildPullMergedJson(
        allocator,
        cfg,
        next_seq,
        pull_id,
        event_uuid,
        idem,
        occurred_at,
        merge_oid,
        target_oid,
    );
    defer allocator.free(event_body);

    const subject = try std.fmt.allocPrint(allocator, "pull.merged #{s}", .{pull_id[0..@min(pull_id.len, 7)]});
    defer allocator.free(subject);
    const commit_oid = try writeSignedPullEvent(allocator, inbox_ref, subject, event_body);
    defer allocator.free(commit_oid);

    cfg.seq = next_seq;
    try writeConfig(repo.config_path, cfg);

    try out("pull.merged #{s}\n", .{pull_id[0..@min(pull_id.len, 7)]});
    try out("  commit: {s}\n", .{commit_oid});
    try out("  ref:    {s}\n", .{inbox_ref});
}

fn writeSignedPullEvent(
    allocator: Allocator,
    inbox_ref: []const u8,
    subject: []const u8,
    event_body: []const u8,
) ![]u8 {
    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);
    const old_head = try resolveOptionalRef(allocator, inbox_ref);
    defer if (old_head) |head| allocator.free(head);
    const all_heads = try inboxHeads(allocator);
    defer freeStringList(allocator, all_heads);

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
        for (all_heads) |known_head| {
            if (std.mem.eql(u8, known_head, head)) continue;
            try commit_args.append(allocator, "-p");
            try commit_args.append(allocator, known_head);
        }
    }

    const commit_raw = gitChecked(allocator, commit_args.items) catch |err| {
        if (err == CliError.GitFailed) {
            try eprint("gt pull: failed to create signed event commit; check Git commit signing configuration\n", .{});
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
