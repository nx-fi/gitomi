const std = @import("std");
const request = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const default_worker_count = 8;
pub const default_port_attempt_limit = 128;
pub const default_host = "127.0.0.1";
pub const default_port = 12655;
pub const default_read_timeout_ms = 30_000;
pub const default_write_timeout_ms = 30_000;

pub const TlsOptions = struct {
    cert_path: []const u8,
    key_path: []const u8,
};

pub const Observability = struct {
    access_log: bool = true,
};

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
    port_supplied: bool = false,
    once: bool = false,
    worker_count: usize = default_worker_count,
    port_attempt_limit: usize = default_port_attempt_limit,
    read_timeout_ms: ?u32 = default_read_timeout_ms,
    write_timeout_ms: ?u32 = default_write_timeout_ms,
    keep_alive_max_requests: usize = 100,
    tls: ?TlsOptions = null,
    observability: Observability = .{},
};

pub fn ConnectionHandler(comptime Context: type) type {
    return *const fn (Allocator, Context, std.net.Stream) anyerror!void;
}

pub fn bindHost(options: Options) []const u8 {
    return if (std.mem.eql(u8, options.host, "localhost")) default_host else options.host;
}

pub fn listen(bind_host: []const u8, options: Options) !std.net.Server {
    if (options.tls != null) return error.TlsUnsupported;
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
        try configureStream(connection.stream, options);
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
        configureStream(connection.stream, options) catch |err| {
            connection.stream.close();
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
            const body_start = end + 4;
            switch (try request.readPlan(raw.items[0..end])) {
                .none => expected_len = body_start,
                .content_length => |content_len| {
                    expected_len = body_start + content_len;
                    if (expected_len.? > max_len) return error.RequestTooLarge;
                },
                .chunked => {
                    if (body_start > max_len) return error.RequestTooLarge;
                    if (try request.chunkedBodyFrameLength(raw.items[body_start..], max_len - body_start)) |frame| {
                        expected_len = body_start + frame.encoded_len;
                        if (expected_len.? > max_len) return error.RequestTooLarge;
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
    return std.mem.eql(u8, host, default_host) or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "localhost");
}

pub fn configureStream(stream: std.net.Stream, options: Options) !void {
    if (options.read_timeout_ms) |timeout_ms| try setSocketTimeout(stream, std.posix.SO.RCVTIMEO, timeout_ms);
    if (options.write_timeout_ms) |timeout_ms| try setSocketTimeout(stream, std.posix.SO.SNDTIMEO, timeout_ms);
}

fn setSocketTimeout(stream: std.net.Stream, optname: u32, timeout_ms: u32) !void {
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
