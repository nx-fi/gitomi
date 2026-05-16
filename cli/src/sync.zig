const std = @import("std");
const auth_binding = @import("auth_binding.zig");
const errors = @import("errors.zig");
const event_mod = @import("event.zig");
const git = @import("git.zig");
const inbox_commit = @import("inbox_commit.zig");
const io = @import("io.zig");
const repo_mod = @import("repo.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const out = io.out;
const eprint = io.eprint;
const gitChecked = git.gitChecked;
const listRefs = git.listRefs;
const emptyTreeOid = git.emptyTreeOid;
const resolveOptionalRef = git.resolveOptionalRef;
const isAncestor = git.isAncestor;
const runCommand = git.runCommand;
const max_git_output = git.max_git_output;
const sanitizeRefSegment = util.sanitizeRefSegment;
const validateEventEnvelope = event_mod.validateEventEnvelope;
const parseValidatedEnvelope = event_mod.parseValidatedEnvelope;
const ActorSeqTracker = event_mod.ActorSeqLastTracker;

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

fn expectedRepoIdForAdmission(allocator: Allocator, genesis_oid: []const u8) ![]u8 {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => {
            var manifest = try repo_mod.loadGenesisManifest(allocator, genesis_oid);
            defer manifest.deinit();
            return try allocator.dupe(u8, manifest.repo_id);
        },
        CliError.ConfigInvalid => {
            try eprint("gt sync: invalid Gitomi config; run `gt init` or fix .git/gitomi/config.toml\n", .{});
            return err;
        },
        else => return err,
    };
    defer cfg.deinit();

    try repo_mod.validateConfigRepoId(allocator, cfg);
    return try allocator.dupe(u8, cfg.repo_id);
}

fn clearStagedRemoteRefs(allocator: Allocator, staging_prefix: []const u8) !void {
    const refs = try listRefs(allocator, staging_prefix);
    defer git.freeStringList(allocator, refs);

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
    defer git.freeStringList(allocator, refs);

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
    defer git.freeStringList(allocator, local_refs);
    if (local_refs.len > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to admit inbox refs; local repository already has {d}, v1 default limit is {d}\n", .{ local_refs.len, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    const new_ref_count = try countNewStagedInboxRefs(allocator, staging_prefix, refs);
    if (local_refs.len + new_ref_count > git.max_default_inbox_refs) {
        try eprint("gt sync: refusing to admit {d} new inbox refs; local repository would exceed v1 default limit {d}\n", .{ new_ref_count, git.max_default_inbox_refs });
        return CliError.UserError;
    }

    const expected_repo_id = try expectedRepoIdForAdmission(allocator, genesis_oid.?);
    defer allocator.free(expected_repo_id);

    const empty_tree = try emptyTreeOid(allocator);
    defer allocator.free(empty_tree);

    for (refs) |staged_ref| {
        try admitStagedInboxRef(allocator, staging_prefix, staged_ref, empty_tree, genesis_oid.?, expected_repo_id);
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
    expected_repo_id: []const u8,
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
            const admitted = validateInboxRange(allocator, staged_ref, old_oid, empty_tree, genesis_oid, expected_repo_id) catch |err| {
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

    const admitted = validateInboxRange(allocator, staged_ref, null, empty_tree, genesis_oid, expected_repo_id) catch |err| {
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
    expected_repo_id: []const u8,
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
        const record = inbox_commit.parseRecord(record_raw) orelse {
            if (inbox_commit.isBlankRawRecord(record_raw)) continue;
            try eprint("gt sync: git log returned malformed inbox commit metadata\n", .{});
            return CliError.GitFailed;
        };
        if (count >= git.max_default_admit_commits) {
            try eprint("gt sync: refusing to admit more than {d} new inbox commits in one pull\n", .{git.max_default_admit_commits});
            return CliError.UserError;
        }
        var envelope = try validateInboxRecord(allocator, record, expected_first_parent, empty_tree);
        defer envelope.deinit();
        try validateEnvelopeRepoId(record.commit, ref, envelope.repo_id, expected_repo_id);
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
        try rememberActorSeq(&actor_seqs, record.commit, ref, envelope.actor_principal, envelope.actor_device, envelope.seq);
        expected_first_parent = record.commit;
        count += 1;
    }
    return count;
}

fn validateEnvelopeRepoId(commit: []const u8, ref: []const u8, repo_id: []const u8, expected_repo_id: []const u8) !void {
    if (std.mem.eql(u8, repo_id, expected_repo_id)) return;
    try eprint("gt sync: rejecting {s} on {s}: repo_id {s} does not match local repo_id {s}\n", .{ commit, ref, repo_id, expected_repo_id });
    return CliError.UserError;
}

fn rememberActorSeq(
    actor_seqs: *ActorSeqTracker,
    commit: []const u8,
    ref: []const u8,
    principal: []const u8,
    device: []const u8,
    seq: i64,
) !void {
    if (try actor_seqs.accept(principal, device, seq)) |previous| {
        try eprint("gt sync: rejecting {s} on {s}: actor {s}/{s} seq {d} is not strictly greater than previous sequence {d}\n", .{ commit, ref, principal, device, seq, previous });
        return CliError.UserError;
    }
}

fn inboxCommitLog(allocator: Allocator, ref: []const u8, local_base: ?[]const u8, genesis_oid: []const u8) ![]u8 {
    if (local_base) |base| {
        const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, ref });
        defer allocator.free(range);
        return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit.log_format, range });
    }
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ genesis_oid, ref });
    defer allocator.free(range);
    return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit.log_format, range });
}

pub fn validateInboxCommit(
    allocator: Allocator,
    commit: []const u8,
    expected_first_parent: ?[]const u8,
    empty_tree: []const u8,
) !event_mod.ValidatedEnvelope {
    const log = try gitChecked(allocator, &.{ "log", "-1", inbox_commit.log_format, commit });
    defer allocator.free(log);

    var records = std.mem.splitScalar(u8, log, 0x1e);
    while (records.next()) |record_raw| {
        const record = inbox_commit.parseRecord(record_raw) orelse {
            if (inbox_commit.isBlankRawRecord(record_raw)) continue;
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
    record: inbox_commit.Record,
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
        try actor_seqs.rememberMax(envelope.actor_principal, envelope.actor_device, envelope.seq);
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
    if (try event_mod.validateParentHashes(allocator, parents, body)) |failure| {
        try eprint("gt sync: rejecting {s}: {s}\n", .{ commit, event_mod.parentHashValidationMessage(failure) });
        return CliError.UserError;
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

test "staging remote segment sanitizes names and falls back when empty" {
    const segment = try stagingRemoteSegment(std.testing.allocator, "HTTPS://GitHub.com/Owner/Repo.git");
    defer std.testing.allocator.free(segment);
    try std.testing.expectEqualStrings("https-github.com-owner-repo.git", segment);

    const fallback = try stagingRemoteSegment(std.testing.allocator, "...");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("remote", fallback);
}

test "staged ref mapping rejects outside and non-inbox refs" {
    try std.testing.expectError(
        CliError.UserError,
        localRefFromStaged(
            std.testing.allocator,
            "refs/gitomi/staging/origin",
            "refs/gitomi/staging/other/inbox/alice/laptop",
        ),
    );
    try std.testing.expectError(
        CliError.UserError,
        localRefFromStaged(
            std.testing.allocator,
            "refs/gitomi/staging/origin",
            "refs/gitomi/staging/origin/genesis",
        ),
    );
}

test "envelope repo id validation rejects foreign repositories" {
    try validateEnvelopeRepoId(
        "commit-1",
        "refs/gitomi/inbox/alice/laptop",
        "018f0000-0000-7000-8000-000000000001",
        "018f0000-0000-7000-8000-000000000001",
    );
    try std.testing.expectError(
        CliError.UserError,
        validateEnvelopeRepoId(
            "commit-2",
            "refs/gitomi/inbox/alice/laptop",
            "018f0000-0000-7000-8000-000000000002",
            "018f0000-0000-7000-8000-000000000001",
        ),
    );
}

test "first parent validation accepts expected history shapes" {
    try validateFirstParentList("root", "", null);
    try validateFirstParentList("child", "parent-a parent-b", "parent-a");

    try std.testing.expectError(CliError.UserError, validateFirstParentList("bad-root", "parent-a", null));
    try std.testing.expectError(CliError.UserError, validateFirstParentList("bad-child", "parent-b parent-a", "parent-a"));
}

test "actor sequence tracker enforces strict per-actor monotonic order" {
    var tracker = ActorSeqTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try rememberActorSeq(&tracker, "commit-1", "refs/gitomi/inbox/ab/c", "ab", "c", 1);
    try rememberActorSeq(&tracker, "commit-2", "refs/gitomi/inbox/a/bc", "a", "bc", 1);
    try rememberActorSeq(&tracker, "commit-3", "refs/gitomi/inbox/ab/c", "ab", "c", 2);

    try std.testing.expectError(
        CliError.UserError,
        rememberActorSeq(&tracker, "commit-4", "refs/gitomi/inbox/ab/c", "ab", "c", 2),
    );
    try std.testing.expectError(
        CliError.UserError,
        rememberActorSeq(&tracker, "commit-5", "refs/gitomi/inbox/ab/c", "ab", "c", 0),
    );

    try tracker.rememberMax("ab", "c", 10);
    try std.testing.expectError(
        CliError.UserError,
        rememberActorSeq(&tracker, "commit-6", "refs/gitomi/inbox/ab/c", "ab", "c", 10),
    );
    try rememberActorSeq(&tracker, "commit-7", "refs/gitomi/inbox/ab/c", "ab", "c", 11);
}
