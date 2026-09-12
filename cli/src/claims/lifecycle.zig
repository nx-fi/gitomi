const std = @import("std");
const m = @import("model.zig");
const ledger = @import("ledger.zig");
const A = std.mem.Allocator;

pub fn renew(a: A, old: m.Record, actor: m.Holder, now: i64, ttl: i64, expected_seq: ?u64) !m.Record {
    if (!old.holder.same(actor)) return error.ClaimHolderChanged;
    if (expected_seq) |seq| if (seq != old.lease_seq) return error.ClaimSequenceChanged;
    if (old.revoked) return error.ClaimRevoked;
    if (try old.expired(actor, now)) return error.ClaimRenewalDeadlineElapsed;
    if (old.lease_seq == std.math.maxInt(u64)) return error.ClaimSequenceExhausted;
    const deadline = now + ttl;
    if (deadline <= try m.timestamp(old.expires_at)) return error.ClaimRenewalMustExtendDeadline;
    if (deadline > try m.timestamp(old.acquired_at) + 4 * 3600) return error.ClaimLifetimeLimit;
    var next = old;
    next.lease_seq += 1;
    next.expires_at = try m.formatTime(a, deadline);
    return next;
}

// Retain the allowance even for our own records when declaring a reap. Reserve
// action slots for the requested operation first; remaining expired records can
// be collected on a later write. Compaction and revocation are separate actions.
pub fn reap(a: A, entries: *std.ArrayList(ledger.Entry), actions: *std.ArrayList(m.Action), now: i64) !void {
    var keep: usize = 0;
    for (entries.items) |entry| {
        if (actions.items.len < 512 and try m.timestamp(entry.record.expires_at) < now - m.skew_allow) {
            try actions.append(a, .{ .op = "reap", .claim_id = entry.record.claim_id, .expired_at = entry.record.expires_at });
        } else {
            entries.items[keep] = entry;
            keep += 1;
        }
    }
    entries.shrinkRetainingCapacity(keep);
}

test "renewal retains identity and lifetime, rejects stale holders and tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var old = m.exampleRecord();
    const now = try m.timestamp("2026-09-12T12:14:00Z");
    const next = try renew(a, old, old.holder, now, 900, 1);
    try std.testing.expectEqual(@as(u64, 2), next.lease_seq);
    try std.testing.expectEqualStrings(old.acquired_at, next.acquired_at);
    try std.testing.expectEqualStrings("2026-09-12T12:29:00Z", next.expires_at);
    try std.testing.expectError(error.ClaimSequenceChanged, renew(a, next, old.holder, now, 1800, 1));
    var other = old.holder;
    other.run_id = "018f0000-0000-7000-8000-000000000011";
    try std.testing.expectError(error.ClaimHolderChanged, renew(a, old, other, now, 900, null));
    try std.testing.expectError(error.ClaimRenewalDeadlineElapsed, renew(a, old, old.holder, now + 60, 900, null));
    try std.testing.expectError(error.ClaimRenewalMustExtendDeadline, renew(a, old, old.holder, now, 30, null));
    try std.testing.expectError(error.ClaimLifetimeLimit, renew(a, old, old.holder, now, 14400, null));
    old.revoked = true;
    try std.testing.expectError(error.ClaimRevoked, renew(a, old, old.holder, now, 900, null));
    old.revoked = false;
    old.lease_seq = std.math.maxInt(u64);
    try std.testing.expectError(error.ClaimSequenceExhausted, renew(a, old, old.holder, now, 900, null));
}

test "opportunistic reaping is strict, includes lapsed revocations, and respects action budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = m.exampleRecord();
    c.revoked = true;
    var entries: std.ArrayList(ledger.Entry) = .empty;
    try entries.append(a, .{ .oid = "blob", .record = c });
    var actions: std.ArrayList(m.Action) = .empty;
    const deadline = try m.timestamp(c.expires_at);
    try reap(a, &entries, &actions, deadline + 30);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try actions.appendNTimes(a, .{ .op = "release", .claim_id = c.claim_id }, 512);
    try reap(a, &entries, &actions, deadline + 31);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    actions.shrinkRetainingCapacity(511);
    try reap(a, &entries, &actions, deadline + 31);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
    try std.testing.expectEqualStrings("reap", actions.items[511].op);
    try std.testing.expectEqualStrings(c.expires_at, actions.items[511].expired_at.?);
}
