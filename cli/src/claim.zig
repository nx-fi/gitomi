const std = @import("std");
const compat = @import("compat");
const git = @import("git.zig");
const repo_mod = @import("repo.zig");
const index = @import("index.zig");
const io = @import("io.zig");
const util = @import("util.zig");
const m = @import("claims/model.zig");
const ledger = @import("claims/ledger.zig");
const display = @import("claims/display.zig");
const hooks = @import("claims/hooks.zig");
const lifecycle = @import("claims/lifecycle.zig");
const A = std.mem.Allocator;

pub const usage =
    "gt claim acquire <paths>... [--mode write|read] [--ttl 15m] [--reason TEXT] [--wait [5m]] [--run-id UUID] [--json]\n" ++
    "gt claim renew <claim-id> [--ttl 15m] [--lease-seq N] [--run-id UUID] [--json]\n" ++
    "gt claim check <paths>... [--mode write|read] [--run-id UUID] [--advisory-only]\n" ++
    "gt claim check --staged [--run-id UUID] [--advisory-only]\n" ++
    "gt claim release <claim-id> | --all | --run UUID\n" ++
    "gt claim ls [--all] [--mine] [--json]\n" ++
    "gt claim hook install|print\n" ++
    "gt peers [<paths>...] [--run-id UUID]\n";

pub fn run(allocator: A, args: []const []const u8, _: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    execute(arena.allocator(), allocator, args) catch |err| {
        switch (err) {
            error.UserError => return err,
            error.ClaimConflict, error.ClaimContention, error.ClaimStale => return err,
            error.ClaimHolderChanged, error.ClaimSequenceChanged, error.ClaimRevoked, error.ClaimRenewalDeadlineElapsed, error.ClaimSequenceExhausted, error.ClaimLeaseNotFound => {
                try io.eprint("gt claim: {s}; this lease cannot authorize further work. Stop work under the old token.\n  Run `gt claim ls --all` to inspect the holder/run and current lease. Acquire a fresh claim before resuming; do not renew a revoked or expired lease.\n", .{@errorName(err)});
                return error.ClaimStale;
            },
            error.ClaimRenewalMustExtendDeadline => {
                try io.eprint("gt claim: renewal must extend the current deadline. --ttl is measured from now.\n  Renew later while the lease is still live, or choose a longer --ttl (30s to 4h). Stop work before the current deadline.\n", .{});
                return error.UserError;
            },
            error.ClaimLifetimeLimit => {
                try io.eprint("gt claim: renewal would exceed four hours since acquired_at, which cannot change.\n  Choose a shorter --ttl, or stop work, release this claim, and acquire a new claim before resuming.\n", .{});
                return error.UserError;
            },
            else => {
                try io.eprint("gt claim: {s}. No claim operation was confirmed.\n  Run `gt claim --help` to correct arguments, `gt status` to check initialization (`gt init` if uninitialized), or `git config --get-regexp '^(user|gpg)\\.'` to check signing.\n  If the ledger is invalid, ask its maintainer to inspect `git log refs/gitomi/claims/ledger`; do not edit through a conflict.\n", .{@errorName(err)});
                return error.UserError;
            },
        }
    };
}

pub fn runPeers(allocator: A, args: []const []const u8, _: []const u8) !void {
    const forwarded = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(forwarded);
    forwarded[0] = "peers";
    @memcpy(forwarded[1..], args);
    if (args.len == 1 and (m.eq(u8, args[0], "--help") or m.eq(u8, args[0], "-h"))) {
        try io.out("gt peers [<paths>...] [--run-id UUID]\nShows up to 50 live peer claims, excluding the current holder/run. Paths are repository-relative; quote globs.\n", .{});
        return;
    }
    try run(allocator, forwarded, "gt peers");
}

const Options = struct {
    command: []const u8,
    paths: []const []const u8 = &.{},
    mode: []const u8 = "write",
    ttl: i64 = 900,
    reason: []const u8 = "",
    wait_seconds: ?i64 = null,
    run_id: []const u8 = "",
    id: ?[]const u8 = null,
    release_run: ?[]const u8 = null,
    all: bool = false,
    mine: bool = false,
    json: bool = false,
    advisory: bool = false,
    staged: bool = false,
    lease_seq: ?u64 = null,
};

fn duration(s: []const u8) !i64 {
    if (s.len < 2) return error.InvalidClaimDuration;
    const multiplier: i64 = switch (s[s.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        else => return error.InvalidClaimDuration,
    };
    for (s[0 .. s.len - 1]) |c| if (!std.ascii.isDigit(c)) return error.InvalidClaimDuration;
    const value = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return error.InvalidClaimDuration;
    if (value < 1 or value > @divTrunc(@as(i64, 86400), multiplier)) return error.InvalidClaimDuration;
    return value * multiplier;
}

fn parse(a: A, args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingClaimCommand;
    var o: Options = .{ .command = args[0] };
    const acquire = m.eq(u8, o.command, "acquire");
    const check = m.eq(u8, o.command, "check");
    const release = m.eq(u8, o.command, "release");
    const renew = m.eq(u8, o.command, "renew");
    const ls = m.eq(u8, o.command, "ls");
    const peers = m.eq(u8, o.command, "peers");
    if (!acquire and !check and !release and !renew and !ls and !peers) return error.UnknownClaimCommand;
    o.run_id = compat.getEnvVarOwned(a, "GT_CLAIM_RUN_ID") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => "",
        else => return err,
    };
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var positional = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional and m.eq(u8, arg, "--")) {
            positional = true;
            continue;
        }
        if (!positional and check and m.eq(u8, arg, "--staged")) {
            o.staged = true;
        } else if (!positional and peers and m.eq(u8, arg, "--run-id")) {
            o.run_id = try util.requireValue(args, &i, arg);
        } else if (!positional and renew and m.eq(u8, arg, "--lease-seq")) {
            const value = try util.requireValue(args, &i, arg);
            for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidClaimSequence;
            o.lease_seq = std.fmt.parseInt(u64, value, 10) catch return error.InvalidClaimSequence;
            if (o.lease_seq.? == 0) return error.InvalidClaimSequence;
        } else if (!positional and std.mem.startsWith(u8, arg, "--")) {
            if (m.eq(u8, arg, "--json") and (acquire or renew or ls)) o.json = true else if (m.eq(u8, arg, "--all") and (release or ls)) o.all = true else if (m.eq(u8, arg, "--mine") and ls) o.mine = true else if (m.eq(u8, arg, "--advisory-only") and check) o.advisory = true else if (m.eq(u8, arg, "--mode") and (acquire or check)) o.mode = try util.requireValue(args, &i, arg) else if (m.eq(u8, arg, "--ttl") and (acquire or renew)) o.ttl = try duration(try util.requireValue(args, &i, arg)) else if (m.eq(u8, arg, "--reason") and acquire) o.reason = try util.requireValue(args, &i, arg) else if (m.eq(u8, arg, "--run-id") and (acquire or renew or check or ls)) o.run_id = try util.requireValue(args, &i, arg) else if (m.eq(u8, arg, "--run") and release) o.release_run = try util.requireValue(args, &i, arg) else if (m.eq(u8, arg, "--wait") and acquire) {
                o.wait_seconds = 300;
                if (i + 1 < args.len) {
                    if (duration(args[i + 1])) |seconds| {
                        o.wait_seconds = seconds;
                        i += 1;
                    } else |_| {}
                }
            } else return error.InvalidClaimOption;
        } else if (acquire or check or peers) {
            if (paths.items.len >= 64) return error.ClaimLimitExceeded;
            try paths.append(a, try m.normalize(a, arg));
        } else if ((release or renew) and o.id == null) {
            o.id = arg;
        } else return error.InvalidClaimArgument;
    }
    if ((acquire or (check and !o.staged)) and paths.items.len == 0) return error.MissingClaimPaths;
    if (o.staged and (paths.items.len != 0 or !m.eq(u8, o.mode, "write"))) return error.StagedCheckRequiresWriteModeAndNoPaths;
    if (!m.eq(u8, o.mode, "write") and !m.eq(u8, o.mode, "read")) return error.InvalidClaimMode;
    if (o.ttl < 30 or o.ttl > 14400) return error.ClaimTtlMustBe30SecondsTo4Hours;
    if (!m.validText(o.reason, 1024)) return error.InvalidClaimReason;
    if (o.run_id.len != 0 and !m.uuid(o.run_id)) return error.InvalidClaimRunId;
    if (o.id) |id| if (!m.uuid(id)) return error.InvalidClaimId;
    if (o.release_run) |id| if (!m.uuid(id)) return error.InvalidClaimRunId;
    if (release and @as(u8, @intFromBool(o.id != null)) + @as(u8, @intFromBool(o.all)) + @as(u8, @intFromBool(o.release_run != null)) != 1) return error.ChooseClaimIdAllOrRun;
    if (renew and o.id == null) return error.MissingClaimId;
    o.paths = paths.items;
    return o;
}

fn deployment(a: A) !void {
    var result = try git.runCommand(a, &.{ "git", "config", "--get", "gitomi.claims.mode" }, null, 1024);
    defer result.deinit();
    if (result.exitCode() == 1) return; // Documented, explicit single-store default.
    if (result.exitCode() != 0) return error.InvalidClaimConfiguration;
    const mode = std.mem.trim(u8, result.stdout, " \r\n");
    if (m.eq(u8, mode, "single-store")) return;
    if (m.eq(u8, mode, "federated")) {
        try io.eprint("gt claim: federated establishment is not implemented. Use a CLI with ledger push/revalidation support for separate clones.\n  Only if all actors share one Git ref store, configure `git config gitomi.claims.mode single-store`.\n", .{});
        return error.FederatedClaimsUnavailable;
    }
    return error.InvalidClaimDeploymentMode;
}

fn execute(a: A, scratch_allocator: A, args: []const []const u8) !void {
    if (args.len == 1 and (m.eq(u8, args[0], "--help") or m.eq(u8, args[0], "-h"))) {
        try io.out("{s}\nDeployment: git config gitomi.claims.mode single-store (default).\nPaths are repository-relative; quote globs. Use a distinct --run-id UUID or GT_CLAIM_RUN_ID for each concurrent agent sharing a signing device.\n", .{usage});
        return;
    }
    if (args.len != 0 and m.eq(u8, args[0], "hook")) {
        if (args.len != 2) return error.ExpectedHookInstallOrPrint;
        if (m.eq(u8, args[1], "print")) {
            try io.out("{s}", .{hooks.script});
            return;
        }
        if (!m.eq(u8, args[1], "install")) return error.ExpectedHookInstallOrPrint;
        var repo = try repo_mod.discoverRepo(a);
        defer repo.deinit();
        var cfg = try repo_mod.loadConfig(a, repo.config_path);
        defer cfg.deinit();
        try repo_mod.validateConfigRepoId(a, cfg);
        try deployment(a);
        try hooks.install(a);
        return;
    }
    var o = try parse(a, args);
    try deployment(a);
    var repo = try repo_mod.discoverRepo(a);
    defer repo.deinit();
    var cfg = try repo_mod.loadConfig(a, repo.config_path);
    defer cfg.deinit();
    try repo_mod.validateConfigRepoId(a, cfg);
    if (o.staged) o.paths = try hooks.stagedPaths(a, repo.root);
    const actor: m.Holder = .{ .principal = cfg.principal, .device = cfg.device, .run_id = o.run_id };
    try index.ensureIndex(a, repo);
    var db = try index.SqliteDb.open(a, repo.index_path, index.sqlite.SQLITE_OPEN_READONLY, false);
    defer db.deinit();
    const id = try util.newUuidV7(a);
    const base = try git.resolveOptionalRef(a, "HEAD");
    const wait_start = std.Io.Clock.awake.now(compat.io()).toMilliseconds();
    var attempt: u32 = 0;
    while (attempt < 12) {
        var arena = std.heap.ArenaAllocator.init(scratch_allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        // Every retry rereads and revalidates; no stale candidate survives CAS.
        const state = try ledger.load(aa, scratch_allocator, &db, cfg.repo_id);
        const now = compat.timestamp();
        if (m.eq(u8, o.command, "ls")) {
            try list(aa, state, actor, o, now);
            return;
        }
        if (m.eq(u8, o.command, "peers")) {
            try io.out("{s}", .{try display.peers(aa, state.entries, actor, o.paths, now)});
            return;
        }
        const release = m.eq(u8, o.command, "release");
        const renew = m.eq(u8, o.command, "renew");
        const previous = if (renew) (ledger.find(state.entries, o.id.?) orelse return error.ClaimLeaseNotFound).record else null;
        const candidate: m.Record = if (previous) |old| try lifecycle.renew(aa, old, actor, now, o.ttl, o.lease_seq) else .{
            .@"$schema" = "urn:gitomi:claim:v1",
            .repo_id = cfg.repo_id,
            .claim_id = id,
            .lease_seq = 1,
            .holder = actor,
            .mode = o.mode,
            .paths = o.paths,
            .acquired_at = try m.formatTime(aa, now),
            .expires_at = try m.formatTime(aa, now + o.ttl),
            .reason = o.reason,
            .base = base orelse "",
        };
        if (!release) {
            var blocked: ?m.Record = null;
            for (state.entries) |entry| {
                if (!(try entry.record.expired(actor, now)) and m.overlap(candidate, entry.record)) {
                    blocked = entry.record;
                    break;
                }
            }
            if (blocked) |peer| {
                const elapsed = std.Io.Clock.awake.now(compat.io()).toMilliseconds() - wait_start;
                if (o.wait_seconds != null and elapsed < o.wait_seconds.? * 1000) {
                    compat.sleep(@intCast(@min(@as(i64, 500), o.wait_seconds.? * 1000 - elapsed) * 1_000_000));
                    continue;
                }
                for (candidate.paths) |path| {
                    if (display.relevant(peer, &.{path})) {
                        try io.eprint("{s}", .{try display.conflict(aa, peer, path, now)});
                        break;
                    }
                }
                if (o.advisory) return;
                if (o.staged) try io.eprint("\n  Resolve the staged-path conflict, then retry git commit.\n  To intentionally bypass the advisory hook: git commit --no-verify\n", .{});
                return error.ClaimConflict;
            }
            if (m.eq(u8, o.command, "check")) {
                if (!o.staged) try io.out("No conflicting claims (single-store).\n", .{});
                return;
            }
            try m.validate(aa, candidate, candidate.claim_id, cfg.repo_id);
        }
        var after: std.ArrayList(ledger.Entry) = .empty;
        var actions: std.ArrayList(m.Action) = .empty;
        for (state.entries) |entry| {
            const c = entry.record;
            if (renew and m.eq(u8, c.claim_id, o.id.?)) continue;
            const selected = release and (if (o.id) |selected_id| m.eq(u8, selected_id, c.claim_id) else c.holder.sameDevice(actor) and (o.all or m.eq(u8, c.holder.run_id, o.release_run.?)));
            if (selected) {
                if (!c.holder.sameDevice(actor)) return error.CannotReleaseAnotherHolder;
                if (actions.items.len >= 512) return error.ClaimActionLimitReleaseIndividualIds;
                try actions.append(aa, .{ .op = "release", .claim_id = c.claim_id });
            } else try after.append(aa, entry);
        }
        if (release and actions.items.len == 0) {
            if (o.id != null) return error.ClaimNotFound;
            try io.out("No matching held claims to release (single-store).\n", .{});
            return;
        }
        const released = actions.items.len;
        if (!release) {
            try after.append(aa, try ledger.storeRecord(aa, candidate));
            try actions.append(aa, .{ .op = if (renew) "renew" else "acquire", .claim_id = candidate.claim_id });
        }
        try lifecycle.reap(aa, &after, &actions, now);
        if (after.items.len > 4096) return error.ClaimLimitExceeded;
        const delta: m.Delta = .{
            .@"$schema" = "urn:gitomi:claim-delta:v1",
            .repo_id = cfg.repo_id,
            .writer = .{ .principal = actor.principal, .device = actor.device },
            .actions = actions.items,
            .wrote_at = try m.formatTime(aa, now),
        };
        if (try ledger.write(aa, &db, state, after.items, delta)) {
            if (previous) |old| if (try old.expired(actor, compat.timestamp())) return error.ClaimRenewalDeadlineElapsed;
            if (!release and try candidate.expired(actor, compat.timestamp())) {
                try io.eprint("gt claim: the lease expired while the signed update was being prepared; do not proceed.\n  Run `gt claim release {s}`, then retry acquisition with a fresh deadline.\n", .{id});
                return error.ClaimStale;
            }
            if (release) try io.out("Released {d} claim(s) (single-store).\n", .{released}) else if (o.json) try io.out("{s}\n", .{try stripUnicodeControls(aa, try m.json(aa, .{ .deployment_mode = "single-store", .established = true, .reason_source = "peer-supplied text", .claim = candidate }))}) else try io.out("Held {s} lease_seq={d} until {s} (single-store, established).\n  When finished: gt claim release {s}\n", .{ candidate.claim_id, candidate.lease_seq, candidate.expires_at, candidate.claim_id });
            return;
        }
        attempt += 1;
        if (attempt < 12) {
            const cap = @min(@as(u64, 2000), @as(u64, 25) << @as(u6, @intCast(attempt - 1)));
            compat.sleep(compat.random.intRangeAtMost(u64, 0, cap) * 1_000_000);
        }
    }
    try io.eprint("gt claim: contention after 12 CAS attempts; no claim operation was confirmed. Retry the same command after a short delay.\n  Run `gt claim ls --all` to inspect current leases.\n", .{});
    return error.ClaimContention;
}

fn displayPaths(a: A, paths: []const []const u8) ![]const []const u8 {
    const safe = try a.alloc([]const u8, paths.len);
    for (paths, safe) |p, *s| s.* = try m.displayText(a, p);
    return safe;
}

fn list(a: A, state: ledger.State, actor: m.Holder, o: Options, now: i64) !void {
    var records: std.ArrayList(m.Record) = .empty;
    for (state.entries) |entry| {
        const c = entry.record;
        if ((!o.all and try c.expired(actor, now)) or (o.mine and !c.holder.same(actor))) continue;
        try records.append(a, c);
    }
    if (o.json) {
        // JSON remains structured data; sanitize fields even in machine output.
        // Record limits already bound strings; JSON escapes ASCII controls.
        // Bidi/C1 are removed by the final Unicode sanitizer below.
        const raw = try m.json(a, .{ .deployment_mode = "single-store", .reason_source = "peer-supplied text", .claims = records.items });
        try io.out("{s}\n", .{try stripUnicodeControls(a, raw)});
        return;
    }
    try io.out("Claims (single-store; successful local CAS establishes a lease)\n", .{});
    for (records.items) |c| {
        try io.out("{s} seq={d} {s}/{s} {s} {s} expires {s}{s}\n  reason {s} [peer-supplied text]\n", .{
            c.claim_id,                                        c.lease_seq,                                 try m.quoted(a, c.holder.principal), try m.quoted(a, c.holder.device),
            if (m.eq(u8, c.mode, "read")) "read" else "write", try m.json(a, try displayPaths(a, c.paths)), c.expires_at,                        if (c.revoked) " REVOKED" else "",
            try m.quoted(a, c.reason),
        });
    }
}

fn stripUnicodeControls(a: A, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (try std.unicode.Utf8View.init(raw)).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        if ((cp >= 127 and cp <= 159) or cp == 0x061c or cp == 0x200e or cp == 0x200f or
            (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) continue;
        try out.appendSlice(a, bytes);
    }
    return out.items;
}

test {
    _ = @import("claims/model.zig");
    _ = @import("claims/ledger.zig");
    _ = @import("claims/display.zig");
    _ = @import("claims/lifecycle.zig");
}
