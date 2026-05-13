const std = @import("std");

pub fn out(comptime fmt: []const u8, args: anytype) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(fmt, args);
    try stdout.flush();
}

pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}
