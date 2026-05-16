const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Response = struct {
    allocator: Allocator,
    stream: std.net.Stream,

    pub fn init(allocator: Allocator, stream: std.net.Stream) Response {
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn html(self: Response, body: []const u8) !void {
        try self.send(200, "OK", "text/html", body, null);
    }

    pub fn ownedHtml(self: Response, body: []u8) !void {
        defer self.allocator.free(body);
        try self.html(body);
    }

    pub fn json(self: Response, body: []const u8, extra_headers: ?[]const u8) !void {
        try self.send(200, "OK", "application/json", body, extra_headers);
    }

    pub fn ownedJson(self: Response, body: []u8, extra_headers: ?[]const u8) !void {
        defer self.allocator.free(body);
        try self.json(body, extra_headers);
    }

    pub fn plain(self: Response, status: u16, reason: []const u8, body: []const u8) !void {
        try self.send(status, reason, "text/plain", body, null);
    }

    pub fn noContent(self: Response) !void {
        try self.send(204, "No Content", "text/plain", "", null);
    }

    pub fn notFound(self: Response) !void {
        try self.plain(404, "Not Found", "Not found\n");
    }

    pub fn redirect(self: Response, location: []const u8) !void {
        const extra = try std.fmt.allocPrint(self.allocator, "Location: {s}\r\n", .{location});
        defer self.allocator.free(extra);
        try self.send(303, "See Other", "text/plain", "See Other\n", extra);
    }

    pub fn temporaryRedirect(self: Response, location: []const u8) !void {
        const extra = try std.fmt.allocPrint(self.allocator, "Location: {s}\r\n", .{location});
        defer self.allocator.free(extra);
        try self.send(307, "Temporary Redirect", "text/plain", "Temporary Redirect\n", extra);
    }

    pub fn send(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra_headers: ?[]const u8,
    ) !void {
        const headers = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n{s}\r\n",
            .{ status, reason, content_type, body.len, extra_headers orelse "" },
        );
        defer self.allocator.free(headers);
        try self.stream.writeAll(headers);
        try self.stream.writeAll(body);
    }

    pub fn owned(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []u8,
        extra_headers: ?[]const u8,
    ) !void {
        defer self.allocator.free(body);
        try self.send(status, reason, content_type, body, extra_headers);
    }

    pub fn binary(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra_headers: ?[]const u8,
    ) !void {
        const headers = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n{s}\r\n",
            .{ status, reason, content_type, body.len, extra_headers orelse "" },
        );
        defer self.allocator.free(headers);
        try self.stream.writeAll(headers);
        try self.stream.writeAll(body);
    }

    pub fn notModified(self: Response, extra_headers: []const u8) !void {
        const headers = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n{s}\r\n",
            .{extra_headers},
        );
        defer self.allocator.free(headers);
        try self.stream.writeAll(headers);
    }
};
