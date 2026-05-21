const std = @import("std");
const request = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const default_worker_count = 8;
pub const default_port_attempt_limit = 128;
pub const default_bind_host = "127.0.0.1";
pub const default_host = "gitomi.localhost";
pub const default_port = 12655;
pub const default_read_timeout_ms = 30_000;
pub const default_write_timeout_ms = 30_000;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    port_supplied: bool = false,
    once: bool = false,
    worker_count: usize = default_worker_count,
    port_attempt_limit: usize = default_port_attempt_limit,
    read_timeout_ms: ?u32 = default_read_timeout_ms,
    write_timeout_ms: ?u32 = default_write_timeout_ms,
};

pub fn ConnectionHandler(comptime Context: type) type {
    return *const fn (Allocator, Context, @import("compat").net.Stream) anyerror!void;
}

pub fn bindHost(options: Options) []const u8 {
    return if (isNamedLoopbackHost(options.host)) default_bind_host else options.host;
}

pub fn listen(bind_host: []const u8, options: Options) !@import("compat").net.Server {
    var port = options.port;
    var attempts: usize = 0;
    while (true) {
        const address = @import("compat").net.Address.parseIp(bind_host, port) catch return error.InvalidHost;

        return address.listen(.{ .reuse_address = false, .kernel_backlog = 32 }) catch |err| {
            if (options.port_supplied or err != error.AddressInUse) return err;
            attempts += 1;
            if (attempts >= options.port_attempt_limit) return error.NoAvailablePort;

            const increment = @import("compat").random.intRangeAtMost(u16, 1, 10);
            if (port > std.math.maxInt(u16) - increment) return error.NoAvailablePort;
            port += increment;
            continue;
        };
    }
}

pub fn serveConnections(
    comptime Context: type,
    allocator: Allocator,
    app_context: Context,
    server: *@import("compat").net.Server,
    options: Options,
    handler: ConnectionHandler(Context),
) !void {
    if (options.once) {
        const connection = try server.accept();
        defer connection.stream.close();
        try configureStream(connection.stream, options);
        try handler(allocator, app_context, connection.stream);
        return;
    }

    const Runner = struct {
        fn run(
            task_allocator: Allocator,
            task_context: Context,
            connection: @import("compat").net.Server.Connection,
            permits: *std.Io.Semaphore,
            task_handler: ConnectionHandler(Context),
        ) void {
            defer permits.post(@import("compat").io());
            defer connection.stream.close();
            task_handler(task_allocator, task_context, connection.stream) catch {};
        }
    };

    var permits = std.Io.Semaphore{ .permits = @max(options.worker_count, 1) };
    while (true) {
        permits.waitUncancelable(@import("compat").io());
        const connection = server.accept() catch |err| {
            permits.post(@import("compat").io());
            return err;
        };
        configureStream(connection.stream, options) catch |err| {
            connection.stream.close();
            permits.post(@import("compat").io());
            return err;
        };
        const thread = std.Thread.spawn(.{ .allocator = allocator }, Runner.run, .{ allocator, app_context, connection, &permits, handler }) catch |err| {
            connection.stream.close();
            permits.post(@import("compat").io());
            return err;
        };
        thread.detach();
    }
}

pub fn readHttpRequest(allocator: Allocator, stream: @import("compat").net.Stream) ![]u8 {
    return readHttpRequestLimit(allocator, stream, request.max_http_request);
}

pub fn readHttpRequestLimit(allocator: Allocator, stream: @import("compat").net.Stream, max_len: usize) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);

    var expected_len: ?usize = null;
    var header_end_seen: ?usize = null;
    while (raw.items.len < max_len) {
        var chunk: [4096]u8 = undefined;
        const read_len = try stream.read(&chunk);
        if (read_len == 0) {
            if (raw.items.len == 0) return error.EndOfStream;
            break;
        }
        try raw.appendSlice(allocator, chunk[0..read_len]);

        const header_end = header_end_seen orelse std.mem.indexOf(u8, raw.items, "\r\n\r\n");
        if (header_end) |end| {
            header_end_seen = end;
            const body_start = std.math.add(usize, end, 4) catch return error.RequestTooLarge;
            if (body_start > max_len) return error.RequestTooLarge;
            switch (try request.readPlan(raw.items[0..end])) {
                .none => expected_len = body_start,
                .content_length => |content_len| {
                    if (content_len > max_len - body_start) return error.RequestTooLarge;
                    expected_len = body_start + content_len;
                },
                .chunked => {
                    if (try request.chunkedBodyFrameLength(raw.items[body_start..], max_len - body_start)) |frame| {
                        if (frame.encoded_len > max_len - body_start) return error.RequestTooLarge;
                        expected_len = body_start + frame.encoded_len;
                    }
                },
            }
        } else if (raw.items.len > request.max_http_header) {
            return error.RequestHeaderTooLarge;
        }

        if (expected_len) |needed| {
            if (raw.items.len >= needed) break;
        }
    }

    if (raw.items.len >= max_len) return error.RequestTooLarge;
    if (expected_len) |needed| {
        if (raw.items.len < needed) return error.BadRequest;
    }
    return raw.toOwnedSlice(allocator);
}

pub fn isClientDisconnect(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, default_bind_host) or
        std.ascii.eqlIgnoreCase(host, "::1") or
        isNamedLoopbackHost(host);
}

fn isNamedLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, default_host);
}

test "server advertises gitomi localhost but binds named loopback to ip loopback" {
    try std.testing.expectEqualStrings("gitomi.localhost", default_host);
    try std.testing.expectEqualStrings(default_bind_host, bindHost(.{}));
    try std.testing.expectEqualStrings(default_bind_host, bindHost(.{ .host = "localhost" }));
    try std.testing.expectEqualStrings(default_bind_host, bindHost(.{ .host = "GITOMI.LOCALHOST" }));
    try std.testing.expect(isLoopbackHost("gitomi.localhost"));
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(!isLoopbackHost("attacker.test"));
}

pub fn configureStream(stream: @import("compat").net.Stream, options: Options) !void {
    if (options.read_timeout_ms) |timeout_ms| try setSocketTimeout(stream, std.posix.SO.RCVTIMEO, timeout_ms);
    if (options.write_timeout_ms) |timeout_ms| try setSocketTimeout(stream, std.posix.SO.SNDTIMEO, timeout_ms);
}

fn setSocketTimeout(stream: @import("compat").net.Stream, optname: u32, timeout_ms: u32) !void {
    if (@import("builtin").os.tag == .windows) {
        try std.posix.setsockopt(
            stream.handle,
            std.posix.SOL.SOCKET,
            optname,
            std.mem.asBytes(&timeout_ms),
        );
        return;
    }

    var tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        optname,
        std.mem.asBytes(&tv),
    );
}
