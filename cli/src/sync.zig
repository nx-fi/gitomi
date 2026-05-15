const std = @import("std");
const auth_binding = @import("auth_binding.zig");
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
const gitChecked = git.gitChecked;
const listRefs = git.listRefs;
const freeStringList = git.freeStringList;
const emptyTreeOid = git.emptyTreeOid;
const resolveOptionalRef = git.resolveOptionalRef;
const isAncestor = git.isAncestor;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const sanitizeRefSegment = util.sanitizeRefSegment;
const validateEventEnvelope = event_mod.validateEventEnvelope;
const parseValidatedEnvelope = event_mod.parseValidatedEnvelope;

pub fn syncPull(allocator: Allocator, remote: []const u8) !void {
    const remote_segment = try stagingRemoteSegment(allocator, remote);
    defer allocator.free(remote_segment);
    const staging_prefix = try std.fmt.allocPrint(allocator, "refs/gitomi/staging/{s}", .{remote_segment});
    defer allocator.free(staging_prefix);
    try clearStagedRemoteRefs(allocator, staging_prefix);
    const fetch_refspec = try std.fmt.allocPrint(allocator, "+refs/gitomi/inbox/*:{s}/inbox/*", .{staging_prefix});
    defer allocator.free(fetch_refspec);
    const genesis_refspec = try std.fmt.allocPrint(allocator, "refs/gitomi/genesis:{s}/genesis", .{staging_prefix});
    defer allocator.free(genesis_refspec);

    try out("fetching Gitomi genesis ref from {s} into {s}/genesis\n", .{ remote, staging_prefix });
    try fetchOptionalGenesisRef(allocator, remote, genesis_refspec);

    try out("fetching Gitomi inbox refs from {s} into {s}\n", .{ remote, staging_prefix });
    const fetched = try gitChecked(allocator, &.{ "fetch", remote, fetch_refspec });
    defer allocator.free(fetched);
    if (fetched.len != 0) try out("{s}", .{fetched});

    const genesis_admission = try admitStagedGenesisRef(allocator, staging_prefix);
    if (genesis_admission == .conflict) {
        try eprint("gt sync: refusing to admit inbox refs from {s} because its genesis conflicts with the local trust root\n", .{remote});
        return CliError.UserError;
    }
    try admitStagedInboxRefs(allocator, staging_prefix);
}

fn clearStagedRemoteRefs(allocator: Allocator, staging_prefix: []const u8) !void {
    const refs = try listRefs(allocator, staging_prefix);
    defer freeStringList(allocator, refs);

    for (refs) |ref| {
        const deleted = try gitChecked(allocator, &.{ "update-ref", "-d", ref });
        allocator.free(deleted);
    }
}

fn fetchOptionalGenesisRef(allocator: Allocator, remote: []const u8, genesis_refspec: []const u8) !void {
    var argv = [_][]const u8{ "git", "fetch", remote, genesis_refspec };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();

    if (result.exitCode() == 0) {
        if (result.stdout.len != 0) try out("{s}", .{result.stdout});
        return;
    }

    const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (isMissingRemoteGenesis(stderr)) {
        try out("no remote Gitomi genesis ref at {s}\n", .{remote});
        return;
    }

    if (stderr.len != 0) {
        try eprint("git fetch failed: {s}\n", .{stderr});
    } else {
        try eprint("git fetch failed\n", .{});
    }
    return CliError.GitFailed;
}

fn isMissingRemoteGenesis(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "couldn't find remote ref refs/gitomi/genesis") != null;
}

pub fn syncPush(allocator: Allocator, remote: []const u8) !void {
    const configured_inbox_ref = try configuredInboxRefIfPresent(allocator);
    defer if (configured_inbox_ref) |ref| allocator.free(ref);
    const own_inbox_oid = if (configured_inbox_ref) |ref|
        try resolveOptionalRef(allocator, ref)
    else
        null;
    defer if (own_inbox_oid) |oid| allocator.free(oid);

    const genesis_oid = try resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);

    if (own_inbox_oid == null and genesis_oid == null) {
        try out("no local Gitomi genesis or configured inbox ref to push\n", .{});
        return;
    }

    if (genesis_oid != null) {
        try out("pushing Gitomi genesis ref to {s}\n", .{remote});
        try pushGenesisRef(allocator, remote);
    }

    var inbox_refs: [1][]const u8 = undefined;
    const refs = if (configured_inbox_ref != null and own_inbox_oid != null) blk: {
        inbox_refs[0] = configured_inbox_ref.?;
        break :blk inbox_refs[0..];
    } else inbox_refs[0..0];
    try pushInboxRefs(allocator, remote, refs);
}

fn configuredInboxRefIfPresent(allocator: Allocator) !?[]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => return null,
        CliError.ConfigInvalid => {
            try eprint("gt sync: invalid Gitomi config; run `gt init` or fix .git/gitomi/config.toml\n", .{});
            return err;
        },
        else => return err,
    };
    defer cfg.deinit();

    try repo_mod.validateConfigRepoId(allocator, cfg);
    return try repo_mod.inboxRef(allocator, cfg);
}

fn pushInboxRefs(allocator: Allocator, remote: []const u8, refs: []const []const u8) !void {
    if (refs.len == 0) {
        try out("no configured Gitomi inbox ref to push\n", .{});
        return;
    }
    if (refs.len > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to push {d} inbox refs; v1 default limit is {d}\n", .{ refs.len, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var refspecs: std.ArrayList([]u8) = .empty;
    defer {
        for (refspecs.items) |refspec| allocator.free(refspec);
        refspecs.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{ "push", remote });
    for (refs) |ref| {
        const refspec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ref, ref });
        errdefer allocator.free(refspec);
        try argv.append(allocator, refspec);
        try refspecs.append(allocator, refspec);
    }

    try out("pushing {d} authoritative Gitomi inbox ref{s} to {s}\n", .{ refs.len, if (refs.len == 1) "" else "s", remote });
    const pushed = try gitChecked(allocator, argv.items);
    defer allocator.free(pushed);
    if (pushed.len != 0) try out("{s}", .{pushed});
}

fn pushGenesisRef(allocator: Allocator, remote: []const u8) !void {
    var argv = [_][]const u8{ "git", "push", remote, "refs/gitomi/genesis:refs/gitomi/genesis" };
    var result = try runCommand(allocator, &argv, null, max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) {
        if (result.stdout.len != 0) try out("{s}", .{result.stdout});
        return;
    }

    try out("genesis ref not pushed to {s}; remote may already have a different trust root\n", .{remote});
}

const GenesisAdmission = enum {
    absent,
    created,
    unchanged,
    conflict,
};

pub fn admitStagedGenesisRef(allocator: Allocator, staging_prefix: []const u8) !GenesisAdmission {
    const staged_ref = try std.fmt.allocPrint(allocator, "{s}/genesis", .{staging_prefix});
    defer allocator.free(staged_ref);
    const staged_oid = (try resolveOptionalRef(allocator, staged_ref)) orelse return .absent;
    defer allocator.free(staged_oid);

    const local_oid = try resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (local_oid) |oid| allocator.free(oid);

    if (local_oid) |local| {
        if (std.mem.eql(u8, local, staged_oid)) {
            try out("unchanged {s}\n", .{repo_mod.genesis_ref});
            return .unchanged;
        } else {
            try out("conflicting {s}; staged ref left at {s}\n", .{ repo_mod.genesis_ref, staged_ref });
            return .conflict;
        }
    }

    var manifest = try repo_mod.loadGenesisManifest(allocator, staged_oid);
    defer manifest.deinit();
    _ = try repo_mod.importOpenPgpPublicKey(allocator, manifest.public_key);
    try verifyGenesisCommitSignature(allocator, staged_oid, manifest.fingerprint);
    const updated = try gitChecked(allocator, &.{ "update-ref", repo_mod.genesis_ref, staged_oid, "" });
    defer allocator.free(updated);
    try out("created {s}\n", .{repo_mod.genesis_ref});
    try autoInitConfigFromGenesis(allocator, staged_oid);
    return .created;
}

fn autoInitConfigFromGenesis(allocator: Allocator, genesis_oid: []const u8) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    if (util.fileExists(repo.config_path)) return;

    var manifest = repo_mod.loadGenesisManifest(allocator, genesis_oid) catch return;
    defer manifest.deinit();

    try std.fs.cwd().makePath(repo.gitomi_dir);

    const principal = try repo_mod.defaultPrincipal(allocator);
    defer allocator.free(principal);
    const device = try repo_mod.defaultDevice(allocator);
    defer allocator.free(device);

    var cfg = repo_mod.Config{
        .allocator = allocator,
        .repo_id = try allocator.dupe(u8, manifest.repo_id),
        .principal = try allocator.dupe(u8, principal),
        .device = try allocator.dupe(u8, device),
        .seq = 0,
    };
    defer cfg.deinit();

    try repo_mod.writeConfig(repo.config_path, cfg);
    try out("auto-configured from genesis: {s}/{s}\n", .{ principal, device });
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

    const genesis_oid = try resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);
    if (genesis_oid == null) {
        try eprint("gt sync: refusing to admit inbox refs without {s}\n", .{repo_mod.genesis_ref});
        return CliError.UserError;
    }

    if (refs.len > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to admit {d} inbox refs; v1 default limit is {d}\n", .{ refs.len, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    const local_refs = try listRefs(allocator, "refs/gitomi/inbox");
    defer freeStringList(allocator, local_refs);
    if (local_refs.len > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to admit inbox refs; local repository already has {d}, v1 default limit is {d}\n", .{ local_refs.len, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    const new_ref_count = try countNewStagedInboxRefs(allocator, staging_prefix, refs);
    if (local_refs.len + new_ref_count > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to admit {d} new inbox refs; local repository would exceed v1 default limit {d}\n", .{ new_ref_count, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |staged_ref| {
        try admitStagedInboxRef(allocator, staging_prefix, staged_ref, empty_tree, genesis_oid.?);
    }
}

fn countNewStagedInboxRefs(allocator: Allocator, staging_prefix: []const u8, refs: []const []const u8) !usize {
    var count: usize = 0;
    for (refs) |staged_ref| {
        const local_ref = try localRefFromStaged(allocator, staging_prefix, staged_ref);
        defer allocator.free(local_ref);
        const local_oid = try resolveOptionalRef(allocator, local_ref);
        if (local_oid) |oid| {
            allocator.free(oid);
        } else {
            count += 1;
        }
    }
    return count;
}

pub fn admitStagedInboxRef(
    allocator: Allocator,
    staging_prefix: []const u8,
    staged_ref: []const u8,
    empty_tree: []const u8,
    genesis_oid: []const u8,
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
            const admitted = validateInboxRange(allocator, staged_ref, old_oid, empty_tree, genesis_oid) catch |err| {
                if (errors.isUserError(err)) {
                    try quarantineStagedRef(allocator, staging_prefix, staged_ref, staged_oid);
                    return;
                }
                return err;
            };
            const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, old_oid });
            defer allocator.free(updated);
            try out("fast-forwarded {s} by {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
            return;
        }

        if (try isAncestor(allocator, staged_oid, old_oid)) {
            try out("stale remote {s}; local ref is ahead\n", .{local_ref});
            return;
        }

        try quarantineStagedRef(allocator, staging_prefix, staged_ref, staged_oid);
        try out("diverged {s}; quarantined staged head\n", .{local_ref});
        return;
    }

    const admitted = validateInboxRange(allocator, staged_ref, null, empty_tree, genesis_oid) catch |err| {
        if (errors.isUserError(err)) {
            try quarantineStagedRef(allocator, staging_prefix, staged_ref, staged_oid);
            return;
        }
        return err;
    };
    const updated = try gitChecked(allocator, &.{ "update-ref", local_ref, staged_oid, "" });
    defer allocator.free(updated);
    try out("created {s} with {d} event{s}\n", .{ local_ref, admitted, if (admitted == 1) "" else "s" });
}

fn quarantineStagedRef(allocator: Allocator, staging_prefix: []const u8, staged_ref: []const u8, staged_oid: []const u8) !void {
    const suffix = if (std.mem.startsWith(u8, staged_ref, staging_prefix) and staged_ref.len > staging_prefix.len and staged_ref[staging_prefix.len] == '/')
        staged_ref[staging_prefix.len + 1 ..]
    else
        staged_ref;
    const quarantine_ref = try std.fmt.allocPrint(allocator, "refs/gitomi/quarantine/{s}/{s}", .{
        staging_prefix["refs/gitomi/staging/".len..],
        suffix,
    });
    defer allocator.free(quarantine_ref);
    const final_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ quarantine_ref, staged_oid[0..@min(staged_oid.len, 12)] });
    defer allocator.free(final_ref);
    const updated = try gitChecked(allocator, &.{ "update-ref", final_ref, staged_oid });
    defer allocator.free(updated);
    const deleted = try gitChecked(allocator, &.{ "update-ref", "-d", staged_ref });
    defer allocator.free(deleted);
    try out("quarantined {s} as {s}\n", .{ staged_ref, final_ref });
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
    genesis_oid: []const u8,
) !usize {
    const log = try inboxCommitLog(allocator, ref, local_base, genesis_oid);
    defer allocator.free(log);

    var count: usize = 0;
    var expected_first_parent: ?[]const u8 = if (local_base) |base| base else genesis_oid;
    var actor_seqs = ActorSeqTracker.init(allocator);
    defer actor_seqs.deinit();
    try seedActorSeqsThroughCommit(allocator, &actor_seqs, local_base);
    var auth_verifier = try auth_binding.Verifier.init(allocator);
    defer auth_verifier.deinit();
    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = parseInboxCommitRecord(record_raw) orelse {
            if (std.mem.trim(u8, record_raw, " \t\r\n").len == 0) continue;
            try eprint("gt sync: git log returned malformed inbox commit metadata\n", .{});
            return CliError.GitFailed;
        };
        if (count >= git.max_default_admit_commits) {
            try eprint("gt sync: refusing to admit more than {d} new inbox commits in one pull\n", .{git.max_default_admit_commits});
            return CliError.UserError;
        }
        var envelope = try validateInboxRecord(allocator, record, expected_first_parent, empty_tree);
        defer envelope.deinit();
        if (try auth_verifier.checkAndRemember(.{
            .ref = ref,
            .commit = record.commit,
            .tree = record.tree,
            .subject = record.subject,
            .body = record.body,
        }, envelope)) |reason| {
            try eprint("gt sync: rejecting {s} on {s}: signing key is not authorized for actor {s}/{s}: {s}\n", .{ record.commit, ref, envelope.actor_principal, envelope.actor_device, reason });
            return CliError.UserError;
        }
        try actor_seqs.remember(record.commit, ref, envelope.actor_principal, envelope.actor_device, envelope.seq);
        expected_first_parent = record.commit;
        count += 1;
    }
    return count;
}

const inbox_commit_log_format = "--format=%H%x00%T%x00%P%x00%s%x00%b%x1e";

const InboxCommitRecord = struct {
    commit: []const u8,
    tree: []const u8,
    parents: []const u8,
    subject: []const u8,
    body: []const u8,
};

const ActorSeqTracker = struct {
    allocator: Allocator,
    last_seq: std.StringHashMap(i64),

    fn init(allocator: Allocator) ActorSeqTracker {
        return .{
            .allocator = allocator,
            .last_seq = std.StringHashMap(i64).init(allocator),
        };
    }

    fn deinit(self: *ActorSeqTracker) void {
        var keys = self.last_seq.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.last_seq.deinit();
    }

    fn seed(self: *ActorSeqTracker, principal: []const u8, device: []const u8, seq: i64) !void {
        const key = try actorSeqKey(self.allocator, principal, device);
        errdefer self.allocator.free(key);
        const entry = try self.last_seq.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            if (seq > entry.value_ptr.*) entry.value_ptr.* = seq;
            return;
        }
        entry.key_ptr.* = key;
        entry.value_ptr.* = seq;
    }

    fn remember(
        self: *ActorSeqTracker,
        commit: []const u8,
        ref: []const u8,
        principal: []const u8,
        device: []const u8,
        seq: i64,
    ) !void {
        const key = try actorSeqKey(self.allocator, principal, device);
        errdefer self.allocator.free(key);
        const entry = try self.last_seq.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            if (seq <= entry.value_ptr.*) {
                try eprint("gt sync: rejecting {s} on {s}: actor {s}/{s} seq {d} is not strictly greater than previous sequence {d}\n", .{ commit, ref, principal, device, seq, entry.value_ptr.* });
                return CliError.UserError;
            }
        } else {
            entry.key_ptr.* = key;
        }
        entry.value_ptr.* = seq;
    }
};

fn actorSeqKey(allocator: Allocator, principal: []const u8, device: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}\x1f{d}:{s}", .{
        principal.len,
        principal,
        device.len,
        device,
    });
}

fn inboxCommitLog(allocator: Allocator, ref: []const u8, local_base: ?[]const u8, genesis_oid: []const u8) ![]u8 {
    if (local_base) |base| {
        const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, ref });
        defer allocator.free(range);
        return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit_log_format, range });
    }
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ genesis_oid, ref });
    defer allocator.free(range);
    return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit_log_format, range });
}

fn parseInboxCommitRecord(record_raw: []const u8) ?InboxCommitRecord {
    const record = std.mem.trim(u8, record_raw, "\r\n");
    if (record.len == 0) return null;

    const first = std.mem.indexOfScalar(u8, record, 0) orelse return null;
    const second_rel = std.mem.indexOfScalar(u8, record[first + 1 ..], 0) orelse return null;
    const second = first + 1 + second_rel;
    const third_rel = std.mem.indexOfScalar(u8, record[second + 1 ..], 0) orelse return null;
    const third = second + 1 + third_rel;
    const fourth_rel = std.mem.indexOfScalar(u8, record[third + 1 ..], 0) orelse return null;
    const fourth = third + 1 + fourth_rel;

    return .{
        .commit = std.mem.trim(u8, record[0..first], " \t\r\n"),
        .tree = std.mem.trim(u8, record[first + 1 .. second], " \t\r\n"),
        .parents = std.mem.trim(u8, record[second + 1 .. third], " \t\r\n"),
        .subject = std.mem.trim(u8, record[third + 1 .. fourth], " \t\r\n"),
        .body = std.mem.trim(u8, record[fourth + 1 ..], " \t\r\n"),
    };
}

pub fn validateInboxCommit(
    allocator: Allocator,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !event_mod.ValidatedEnvelope {
    const log = try gitChecked(allocator, &.{ "log", "-1", inbox_commit_log_format, commit });
    defer allocator.free(log);

    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = parseInboxCommitRecord(record_raw) orelse {
            if (std.mem.trim(u8, record_raw, " \t\r\n").len == 0) continue;
            try eprint("gt sync: git log returned malformed inbox commit metadata\n", .{});
            return CliError.GitFailed;
        };
        return try validateInboxRecord(allocator, record, expected_first_parent, empty_tree);
    }

    try eprint("gt sync: rejecting {s}: commit metadata not found\n", .{commit});
    return CliError.UserError;
}

fn validateInboxRecord(
    allocator: Allocator,
    record: InboxCommitRecord,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !event_mod.ValidatedEnvelope {
    if (!std.mem.eql(u8, record.tree, empty_tree)) {
        try eprint("gt sync: rejecting {s}: inbox event does not use the empty tree\n", .{record.commit});
        return CliError.UserError;
    }

    try validateFirstParentList(record.commit, record.parents, expected_first_parent);
    try verifyCommitSignature(allocator, record.commit);

    if (record.subject.len > git.max_event_subject_bytes) {
        try eprint("gt sync: rejecting {s}: subject exceeds v1 subject size limit\n", .{record.commit});
        return CliError.UserError;
    }

    if (record.body.len > git.max_event_body_bytes) {
        try eprint("gt sync: rejecting {s}: event body exceeds v1 body size limit\n", .{record.commit});
        return CliError.UserError;
    }
    try validateEventEnvelope(allocator, record.commit, record.body);
    try validateEnvelopeParentHashes(allocator, record.commit, record.parents, record.body);
    return try parseValidatedEnvelope(allocator, record.body);
}

fn seedActorSeqsThroughCommit(allocator: Allocator, actor_seqs: *ActorSeqTracker, commit_opt: ?[]const u8) !void {
    const commit = commit_opt orelse return;
    const log = try gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", "--format=%b%x1e", commit });
    defer allocator.free(log);

    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const body = std.mem.trim(u8, record_raw, " \t\r\n");
        if (body.len == 0) continue;
        var envelope = parseValidatedEnvelope(allocator, body) catch continue;
        defer envelope.deinit();
        try actor_seqs.seed(envelope.actor_principal, envelope.actor_device, envelope.seq);
    }
}

pub fn validateFirstParent(allocator: Allocator, commit: []const u8, expected_first_parent: ?[]const u8) !void {
    const parents_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%P", commit });
    defer allocator.free(parents_raw);
    const parents = std.mem.trim(u8, parents_raw, " \t\r\n");
    return validateFirstParentList(commit, parents, expected_first_parent);
}

fn validateFirstParentList(commit: []const u8, parents: []const u8, expected_first_parent: ?[]const u8) !void {
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

pub fn verifyGenesisCommitSignature(allocator: Allocator, commit: []const u8, expected_fingerprint: []const u8) !void {
    try verifyCommitSignature(allocator, commit);
    const actual_fingerprint = (try git.verifiedCommitSigningKeyFingerprint(allocator, commit)) orelse {
        try eprint("gt sync: rejecting genesis {s}: signature fingerprint not found\n", .{commit});
        return CliError.UserError;
    };
    defer allocator.free(actual_fingerprint);
    if (!std.mem.eql(u8, actual_fingerprint, expected_fingerprint)) {
        try eprint("gt sync: rejecting genesis {s}: signature fingerprint does not match manifest key\n", .{commit});
        return CliError.UserError;
    }
}

fn validateEnvelopeParentHashes(allocator: Allocator, commit: []const u8, parents: []const u8, body: []const u8) !void {
    var parent_list: std.ArrayList([]const u8) = .empty;
    defer parent_list.deinit(allocator);
    var parent_it = std.mem.tokenizeScalar(u8, parents, ' ');
    while (parent_it.next()) |parent| try parent_list.append(allocator, parent);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return CliError.UserError;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return CliError.UserError,
    };
    const parent_hashes_value = root.get("parent_hashes") orelse return CliError.UserError;
    const parent_hashes = switch (parent_hashes_value) {
        .object => |object| object,
        else => return CliError.UserError,
    };
    const log_value = parent_hashes.get("log") orelse return CliError.UserError;
    const log_hash = switch (log_value) {
        .string => |value| value,
        else => return CliError.UserError,
    };
    const anchor_value = parent_hashes.get("anchor") orelse return CliError.UserError;
    const anchor_hash = switch (anchor_value) {
        .string => |value| value,
        else => return CliError.UserError,
    };
    const first_parent = if (parent_list.items.len == 0) null else parent_list.items[0];
    if (log_hash.len == 0) {
        if (first_parent == null or anchor_hash.len == 0 or !std.mem.eql(u8, anchor_hash, first_parent.?)) {
            try eprint("gt sync: rejecting {s}: parent_hashes.anchor does not match root genesis parent\n", .{commit});
            return CliError.UserError;
        }
    } else {
        if (first_parent == null or !std.mem.eql(u8, log_hash, first_parent.?)) {
            try eprint("gt sync: rejecting {s}: parent_hashes.log does not match first parent\n", .{commit});
            return CliError.UserError;
        }
        if (anchor_hash.len != 0) {
            try eprint("gt sync: rejecting {s}: non-root event has parent_hashes.anchor\n", .{commit});
            return CliError.UserError;
        }
    }

    const causal_value = parent_hashes.get("causal") orelse return CliError.UserError;
    const causal = switch (causal_value) {
        .array => |array| array,
        else => return CliError.UserError,
    };
    const related_value = parent_hashes.get("related") orelse return CliError.UserError;
    const related = switch (related_value) {
        .array => |array| array,
        else => return CliError.UserError,
    };
    const expected_causal_len = if (parent_list.items.len == 0) 0 else parent_list.items.len - 1;
    if (causal.items.len != expected_causal_len) {
        try eprint("gt sync: rejecting {s}: parent_hashes.causal does not match parent count\n", .{commit});
        return CliError.UserError;
    }
    if (causal.items.len > git.max_causal_parents) {
        try eprint("gt sync: rejecting {s}: parent_hashes.causal exceeds v1 causal parent cap\n", .{commit});
        return CliError.UserError;
    }
    if (related.items.len > git.max_related_parents) {
        try eprint("gt sync: rejecting {s}: parent_hashes.related exceeds v1 related parent cap\n", .{commit});
        return CliError.UserError;
    }
    for (causal.items, 0..) |item, idx| {
        if (item != .string or !std.mem.eql(u8, item.string, parent_list.items[idx + 1])) {
            try eprint("gt sync: rejecting {s}: parent_hashes.causal does not match Git parents\n", .{commit});
            return CliError.UserError;
        }
    }
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

test "missing remote genesis fetch errors are optional" {
    try std.testing.expect(isMissingRemoteGenesis("fatal: couldn't find remote ref refs/gitomi/genesis"));
    try std.testing.expect(!isMissingRemoteGenesis("fatal: authentication failed"));
}
