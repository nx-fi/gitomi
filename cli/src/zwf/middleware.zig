const std = @import("std");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");

pub const StaticAsset = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
    etag: []const u8,
    binary: bool = false,
};

pub fn textAsset(comptime path: []const u8, comptime content_type: []const u8, comptime body: []const u8) StaticAsset {
    return asset(path, content_type, body, false);
}

pub fn binaryAsset(comptime path: []const u8, comptime content_type: []const u8, comptime body: []const u8) StaticAsset {
    return asset(path, content_type, body, true);
}

pub fn fontAsset(comptime path: []const u8, comptime body: []const u8) StaticAsset {
    return binaryAsset(path, "font/woff2", body);
}

pub fn asset(
    comptime path: []const u8,
    comptime content_type: []const u8,
    comptime body: []const u8,
    comptime binary: bool,
) StaticAsset {
    return .{
        .path = path,
        .content_type = content_type,
        .body = body,
        .etag = staticAssetEtag(body),
        .binary = binary,
    };
}

pub fn sendStaticAssets(
    response: response_mod.Response,
    request: request_mod.Request,
    assets: []const StaticAsset,
) !bool {
    if (request.method != .GET and request.method != .HEAD) return false;
    for (assets) |item| {
        if (!std.mem.eql(u8, request.path, item.path)) continue;
        try sendCachedAsset(response, request, item);
        return true;
    }
    return false;
}

pub fn sendCachedAsset(
    response: response_mod.Response,
    request: request_mod.Request,
    item: StaticAsset,
) !void {
    const extra = try std.fmt.allocPrint(
        response.allocator,
        "Cache-Control: public, max-age=86400\r\nETag: {s}\r\n",
        .{item.etag},
    );
    defer response.allocator.free(extra);

    if (etagMatches(request.headerValue("if-none-match"), item.etag)) {
        try response.notModified(extra);
        return;
    }

    if (item.binary) {
        try response.binary(200, "OK", item.content_type, item.body, extra);
    } else {
        try response.send(200, "OK", item.content_type, item.body, extra);
    }
}

pub fn staticAssetEtag(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("\"{x}\"", .{body.len});
}

pub fn etagMatches(if_none_match: ?[]const u8, etag: []const u8) bool {
    const header = if_none_match orelse return false;
    var values = std.mem.splitScalar(u8, header, ',');
    while (values.next()) |raw_value| {
        var value = std.mem.trim(u8, raw_value, " \t");
        if (std.mem.eql(u8, value, "*")) return true;
        if (value.len >= 2 and std.ascii.eqlIgnoreCase(value[0..2], "W/")) {
            value = std.mem.trim(u8, value[2..], " \t");
        }
        if (std.mem.eql(u8, value, etag)) return true;
    }
    return false;
}

pub fn Chain(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Next = *const fn (Context) anyerror!void;
        pub const Handler = *const fn (Context, Next) anyerror!void;

        handlers: []const Handler,

        pub fn init(handlers: []const Handler) Self {
            return .{ .handlers = handlers };
        }
    };
}

test "static asset etag matcher handles lists and weak tags" {
    try std.testing.expect(etagMatches("\"old\", \"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(etagMatches("W/\"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(etagMatches("*", "\"asset-etag\""));
    try std.testing.expect(!etagMatches("\"different\"", "\"asset-etag\""));
}
