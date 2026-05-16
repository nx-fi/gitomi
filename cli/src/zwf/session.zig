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

/// CookieSession transports an opaque session id only. It validates the generated
/// id shape, but it does not sign cookies, consult a backing store, or prove that
/// an existing id is trusted. Callers must look ids up in server-side state and
/// rotate them when authentication or privilege level changes.
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
            if (isValidId(existing)) return .{ .id = existing, .created = false };
            allocator.free(existing);
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

pub fn encodedIdSize() usize {
    return std.base64.url_safe_no_pad.Encoder.calcSize(id_bytes);
}

pub fn generateIdOwned(allocator: Allocator) ![]u8 {
    var random_bytes: [id_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const size = encodedIdSize();
    const id = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(id, &random_bytes);
    return id;
}

pub fn isValidId(value: []const u8) bool {
    if (value.len != encodedIdSize()) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

test "session ids are URL-safe" {
    const id = try generateIdOwned(std.testing.allocator);
    defer std.testing.allocator.free(id);
    try std.testing.expect(isValidId(id));
    try std.testing.expect(!isValidId("abc"));
    try std.testing.expect(!isValidId("..........................................."));
}

test "cookie sessions ignore malformed existing ids" {
    const raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Cookie: zwf_session=../../bad\r\n" ++
        "\r\n";
    const request = try request_mod.Request.parse(raw);

    const stream: std.net.Stream = undefined;
    var session = try (CookieSession{}).loadOrCreate(
        std.testing.allocator,
        request,
        response_mod.Response.init(std.testing.allocator, stream),
    );
    defer session.deinit(std.testing.allocator);

    try std.testing.expect(session.created);
    try std.testing.expect(isValidId(session.id));
    try std.testing.expect(session.set_cookie != null);
}
