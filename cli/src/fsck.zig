const std = @import("std");
const auth_binding = @import("auth_binding.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const gitChecked = git.gitChecked;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const isRefSafeSegment = util.isRefSafeSegment;
const looksLikeUuid = util.looksLikeUuid;
const eprint = @import("io.zig").eprint;
const Envelope = event_mod.ValidatedEnvelope;

pub const State = struct {
    allocator: Allocator,
    config_repo_id: ?[]const u8,
    observed_repo_id: ?[]u8 = null,
    actor_seqs: event_mod.ActorSeqAdmissionTracker,
    refs: usize = 0,
    commits: usize = 0,
    errors: usize = 0,

    pub fn init(allocator: Allocator, config_repo_id: ?[]const u8) State {
        return .{
            .allocator = allocator,
            .config_repo_id = config_repo_id,
            .actor_seqs = event_mod.ActorSeqAdmissionTracker.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.observed_repo_id) |repo_id| self.allocator.free(repo_id);
        self.actor_seqs.deinit();
    }

    pub fn fail(self: *State, comptime fmt: []const u8, args: anytype) !void {
        self.errors += 1;
        try eprint("error: " ++ fmt ++ "\n", args);
    }

    fn checkRepoId(self: *State, commit: []const u8, repo_id: []const u8) !void {
        if (self.config_repo_id) |expected| {
            if (!std.mem.eql(u8, repo_id, expected)) {
                try self.fail("{s}: repo_id {s} does not match config repo_id {s}", .{ commit, repo_id, expected });
            }
            return;
        }

        if (self.observed_repo_id) |expected| {
            if (!std.mem.eql(u8, repo_id, expected)) {
                try self.fail("{s}: repo_id {s} does not match repository repo_id {s}", .{ commit, repo_id, expected });
            }
        } else {
            self.observed_repo_id = try self.allocator.dupe(u8, repo_id);
        }
    }

    fn checkActorSeq(self: *State, commit: []const u8, principal: []const u8, device: []const u8, seq: i64) !void {
        switch (try self.actor_seqs.accept(principal, device, seq)) {
            .accepted => {},
            .duplicate => try self.fail("{s}: duplicate actor sequence ({s}, {s}, {d})", .{ commit, principal, device, seq }),
            .stale => |previous| try self.fail("{s}: actor sequence ({s}, {s}, {d}) is not strictly greater than previous sequence {d}", .{ commit, principal, device, seq, previous }),
        }
    }
};

pub fn checkInboxRef(allocator: Allocator, fsck: *State, auth_verifier: ?*auth_binding.Verifier, ref: []const u8, empty_tree: []const u8, genesis_oid: []const u8) !void {
    fsck.refs += 1;
    try checkInboxRefName(fsck, ref);

    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ genesis_oid, ref });
    defer allocator.free(range);
    const commits = try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", range });
    defer allocator.free(commits);

    var expected_first_parent: ?[]const u8 = genesis_oid;
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try checkInboxCommit(allocator, fsck, auth_verifier, ref, commit, expected_first_parent, empty_tree);
        expected_first_parent = commit;
    }
}

pub fn checkInboxRefName(fsck: *State, ref: []const u8) !void {
    const prefix = "refs/gitomi/inbox/";
    if (!std.mem.startsWith(u8, ref, prefix)) {
        try fsck.fail("{s}: inbox ref is outside {s}", .{ ref, prefix });
        return;
    }

    const suffix = ref[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse {
        try fsck.fail("{s}: inbox ref must be refs/gitomi/inbox/<principal>/<device>", .{ref});
        return;
    };
    const principal = suffix[0..slash];
    const device = suffix[slash + 1 ..];

    if (std.mem.indexOfScalar(u8, device, '/') != null) {
        try fsck.fail("{s}: inbox ref has extra path segments", .{ref});
    }
    if (!isRefSafeSegment(principal)) {
        try fsck.fail("{s}: principal segment is not ref-safe", .{ref});
    }
    if (!isRefSafeSegment(device)) {
        try fsck.fail("{s}: device segment is not ref-safe", .{ref});
    }
}

fn checkInboxCommit(
    allocator: Allocator,
    fsck: *State,
    auth_verifier: ?*auth_binding.Verifier,
    ref: []const u8,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !void {
    fsck.commits += 1;

    const tree_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%T", commit });
    defer allocator.free(tree_raw);
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");
    if (!std.mem.eql(u8, tree, empty_tree)) {
        try fsck.fail("{s}: {s}: inbox event does not use the empty tree", .{ ref, commit });
    }

    try checkFirstParent(allocator, fsck, ref, commit, expected_first_parent);
    try verifyCommitSignature(allocator, fsck, ref, commit);

    const subject_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%s", commit });
    defer allocator.free(subject_raw);
    const subject = std.mem.trim(u8, subject_raw, " \t\r\n");
    if (subject.len > git.max_event_subject_bytes) {
        try fsck.fail("{s}: {s}: subject exceeds v1 subject size limit", .{ ref, commit });
    }

    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    if (body.len > git.max_event_body_bytes) {
        try fsck.fail("{s}: {s}: event body exceeds v1 body size limit", .{ ref, commit });
    }
    try checkParentHashes(allocator, fsck, ref, commit, body);

    const envelope = try parseEnvelope(allocator, fsck, ref, commit, body);
    if (envelope) |parsed| {
        defer parsed.deinit();
        try fsck.checkRepoId(commit, parsed.repo_id);
        try fsck.checkActorSeq(commit, parsed.actor_principal, parsed.actor_device, parsed.seq);
        if (auth_verifier) |verifier| {
            if (try verifier.checkExisting(commit, parsed)) |reason| {
                try fsck.fail("{s}: {s}: signing key is not authorized for actor {s}/{s}: {s}", .{ ref, commit, parsed.actor_principal, parsed.actor_device, reason });
            }
        }
    }
}

fn checkParentHashes(
    allocator: Allocator,
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    body: []const u8,
) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");

    const failure = (try event_mod.validateParentHashes(allocator, parents, body)) orelse return;
    switch (failure) {
        .invalid_event_body, .invalid_parent_hashes => return,
        else => try fsck.fail("{s}: {s}: {s}", .{ ref, commit, event_mod.parentHashValidationMessage(failure) }),
    }
}

fn checkFirstParent(
    allocator: Allocator,
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    const first_parent = it.next();

    if (expected_first_parent) |expected| {
        if (first_parent == null or !std.mem.eql(u8, first_parent.?, expected)) {
            try fsck.fail("{s}: {s}: first parent is not previous inbox event {s}", .{ ref, commit, expected });
        }
    } else if (first_parent != null) {
        try fsck.fail("{s}: {s}: root inbox event has a parent", .{ ref, commit });
    }
}

fn verifyCommitSignature(allocator: Allocator, fsck: *State, ref: []const u8, commit: []const u8) !void {
    var argv = [_][]const u8{ "git", "verify-commit", commit };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return;

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr.len != 0) {
        try fsck.fail("{s}: {s}: signature verification failed: {s}", .{ ref, commit, stderr });
    } else {
        try fsck.fail("{s}: {s}: signature verification failed", .{ ref, commit });
    }
}

fn parseEnvelope(
    allocator: Allocator,
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    body: []const u8,
) !?event_mod.ValidatedEnvelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try fsck.fail("{s}: {s}: event body is not valid JSON", .{ ref, commit });
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try fsck.fail("{s}: {s}: event body must be a JSON object", .{ ref, commit });
            return null;
        },
    };

    if (try event_mod.validateEnvelopeObject(allocator, root)) |message| {
        defer allocator.free(message);
        try fsck.fail("{s}: {s}: {s}", .{ ref, commit, message });
        return null;
    }

    return event_mod.parseValidatedEnvelopeObject(allocator, root) catch {
        try fsck.fail("{s}: {s}: invalid event envelope", .{ ref, commit });
        return null;
    };
}

test "fsck inbox ref name validates structure and ref-safe segments" {
    var state = State.init(std.testing.allocator, null);
    defer state.deinit();

    try checkInboxRefName(&state, "refs/gitomi/inbox/alice/laptop");
    try std.testing.expectEqual(@as(usize, 0), state.errors);

    try checkInboxRefName(&state, "refs/heads/main");
    try std.testing.expectEqual(@as(usize, 1), state.errors);

    try checkInboxRefName(&state, "refs/gitomi/inbox/alice");
    try std.testing.expectEqual(@as(usize, 2), state.errors);

    try checkInboxRefName(&state, "refs/gitomi/inbox/alice/laptop/extra");
    try std.testing.expectEqual(@as(usize, 4), state.errors);

    try checkInboxRefName(&state, "refs/gitomi/inbox/al ice/laptop");
    try std.testing.expectEqual(@as(usize, 5), state.errors);
}

test "fsck repo id checks configured and observed repository identity" {
    var configured = State.init(std.testing.allocator, "repo-a");
    defer configured.deinit();
    try configured.checkRepoId("commit-1", "repo-a");
    try std.testing.expectEqual(@as(usize, 0), configured.errors);
    try configured.checkRepoId("commit-2", "repo-b");
    try std.testing.expectEqual(@as(usize, 1), configured.errors);

    var observed = State.init(std.testing.allocator, null);
    defer observed.deinit();
    try observed.checkRepoId("commit-3", "repo-a");
    try std.testing.expectEqualStrings("repo-a", observed.observed_repo_id.?);
    try observed.checkRepoId("commit-4", "repo-a");
    try std.testing.expectEqual(@as(usize, 0), observed.errors);
    try observed.checkRepoId("commit-5", "repo-b");
    try std.testing.expectEqual(@as(usize, 1), observed.errors);
}

test "fsck actor sequence checks duplicates and monotonicity per actor" {
    var state = State.init(std.testing.allocator, null);
    defer state.deinit();

    try state.checkActorSeq("commit-1", "ab", "c", 1);
    try state.checkActorSeq("commit-2", "a", "bc", 1);
    try state.checkActorSeq("commit-3", "ab", "c", 2);
    try std.testing.expectEqual(@as(usize, 0), state.errors);

    try state.checkActorSeq("commit-4", "ab", "c", 2);
    try std.testing.expectEqual(@as(usize, 1), state.errors);

    try state.checkActorSeq("commit-5", "ab", "c", 0);
    try std.testing.expectEqual(@as(usize, 2), state.errors);
}

test "fsck envelope parsing reports malformed bodies without crashing" {
    var state = State.init(std.testing.allocator, null);
    defer state.deinit();

    try std.testing.expect((try parseEnvelope(std.testing.allocator, &state, "refs/gitomi/inbox/alice/laptop", "commit-1", "not json")) == null);
    try std.testing.expectEqual(@as(usize, 1), state.errors);

    try std.testing.expect((try parseEnvelope(std.testing.allocator, &state, "refs/gitomi/inbox/alice/laptop", "commit-2", "[]")) == null);
    try std.testing.expectEqual(@as(usize, 2), state.errors);
}
