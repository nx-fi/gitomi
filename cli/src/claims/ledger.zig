const std = @import("std");
const git = @import("../git.zig");
const util = @import("../util.zig");
const index = @import("../index.zig");
const m = @import("model.zig");
const A = std.mem.Allocator;
pub const ref = "refs/gitomi/claims/ledger";
pub const Entry = struct { oid: []const u8, record: m.Record };
pub const State = struct {
    head: ?[]const u8 = null,
    entries: []const Entry = &.{},
};

// All allocations belong to the caller's per-attempt arena. No worktree or Git
// index is used: blob/tree objects are read and written through Git plumbing.
pub fn readTree(a: A, head: []const u8, repo_id: []const u8) ![]const Entry {
    const raw = try git.gitChecked(a, &.{ "ls-tree", "-r", "-t", "-z", "--full-tree", head });
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, raw, 0);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidClaimTree;
        var fields = std.mem.tokenizeScalar(u8, line[0..tab], ' ');
        const mode = fields.next() orelse return error.InvalidClaimTree;
        const kind = fields.next() orelse return error.InvalidClaimTree;
        const oid = fields.next() orelse return error.InvalidClaimTree;
        const path = line[tab + 1 ..];
        if (m.eq(u8, path, "claims") and m.eq(u8, kind, "tree") and m.eq(u8, mode, "040000")) continue;
        if (!m.eq(u8, mode, "100644") or !m.eq(u8, kind, "blob") or path.len != 48 or
            !std.mem.startsWith(u8, path, "claims/") or !std.mem.endsWith(u8, path, ".json")) return error.InvalidClaimTree;
        if (entries.items.len >= 4096) return error.ClaimLimitExceeded;
        const body = try git.gitCheckedInputMax(a, &.{ "cat-file", "blob", oid }, null, 16 * 1024);
        var record = (try std.json.parseFromSlice(m.Record, a, body, .{ .allocate = .alloc_always })).value;
        try m.validate(a, record, path[7..43], repo_id);
        const paths = try a.alloc([]const u8, record.paths.len);
        for (record.paths, paths) |p, *normalized| normalized.* = try m.normalize(a, p);
        record.paths = paths;
        try entries.append(a, .{ .oid = oid, .record = record });
    }
    return entries.toOwnedSlice(a);
}

pub fn find(entries: []const Entry, id: []const u8) ?Entry {
    for (entries) |entry| if (m.eq(u8, entry.record.claim_id, id)) return entry;
    return null;
}

fn verifySigner(a: A, db: *index.SqliteDb, commit: []const u8, writer: m.Writer, active: bool) !void {
    if (!m.validText(writer.principal, 256) or !util.isRefSafeSegment(writer.principal) or
        !m.validText(writer.device, 256) or !util.isRefSafeSegment(writer.device)) return error.InvalidClaimSigner;
    const fingerprint = (try git.verifiedCommitSigningKeyFingerprint(a, commit)) orelse return error.UnverifiedClaimSigner;
    // Revocation must block new writes without invalidating the signed history
    // of unrelated leases. Both tables contain only accepted device bindings.
    var stmt = try db.prepare(if (active)
        "SELECT 1 FROM identity_devices WHERE principal = ? AND device = ? AND key_fingerprint = ? AND revoked_event_hash IS NULL LIMIT 1"
    else
        "SELECT 1 FROM identity_device_events WHERE principal = ? AND device = ? AND key_fingerprint = ? AND event_type = 'identity.device_added' LIMIT 1");
    defer stmt.deinit();
    try stmt.bindText(1, writer.principal);
    try stmt.bindText(2, writer.device);
    try stmt.bindText(3, fingerprint);
    if (!(try stmt.step())) return error.UnboundClaimSigner;
}

fn validateDeltaAt(before: []const Entry, after: []const Entry, delta: m.Delta, verifier_now: i64) !void {
    if (!m.eq(u8, delta.@"$schema", "urn:gitomi:claim-delta:v1") or
        delta.actions.len == 0 or delta.actions.len > 512) return error.InvalidClaimDelta;
    const wrote = try m.timestamp(delta.wrote_at);
    // A signature authenticates wrote_at but cannot make it a trustworthy
    // clock. Bound every commit, including intermediate fetched commits, to the
    // verifier's clock before using wrote_at for expiry authorization.
    if (wrote > verifier_now + m.max_skew) return error.FutureClaimDelta;
    const signer: m.Holder = .{ .principal = delta.writer.principal, .device = delta.writer.device };
    var changed: usize = 0;
    for (before) |old| {
        const next = find(after, old.record.claim_id);
        if (next == null or !m.eq(u8, old.oid, next.?.oid)) changed += 1;
    }
    for (after) |next| if (find(before, next.record.claim_id) == null) {
        changed += 1;
    };
    if (changed != delta.actions.len) return error.ClaimDeltaDiffMismatch;
    for (delta.actions, 0..) |action, i| {
        if (!m.uuid(action.claim_id)) return error.InvalidClaimDelta;
        for (delta.actions[0..i]) |previous| if (m.eq(u8, previous.claim_id, action.claim_id)) return error.ClaimDeltaDiffMismatch;
        const old = find(before, action.claim_id);
        const next = find(after, action.claim_id);
        if (old == null and next != null) {
            if (!m.eq(u8, action.op, "acquire") or next.?.record.lease_seq != 1 or
                !next.?.record.holder.sameDevice(signer) or
                action.expired_at != null or action.authorized_by != null) return error.UnauthorizedClaimDelta;
        } else if (old != null and next == null) {
            if (action.authorized_by != null) return error.UnauthorizedClaimDelta;
            if (m.eq(u8, action.op, "release")) {
                if (!old.?.record.holder.sameDevice(signer) or action.expired_at != null) return error.UnauthorizedClaimDelta;
            } else if (m.eq(u8, action.op, "reap")) {
                if (try m.timestamp(old.?.record.expires_at) >= wrote - m.skew_allow or
                    !m.eq(u8, action.expired_at orelse return error.InvalidClaimDelta, old.?.record.expires_at)) return error.UnauthorizedClaimDelta;
            } else return error.ClaimDeltaDiffMismatch;
        } else if (old != null and next != null and !m.eq(u8, old.?.oid, next.?.oid)) {
            const previous = old.?.record;
            const renewed = next.?.record;
            if (!m.eq(u8, action.op, "renew")) return error.UnsupportedClaimLifecycleDelta;
            if (action.expired_at != null or action.authorized_by != null or
                !previous.holder.sameDevice(signer) or !renewed.holder.sameDevice(signer) or
                !m.eq(u8, previous.claim_id, renewed.claim_id) or
                !m.eq(u8, previous.repo_id, renewed.repo_id) or
                !m.eq(u8, previous.acquired_at, renewed.acquired_at) or
                renewed.lease_seq <= previous.lease_seq or previous.revoked or
                try m.compareTime(previous.expires_at, delta.wrote_at) != .gt or
                try m.compareTime(renewed.expires_at, previous.expires_at) != .gt) return error.UnauthorizedClaimDelta;
        } else {
            return error.UnsupportedClaimLifecycleDelta;
        }
    }
    for (after, 0..) |left, i| {
        if (try left.record.expired(signer, wrote)) continue;
        for (after[i + 1 ..]) |right| {
            if (!(try right.record.expired(signer, wrote)) and m.overlap(left.record, right.record)) return error.ConflictingClaimLedger;
        }
    }
}

pub fn validateDelta(before: []const Entry, after: []const Entry, delta: m.Delta) !void {
    return validateDeltaAt(before, after, delta, @import("compat").timestamp());
}

fn commitDelta(a: A, head: []const u8) !m.Delta {
    const raw = try git.gitCheckedInputMax(a, &.{ "cat-file", "commit", head }, null, 300 * 1024);
    const start = (std.mem.indexOf(u8, raw, "\n\n") orelse return error.InvalidClaimCommit) + 2;
    const message = raw[start..];
    const split = std.mem.indexOf(u8, message, "\n\n") orelse return error.InvalidClaimCommit;
    if (split == 0 or split > 512 or std.mem.indexOfScalar(u8, message[0..split], '\n') != null) return error.InvalidClaimCommit;
    const body = message[split + 2 ..];
    if (body.len > 256 * 1024) return error.ClaimLimitExceeded;
    return (try std.json.parseFromSlice(m.Delta, a, body, .{ .allocate = .alloc_always })).value;
}

pub fn verifyCommit(a: A, db: *index.SqliteDb, head: []const u8, before: []const Entry, after: []const Entry, repo_id: []const u8, verifier_now: i64) !void {
    const delta = try commitDelta(a, head);
    if (!m.eq(u8, delta.repo_id, repo_id)) return error.InvalidClaimRepository;
    try verifySigner(a, db, head, delta.writer, false);
    try validateDeltaAt(before, after, delta, verifier_now);
}

// Read current state directly from the tip tree. Independently authenticate the
// local chain before trusting it. No reducer, inbox admission, or quarantine.
// A future verified-head cache can avoid rechecking history across invocations.
pub fn load(a: A, scratch_allocator: A, db: *index.SqliteDb, repo_id: []const u8) !State {
    const head = (try resolve(a)) orelse return .{};
    const verifier_now = @import("compat").timestamp();
    const chain = try git.gitChecked(a, &.{ "rev-list", "--first-parent", "--reverse", "--parents", head });
    var lines = std.mem.tokenizeScalar(u8, chain, '\n');
    var previous: ?[]const u8 = null;
    var previous_arena = std.heap.ArenaAllocator.init(scratch_allocator);
    defer previous_arena.deinit();
    var before: []const Entry = &.{};
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const commit = words.next() orelse return error.InvalidClaimCommit;
        const parent = words.next();
        if (words.next() != null or (previous == null) != (parent == null)) return error.InvalidClaimParents;
        if (parent != null and !m.eq(u8, parent.?, previous.?)) return error.InvalidClaimParents;
        var current_arena = std.heap.ArenaAllocator.init(scratch_allocator);
        errdefer current_arena.deinit();
        const ca = current_arena.allocator();
        const after = try readTree(ca, commit, repo_id);
        try verifyCommit(ca, db, commit, before, after, repo_id, verifier_now);
        previous_arena.deinit();
        previous_arena = current_arena;
        before = after;
        previous = commit;
    }
    if (previous == null or !m.eq(u8, previous.?, head)) return error.InvalidClaimCommit;
    return .{ .head = head, .entries = try readTree(a, head, repo_id) };
}

pub fn storeRecord(a: A, record: m.Record) !Entry {
    const body = try m.json(a, record);
    if (body.len > 16 * 1024) return error.ClaimLimitExceeded;
    const raw = try git.gitCheckedInput(a, &.{ "hash-object", "-w", "--stdin" }, body);
    return .{ .oid = std.mem.trim(u8, raw, "\r\n"), .record = record };
}

pub fn write(a: A, db: *index.SqliteDb, before: State, after: []const Entry, delta: m.Delta) !bool {
    try validateDelta(before.entries, after, delta);
    var listing: std.ArrayList(u8) = .empty;
    for (after) |entry| {
        try @import("compat").appendPrint(a, &listing, "100644 blob {s}\t{s}.json\x00", .{ entry.oid, entry.record.claim_id });
    }
    const subtree = std.mem.trim(u8, try git.gitCheckedInput(a, &.{ "mktree", "-z" }, listing.items), "\r\n");
    const root_listing = if (after.len == 0) "" else try std.fmt.allocPrint(a, "040000 tree {s}\tclaims\x00", .{subtree});
    const tree = std.mem.trim(u8, try git.gitCheckedInput(a, &.{ "mktree", "-z" }, root_listing), "\r\n");
    const body = try m.json(a, delta);
    if (body.len > 256 * 1024) return error.ClaimLimitExceeded;
    const subject = try std.fmt.allocPrint(a, "claim.{s} {s}", .{ delta.actions[0].op, delta.actions[0].claim_id[0..7] });
    const message = try std.fmt.allocPrint(a, "{s}\n\n{s}\n", .{ subject, body });
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "commit-tree", "-S", tree });
    if (before.head) |parent| try args.appendSlice(a, &.{ "-p", parent });
    const commit = std.mem.trim(u8, try git.gitCheckedInput(a, args.items, message), "\r\n");
    try verifySigner(a, db, commit, delta.writer, true);
    // Signing (including an interactive signer) can outlast the old lease.
    // Recheck immediately before CAS; a new deadline cannot revive an old one.
    for (delta.actions) |action| {
        if (!m.eq(u8, action.op, "renew")) continue;
        const old = (find(before.entries, action.claim_id) orelse return error.InvalidClaimDelta).record;
        if (try old.expired(old.holder, @import("compat").timestamp())) return error.ClaimRenewalDeadlineElapsed;
    }
    // An empty old OID requires absence (also works with SHA-256 repositories).
    var result = try git.runCommand(a, &.{ "git", "update-ref", "--no-deref", ref, commit, before.head orelse "" }, null, git.max_git_output);
    defer result.deinit();
    if (result.exitCode() == 0) return true;
    const current = try resolve(a);
    const moved = if (current) |oid| before.head == null or !m.eq(u8, oid, before.head.?) else before.head != null;
    if (moved or (std.mem.indexOf(u8, result.stderr, "cannot lock ref") != null and
        std.mem.indexOf(u8, result.stderr, "File exists") != null)) return false;
    return error.ClaimRefWriteFailed;
}

fn resolve(a: A) !?[]const u8 {
    // Unlike rev-parse's optional helper, an IO failure must not masquerade as
    // an empty ledger and make a read-only conflict check return success.
    var symbolic = try git.runCommand(a, &.{ "git", "symbolic-ref", "-q", ref }, null, 1024);
    defer symbolic.deinit();
    if (symbolic.exitCode() == 0) return error.SymbolicClaimRef;
    if (symbolic.exitCode() != 1) return error.ClaimRefReadFailed;
    var result = try git.runCommand(a, &.{ "git", "for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)", ref }, null, git.max_git_output);
    defer result.deinit();
    // Git can return success while warning that it ignored a broken ref.
    // Treating that as absence would make 'check' fail open.
    if (result.exitCode() != 0 or result.stderr.len != 0) return error.ClaimRefReadFailed;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (!m.eq(u8, fields.next() orelse return error.InvalidClaimRef, ref)) continue;
        const oid = fields.next() orelse return error.InvalidClaimRef;
        if ((fields.next() orelse return error.InvalidClaimRef).len != 0) return error.SymbolicClaimRef;
        if (!git.isFullOid(oid)) return error.InvalidClaimRef;
        return try a.dupe(u8, oid);
    }
    return null;
}

test "delta authority applies only to changed claims; peer deletion waits out skew" {
    const c = m.exampleRecord();
    const alice: Entry = .{ .oid = "alice-blob", .record = c };
    var b = c;
    b.claim_id = "018f0000-0000-7000-8000-000000000003";
    b.holder = .{ .principal = "bob", .device = "desktop" };
    b.paths = &.{"docs/**"};
    const bob: Entry = .{ .oid = "bob-blob", .record = b };
    var delta: m.Delta = .{
        .@"$schema" = "urn:gitomi:claim-delta:v1",
        .repo_id = c.repo_id,
        .writer = .{ .principal = "bob", .device = "desktop" },
        .actions = &.{.{ .op = "acquire", .claim_id = b.claim_id }},
        .wrote_at = "2026-09-12T12:00:00Z",
    };
    try validateDelta(&.{alice}, &.{ alice, bob }, delta);
    delta.actions = &.{.{ .op = "release", .claim_id = c.claim_id }};
    try std.testing.expectError(error.UnauthorizedClaimDelta, validateDelta(&.{alice}, &.{}, delta));
    delta.actions = &.{.{ .op = "reap", .claim_id = c.claim_id, .expired_at = c.expires_at }};
    delta.wrote_at = "2026-09-12T12:15:30Z";
    try std.testing.expectError(error.UnauthorizedClaimDelta, validateDelta(&.{alice}, &.{}, delta));
    delta.wrote_at = "2026-09-12T12:15:31Z";
    try validateDelta(&.{alice}, &.{}, delta);
    try validateDeltaAt(&.{alice}, &.{}, delta, try m.timestamp("2026-09-12T12:15:16Z"));
    delta.wrote_at = "2026-09-13T12:15:31Z";
    try std.testing.expectError(error.FutureClaimDelta, validateDeltaAt(
        &.{alice},
        &.{},
        delta,
        try m.timestamp("2026-09-12T12:15:16Z"),
    ));
    delta.wrote_at = "2026-09-12T12:15:31Z";
    delta.actions = &.{.{ .op = "steal", .claim_id = c.claim_id, .authorized_by = "bob" }};
    try std.testing.expectError(error.UnauthorizedClaimDelta, validateDelta(&.{alice}, &.{}, delta));
}

test "declared actions must match diff exactly, and acquisitions cannot create conflicts" {
    const c = m.exampleRecord();
    const entry: Entry = .{ .oid = "one", .record = c };
    const action: m.Action = .{ .op = "acquire", .claim_id = c.claim_id };
    var delta: m.Delta = .{
        .@"$schema" = "urn:gitomi:claim-delta:v1",
        .repo_id = c.repo_id,
        .writer = .{ .principal = "alice", .device = "laptop" },
        .actions = &.{action},
        .wrote_at = c.acquired_at,
    };
    try validateDelta(&.{}, &.{entry}, delta);
    try std.testing.expectError(error.ClaimDeltaDiffMismatch, validateDelta(&.{entry}, &.{entry}, delta));
    var other = c;
    other.claim_id = "018f0000-0000-7000-8000-000000000003";
    other.holder = .{ .principal = "bob", .device = "desktop" };
    const added: Entry = .{ .oid = "two", .record = other };
    delta.writer = .{ .principal = "bob", .device = "desktop" };
    delta.actions = &.{.{ .op = "acquire", .claim_id = other.claim_id }};
    try std.testing.expectError(error.ConflictingClaimLedger, validateDelta(&.{entry}, &.{ entry, added }, delta));
    delta.actions = &.{action};
    try std.testing.expectError(error.UnauthorizedClaimDelta, validateDelta(&.{}, &.{entry}, delta));
}

test "renewal diff rejects foreign holders, stale sequences, expiry, and revocation" {
    var old = m.exampleRecord();
    var next = old;
    next.lease_seq = 2;
    next.expires_at = "2026-09-12T12:29:00Z";
    var delta: m.Delta = .{
        .@"$schema" = "urn:gitomi:claim-delta:v1",
        .repo_id = old.repo_id,
        .writer = .{ .principal = "alice", .device = "laptop" },
        .actions = &.{.{ .op = "renew", .claim_id = old.claim_id }},
        .wrote_at = "2026-09-12T12:14:00Z",
    };
    try validateDelta(&.{.{ .oid = "old", .record = old }}, &.{.{ .oid = "new", .record = next }}, delta);
    for (0..10) |scenario| {
        var invalid = next;
        var previous = old;
        var d = delta;
        switch (scenario) {
            0 => invalid.lease_seq = old.lease_seq,
            1 => invalid.holder.principal = "bob",
            2 => previous.holder.principal = "bob",
            3 => invalid.acquired_at = "2026-09-12T12:01:00Z",
            4 => invalid.repo_id = "018f0000-0000-7000-8000-000000000099",
            5 => previous.revoked = true,
            6 => invalid.expires_at = old.expires_at,
            7 => d.wrote_at = old.expires_at,
            8 => d.actions = &.{.{ .op = "renew", .claim_id = old.claim_id, .authorized_by = "alice" }},
            9 => d.actions = &.{.{ .op = "renew", .claim_id = old.claim_id, .expired_at = old.expires_at }},
            else => unreachable,
        }
        try std.testing.expectError(error.UnauthorizedClaimDelta, validateDelta(&.{.{ .oid = "old", .record = previous }}, &.{.{ .oid = "new", .record = invalid }}, d));
    }
    // Timestamp comparisons retain sub-second precision at admission. Holder
    // execution still rounds its own deadline down and stops conservatively.
    old.expires_at = "2026-09-12T12:15:00.1Z";
    next.expires_at = "2026-09-12T12:15:00.2Z";
    delta.wrote_at = "2026-09-12T12:15:00.01Z";
    try validateDelta(&.{.{ .oid = "old", .record = old }}, &.{.{ .oid = "new", .record = next }}, delta);
}
