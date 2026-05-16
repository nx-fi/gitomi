const std = @import("std");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");

const Allocator = std.mem.Allocator;

pub const id_bytes = 32;
pub const default_cookie_name = "zwf_session";

pub const Session = struct {
    id: []u8,
    created: bool,
    set_cookie: ?response_mod.Header = null,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.set_cookie) |header| allocator.free(header.value);
        self.* = undefined;
    }
};

pub const CookieSession = struct {
    name: []const u8 = default_cookie_name,
    cookie: response_mod.CookieOptions = .{},

    pub fn loadOrCreate(
        self: CookieSession,
        allocator: Allocator,
        request: request_mod.Request,
        response: response_mod.Response,
    ) !Session {
        if (try request.cookieValueOwned(allocator, self.name)) |existing| {
            return .{ .id = existing, .created = false };
        }

        const id = try generateIdOwned(allocator);
        errdefer allocator.free(id);
        return .{
            .id = id,
            .created = true,
            .set_cookie = try response.setCookieHeaderOwned(self.name, id, self.cookie),
        };
    }
};

pub fn generateIdOwned(allocator: Allocator) ![]u8 {
    var random_bytes: [id_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const id = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(id, &random_bytes);
    return id;
}

test "session ids are URL-safe" {
    const id = try generateIdOwned(std.testing.allocator);
    defer std.testing.allocator.free(id);
    try std.testing.expect(id.len > 32);
    for (id) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}
