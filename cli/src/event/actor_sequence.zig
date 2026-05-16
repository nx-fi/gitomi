const std = @import("std");

const Allocator = std.mem.Allocator;

pub const AdmissionResult = union(enum) {
    accepted,
    duplicate,
    stale: i64,
};

pub const LastSeqTracker = struct {
    allocator: Allocator,
    last_seq: std.StringHashMap(i64),

    pub fn init(allocator: Allocator) LastSeqTracker {
        return .{
            .allocator = allocator,
            .last_seq = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *LastSeqTracker) void {
        var keys = self.last_seq.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.last_seq.deinit();
    }

    pub fn accept(self: *LastSeqTracker, principal: []const u8, device: []const u8, seq: i64) !?i64 {
        const key = try actorKey(self.allocator, principal, device);
        errdefer self.allocator.free(key);
        const entry = try self.last_seq.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            if (seq <= entry.value_ptr.*) return entry.value_ptr.*;
        } else {
            entry.key_ptr.* = key;
        }
        entry.value_ptr.* = seq;
        return null;
    }

    pub fn rememberMax(self: *LastSeqTracker, principal: []const u8, device: []const u8, seq: i64) !void {
        const key = try actorKey(self.allocator, principal, device);
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
};

pub const AdmissionTracker = struct {
    allocator: Allocator,
    seen: std.BufSet,
    last_seq: LastSeqTracker,

    pub fn init(allocator: Allocator) AdmissionTracker {
        return .{
            .allocator = allocator,
            .seen = std.BufSet.init(allocator),
            .last_seq = LastSeqTracker.init(allocator),
        };
    }

    pub fn deinit(self: *AdmissionTracker) void {
        self.seen.deinit();
        self.last_seq.deinit();
    }

    pub fn accept(self: *AdmissionTracker, principal: []const u8, device: []const u8, seq: i64) !AdmissionResult {
        const key = try actorSeqKey(self.allocator, principal, device, seq);
        defer self.allocator.free(key);
        if (self.seen.contains(key)) return .duplicate;

        if (try self.last_seq.accept(principal, device, seq)) |previous| return .{ .stale = previous };
        try self.seen.insert(key);
        return .accepted;
    }

    pub fn rememberMax(self: *AdmissionTracker, principal: []const u8, device: []const u8, seq: i64) !void {
        const key = try actorSeqKey(self.allocator, principal, device, seq);
        defer self.allocator.free(key);
        if (!self.seen.contains(key)) try self.seen.insert(key);
        try self.last_seq.rememberMax(principal, device, seq);
    }
};

pub fn actorKey(allocator: Allocator, principal: []const u8, device: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}\x1f{d}:{s}", .{
        principal.len,
        principal,
        device.len,
        device,
    });
}

pub fn actorSeqKey(allocator: Allocator, principal: []const u8, device: []const u8, seq: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}\x1f{d}:{s}\x1f{d}", .{
        principal.len,
        principal,
        device.len,
        device,
        seq,
    });
}

test "actor sequence keys are length prefixed" {
    const key = try actorSeqKey(std.testing.allocator, "ab", "c", 1);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("2:ab\x1f1:c\x1f1", key);

    const other = try actorSeqKey(std.testing.allocator, "a", "bc", 1);
    defer std.testing.allocator.free(other);
    try std.testing.expect(!std.mem.eql(u8, key, other));
}

test "admission tracker reports duplicates and stale sequences" {
    var tracker = AdmissionTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expectEqual(AdmissionResult.accepted, try tracker.accept("ab", "c", 1));
    try std.testing.expectEqual(AdmissionResult.accepted, try tracker.accept("a", "bc", 1));
    try std.testing.expectEqual(AdmissionResult.accepted, try tracker.accept("ab", "c", 2));
    try std.testing.expectEqual(AdmissionResult.duplicate, try tracker.accept("ab", "c", 2));
    try std.testing.expectEqual(AdmissionResult{ .stale = 2 }, try tracker.accept("ab", "c", 0));
}

test "last sequence tracker remembers maximum seed" {
    var tracker = LastSeqTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try tracker.rememberMax("ab", "c", 10);
    try tracker.rememberMax("ab", "c", 5);
    try std.testing.expectEqual(@as(?i64, 10), try tracker.accept("ab", "c", 10));
    try std.testing.expectEqual(@as(?i64, null), try tracker.accept("ab", "c", 11));
}
