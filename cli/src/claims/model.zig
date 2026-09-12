const std = @import("std");
const util = @import("../util.zig");
const A = std.mem.Allocator;
pub const eq = std.mem.eql;
pub const skew_allow: i64 = 30;

pub const Holder = struct {
    principal: []const u8,
    device: []const u8,
    run_id: []const u8 = "",

    pub fn sameDevice(a: Holder, b: Holder) bool {
        return eq(u8, a.principal, b.principal) and eq(u8, a.device, b.device);
    }
    pub fn same(a: Holder, b: Holder) bool {
        return a.sameDevice(b) and eq(u8, a.run_id, b.run_id);
    }
};

pub const Record = struct {
    @"$schema": []const u8,
    repo_id: []const u8,
    claim_id: []const u8,
    lease_seq: u64,
    holder: Holder,
    mode: []const u8,
    paths: []const []const u8,
    acquired_at: []const u8,
    expires_at: []const u8,
    revoked: bool = false,
    reason: []const u8,
    base: []const u8 = "",

    pub fn expired(c: Record, actor: Holder, now: i64) !bool {
        const deadline = try timestamp(c.expires_at);
        // Strict holder deadline; peers retain exclusion through the allowance.
        return if (c.holder.sameDevice(actor)) deadline <= now else deadline < now - skew_allow;
    }
};

pub const Writer = struct { principal: []const u8, device: []const u8 };
pub const Action = struct {
    op: []const u8,
    claim_id: []const u8,
    expired_at: ?[]const u8 = null,
    authorized_by: ?[]const u8 = null,
};
pub const Delta = struct {
    @"$schema": []const u8,
    repo_id: []const u8,
    writer: Writer,
    actions: []const Action,
    wrote_at: []const u8,
};

pub fn uuid(value: []const u8) bool {
    if (!util.looksLikeUuid(value) or value[14] != '7') return false;
    if (std.mem.indexOfScalar(u8, "89ab", value[19]) == null) return false;
    for (value) |c| if (c != '-' and !std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

pub fn validText(s: []const u8, limit: usize) bool {
    return s.len <= limit and std.unicode.utf8ValidateSlice(s);
}

pub fn validate(a: A, c: Record, id: []const u8, repo_id: []const u8) !void {
    if (!eq(u8, c.@"$schema", "urn:gitomi:claim:v1") or !uuid(c.claim_id) or
        !uuid(c.repo_id) or !eq(u8, c.claim_id, id) or !eq(u8, c.repo_id, repo_id) or
        c.lease_seq == 0 or c.paths.len == 0 or c.paths.len > 64 or
        !validText(c.holder.principal, 256) or !util.isRefSafeSegment(c.holder.principal) or
        !validText(c.holder.device, 256) or !util.isRefSafeSegment(c.holder.device) or
        (c.holder.run_id.len != 0 and !uuid(c.holder.run_id)) or
        !validText(c.reason, 1024) or !validText(c.mode, 256) or
        (c.base.len != 0 and !@import("../git.zig").isFullOid(c.base))) return error.InvalidClaim;
    const start = try timestamp(c.acquired_at);
    const end = try timestamp(c.expires_at);
    const fractional_order = fractionsOrder(c.expires_at, c.acquired_at);
    if (end < start or (end == start and fractional_order != .gt) or
        end - start > 4 * 3600 or (end - start == 4 * 3600 and fractional_order == .gt)) return error.InvalidClaim;
    for (c.paths) |p| {
        const normalized = try normalize(a, p);
        a.free(normalized);
    }
}

pub fn normalize(a: A, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or !validText(raw, 512) or raw[0] == '/') return error.InvalidClaimPath;
    const path = if (std.mem.startsWith(u8, raw, "./")) raw[2..] else raw;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (eq(u8, segment, ".") or eq(u8, segment, "..")) return error.InvalidClaimPath;
        if (out.items.len != 0) try out.append(a, '/');
        try out.appendSlice(a, segment);
    }
    if (out.items.len == 0) return error.InvalidClaimPath;
    if (std.mem.endsWith(u8, path, "/")) try out.appendSlice(a, "/**");
    if (out.items.len > 512) return error.InvalidClaimPath;
    return out.toOwnedSlice(a);
}

// Exact literal/glob matching, bounded by the 512-byte pattern limit.
fn matches(pattern: []const u8, literal: []const u8) bool {
    var prev = [_]bool{false} ** 513;
    prev[0] = true;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        var next = [_]bool{false} ** 513;
        const token = pattern[i];
        const recursive = token == '*' and i + 1 < pattern.len and pattern[i + 1] == '*';
        if (recursive) i += 1;
        if (token == '*') next[0] = prev[0];
        for (literal, 0..) |c, j| {
            next[j + 1] = if (token == '*') prev[j + 1] or (next[j] and (recursive or c != '/')) else prev[j] and (token == c or (token == '?' and c != '/'));
        }
        prev = next;
    }
    return prev[literal.len];
}

pub fn intersects(a: []const u8, b: []const u8) bool {
    const aw = std.mem.indexOfAny(u8, a, "*?");
    const bw = std.mem.indexOfAny(u8, b, "*?");
    // '?' denotes a character, not a UTF-8 byte. Until matching operates on
    // codepoints, never infer disjointness from byte-DP on Unicode patterns.
    if (aw != null or bw != null) {
        for (a) |c| if (c >= 128) return true;
        for (b) |c| if (c >= 128) return true;
    }
    if (aw == null) return matches(b, a);
    if (bw == null) return matches(a, b);
    // Different literal prefixes prove disjointness. All uncertain glob/glob
    // pairs conflict, including suffixes that would require language intersection.
    for (a[0..@min(aw.?, bw.?)], b[0..@min(aw.?, bw.?)]) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

pub fn overlap(a: Record, b: Record) bool {
    if (eq(u8, a.claim_id, b.claim_id) or a.holder.same(b.holder)) return false;
    if (eq(u8, a.mode, "read") and eq(u8, b.mode, "read")) return false;
    for (a.paths) |ap| for (b.paths) |bp| {
        if (intersects(ap, bp)) return true;
    };
    return false;
}

// UTC RFC3339, with optional fractional seconds. Round down: holder expiry is
// early, while the peer's strict '<' comparison cannot reap until the next second.
pub fn timestamp(s: []const u8) !i64 {
    if (s.len < 20 or s.len > 40 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or
        s[13] != ':' or s[16] != ':' or s[s.len - 1] != 'Z') return error.InvalidClaimTimestamp;
    if (s.len > 20) {
        if (s[19] != '.' or s.len < 22) return error.InvalidClaimTimestamp;
        for (s[20 .. s.len - 1]) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidClaimTimestamp;
        }
    }
    const y = try number(s[0..4]);
    const m = try number(s[5..7]);
    const d = try number(s[8..10]);
    const h = try number(s[11..13]);
    const minute = try number(s[14..16]);
    const second = try number(s[17..19]);
    if (y < 1970 or m < 1 or m > 12 or h > 23 or minute > 59 or second > 59) return error.InvalidClaimTimestamp;
    const leap = @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
    const months = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (d < 1 or d > months[@intCast(m - 1)]) return error.InvalidClaimTimestamp;
    var days: i64 = 0;
    var year: i64 = 1970;
    while (year < y) : (year += 1) days += if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) @as(i64, 366) else 365;
    for (months[0..@intCast(m - 1)]) |n| days += n;
    return (days + d - 1) * 86400 + h * 3600 + minute * 60 + second;
}

fn number(s: []const u8) !i64 {
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidClaimTimestamp;
    return std.fmt.parseInt(i64, s, 10);
}

fn fractionsOrder(a: []const u8, b: []const u8) std.math.Order {
    const af = if (a.len > 20) a[20 .. a.len - 1] else "";
    const bf = if (b.len > 20) b[20 .. b.len - 1] else "";
    for (0..@max(af.len, bf.len)) |i| {
        const ac = if (i < af.len) af[i] else '0';
        const bc = if (i < bf.len) bf[i] else '0';
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
    }
    return .eq;
}

pub fn formatTime(a: A, seconds: i64) ![]const u8 {
    if (seconds < 0) return error.InvalidClaimTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, @intFromEnum(md.month), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

pub fn json(a: A, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.toOwnedSlice();
}

pub fn quoted(a: A, s: []const u8) ![]const u8 {
    const clean = try displayText(a, s);
    defer a.free(clean);
    return json(a, clean);
}

pub fn displayText(a: A, s: []const u8) ![]const u8 {
    var clean: std.ArrayList(u8) = .empty;
    errdefer clean.deinit(a);
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        if (cp < 32 or (cp >= 127 and cp <= 159) or cp == 0x061c or
            cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or
            (cp >= 0x2066 and cp <= 0x2069)) continue;
        if (clean.items.len + bytes.len > 1024) break;
        try clean.appendSlice(a, bytes);
    }
    return clean.toOwnedSlice(a);
}

test "normalization and conservative intersection" {
    const a = std.testing.allocator;
    const p = try normalize(a, "./src//session/");
    defer a.free(p);
    try std.testing.expectEqualStrings("src/session/**", p);
    try std.testing.expectError(error.InvalidClaimPath, normalize(a, "a/../b"));
    try std.testing.expect(!intersects("src/*", "src/a/b"));
    try std.testing.expect(intersects("src/**", "src/a/b"));
    try std.testing.expect(intersects("src/a?.zig", "src/ab.zig"));
    try std.testing.expect(!intersects("src/a?", "src/a"));
    try std.testing.expect(!intersects("src/**", "docs/**"));
    try std.testing.expect(intersects("src/*.zig", "src/a*"));
    try std.testing.expect(intersects("src/*.zig", "src/*.rs"));
    try std.testing.expect(intersects("src/?.zig", "src/é.zig"));
}

test "UTC dates and untrusted display" {
    const a = std.testing.allocator;
    const seconds = try timestamp("2026-09-12T12:34:56Z");
    const formatted = try formatTime(a, seconds);
    defer a.free(formatted);
    try std.testing.expectEqualStrings("2026-09-12T12:34:56Z", formatted);
    try std.testing.expectError(error.InvalidClaimTimestamp, timestamp("2026-02-29T12:34:56Z"));
    const safe = try quoted(a, "a\n\x1b[31m\u{202e}b");
    defer a.free(safe);
    try std.testing.expectEqualStrings("\"a[31mb\"", safe);
}

pub fn exampleRecord() Record {
    return .{
        .@"$schema" = "urn:gitomi:claim:v1",
        .repo_id = "018f0000-0000-7000-8000-000000000001",
        .claim_id = "018f0000-0000-7000-8000-000000000002",
        .lease_seq = 1,
        .holder = .{ .principal = "alice", .device = "laptop" },
        .mode = "write",
        .paths = &.{"src/**"},
        .acquired_at = "2026-09-12T12:00:00Z",
        .expires_at = "2026-09-12T12:15:00Z",
        .reason = "test",
    };
}

test "expiry is strict for holder and late for peers, even after revocation" {
    var c = exampleRecord();
    const peer: Holder = .{ .principal = "bob", .device = "desktop" };
    const deadline = try timestamp(c.expires_at);
    try std.testing.expect(!(try c.expired(c.holder, deadline - 1)));
    try std.testing.expect(try c.expired(c.holder, deadline));
    try std.testing.expect(!(try c.expired(peer, deadline + 30)));
    try std.testing.expect(try c.expired(peer, deadline + 31));
    c.revoked = true;
    try std.testing.expect(!(try c.expired(peer, deadline)));
}

test "holder triples, readers, and unknown modes" {
    const c = exampleRecord();
    var other = c;
    other.claim_id = "018f0000-0000-7000-8000-000000000003";
    try std.testing.expect(!overlap(c, other));
    other.holder.run_id = "018f0000-0000-7000-8000-000000000004";
    try std.testing.expect(overlap(c, other));
    var reader = c;
    reader.mode = "read";
    other.mode = "read";
    try std.testing.expect(!overlap(reader, other));
    other.mode = "future-unknown-mode";
    try std.testing.expect(overlap(reader, other));
}

test "record schema limits include exact fractional maximum duration" {
    var c = exampleRecord();
    const a = std.testing.allocator;
    try validate(a, c, c.claim_id, c.repo_id);
    c.expires_at = "2026-09-12T16:00:00.1Z";
    try std.testing.expectError(error.InvalidClaim, validate(a, c, c.claim_id, c.repo_id));
    c.acquired_at = "2026-09-12T12:00:00.10Z";
    try validate(a, c, c.claim_id, c.repo_id);
}
