const std = @import("std");
const request_mod = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const token_bytes = 32;
pub const field_name = "_csrf";
pub const header_name = "x-csrf-token";

pub fn generateTokenOwned(allocator: Allocator) ![]u8 {
    var random_bytes: [token_bytes]u8 = undefined;
    @import("compat").random.bytes(&random_bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const token = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(token, &random_bytes);
    return token;
}

pub fn tokenFromRequestOwned(allocator: Allocator, request: request_mod.Request) !?[]u8 {
    if (request.headerValue(header_name)) |value| return try allocator.dupe(u8, value);
    if (request.body.len == 0) return null;
    if (!request.isFormUrlEncoded()) return null;
    var form = try request.formValues(allocator);
    defer form.deinit();
    const value = form.value(field_name) orelse return null;
    return try allocator.dupe(u8, value);
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

test "csrf token extraction only parses url encoded forms" {
    const form_body = "_csrf=abc";
    const form_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{form_body.len}) ++ "\r\n" ++
        "\r\n" ++
        form_body;
    const form_request = try request_mod.Request.parse(form_raw);
    const token = try tokenFromRequestOwned(std.testing.allocator, form_request);
    defer if (token) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("abc", token.?);

    const json_body = "{\"_csrf\":\"abc\"}";
    const json_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{json_body.len}) ++ "\r\n" ++
        "\r\n" ++
        json_body;
    const json_request = try request_mod.Request.parse(json_raw);
    const skipped = try tokenFromRequestOwned(std.testing.allocator, json_request);
    try std.testing.expect(skipped == null);
}
