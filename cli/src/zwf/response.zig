const std = @import("std");
const request_mod = @import("request.zig");

const Allocator = std.mem.Allocator;

pub const Header = request_mod.Header;

pub const Compression = enum {
    none,
    gzip,
};

pub const Options = struct {
    head: bool = false,
    compression: Compression = .none,
};

pub const CookieSameSite = enum {
    lax,
    strict,
    none,

    fn text(self: CookieSameSite) []const u8 {
        return switch (self) {
            .lax => "Lax",
            .strict => "Strict",
            .none => "None",
        };
    }
};

pub const CookieOptions = struct {
    path: ?[]const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    http_only: bool = true,
    secure: bool = false,
    same_site: ?CookieSameSite = .lax,
};

pub const SentInfo = struct {
    status: u16 = 0,
    bytes: usize = 0,
    compressed: bool = false,
};

pub const Response = struct {
    allocator: Allocator,
    stream: std.net.Stream,
    options: Options = .{},
    sent: ?*SentInfo = null,

    pub fn init(allocator: Allocator, stream: std.net.Stream) Response {
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn initWithOptions(allocator: Allocator, stream: std.net.Stream, options: Options) Response {
        return .{ .allocator = allocator, .stream = stream, .options = options };
    }

    pub fn initWithRequest(allocator: Allocator, stream: std.net.Stream, request: request_mod.Request) Response {
        return initWithOptions(allocator, stream, .{
            .head = request.method == .HEAD,
        });
    }

    pub fn withSentInfo(self: Response, sent: *SentInfo) Response {
        var copy = self;
        copy.sent = sent;
        return copy;
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

    pub fn jsonHeaders(self: Response, body: []const u8, extra_headers: []const Header) !void {
        try self.sendWithHeaders(200, "OK", "application/json", body, extra_headers, .{ .charset = true });
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
        try validateHeaderValue(location);
        const headers = [_]Header{.{ .name = "Location", .value = location }};
        try self.sendWithHeaders(303, "See Other", "text/plain", "See Other\n", &headers, .{ .charset = true });
    }

    pub fn temporaryRedirect(self: Response, location: []const u8) !void {
        try validateHeaderValue(location);
        const headers = [_]Header{.{ .name = "Location", .value = location }};
        try self.sendWithHeaders(307, "Temporary Redirect", "text/plain", "Temporary Redirect\n", &headers, .{ .charset = true });
    }

    pub fn send(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra_headers: ?[]const u8,
    ) !void {
        const headers = try parseRawHeaders(self.allocator, extra_headers orelse "");
        defer self.allocator.free(headers);
        try self.sendWithHeaders(status, reason, content_type, body, headers, .{ .charset = true });
    }

    pub fn sendWithHeaders(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra_headers: []const Header,
        send_options: SendOptions,
    ) !void {
        try validateStatus(status, reason);
        try validateHeaderValue(content_type);
        try validateExtraHeaders(extra_headers);

        const may_compress = self.options.compression == .gzip and
            statusAllowsBody(status) and
            body.len >= 1024 and
            !hasHeader(extra_headers, "content-encoding") and
            isCompressibleContentType(content_type);

        var compressed_body: ?[]u8 = null;
        defer if (compressed_body) |compressed| self.allocator.free(compressed);
        const response_body = if (may_compress) blk: {
            if (try gzipIfSmallerOwned(self.allocator, body)) |encoded| {
                compressed_body = encoded;
                break :blk encoded;
            }
            break :blk body;
        } else body;

        const content_type_value = try contentTypeValueOwned(self.allocator, content_type, send_options.charset);
        defer self.allocator.free(content_type_value);

        var headers: std.ArrayList(u8) = .empty;
        defer headers.deinit(self.allocator);
        try appendStatusLine(&headers, self.allocator, status, reason);
        try appendHeader(&headers, self.allocator, "Content-Type", content_type_value);
        try appendCommonHeaders(&headers, self.allocator);
        if (compressed_body != null) {
            try appendHeader(&headers, self.allocator, "Content-Encoding", "gzip");
            try appendHeader(&headers, self.allocator, "Vary", "Accept-Encoding");
        }
        try appendContentLengthIfAllowed(&headers, self.allocator, status, response_body.len);
        for (extra_headers) |header| try appendHeader(&headers, self.allocator, header.name, header.value);
        try headers.appendSlice(self.allocator, "\r\n");

        try self.stream.writeAll(headers.items);
        if (!self.options.head and statusAllowsBody(status) and response_body.len > 0) {
            try self.stream.writeAll(response_body);
        }
        self.record(status, response_body.len, compressed_body != null);
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
        const headers = try parseRawHeaders(self.allocator, extra_headers orelse "");
        defer self.allocator.free(headers);
        try self.sendWithHeaders(status, reason, content_type, body, headers, .{ .charset = false });
    }

    pub fn binaryHeaders(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        body: []const u8,
        extra_headers: []const Header,
    ) !void {
        try self.sendWithHeaders(status, reason, content_type, body, extra_headers, .{ .charset = false });
    }

    pub fn notModified(self: Response, extra_headers: []const u8) !void {
        const headers = try parseRawHeaders(self.allocator, extra_headers);
        defer self.allocator.free(headers);
        try self.notModifiedHeaders(headers);
    }

    pub fn notModifiedHeaders(self: Response, extra_headers: []const Header) !void {
        try self.sendWithHeaders(304, "Not Modified", "text/plain", "", extra_headers, .{ .charset = false });
    }

    pub fn streamChunked(
        self: Response,
        status: u16,
        reason: []const u8,
        content_type: []const u8,
        extra_headers: []const Header,
        send_options: SendOptions,
    ) !ChunkedResponse {
        try validateStatus(status, reason);
        try validateHeaderValue(content_type);
        try validateExtraHeaders(extra_headers);

        var headers: std.ArrayList(u8) = .empty;
        defer headers.deinit(self.allocator);
        try appendStatusLine(&headers, self.allocator, status, reason);
        const content_type_value = try contentTypeValueOwned(self.allocator, content_type, send_options.charset);
        defer self.allocator.free(content_type_value);
        try appendHeader(&headers, self.allocator, "Content-Type", content_type_value);
        try appendCommonHeaders(&headers, self.allocator);
        try appendHeader(&headers, self.allocator, "Transfer-Encoding", "chunked");
        for (extra_headers) |header| try appendHeader(&headers, self.allocator, header.name, header.value);
        try headers.appendSlice(self.allocator, "\r\n");
        try self.stream.writeAll(headers.items);
        self.record(status, 0, false);
        return .{ .response = self, .ended = false };
    }

    pub fn setCookieHeaderOwned(self: Response, name: []const u8, value: []const u8, options: CookieOptions) !Header {
        try validateCookieName(name);
        try validateCookieValue(value);
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, name);
        try buf.append(self.allocator, '=');
        try buf.appendSlice(self.allocator, value);
        if (options.path) |path| {
            try validateCookieValue(path);
            try buf.appendSlice(self.allocator, "; Path=");
            try buf.appendSlice(self.allocator, path);
        }
        if (options.domain) |domain| {
            try validateCookieValue(domain);
            try buf.appendSlice(self.allocator, "; Domain=");
            try buf.appendSlice(self.allocator, domain);
        }
        if (options.max_age) |max_age| try std.fmt.format(buf.writer(self.allocator), "; Max-Age={d}", .{max_age});
        if (options.http_only) try buf.appendSlice(self.allocator, "; HttpOnly");
        if (options.secure) try buf.appendSlice(self.allocator, "; Secure");
        if (options.same_site) |same_site| {
            try buf.appendSlice(self.allocator, "; SameSite=");
            try buf.appendSlice(self.allocator, same_site.text());
        }
        return .{ .name = "Set-Cookie", .value = try buf.toOwnedSlice(self.allocator) };
    }

    fn record(self: Response, status: u16, bytes: usize, compressed: bool) void {
        if (self.sent) |sent| {
            sent.* = .{
                .status = status,
                .bytes = bytes,
                .compressed = compressed,
            };
        }
    }
};

pub const SendOptions = struct {
    charset: bool = true,
};

pub const ChunkedResponse = struct {
    response: Response,
    ended: bool,

    pub fn write(self: *ChunkedResponse, bytes: []const u8) !void {
        if (self.ended) return error.ResponseAlreadyEnded;
        if (self.response.options.head or bytes.len == 0) return;
        const prefix = try std.fmt.allocPrint(self.response.allocator, "{x}\r\n", .{bytes.len});
        defer self.response.allocator.free(prefix);
        try self.response.stream.writeAll(prefix);
        try self.response.stream.writeAll(bytes);
        try self.response.stream.writeAll("\r\n");
        if (self.response.sent) |sent| sent.bytes += bytes.len;
    }

    pub fn end(self: *ChunkedResponse) !void {
        if (self.ended) return;
        self.ended = true;
        try self.response.stream.writeAll("0\r\n\r\n");
    }
};

fn contentTypeValueOwned(allocator: Allocator, content_type: []const u8, charset: bool) ![]u8 {
    if (!charset or std.mem.indexOfScalar(u8, content_type, ';') != null) return allocator.dupe(u8, content_type);
    return std.fmt.allocPrint(allocator, "{s}; charset=utf-8", .{content_type});
}

fn appendStatusLine(buf: *std.ArrayList(u8), allocator: Allocator, status: u16, reason: []const u8) !void {
    try std.fmt.format(buf.writer(allocator), "HTTP/1.1 {d} {s}\r\n", .{ status, reason });
}

fn appendCommonHeaders(buf: *std.ArrayList(u8), allocator: Allocator) !void {
    try appendHeader(buf, allocator, "Connection", "close");
    try appendHeader(buf, allocator, "X-Content-Type-Options", "nosniff");
}

fn appendHeader(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: []const u8) !void {
    try validateHeaderName(name);
    try validateHeaderValue(value);
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, ": ");
    try buf.appendSlice(allocator, value);
    try buf.appendSlice(allocator, "\r\n");
}

fn appendHeaderInt(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: usize) !void {
    try validateHeaderName(name);
    try std.fmt.format(buf.writer(allocator), "{s}: {d}\r\n", .{ name, value });
}

fn appendContentLengthIfAllowed(buf: *std.ArrayList(u8), allocator: Allocator, status: u16, value: usize) !void {
    if (statusAllowsBody(status)) try appendHeaderInt(buf, allocator, "Content-Length", value);
}

fn parseRawHeaders(allocator: Allocator, raw: []const u8) ![]Header {
    if (raw.len == 0) return allocator.alloc(Header, 0);
    if (!std.mem.endsWith(u8, raw, "\r\n")) return error.BadHeaderValue;
    var headers: std.ArrayList(Header) = .empty;
    errdefer headers.deinit(allocator);
    var rest = raw;
    while (rest.len > 0) {
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadHeaderValue;
        const line = rest[0..end];
        rest = rest[end + 2 ..];
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeaderValue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try validateHeaderName(name);
        try validateHeaderValue(value);
        try headers.append(allocator, .{ .name = name, .value = value });
    }
    return headers.toOwnedSlice(allocator);
}

fn validateExtraHeaders(headers: []const Header) !void {
    for (headers) |header| {
        try validateExtraHeaderName(header.name);
        try validateHeaderValue(header.value);
    }
}

pub fn validateHeaderName(name: []const u8) !void {
    try request_mod.validateHeaderName(name);
}

pub fn validateExtraHeaderName(name: []const u8) !void {
    try validateHeaderName(name);
    if (isManagedExtraHeaderName(name)) return error.ManagedResponseHeader;
}

pub fn validateHeaderValue(value: []const u8) !void {
    try request_mod.validateHeaderValue(value);
}

fn validateStatus(status: u16, reason: []const u8) !void {
    if (status < 100 or status > 999) return error.BadStatus;
    try validateHeaderValue(reason);
}

fn hasHeader(headers: []const Header, wanted: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted)) return true;
    }
    return false;
}

fn isManagedExtraHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-authenticate") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "te") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}

fn statusAllowsBody(status: u16) bool {
    return status != 204 and status != 304 and status >= 200;
}

fn isCompressibleContentType(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "text/") or
        std.ascii.eqlIgnoreCase(content_type, "application/json") or
        std.ascii.eqlIgnoreCase(content_type, "application/javascript") or
        std.ascii.eqlIgnoreCase(content_type, "image/svg+xml");
}

pub fn gzipStoreOwned(allocator: Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });

    var offset: usize = 0;
    while (offset < body.len or (body.len == 0 and offset == 0)) {
        const remaining = body.len - offset;
        const chunk_len = @min(remaining, 65535);
        const final = offset + chunk_len >= body.len;
        try out.append(allocator, if (final) 0x01 else 0x00);
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(chunk_len), .little);
        try out.appendSlice(allocator, &len_bytes);
        std.mem.writeInt(u16, &len_bytes, ~@as(u16, @intCast(chunk_len)), .little);
        try out.appendSlice(allocator, &len_bytes);
        try out.appendSlice(allocator, body[offset .. offset + chunk_len]);
        offset += chunk_len;
        if (body.len == 0) break;
    }

    var crc = std.hash.Crc32.init();
    crc.update(body);
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], crc.final(), .little);
    std.mem.writeInt(u32, footer[4..8], @truncate(body.len), .little);
    try out.appendSlice(allocator, &footer);
    return out.toOwnedSlice(allocator);
}

fn gzipIfSmallerOwned(allocator: Allocator, body: []const u8) !?[]u8 {
    const encoded = try gzipStoreOwned(allocator, body);
    if (encoded.len >= body.len) {
        allocator.free(encoded);
        return null;
    }
    return encoded;
}

fn validateCookieName(name: []const u8) !void {
    try validateHeaderName(name);
}

fn validateCookieValue(value: []const u8) !void {
    for (value) |c| {
        if (c <= 0x20 or c == 0x7f or c == ';' or c == ',') return error.BadCookieValue;
    }
}

test "response rejects redirect header injection" {
    try std.testing.expectError(error.BadHeaderValue, validateHeaderValue("/ok\r\nX-Bad: yes"));
}

test "gzip store emits gzip envelope" {
    const encoded = try gzipStoreOwned(std.testing.allocator, "hello");
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > "hello".len);
    try std.testing.expectEqual(@as(u8, 0x1f), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), encoded[1]);
}

test "stored gzip is skipped when it would expand the response" {
    const encoded = try gzipIfSmallerOwned(std.testing.allocator, "hello");
    defer if (encoded) |bytes| std.testing.allocator.free(bytes);
    try std.testing.expect(encoded == null);
}

test "common response headers close the connection" {
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(std.testing.allocator);
    try appendCommonHeaders(&headers, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, headers.items, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers.items, "keep-alive") == null);
}

test "bodyless response headers do not emit content length" {
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(std.testing.allocator);
    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 204, 10);
    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 304, 10);
    try std.testing.expectEqual(@as(usize, 0), headers.items.len);

    try appendContentLengthIfAllowed(&headers, std.testing.allocator, 200, 10);
    try std.testing.expectEqualStrings("Content-Length: 10\r\n", headers.items);
}

test "extra response headers reject managed and hop by hop names" {
    try std.testing.expectError(error.ManagedResponseHeader, validateExtraHeaders(&[_]Header{
        .{ .name = "Content-Length", .value = "1" },
    }));
    try std.testing.expectError(error.ManagedResponseHeader, validateExtraHeaders(&[_]Header{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    }));
    try std.testing.expectError(error.ManagedResponseHeader, validateExtraHeaders(&[_]Header{
        .{ .name = "Connection", .value = "keep-alive" },
    }));
    try std.testing.expectError(error.ManagedResponseHeader, validateExtraHeaders(&[_]Header{
        .{ .name = "Content-Type", .value = "text/plain" },
    }));
}
