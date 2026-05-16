const std = @import("std");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");

pub const StaticAsset = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
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
    const etag = try staticAssetEtagOwned(response.allocator, item.body);
    defer response.allocator.free(etag);

    const extra = [_]response_mod.Header{
        .{ .name = "Cache-Control", .value = "public, max-age=86400" },
        .{ .name = "ETag", .value = etag },
    };
    const asset_response = responseForAssetRequest(response, request);

    if (etagMatches(request.headerValue("if-none-match"), etag)) {
        try asset_response.notModifiedHeaders(&extra);
        return;
    }

    if (item.binary) {
        try asset_response.binaryHeaders(200, "OK", item.content_type, item.body, &extra);
    } else {
        try asset_response.sendWithHeaders(200, "OK", item.content_type, item.body, &extra, .{ .charset = true });
    }
}

fn responseForAssetRequest(response: response_mod.Response, request: request_mod.Request) response_mod.Response {
    var asset_response = response;
    asset_response.options.compression = .none;
    asset_response.options.head = request.method == .HEAD;
    return asset_response;
}

pub fn staticAssetEtagOwned(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\"{x}-{x}\"", .{ body.len, staticAssetHash(body) });
}

fn staticAssetHash(body: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (body) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
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

        pub const Terminal = *const fn (Context) anyerror!void;
        pub const Handler = *const fn (Context, *Next) anyerror!void;

        pub const Next = struct {
            context: Context,
            handlers: []const Handler,
            terminal: Terminal,
            index: usize = 0,

            pub fn run(self: *Next) anyerror!void {
                if (self.index >= self.handlers.len) {
                    try self.terminal(self.context);
                    return;
                }
                const handler = self.handlers[self.index];
                self.index += 1;
                try handler(self.context, self);
            }
        };

        handlers: []const Handler,

        pub fn init(handlers: []const Handler) Self {
            return .{ .handlers = handlers };
        }

        pub fn run(self: Self, context: Context, terminal: Terminal) !void {
            var next = Next{
                .context = context,
                .handlers = self.handlers,
                .terminal = terminal,
            };
            try next.run();
        }
    };
}

test "static asset etag matcher handles lists and weak tags" {
    try std.testing.expect(etagMatches("\"old\", \"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(etagMatches("W/\"asset-etag\"", "\"asset-etag\""));
    try std.testing.expect(etagMatches("*", "\"asset-etag\""));
    try std.testing.expect(!etagMatches("\"different\"", "\"asset-etag\""));
}

test "static asset etags include a content hash" {
    const first = try staticAssetEtagOwned(std.testing.allocator, "abcd");
    defer std.testing.allocator.free(first);
    const second = try staticAssetEtagOwned(std.testing.allocator, "wxyz");
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "static assets enforce head requests" {
    const raw =
        "HEAD /asset.txt HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "\r\n";
    const request = try request_mod.Request.parse(raw);
    const response = response_mod.Response.init(std.testing.allocator, undefined);
    const asset_response = responseForAssetRequest(response, request);
    try std.testing.expect(asset_response.options.head);
    try std.testing.expectEqual(response_mod.Compression.none, asset_response.options.compression);
}

test "middleware chain executes in order" {
    const Context = struct {
        value: *usize,
    };
    const TestChain = Chain(Context);
    const first = struct {
        fn run(ctx: Context, next: *TestChain.Next) !void {
            ctx.value.* += 1;
            try next.run();
            ctx.value.* += 10;
        }
    }.run;
    const second = struct {
        fn run(ctx: Context, next: *TestChain.Next) !void {
            ctx.value.* += 2;
            try next.run();
            ctx.value.* += 20;
        }
    }.run;
    const terminal = struct {
        fn run(ctx: Context) !void {
            ctx.value.* += 3;
        }
    }.run;

    var value: usize = 0;
    const handlers = [_]TestChain.Handler{ first, second };
    try TestChain.init(&handlers).run(.{ .value = &value }, terminal);
    try std.testing.expectEqual(@as(usize, 36), value);
}
