const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const io = @import("../io.zig");
const m = @import("model.zig");
const ledger = @import("ledger.zig");
const A = std.mem.Allocator;

pub const Token = struct { claim_id: []const u8, lease_seq: u64, expires_at: []const u8 };

// A local observation only: callers authenticate the local ledger before this
// gate. No fetch, mutation, signing, or implicit renewal belongs on this path.
pub fn fence(entries: []const ledger.Entry, actor: m.Holder, token: Token, now: i64, mode: enum { read, write }) !i64 {
    const c = (ledger.find(entries, token.claim_id) orelse return error.ClaimLeaseNotFound).record;
    if (!c.holder.same(actor)) return error.ClaimHolderChanged;
    if (c.lease_seq != token.lease_seq) return error.ClaimSequenceChanged;
    if (try m.compareTime(c.expires_at, token.expires_at) != .eq) return error.ClaimCapturedDeadlineChanged;
    const deadline = try m.timestamp(token.expires_at);
    if (deadline <= now) return error.ClaimExecutionDeadlineElapsed;
    if (mode == .write and m.eq(u8, c.mode, "read")) return error.ClaimExecRequiresWriteLease;
    // Revocation preserves this deadline and blocks renewal. It does not erase
    // the current token or shorten the holder's exclusion window (§6.2, §8.4).
    return deadline;
}

const Result = extern struct { kind: c_int, status: c_int, error_number: c_int };
extern fn gt_claim_exec(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, deadline_ms: i64, margin_ms: i64, result: *Result) void;
extern fn gt_claim_exec_prepare() c_int;

pub fn prepare() !void {
    if (comptime builtin.os.tag == .linux) {
        const err = gt_claim_exec_prepare();
        if (err != 0) {
            try io.eprint("gt claim exec: could not prepare child-process supervision (OS error {d}). No command was started.\n  Restore normal SIGCHLD handling in the invoking harness and retry.\n", .{err});
            return error.UserError;
        }
    }
}

pub fn run(a: A, entries: []const ledger.Entry, actor: m.Holder, token: Token, argv: []const []const u8, abort_margin: i64, mode: []const u8) !void {
    if (comptime builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) {
        try io.eprint("gt claim exec: supervised execution currently requires Linux x86_64 or aarch64. No command was started.\n  Use a runner adapter with fencing and deadline cancellation support on this platform.\n", .{});
        return error.UserError;
    } else {
        // Prepare buffers before passing the fence. Forked processes never use
        // the Zig allocator, IO globals, SQLite, or Git helpers.
        const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, args) |arg, *z| z.* = (try a.dupeZ(u8, arg)).ptr;
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        var i: usize = 0;
        while (std.c.environ[i]) |raw| : (i += 1) {
            const value = std.mem.span(raw);
            if (std.mem.startsWith(u8, value, "GT_CLAIM_RUN_ID=") or
                std.mem.startsWith(u8, value, "GT_CLAIM_ID=") or
                std.mem.startsWith(u8, value, "GT_CLAIM_LEASE_SEQ=") or
                std.mem.startsWith(u8, value, "GT_CLAIM_EXPIRES_AT=")) continue;
            try env.append(a, raw);
        }
        const pairs = [_][2][]const u8{
            .{ "GT_CLAIM_RUN_ID", actor.run_id },
            .{ "GT_CLAIM_ID", token.claim_id },
            .{ "GT_CLAIM_LEASE_SEQ", try std.fmt.allocPrint(a, "{d}", .{token.lease_seq}) },
            .{ "GT_CLAIM_EXPIRES_AT", token.expires_at },
        };
        for (pairs) |pair| try env.append(a, (try a.dupeZ(u8, try std.fmt.allocPrint(a, "{s}={s}", .{ pair[0], pair[1] }))).ptr);
        const environment = try env.toOwnedSliceSentinel(a, null);
        const deadline = try fence(entries, actor, token, compat.timestamp(), if (m.eq(u8, mode, "read")) .read else .write);
        var result: Result = undefined;
        gt_claim_exec(args.ptr, environment.ptr, deadline * 1000, abort_margin * 1000, &result);
        switch (result.kind) {
            0 => {
                if (compat.timestamp() >= deadline) return error.ClaimExecutionDeadlineElapsed;
            },
            2 => return error.ClaimExecutionDeadlineElapsed,
            3 => {
                try io.eprint("gt claim exec: canceled; the supervised process group has stopped.\n  Inspect the command's partial work before retrying. The claim remains held until release or expiry.\n", .{});
                return error.UserError;
            },
            1 => {
                try io.eprint("gt claim exec: command failed with status {d}; the supervised process group has stopped.\n  Inspect the command's output and partial work before retrying with a current lease.\n", .{result.status});
                return error.UserError;
            },
            else => {
                try io.eprint("gt claim exec: command setup or supervision failed (OS error {d}).\n  Check the executable, arguments, and Linux support for timerfd, seccomp, and process supervision. Inspect any partial work before retrying. The claim was not released.\n", .{result.error_number});
                return error.UserError;
            },
        }
    }
}

test "fence checks captured identity, sequence, and deadline with no peer grace" {
    var c = m.exampleRecord();
    var entries = [_]ledger.Entry{.{ .oid = "blob", .record = c }};
    var token: Token = .{ .claim_id = c.claim_id, .lease_seq = c.lease_seq, .expires_at = c.expires_at };
    const end = try m.timestamp(token.expires_at);
    try std.testing.expectEqual(end, try fence(&entries, c.holder, token, end - 1, .write));
    try std.testing.expectError(error.ClaimExecutionDeadlineElapsed, fence(&entries, c.holder, token, end, .write));
    try std.testing.expectError(error.ClaimLeaseNotFound, fence(&.{}, c.holder, token, end - 1, .write));
    token.lease_seq = 2;
    try std.testing.expectError(error.ClaimSequenceChanged, fence(&entries, c.holder, token, end - 1, .write));
    token.lease_seq = 1;
    token.expires_at = "2026-09-12T12:15:01Z";
    try std.testing.expectError(error.ClaimCapturedDeadlineChanged, fence(&entries, c.holder, token, end - 1, .write));
    token.expires_at = c.expires_at;
    var other = c.holder;
    other.run_id = "018f0000-0000-7000-8000-000000000011";
    try std.testing.expectError(error.ClaimHolderChanged, fence(&entries, other, token, end - 1, .write));
    other = c.holder;
    other.principal = "bob";
    try std.testing.expectError(error.ClaimHolderChanged, fence(&entries, other, token, end - 1, .write));
    entries[0].record.mode = "read";
    try std.testing.expectError(error.ClaimExecRequiresWriteLease, fence(&entries, c.holder, token, end - 1, .write));
    try std.testing.expectEqual(end, try fence(&entries, c.holder, token, end - 1, .read));
    c.revoked = true;
    entries[0].record = c;
    try std.testing.expectEqual(end, try fence(&entries, c.holder, token, end - 1, .write));
}
