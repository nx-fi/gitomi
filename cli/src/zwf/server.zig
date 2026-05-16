const std = @import("std");
const request = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const default_worker_count = 8;
pub const default_port_attempt_limit = 128;
pub const default_host = "127.0.0.1";
pub const default_port = 12655;

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    port_supplied: bool = false,
    once: bool = false,
    worker_count: usize = default_worker_count,
    port_attempt_limit: usize = default_port_attempt_limit,
};

pub fn ConnectionHandler(comptime Context: type) type {
    return *const fn (Allocator, Context, std.net.Stream) anyerror!void;
}

pub fn bindHost(options: Options) []const u8 {
    return if (std.mem.eql(u8, options.host, "localhost")) default_host else options.host;
}

pub fn listen(bind_host: []const u8, options: Options) !std.net.Server {
    var port = options.port;
    var attempts: usize = 0;
    while (true) {
        const address = std.net.Address.parseIp(bind_host, port) catch return error.InvalidHost;

        return address.listen(.{ .reuse_address = false, .kernel_backlog = 32 }) catch |err| {
            if (options.port_supplied or err != error.AddressInUse) return err;
            attempts += 1;
            if (attempts >= options.port_attempt_limit) return error.NoAvailablePort;

            const increment = std.crypto.random.intRangeAtMost(u16, 1, 10);
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
    server: *std.net.Server,
    options: Options,
    handler: ConnectionHandler(Context),
) !void {
    if (options.once) {
        const connection = try server.accept();
        defer connection.stream.close();
        try handler(allocator, app_context, connection.stream);
        return;
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @max(options.worker_count, 1),
    });
    defer pool.deinit();

    const Runner = struct {
        fn run(
            task_allocator: Allocator,
            task_context: Context,
            connection: std.net.Server.Connection,
            permits: *std.Thread.Semaphore,
            task_handler: ConnectionHandler(Context),
        ) void {
            defer permits.post();
            defer connection.stream.close();
            task_handler(task_allocator, task_context, connection.stream) catch {};
        }
    };

    var permits = std.Thread.Semaphore{ .permits = @max(options.worker_count, 1) };
    while (true) {
        permits.wait();
        const connection = server.accept() catch |err| {
            permits.post();
            return err;
        };
        pool.spawn(Runner.run, .{ allocator, app_context, connection, &permits, handler }) catch |err| {
            connection.stream.close();
            permits.post();
            return err;
        };
    }
}

pub fn readHttpRequest(allocator: Allocator, stream: std.net.Stream) ![]u8 {
    return readHttpRequestLimit(allocator, stream, request.max_http_request);
}

pub fn readHttpRequestLimit(allocator: Allocator, stream: std.net.Stream, max_len: usize) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);

    var expected_len: ?usize = null;
    while (raw.items.len < max_len) {
        var chunk: [4096]u8 = undefined;
        const read_len = try stream.read(&chunk);
        if (read_len == 0) break;
        try raw.appendSlice(allocator, chunk[0..read_len]);

        if (expected_len == null) {
            if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |header_end| {
                const content_len = try request.parseContentLength(raw.items[0..header_end]);
                expected_len = header_end + 4 + content_len;
                if (expected_len.? > max_len) return error.RequestTooLarge;
            }
        }

        if (expected_len) |needed| {
            if (raw.items.len >= needed) break;
        }
    }

    if (raw.items.len == 0) return error.BadRequest;
    if (raw.items.len >= max_len) return error.RequestTooLarge;
    return raw.toOwnedSlice(allocator);
}

pub fn isClientDisconnect(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, default_host) or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "localhost");
}
