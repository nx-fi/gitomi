const std = @import("std");
const request_mod = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const token_bytes = 32;
pub const field_name = "_csrf";
pub const header_name = "x-csrf-token";

pub fn generateTokenOwned(allocator: Allocator) ![]u8 {
    var random_bytes: [token_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const token = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(token, &random_bytes);
    return token;
}

pub fn tokenFromRequestOwned(allocator: Allocator, request: request_mod.Request) !?[]u8 {
    if (request.headerValue(header_name)) |value| return allocator.dupe(u8, value);
    if (request.body.len == 0) return null;
    var form = try request.formValues(allocator);
    defer form.deinit();
    const value = form.value(field_name) orelse return null;
    return allocator.dupe(u8, value);
}

pub fn verify(expected: []const u8, submitted: []const u8) bool {
    if (expected.len != submitted.len) return false;
    var diff: u8 = 0;
    for (expected, submitted) |a, b| diff |= a ^ b;
    return diff == 0;
}

pub fn verifyRequest(allocator: Allocator, request: request_mod.Request, expected: []const u8) !bool {
    const submitted = try tokenFromRequestOwned(allocator, request) orelse return false;
    defer allocator.free(submitted);
    return verify(expected, submitted);
}

test "csrf tokens verify with constant-time helper" {
    const token = try generateTokenOwned(std.testing.allocator);
    defer std.testing.allocator.free(token);
    try std.testing.expect(verify(token, token));
    try std.testing.expect(!verify(token, "different"));
}
