const std = @import("std");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const io = @import("io.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;
const gitChecked = git.gitChecked;
const listRefs = git.listRefs;
const freeStringList = git.freeStringList;
const emptyTreeOid = git.emptyTreeOid;
const resolveOptionalRef = git.resolveOptionalRef;
const revListRange = git.revListRange;
const isAncestor = git.isAncestor;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const sanitizeRefSegment = util.sanitizeRefSegment;
const validateEventEnvelope = event_mod.validateEventEnvelope;

pub fn syncPull(allocator: Allocator, remote: []const u8) !void {
    const remote_segment = try stagingRemoteSegment(allocator, remote);
    defer allocator.free(remote_segment);
    const staging_prefix = try std.fmt.allocPrint(allocator, "refs/gitomi/staging/{s}", .{remote_segment});
    defer allocator.free(staging_prefix);
    const fetch_refspec = try std.fmt.allocPrint(allocator, "+refs/gitomi/inbox/*:{s}/inbox/*", .{staging_prefix});
    defer allocator.free(fetch_refspec);

    try out("fetching Gitomi inbox refs from {s} into {s}\n", .{ remote, staging_prefix });
    const fetched = try gitChecked(allocator, &.{ "fetch", remote, fetch_refspec });
    defer allocator.free(fetched);
    if (fetched.len != 0) try out("{s}", .{fetched});

    try admitStagedInboxRefs(allocator, staging_prefix);
}

pub fn syncPush(allocator: Allocator, remote: []const u8) !void {
    const refs = try listRefs(allocator, "refs/gitomi/inbox");
    defer freeStringList(allocator, refs);

    if (refs.len == 0) {
        try out("no local Gitomi inbox refs to push\n", .{});
        return;
    }

    var push_args: std.ArrayList([]const u8) = .empty;
    defer push_args.deinit(allocator);
    var refspecs: std.ArrayList([]u8) = .empty;
    defer {
        for (refspecs.items) |refspec| allocator.free(refspec);
        refspecs.deinit(allocator);
    }

    try push_args.append(allocator, "push");
    try push_args.append(allocator, remote);
    for (refs) |ref| {
        const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, ref });
        try refspecs.append(allocator, refspec);
        try push_args.append(allocator, refspec);
    }

    try out("pushing {d} Gitomi inbox ref{s} to {s}\n", .{ refs.len, if (refs.len == 1) "" else "s", remote });
    const pushed = try gitChecked(allocator, push_args.items);
    defer allocator.free(pushed);
    if (pushed.len != 0) try out("{s}", .{pushed});
}

pub fn stagingRemoteSegment(allocator: Allocator, remote: []const u8) ![]u8 {
    const segment = try sanitizeRefSegment(allocator, remote);
    if (segment.len != 0) return segment;
    allocator.free(segment);
    return allocator.dupe(u8, "remote");
}

pub fn admitStagedInboxRefs(allocator: Allocator, staging_prefix: []const u8) !void {
    const staged_inbox_prefix = try std.fmt.allocPrint(allocator, "{s}/inbox", .{staging_prefix});
    defer allocator.free(staged_inbox_prefix);

    const refs = try listRefs(allocator, staged_inbox_prefix);
    defer freeStringList(allocator, refs);

    if (refs.len == 0) {
        try out("no staged Gitomi inbox refs to admit\n", .{});
        return;
    }

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |staged_ref| {
        try admitStagedInboxRef(allocator, staging_prefix, staged_ref, empty_tree);
    }
}

pub fn admitStagedInboxRef(
    allocator: Allocator,
    staging_prefix: []const u8,
    staged_ref: []const u8,
    empty_tree: []const u8,
) !void {
    const staged_oid = (try resolveOptionalRef(allocator, staged_ref)) orelse return;
    defer allocator.free(staged_oid);

    const local_ref = try localRefFromStaged(allocator, staging_prefix, staged_ref);
    defer allocator.free(local_ref);

    const local_oid = try resolveOptionalRef(allocator, local_ref);
    defer if (local_oid) |oid| allocator.free(oid);

    if (local_oid) |old_oid| {
        if (std.mem.eql(u8, old_oid, staged_oid)) {
            try out("unchanged {s}\n", .{local_ref});
            return;
        }

        if (try isAncestor(allocator, old_oid, staged_oid)) {
            const admitted = try validateInboxRange(allocator, staged_ref, old_oid, empty_tree);
            const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, old_oid });
            defer allocator.free(updated);
            try out("fast-forwarded {s} by {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
            return;
        }

        if (try isAncestor(allocator, staged_oid, old_oid)) {
            try out("stale remote {s}; local ref is ahead\n", .{local_ref});
            return;
        }

        try out("diverged {s}; staged ref left at {s}\n", .{ local_ref, staged_ref });
        return;
    }

    const admitted = try validateInboxRange(allocator, staged_ref, null, empty_tree);
    const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, "" });
    defer allocator.free(updated);
    try out("created {s} with {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
}

pub fn localRefFromStaged(allocator: Allocator, staging_prefix: []const u8, staged_ref: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, staged_ref, staging_prefix) or staged_ref.len <= staging_prefix.len or staged_ref[staging_prefix.len] != '/') {
        try eprint("gt sync: staged ref {s} is outside {s}\n", .{ staged_ref, staging_prefix });
        return CliError.UserError;
    }
    const suffix = staged_ref[staging_prefix.len + 1 ..];
    if (!std.mem.startsWith(u8, suffix, "inbox/")) {
        try eprint("gt sync: refusing to admit non-inbox staged ref {s}\n", .{staged_ref});
        return CliError.UserError;
    }
    return std.fmt.allocPrint(allocator, "refs/gitomi/{s}", .{suffix});
}

pub fn validateInboxRange(
    allocator: Allocator,
    ref: []const u8,
    local_base: ?[]const u8,
    empty_tree: []const u8,
) !usize {
    const commits = if (local_base) |base|
        try revListRange(allocator, base, ref)
    else
        try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", ref });
    defer allocator.free(commits);

    var count: usize = 0;
    var expected_first_parent = local_base;
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try validateInboxCommit(allocator, commit, expected_first_parent, empty_tree);
        expected_first_parent = commit;
        count += 1;
    }
    return count;
}

pub fn validateInboxCommit(
    allocator: Allocator,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !void {
    const tree_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%T", commit });
    defer allocator.free(tree_raw);
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");
    if (!std.mem.eql(u8, tree, empty_tree)) {
        try eprint("gt sync: rejecting {s}: inbox event does not use the empty tree\n", .{commit});
        return CliError.UserError;
    }

    try validateFirstParent(allocator, commit, expected_first_parent);
    try verifyCommitSignature(allocator, commit);

    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    try validateEventEnvelope(allocator, commit, body);
}

pub fn validateFirstParent(allocator: Allocator, commit: []const u8, expected_first_parent: ?[]const u8) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    const first_parent = it.next();

    if (expected_first_parent) |expected| {
        if (first_parent == null or !std.mem.eql(u8, first_parent.?, expected)) {
            try eprint("gt sync: rejecting {s}: first parent is not the previous inbox head\n", .{commit});
            return CliError.UserError;
        }
    } else if (first_parent != null) {
        try eprint("gt sync: rejecting {s}: root inbox event has a first parent\n", .{commit});
        return CliError.UserError;
    }
}

pub fn verifyCommitSignature(allocator: Allocator, commit: []const u8) !void {
    var argv = [_][]const u8{ "git", "verify-commit", commit };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return;

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try eprint("gt sync: rejecting {s}: signature verification failed: {s}\n", .{ commit, stderr });
    } else {
        try eprint("gt sync: rejecting {s}: signature verification failed\n", .{commit});
    }
    return CliError.UserError;
}

test "staged refs map back to authoritative inbox refs" {
    const local_ref = try localRefFromStaged(
        std.testing.allocator,
        "refs/gitomi/staging/origin",
        "refs/gitomi/staging/origin/inbox/alice/laptop",
    );
    defer std.testing.allocator.free(local_ref);
    try std.testing.expectEqualStrings("refs/gitomi/inbox/alice/laptop", local_ref);
}
