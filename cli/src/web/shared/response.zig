const std = @import("std");
const zwf_response = @import("../../zwf/response.zig");

const Allocator = std.mem.Allocator;

pub fn sendRedirect(allocator: Allocator, stream: std.net.Stream, location: []const u8) !void {
    try zwf_response.validateHeaderValue(location);
    const extra = try std.fmt.allocPrint(allocator, "Location: {s}\r\n", .{location});
    defer allocator.free(extra);
    try sendResponse(allocator, stream, 303, "See Other", "text/plain", "See Other\n", extra);
}

pub fn sendPlainResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    body: []const u8,
) !void {
    try sendResponse(allocator, stream, status, reason, "text/plain", body, null);
}

pub fn sendResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: ?[]const u8,
) !void {
    try validateRawExtraHeaders(extra_headers orelse "");
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);
    try std.fmt.format(
        headers.writer(allocator),
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}; charset=utf-8\r\n",
        .{ status, reason, content_type },
    );
    try appendContentLengthIfAllowed(&headers, allocator, status, body.len);
    try headers.appendSlice(allocator, "Connection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\n");
    try headers.appendSlice(allocator, extra_headers orelse "");
    try headers.appendSlice(allocator, "\r\n");
    try stream.writeAll(headers.items);
    if (statusAllowsBody(status) and body.len > 0) try stream.writeAll(body);
}

pub fn sendBinaryResponse(
    allocator: Allocator,
    stream: std.net.Stream,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: ?[]const u8,
) !void {
    try validateRawExtraHeaders(extra_headers orelse "");
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);
    try std.fmt.format(
        headers.writer(allocator),
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n",
        .{ status, reason, content_type },
    );
    try appendContentLengthIfAllowed(&headers, allocator, status, body.len);
    try headers.appendSlice(allocator, "Connection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\n");
    try headers.appendSlice(allocator, extra_headers orelse "");
    try headers.appendSlice(allocator, "\r\n");
    try stream.writeAll(headers.items);
    if (statusAllowsBody(status) and body.len > 0) try stream.writeAll(body);
}

fn statusAllowsBody(status: u16) bool {
    return status != 204 and status != 304 and status >= 200;
}

fn appendContentLengthIfAllowed(buf: *std.ArrayList(u8), allocator: Allocator, status: u16, body_len: usize) !void {
    if (statusAllowsBody(status)) try std.fmt.format(buf.writer(allocator), "Content-Length: {d}\r\n", .{body_len});
}

fn validateRawExtraHeaders(raw: []const u8) !void {
    if (raw.len == 0) return;
    if (!std.mem.endsWith(u8, raw, "\r\n")) return error.BadHeaderValue;
    var rest = raw;
    while (rest.len > 0) {
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadHeaderValue;
        const line = rest[0..end];
        rest = rest[end + 2 ..];
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeaderValue;
        try zwf_response.validateExtraHeaderName(std.mem.trim(u8, line[0..colon], " \t"));
        try zwf_response.validateHeaderValue(std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }
}

test "legacy response helpers omit content length for 204" {
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(std.testing.allocator);
    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 204, 10);
    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 304, 10);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);

    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 200, 10);
    try std.testing.expectEqualStrings("Content-Length: 10\r\n", headers.items);
}

test "legacy raw extra headers reject managed names" {
    try std.testing.expectError(error.ManagedResponseHeader, validateRawExtraHeaders("Content-Length: 1\r\n"));
    try std.testing.expectError(error.ManagedResponseHeader, validateRawExtraHeaders("Transfer-Encoding: chunked\r\n"));
    try std.testing.expectError(error.ManagedResponseHeader, validateRawExtraHeaders("Connection: keep-alive\r\n"));
    try std.testing.expectError(error.ManagedResponseHeader, validateRawExtraHeaders("Content-Type: text/plain\r\n"));
    try std.testing.expectError(error.ManagedResponseHeader, validateRawExtraHeaders("Referrer-Policy: unsafe-url\r\n"));
}
