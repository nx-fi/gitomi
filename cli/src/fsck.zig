const std = @import("std");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const gitChecked = git.gitChecked;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const isRefSafeSegment = util.isRefSafeSegment;
const looksLikeUuid = util.looksLikeUuid;
const event_schema = event_mod.event_schema;
const isKnownObjectKind = event_mod.isKnownObjectKind;
const payloadRequirementError = event_mod.payloadRequirementError;
const objectIdRequirementError = event_mod.objectIdRequirementError;
const eprint = @import("io.zig").eprint;

const Envelope = struct {
    allocator: Allocator,
    repo_id: []u8,
    actor_principal: []u8,
    actor_device: []u8,
    seq: u64,

    fn deinit(self: Envelope) void {
        self.allocator.free(self.repo_id);
        self.allocator.free(self.actor_principal);
        self.allocator.free(self.actor_device);
    }
};

pub const State = struct {
    allocator: Allocator,
    config_repo_id: ?[]const u8,
    observed_repo_id: ?[]u8 = null,
    actor_seqs: std.BufSet,
    actor_last_seq: std.StringHashMap(u64),
    refs: usize = 0,
    commits: usize = 0,
    errors: usize = 0,

    pub fn init(allocator: Allocator, config_repo_id: ?[]const u8) State {
        return .{
            .allocator = allocator,
            .config_repo_id = config_repo_id,
            .actor_seqs = std.BufSet.init(allocator),
            .actor_last_seq = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.observed_repo_id) |repo_id| self.allocator.free(repo_id);
        self.actor_seqs.deinit();
        var keys = self.actor_last_seq.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.actor_last_seq.deinit();
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

    fn checkActorSeq(self: *State, commit: []const u8, principal: []const u8, device: []const u8, seq: u64) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}\x1f{d}", .{ principal.len, principal, device.len, device, seq });
        defer self.allocator.free(key);

        if (self.actor_seqs.contains(key)) {
            try self.fail("{s}: duplicate actor sequence ({s}, {s}, {d})", .{ commit, principal, device, seq });
            return;
        }
        try self.actor_seqs.insert(key);

        const actor_key = try std.fmt.allocPrint(self.allocator, "{d}:{s}\x1f{d}:{s}", .{ principal.len, principal, device.len, device });
        errdefer self.allocator.free(actor_key);
        const entry = try self.actor_last_seq.getOrPut(actor_key);
        if (entry.found_existing) {
            self.allocator.free(actor_key);
            if (seq <= entry.value_ptr.*) {
                try self.fail("{s}: actor sequence ({s}, {s}, {d}) is not strictly greater than previous sequence {d}", .{ commit, principal, device, seq, entry.value_ptr.* });
                return;
            }
        } else {
            entry.key_ptr.* = actor_key;
        }
        entry.value_ptr.* = seq;
    }
};

pub fn checkInboxRef(allocator: Allocator, fsck: *State, ref: []const u8, empty_tree: []const u8) !void {
    fsck.refs += 1;
    try checkInboxRefName(fsck, ref);

    const commits = try gitChecked(allocator, &.{ "rev-list", "--first-parent", "--reverse", ref });
    defer allocator.free(commits);

    var expected_first_parent: ?[]const u8 = null;
    var it = std.mem.tokenizeScalar(u8, commits, '\n');
    while (it.next()) |commit_raw| {
        const commit = std.mem.trim(u8, commit_raw, " \t\r\n");
        if (commit.len == 0) continue;
        try checkInboxCommit(allocator, fsck, ref, commit, expected_first_parent, empty_tree);
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
    }
}

fn checkParentHashes(
    allocator: Allocator,
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const parent_hashes_value = root.get("parent_hashes") orelse return;
    const parent_hashes = switch (parent_hashes_value) {
        .object => |object| object,
        else => return,
    };
    const log_hash = switch (parent_hashes.get("log") orelse return) {
        .string => |value| value,
        else => return,
    };
    const causal = switch (parent_hashes.get("causal") orelse return) {
        .array => |array| array,
        else => return,
    };
    const related = switch (parent_hashes.get("related") orelse return) {
        .array => |array| array,
        else => return,
    };

    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    var parent_list: std.ArrayList([]const u8) = .empty;
    defer parent_list.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, parents, ' ');
    while (it.next()) |parent| try parent_list.append(allocator, parent);

    const expected_log = if (parent_list.items.len == 0) "" else parent_list.items[0];
    if (!std.mem.eql(u8, log_hash, expected_log)) {
        try fsck.fail("{s}: {s}: parent_hashes.log does not match first parent", .{ ref, commit });
    }

    const expected_causal_len = if (parent_list.items.len == 0) 0 else parent_list.items.len - 1;
    if (causal.items.len != expected_causal_len) {
        try fsck.fail("{s}: {s}: parent_hashes.causal does not match parent count", .{ ref, commit });
        return;
    }
    if (causal.items.len > git.max_causal_parents) {
        try fsck.fail("{s}: {s}: parent_hashes.causal exceeds v1 causal parent cap", .{ ref, commit });
        return;
    }
    if (related.items.len > git.max_related_parents) {
        try fsck.fail("{s}: {s}: parent_hashes.related exceeds v1 related parent cap", .{ ref, commit });
        return;
    }
    for (causal.items, 0..) |item, idx| {
        if (item != .string or !std.mem.eql(u8, item.string, parent_list.items[idx + 1])) {
            try fsck.fail("{s}: {s}: parent_hashes.causal does not match Git parents", .{ ref, commit });
            return;
        }
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
) !?Envelope {
    var ok = true;
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

    const schema = try requireString(fsck, ref, commit, root, "$schema", &ok);
    if (schema) |value| {
        if (!std.mem.eql(u8, value, event_schema)) {
            try fsck.fail("{s}: {s}: $schema must be {s}", .{ ref, commit, event_schema });
            ok = false;
        }
    }

    const repo_id = try requireUuid(fsck, ref, commit, root, "repo_id", &ok);
    _ = try requireUuid(fsck, ref, commit, root, "event_uuid", &ok);
    const event_type = try requireString(fsck, ref, commit, root, "event_type", &ok);
    _ = try requireUuid(fsck, ref, commit, root, "idempotency_key", &ok);
    _ = try requireObject(fsck, ref, commit, root, "legacy", &ok);
    const payload = try requireObject(fsck, ref, commit, root, "payload", &ok);

    const seq = try requireSeq(fsck, ref, commit, root, &ok);

    const occurred_at = try requireString(fsck, ref, commit, root, "occurred_at", &ok);
    if (occurred_at) |value| {
        if (value.len == 0 or value[value.len - 1] != 'Z') {
            try fsck.fail("{s}: {s}: occurred_at must be a UTC RFC3339 timestamp", .{ ref, commit });
            ok = false;
        }
    }

    const parent_hashes = try requireObject(fsck, ref, commit, root, "parent_hashes", &ok);
    if (parent_hashes) |parents_map| {
        _ = try requireStringAllowEmpty(fsck, ref, commit, parents_map, "log", &ok);
        try requireStringArray(fsck, ref, commit, parents_map, "causal", &ok);
        try requireStringArray(fsck, ref, commit, parents_map, "related", &ok);
    }

    const object = try requireObject(fsck, ref, commit, root, "object", &ok);
    if (object) |object_map| {
        const kind = try requireString(fsck, ref, commit, object_map, "kind", &ok);
        const object_id = try requireString(fsck, ref, commit, object_map, "id", &ok);
        if (kind) |value| {
            if (!isKnownObjectKind(value)) {
                try fsck.fail("{s}: {s}: unknown object kind '{s}'", .{ ref, commit, value });
                ok = false;
            } else if (event_type != null and payload != null) {
                if (payloadRequirementError(event_type.?, value, payload.?)) |message| {
                    try fsck.fail("{s}: {s}: {s}", .{ ref, commit, message });
                    ok = false;
                }
                if (object_id != null) {
                    if (objectIdRequirementError(event_type.?, value, object_id.?, payload.?)) |message| {
                        try fsck.fail("{s}: {s}: {s}", .{ ref, commit, message });
                        ok = false;
                    }
                }
            }
        }
    }

    const actor = try requireObject(fsck, ref, commit, root, "actor", &ok);
    var actor_principal: ?[]const u8 = null;
    var actor_device: ?[]const u8 = null;
    if (actor) |actor_map| {
        actor_principal = try requireString(fsck, ref, commit, actor_map, "principal", &ok);
        actor_device = try requireString(fsck, ref, commit, actor_map, "device", &ok);
    }

    if (!ok or repo_id == null or actor_principal == null or actor_device == null or seq == null) {
        return null;
    }

    var repo_id_owned: ?[]u8 = try allocator.dupe(u8, repo_id.?);
    errdefer if (repo_id_owned) |value| allocator.free(value);
    var principal_owned: ?[]u8 = try allocator.dupe(u8, actor_principal.?);
    errdefer if (principal_owned) |value| allocator.free(value);
    var device_owned: ?[]u8 = try allocator.dupe(u8, actor_device.?);
    errdefer if (device_owned) |value| allocator.free(value);

    const envelope = Envelope{
        .allocator = allocator,
        .repo_id = repo_id_owned.?,
        .actor_principal = principal_owned.?,
        .actor_device = device_owned.?,
        .seq = seq.?,
    };
    repo_id_owned = null;
    principal_owned = null;
    device_owned = null;
    return envelope;
}

fn requireObject(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?std.json.ObjectMap {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return null;
    };
    return switch (value) {
        .object => |child| child,
        else => {
            try fsck.fail("{s}: {s}: {s} must be an object", .{ ref, commit, key });
            ok.* = false;
            return null;
        },
    };
}

fn requireString(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?[]const u8 {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return null;
    };
    const string = switch (value) {
        .string => |s| s,
        else => {
            try fsck.fail("{s}: {s}: {s} must be a string", .{ ref, commit, key });
            ok.* = false;
            return null;
        },
    };
    if (string.len == 0) {
        try fsck.fail("{s}: {s}: {s} must not be empty", .{ ref, commit, key });
        ok.* = false;
        return null;
    }
    return string;
}

fn requireStringAllowEmpty(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?[]const u8 {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return null;
    };
    return switch (value) {
        .string => |string| string,
        else => {
            try fsck.fail("{s}: {s}: {s} must be a string", .{ ref, commit, key });
            ok.* = false;
            return null;
        },
    };
}

fn requireStringArray(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !void {
    const value = object.get(key) orelse {
        try fsck.fail("{s}: {s}: missing {s}", .{ ref, commit, key });
        ok.* = false;
        return;
    };
    const array = switch (value) {
        .array => |items| items,
        else => {
            try fsck.fail("{s}: {s}: {s} must be an array", .{ ref, commit, key });
            ok.* = false;
            return;
        },
    };
    for (array.items) |item| {
        if (item != .string) {
            try fsck.fail("{s}: {s}: {s} must contain only strings", .{ ref, commit, key });
            ok.* = false;
            return;
        }
    }
}

fn requireUuid(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    key: []const u8,
    ok: *bool,
) !?[]const u8 {
    const value = try requireString(fsck, ref, commit, object, key, ok);
    if (value) |string| {
        if (!looksLikeUuid(string)) {
            try fsck.fail("{s}: {s}: {s} must be a UUID", .{ ref, commit, key });
            ok.* = false;
            return null;
        }
    }
    return value;
}

fn requireSeq(
    fsck: *State,
    ref: []const u8,
    commit: []const u8,
    object: std.json.ObjectMap,
    ok: *bool,
) !?u64 {
    const value = object.get("seq") orelse {
        try fsck.fail("{s}: {s}: missing seq", .{ ref, commit });
        ok.* = false;
        return null;
    };
    return switch (value) {
        .integer => |seq| {
            if (seq < 0) {
                try fsck.fail("{s}: {s}: seq must be a non-negative integer", .{ ref, commit });
                ok.* = false;
                return null;
            }
            return @as(u64, @intCast(seq));
        },
        else => {
            try fsck.fail("{s}: {s}: seq must be a non-negative integer", .{ ref, commit });
            ok.* = false;
            return null;
        },
    };
}
