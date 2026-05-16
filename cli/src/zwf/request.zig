const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_http_request = 10 * 1024 * 1024;
pub const max_path_params = 8;

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    other,

    pub fn parse(value: []const u8) Method {
        if (std.ascii.eqlIgnoreCase(value, "GET")) return .GET;
        if (std.ascii.eqlIgnoreCase(value, "POST")) return .POST;
        if (std.ascii.eqlIgnoreCase(value, "PUT")) return .PUT;
        if (std.ascii.eqlIgnoreCase(value, "PATCH")) return .PATCH;
        if (std.ascii.eqlIgnoreCase(value, "DELETE")) return .DELETE;
        if (std.ascii.eqlIgnoreCase(value, "HEAD")) return .HEAD;
        if (std.ascii.eqlIgnoreCase(value, "OPTIONS")) return .OPTIONS;
        return .other;
    }

    pub fn text(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .other => "OTHER",
        };
    }
};

pub const ByteRange = struct {
    start: ?usize,
    end: ?usize,
};

pub const HeaderMap = struct {
    raw: []const u8,

    pub fn value(self: HeaderMap, header_name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.raw, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(name, header_name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    pub fn contentLength(self: HeaderMap) !usize {
        const raw = self.value("content-length") orelse return 0;
        return std.fmt.parseUnsigned(usize, raw, 10) catch error.BadRequest;
    }
};

pub const QueryMap = struct {
    target: []const u8,

    pub fn valueOwned(self: QueryMap, allocator: Allocator, wanted_key: []const u8) !?[]u8 {
        const query_start = std.mem.indexOfScalar(u8, self.target, '?') orelse return null;
        return queryStringValueOwned(allocator, self.target[query_start + 1 ..], wanted_key);
    }
};

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParamMap = struct {
    items: [max_path_params]Param = undefined,
    len: usize = 0,

    pub fn empty() ParamMap {
        return .{ .items = undefined, .len = 0 };
    }

    pub fn put(self: *ParamMap, name: []const u8, value: []const u8) !void {
        if (self.len >= self.items.len) return error.TooManyPathParams;
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    pub fn get(self: ParamMap, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

pub const Request = struct {
    method: Method,
    method_text: []const u8,
    target: []const u8,
    path: []const u8,
    body: []const u8,
    headers: HeaderMap,
    query: QueryMap,
    params: ParamMap = ParamMap.empty(),
    range: ?ByteRange = null,

    pub fn parse(raw: []const u8) !Request {
        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
        const headers = HeaderMap{ .raw = raw[0..header_end] };
        const content_len = try headers.contentLength();
        const body_start = header_end + 4;
        if (raw.len < body_start + content_len) return error.BadRequest;

        var lines = std.mem.splitSequence(u8, headers.raw, "\r\n");
        const request_line = lines.next() orelse return error.BadRequest;
        var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
        const method_text = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        _ = parts.next() orelse return error.BadRequest;

        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        return .{
            .method = Method.parse(method_text),
            .method_text = method_text,
            .target = target,
            .path = target[0..query_start],
            .body = raw[body_start .. body_start + content_len],
            .headers = headers,
            .query = .{ .target = target },
            .range = parseRangeHeader(headers),
        };
    }

    pub fn withParams(self: Request, params: ParamMap) Request {
        var copy = self;
        copy.params = params;
        return copy;
    }

    pub fn headerValue(self: Request, name: []const u8) ?[]const u8 {
        return self.headers.value(name);
    }

    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn queryValueOwned(self: Request, allocator: Allocator, name: []const u8) !?[]u8 {
        return self.query.valueOwned(allocator, name);
    }

    pub fn formValues(self: Request, allocator: Allocator) !FormData {
        return FormData.parse(allocator, self.body);
    }
};

pub const FormField = struct {
    name: []u8,
    value: []u8,
};

pub const FormData = struct {
    allocator: Allocator,
    fields: []FormField,

    pub fn parse(allocator: Allocator, body: []const u8) !FormData {
        var fields: std.ArrayList(FormField) = .empty;
        errdefer {
            for (fields.items) |field| {
                allocator.free(field.name);
                allocator.free(field.value);
            }
            fields.deinit(allocator);
        }

        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..equals];
            const raw_value = if (equals < pair.len) pair[equals + 1 ..] else "";
            const name = try percentDecodeForm(allocator, raw_name);
            errdefer allocator.free(name);
            const decoded_value = try percentDecodeForm(allocator, raw_value);
            errdefer allocator.free(decoded_value);
            try fields.append(allocator, .{ .name = name, .value = decoded_value });
        }

        return .{
            .allocator = allocator,
            .fields = try fields.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: FormData) void {
        for (self.fields) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        self.allocator.free(self.fields);
    }

    pub fn value(self: FormData, name: []const u8) ?[]const u8 {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }
};

pub fn parseContentLength(headers: []const u8) !usize {
    return (HeaderMap{ .raw = headers }).contentLength();
}

pub fn queryStringValueOwned(allocator: Allocator, query: []const u8, wanted_key: []const u8) !?[]u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const raw_key = field[0..equals];
        const raw_value = if (equals < field.len) field[equals + 1 ..] else "";
        const key = try percentDecodeForm(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecodeForm(allocator, raw_value);
    }
    return null;
}

pub fn percentDecodeForm(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < value.len) {
            const decoded = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch null;
            if (decoded) |byte| {
                try out.append(allocator, byte);
                i += 3;
            } else {
                try out.append(allocator, c);
                i += 1;
            }
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseRangeHeader(headers: HeaderMap) ?ByteRange {
    const value = headers.value("range") orelse return null;
    return parseByteRange(value);
}

fn parseByteRange(value: []const u8) ?ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_raw = std.mem.trim(u8, spec[0..dash], " \t");
    const end_raw = std.mem.trim(u8, spec[dash + 1 ..], " \t");
    if (start_raw.len == 0 and end_raw.len == 0) return null;
    return .{
        .start = if (start_raw.len == 0) null else std.fmt.parseUnsigned(usize, start_raw, 10) catch return null,
        .end = if (end_raw.len == 0) null else std.fmt.parseUnsigned(usize, end_raw, 10) catch return null,
    };
}

test "request parser separates method path headers query and body" {
    const raw =
        "POST /issues?title=hello+world HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "title=Smoke";
    const parsed = try Request.parse(raw);
    try std.testing.expectEqual(Method.POST, parsed.method);
    try std.testing.expectEqualStrings("POST", parsed.method_text);
    try std.testing.expectEqualStrings("/issues?title=hello+world", parsed.target);
    try std.testing.expectEqualStrings("/issues", parsed.path);
    try std.testing.expectEqualStrings("title=Smoke", parsed.body);

    const title = try parsed.queryValueOwned(std.testing.allocator, "title");
    defer if (title) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("hello world", title.?);
}

test "request parser accepts byte ranges and cache validators" {
    const raw =
        "GET /raw?path=movie.mp4 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Range: bytes=10-99\r\n" ++
        "If-None-Match: \"asset-etag\"\r\n" ++
        "\r\n";
    const parsed = try Request.parse(raw);
    try std.testing.expectEqual(Method.GET, parsed.method);
    try std.testing.expect(parsed.range != null);
    try std.testing.expectEqual(@as(?usize, 10), parsed.range.?.start);
    try std.testing.expectEqual(@as(?usize, 99), parsed.range.?.end);
    try std.testing.expectEqualStrings("\"asset-etag\"", parsed.headerValue("if-none-match").?);
}

test "form parser decodes url encoded values" {
    const data = try FormData.parse(std.testing.allocator, "title=Hello+World&path=src%2Fmain.zig");
    defer data.deinit();

    try std.testing.expectEqualStrings("Hello World", data.value("title").?);
    try std.testing.expectEqualStrings("src/main.zig", data.value("path").?);
}
