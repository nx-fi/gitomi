const std = @import("std");
const errors = @import("errors.zig");
const io = @import("io.zig");

const Allocator = std.mem.Allocator;
const CliError = errors.CliError;
const eprint = io.eprint;

pub const short_object_ref_len: usize = 7;
pub const max_object_ref_len: usize = 64;

pub const OwnedSliceList = struct {
    allocator: Allocator,
    items: std.ArrayList([]u8) = .empty,

    pub fn dupe(self: *OwnedSliceList, value: []const u8) ![]u8 {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, owned);
        return owned;
    }

    pub fn release(self: *OwnedSliceList) void {
        self.items.clearRetainingCapacity();
    }

    pub fn deinit(self: *OwnedSliceList) void {
        for (self.items.items) |value| {
            self.allocator.free(value);
        }
        self.items.deinit(self.allocator);
    }
};

pub fn splitCommaFields(allocator: Allocator, raw: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len != 0) try list.append(allocator, trimmed);
    }
    return list;
}

pub fn checkedRefSegment(allocator: Allocator, raw: []const u8, label: []const u8) ![]u8 {
    if (!isRefSafeSegment(raw)) {
        try eprint("gt init: {s} must be a ref-safe segment using letters, digits, '.', '_', '-', or '@'\n", .{label});
        return CliError.InvalidArgument;
    }
    return allocator.dupe(u8, raw);
}

pub fn sanitizeRefSegment(allocator: Allocator, raw: []const u8) ![]u8 {
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);

    var last_dash = false;
    for (raw) |c| {
        const lower = std.ascii.toLower(c);
        const keep = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '_' or lower == '.' or lower == '@';
        if (keep) {
            try out_buf.append(allocator, lower);
            last_dash = false;
        } else if (!last_dash) {
            try out_buf.append(allocator, '-');
            last_dash = true;
        }
    }

    while (out_buf.items.len > 0 and (out_buf.items[0] == '-' or out_buf.items[0] == '.')) {
        _ = out_buf.orderedRemove(0);
    }
    while (out_buf.items.len > 0 and (out_buf.items[out_buf.items.len - 1] == '-' or out_buf.items[out_buf.items.len - 1] == '.')) {
        out_buf.items.len -= 1;
    }

    if (!isRefSafeSegment(out_buf.items)) {
        out_buf.clearRetainingCapacity();
    }

    return out_buf.toOwnedSlice(allocator);
}

pub fn isRefSafeSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    if (std.mem.indexOf(u8, value, "@{") != null) return false;
    if (std.mem.endsWith(u8, value, ".lock")) return false;
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.' or c == '@';
        if (!ok) return false;
    }
    return true;
}

pub fn looksLikeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, idx| {
        if (idx == 8 or idx == 13 or idx == 18 or idx == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) {
            return false;
        }
    }
    return true;
}

pub fn newUuidV7(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const ts: u64 = @intCast(std.time.milliTimestamp());
    inline for (.{ 40, 32, 24, 16, 8, 0 }, 0..) |shift, idx| {
        bytes[idx] = @truncate(ts >> shift);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const out_buf = try allocator.alloc(u8, 36);
    formatUuid(bytes, out_buf);
    return out_buf;
}

pub fn formatUuid(bytes: [16]u8, out_buf: []u8) void {
    const hex = "0123456789abcdef";
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out_buf[j] = '-';
            j += 1;
        }
        out_buf[j] = hex[b >> 4];
        out_buf[j + 1] = hex[b & 0x0f];
        j += 2;
    }
}

pub fn rfc3339Now(allocator: Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    if (timestamp < 0) return error.InvalidTimestamp;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
    const day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

pub fn sha256Hex(allocator: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out_buf = try allocator.alloc(u8, digest.len * 2);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out_buf[i * 2] = hex[b >> 4];
        out_buf[i * 2 + 1] = hex[b & 0x0f];
    }
    return out_buf;
}

pub fn shortObjectRef(out_buf: *[short_object_ref_len]u8, object_id: []const u8) []const u8 {
    return objectRefPrefix(out_buf[0..], object_id);
}

pub fn objectRefPrefix(out_buf: []u8, object_id: []const u8) []const u8 {
    std.debug.assert(out_buf.len <= max_object_ref_len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(object_id, &digest, .{});
    const hex = "0123456789abcdef";
    for (out_buf, 0..) |*c, i| {
        const b = digest[i / 2];
        c.* = if (i % 2 == 0) hex[b >> 4] else hex[b & 0x0f];
    }
    return out_buf;
}

pub fn isObjectRefPrefix(value: []const u8) bool {
    if (value.len < short_object_ref_len or value.len > max_object_ref_len) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn requireValue(args: []const []const u8, index: *usize, name: []const u8) ![]const u8 {
    if (index.* + 1 >= args.len) {
        try eprint("{s} requires a value\n", .{name});
        return CliError.MissingArgument;
    }
    index.* += 1;
    return args[index.*];
}

pub fn countNonEmptyLines(bytes: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |_| count += 1;
    return count;
}

pub fn trimOwned(allocator: Allocator, owned: []u8) ![]u8 {
    const duped = try trimDup(allocator, owned);
    allocator.free(owned);
    return duped;
}

pub fn trimDup(allocator: Allocator, bytes: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trim(u8, bytes, " \t\r\n"));
}

pub fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "uuid formatter emits canonical lowercase form" {
    const bytes = [16]u8{
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0x10, 0x32, 0x54, 0x76,
        0x98, 0xba, 0xdc, 0xfe,
    };
    var out_buf: [36]u8 = undefined;
    formatUuid(bytes, &out_buf);
    try std.testing.expectEqualStrings("01234567-89ab-cdef-1032-547698badcfe", &out_buf);
}

test "object refs are sha256 prefixes" {
    var short_buf: [short_object_ref_len]u8 = undefined;
    const short = shortObjectRef(&short_buf, "018f0000-0000-7000-8000-000000000002");

    const full = try sha256Hex(std.testing.allocator, "018f0000-0000-7000-8000-000000000002");
    defer std.testing.allocator.free(full);

    try std.testing.expectEqualStrings(full[0..short_object_ref_len], short);
    try std.testing.expect(isObjectRefPrefix(short));
    try std.testing.expect(!isObjectRefPrefix("018f00"));
    try std.testing.expect(!isObjectRefPrefix("018f00z"));
}

test "ref segment sanitization" {
    const sanitized = try sanitizeRefSegment(std.testing.allocator, "Dev User@example.com");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("dev-user@example.com", sanitized);
    try std.testing.expect(isRefSafeSegment(sanitized));
    try std.testing.expect(!isRefSafeSegment("../bad"));
    try std.testing.expect(!isRefSafeSegment("bad@{ref"));
}
