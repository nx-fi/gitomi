const std = @import("std");
const compat = @import("compat");

const BufferedStream = struct {
    mutex: compat.Mutex = .{},
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer = undefined,
    initialized: bool = false,

    fn print(self: *BufferedStream, file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.initialized) {
            self.writer = file.writerStreaming(compat.io(), &self.buffer);
            self.initialized = true;
        }

        const stream = &self.writer.interface;
        try stream.print(fmt, args);
        try stream.flush();
    }
};

var stdout_stream: BufferedStream = .{};
var stderr_stream: BufferedStream = .{};

pub fn out(comptime fmt: []const u8, args: anytype) !void {
    try stdout_stream.print(std.Io.File.stdout(), fmt, args);
}

pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
    try stderr_stream.print(std.Io.File.stderr(), fmt, args);
}
