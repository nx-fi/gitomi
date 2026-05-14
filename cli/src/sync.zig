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

    try admitStagedGenesisRef(allocator, staging_prefix);
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
    try validateConfiguredRepoIfPresent(allocator);

    const inbox_refs = try listRefs(allocator, "refs/gitomi/inbox");
    defer freeStringList(allocator, inbox_refs);

    const genesis_oid = try resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (genesis_oid) |oid| allocator.free(oid);

    if (inbox_refs.len == 0 and genesis_oid == null) {
        try out("no local Gitomi refs to push\n", .{});
        return;
    }

    if (genesis_oid != null) {
        try out("pushing Gitomi genesis ref to {s}\n", .{remote});
        try pushGenesisRef(allocator, remote);
    }

    try pushInboxRefs(allocator, remote, inbox_refs);
}

fn validateConfiguredRepoIfPresent(allocator: Allocator) !void {
    var repo = try repo_mod.discoverRepo(allocator);
    defer repo.deinit();

    var cfg = repo_mod.loadConfig(allocator, repo.config_path) catch |err| switch (err) {
        CliError.ConfigNotFound => return,
        CliError.ConfigInvalid => {
            try eprint("gt sync: invalid Gitomi config; run `gt init` or fix .git/gitomi/config.toml\n", .{});
            return err;
        },
        else => return err,
    };
    defer cfg.deinit();

    try repo_mod.validateConfigRepoId(allocator, cfg);
}

fn pushInboxRefs(allocator: Allocator, remote: []const u8, refs: [][]u8) !void {
    if (refs.len == 0) {
        try out("no authoritative Gitomi inbox refs to push\n", .{});
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

pub fn admitStagedGenesisRef(allocator: Allocator, staging_prefix: []const u8) !void {
    const staged_ref = try std.fmt.allocPrint(allocator, "{s}/genesis", .{staging_prefix});
    defer allocator.free(staged_ref);
    const staged_oid = (try resolveOptionalRef(allocator, staged_ref)) orelse return;
    defer allocator.free(staged_oid);

    const local_oid = try resolveOptionalRef(allocator, repo_mod.genesis_ref);
    defer if (local_oid) |oid| allocator.free(oid);

    if (local_oid) |local| {
        if (std.mem.eql(u8, local, staged_oid)) {
            try out("unchanged {s}\n", .{repo_mod.genesis_ref});
        } else {
            try out("conflicting {s}; staged ref left at {s}\n", .{ repo_mod.genesis_ref, staged_ref });
        }
        return;
    }

    try verifyCommitSignature(allocator, staged_oid);
    try repo_mod.validateGenesisManifest(allocator, staged_oid);
    const updated = try gitChecked(allocator, &.{ "update-ref", repo_mod.genesis_ref, staged_oid, "" });
    defer allocator.free(updated);
    try out("created {s}\n", .{repo_mod.genesis_ref});
    try autoInitConfigFromGenesis(allocator, staged_oid);
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
        try admitStagedInboxRef(allocator, staging_prefix, staged_ref, empty_tree);
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
            const admitted = validateInboxRange(allocator, staged_ref, old_oid, empty_tree) catch |err| {
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

    const admitted = validateInboxRange(allocator, staged_ref, null, empty_tree) catch |err| {
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
) !usize {
    const log = try inboxCommitLog(allocator, ref, local_base);
    defer allocator.free(log);

    var count: usize = 0;
    var expected_first_parent = local_base;
    var last_seq = try seqForCommit(allocator, local_base);
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
        if (last_seq) |previous_seq| {
            if (envelope.seq <= previous_seq) {
                try eprint("gt sync: rejecting {s}: seq {d} is not strictly greater than previous sequence {d}\n", .{ record.commit, envelope.seq, previous_seq });
                return CliError.UserError;
            }
        }
        last_seq = envelope.seq;
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

fn inboxCommitLog(allocator: Allocator, ref: []const u8, local_base: ?[]const u8) ![]u8 {
    if (local_base) |base| {
        const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ base, ref });
        defer allocator.free(range);
        return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit_log_format, range });
    }
    return gitChecked(allocator, &.{ "log", "--first-parent", "--reverse", inbox_commit_log_format, ref });
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

fn seqForCommit(allocator: Allocator, commit_opt: ?[]const u8) !?i64 {
    const commit = commit_opt orelse return null;
    const body_raw = try gitChecked(allocator, &.{ "show", "-s", "--format=%b", commit });
    defer allocator.free(body_raw);
    const body = std.mem.trim(u8, body_raw, " \t\r\n");
    var envelope = parseValidatedEnvelope(allocator, body) catch return null;
    defer envelope.deinit();
    return envelope.seq;
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
    const expected_log = if (parent_list.items.len == 0) "" else parent_list.items[0];
    if (!std.mem.eql(u8, log_hash, expected_log)) {
        try eprint("gt sync: rejecting {s}: parent_hashes.log does not match first parent\n", .{commit});
        return CliError.UserError;
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
