const std = @import("std");
const compat = @import("compat");
const m = @import("model.zig");
const ledger = @import("ledger.zig");
const A = std.mem.Allocator;

pub const peer_limit = 50;

fn quotedSummary(a: A, value: []const u8, limit: usize) ![]const u8 {
    const clean = try m.displayText(a, value);
    defer a.free(clean);
    if (clean.len <= limit) return m.json(a, clean);
    var end = limit;
    while (end != 0 and clean[end] & 0xc0 == 0x80) end -= 1;
    const clipped = try std.fmt.allocPrint(a, "{s}…", .{clean[0..end]});
    defer a.free(clipped);
    return m.json(a, clipped);
}

pub fn relevant(record: m.Record, paths: []const []const u8) bool {
    if (paths.len == 0) return true;
    for (paths) |path| for (record.paths) |pattern| {
        if (m.intersects(path, pattern)) return true;
    };
    return false;
}

/// A bounded summary of claim metadata only. Never reads inbox trace/session
/// bodies. One physical line per peer, even for hostile paths and reasons.
pub fn peers(a: A, entries: []const ledger.Entry, actor: m.Holder, paths: []const []const u8, now: i64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "Peers (single-store)\n");
    var count: usize = 0;
    for (entries) |entry| {
        const c = entry.record;
        if (c.holder.same(actor) or try c.expired(actor, now) or !relevant(c, paths)) continue;
        count += 1;
        if (count > peer_limit) continue;
        try compat.appendPrint(a, &buf, "{s} {s}/{s} run={s} {s}{s} ", .{
            c.claim_id,                                             try quotedSummary(a, c.holder.principal, 64),      try quotedSummary(a, c.holder.device, 64),
            if (c.holder.run_id.len == 0) "-" else c.holder.run_id, if (m.eq(u8, c.mode, "read")) "read" else "write", if (c.revoked) " REVOKED" else "",
        });
        for (c.paths[0..@min(c.paths.len, 3)], 0..) |path, i| {
            if (i != 0) try buf.appendSlice(a, ", ");
            try buf.appendSlice(a, try quotedSummary(a, path, 80));
        }
        if (c.paths.len > 3) try compat.appendPrint(a, &buf, " (+{d} paths)", .{c.paths.len - 3});
        try compat.appendPrint(a, &buf, " expires in {d}s; reason {s} [peer-supplied text]\n", .{
            @max(@as(i64, 0), try m.timestamp(c.expires_at) - now), try quotedSummary(a, c.reason, 160),
        });
    }
    if (count == 0) try buf.appendSlice(a, "No relevant live peer claims.\n");
    if (count > peer_limit) try compat.appendPrint(a, &buf, "{d} more peer claims; narrow with `gt peers <paths>` or run `gt claim ls --all`.\n", .{count - peer_limit});
    return buf.toOwnedSlice(a);
}

/// Shell quoting is for a runnable suggestion, never for executing input.
/// If sanitizing a path would change its meaning, omit the path suggestion.
fn commandPath(a: A, path: []const u8) !?[]const u8 {
    const clean = try m.displayText(a, path);
    defer a.free(clean);
    if (!m.eq(u8, clean, path)) return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.append(a, '\'');
    for (path) |c| {
        if (c == '\'') try buf.appendSlice(a, "'\\''") else try buf.append(a, c);
    }
    try buf.append(a, '\'');
    return try buf.toOwnedSlice(a);
}

pub fn conflict(a: A, peer: m.Record, requested: []const u8, now: i64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try compat.appendPrint(a, &buf, "BLOCKED  {s}\n  held by {s} (device {s}, run {s}), {s}{s}, expires in {d}s\n" ++
        "  reason {s} [peer-supplied text]\n\n", .{
        try m.quoted(a, requested),                                   try m.quoted(a, peer.holder.principal),               try m.quoted(a, peer.holder.device),
        if (peer.holder.run_id.len == 0) "-" else peer.holder.run_id, if (m.eq(u8, peer.mode, "read")) "read" else "write", if (peer.revoked) " REVOKED" else "",
        @max(@as(i64, 0), try m.timestamp(peer.expires_at) - now),    try m.quoted(a, peer.reason),
    });
    if (try commandPath(a, requested)) |path| {
        try compat.appendPrint(a, &buf, "  gt peers -- {s}    inspect peers on this path\n", .{path});
    } else try buf.appendSlice(a, "  gt peers    inspect current peers\n");
    try buf.appendSlice(a, "  gt claim ls --all    inspect the full ledger\n" ++
        "  Retry your acquire command with --wait 5m, or choose different paths.\n" ++
        "  Peer clock allowance may retain exclusion for 30s after the displayed expiry.\n\n" ++
        "  This repository coordinates parallel agents with leases. Claim paths before editing.\n" ++
        "  Exit 3 means do not proceed. See AGENTS.md.\n");
    return buf.toOwnedSlice(a);
}

test "peers include shared readers, filter own and expired claims, and cap output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actor = m.exampleRecord().holder;
    var entries: [54]ledger.Entry = undefined;
    for (&entries, 0..) |*entry, i| {
        var c = m.exampleRecord();
        c.claim_id = try std.fmt.allocPrint(a, "018f0000-0000-7000-8000-{d:0>12}", .{i});
        c.holder.principal = "bob";
        c.mode = "read";
        entry.* = .{ .oid = "fixture", .record = c };
    }
    entries[0].record.holder = actor;
    entries[1].record.expires_at = "2026-09-12T11:00:00Z";
    entries[2].record.paths = &.{"docs/**"};
    entries[3].record.reason = "summary\n\x1b[31m\u{202e}text";
    entries[3].record.revoked = true;
    const result = try peers(a, &entries, actor, &.{"src/auth.zig"}, try m.timestamp("2026-09-12T12:01:00Z"));
    try std.testing.expectEqual(@as(usize, 52), std.mem.count(u8, result, "\n"));
    try std.testing.expectEqual(@as(usize, 50), std.mem.count(u8, result, "[peer-supplied text]"));
    try std.testing.expect(std.mem.indexOf(u8, result, "read REVOKED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1 more peer claims") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "docs/**") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\u{202e}") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, 27) == null);
}

test "conflict suggestions safely quote shell metacharacters and omit changed paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const peer = m.exampleRecord();
    const now = try m.timestamp(peer.acquired_at);
    const message = try conflict(a, peer, "src/it's $(touch bad);`id`.zig", now);
    try std.testing.expect(std.mem.indexOf(u8, message, "gt peers -- 'src/it'\\''s $(touch bad);`id`.zig'") != null);
    const control = try conflict(a, peer, "src/\n\u{202e}x", now);
    try std.testing.expect(std.mem.indexOf(u8, control, "gt peers --") == null);
    try std.testing.expect(std.mem.indexOf(u8, control, "[peer-supplied text]") != null);
}
