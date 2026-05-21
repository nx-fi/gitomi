const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn io() std.Io {
    if (comptime builtin.is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn sleep(ns: u64) void {
    const duration = std.Io.Duration.fromNanoseconds(@intCast(@min(ns, @as(u64, std.math.maxInt(i64)))));
    std.Io.sleep(io(), duration, .awake) catch {};
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io()).toSeconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io()).toMilliseconds();
}

pub fn readFile(file: std.Io.File, buffer: []u8) !usize {
    return file.readStreaming(io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

pub fn readFileAlloc(allocator: Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try readFile(file, &buffer);
        if (read_len == 0) break;
        if (out.items.len > max_bytes or read_len > max_bytes - out.items.len) return error.StreamTooLong;
        try out.appendSlice(allocator, buffer[0..read_len]);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn seekFileToEnd(file: std.Io.File) !void {
    const current_io = io();
    const end = try file.length(current_io);
    try current_io.vtable.fileSeekTo(current_io.userdata, file, end);
}

pub fn getEnvVarOwned(allocator: Allocator, name: []const u8) ![]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value_z = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value_z));
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

pub const random = struct {
    pub fn bytes(buffer: []u8) void {
        io().random(buffer);
    }

    pub fn intRangeAtMost(comptime T: type, at_least: T, at_most: T) T {
        var source = std.Random.IoSource{ .io = io() };
        return source.interface().intRangeAtMost(T, at_least, at_most);
    }
};

pub fn appendPrint(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, buf);
    errdefer writer.deinit();
    try writer.writer.print(fmt, args);
    buf.* = writer.toArrayList();
}

pub const net = struct {
    pub const Address = struct {
        inner: std.Io.net.IpAddress,

        pub fn parseIp(host: []const u8, port: u16) !Address {
            return .{ .inner = try std.Io.net.IpAddress.parse(host, port) };
        }

        pub fn listen(self: Address, options: std.Io.net.IpAddress.ListenOptions) !Server {
            const inner = try self.inner.listen(io(), options);
            return .{
                .inner = inner,
                .listen_address = .{ .inner = inner.socket.address },
            };
        }

        pub fn getPort(self: Address) u16 {
            return self.inner.getPort();
        }
    };

    pub const Server = struct {
        inner: std.Io.net.Server,
        listen_address: Address,

        pub const Connection = struct {
            stream: Stream,
        };

        pub fn deinit(self: *Server) void {
            self.inner.deinit(io());
        }

        pub fn accept(self: *Server) !Connection {
            const inner_stream = try self.inner.accept(io());
            return .{ .stream = Stream.init(inner_stream) };
        }
    };

    pub const Stream = struct {
        inner: std.Io.net.Stream,
        handle: std.Io.net.Socket.Handle,

        fn init(inner: std.Io.net.Stream) Stream {
            return .{ .inner = inner, .handle = inner.socket.handle };
        }

        pub fn close(self: Stream) void {
            self.inner.close(io());
        }

        pub fn read(self: Stream, buffer: []u8) !usize {
            var data = [_][]u8{buffer};
            return io().vtable.netRead(io().userdata, self.handle, &data);
        }

        pub fn writeAll(self: Stream, bytes: []const u8) !void {
            var buffer: [4096]u8 = undefined;
            var writer = self.inner.writer(io(), &buffer);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
        }
    };
};

pub const ChildOutput = struct {
    stdout: []u8,
    stderr: []u8,
};

pub fn spawnChild(
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
) !std.process.Child {
    return std.process.spawn(io(), .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = env_map,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

pub fn writeChildInput(child: *std.process.Child, input: []const u8) !void {
    const stdin = child.stdin orelse return;
    try stdin.writeStreamingAll(io(), input);
    stdin.close(io());
    child.stdin = null;
}

pub fn collectChildOutput(
    allocator: Allocator,
    child: *std.process.Child,
    max_output_bytes: usize,
) !ChildOutput {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(4096, .none)) |_| {
        if (stdout_reader.bufferedLen() > max_output_bytes or stderr_reader.bufferedLen() > max_output_bytes) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);

    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);

    return .{ .stdout = stdout, .stderr = stderr };
}

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

pub fn runProcess(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    max_output_bytes: usize,
    env_map: ?*const std.process.Environ.Map,
) !RunResult {
    var child = try spawnChild(argv, cwd, input, env_map);
    defer child.kill(io());

    if (input) |bytes| try writeChildInput(&child, bytes);
    const output = try collectChildOutput(allocator, &child, max_output_bytes);
    errdefer {
        allocator.free(output.stdout);
        allocator.free(output.stderr);
    }
    const term = try child.wait(io());

    return .{
        .stdout = output.stdout,
        .stderr = output.stderr,
        .term = term,
    };
}

pub fn terminateChildNoWait(child: *std.process.Child) void {
    switch (builtin.os.tag) {
        .windows => child.kill(io()),
        else => if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {},
    }
}
