const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_http_request = 10 * 1024 * 1024;
pub const max_http_header = 64 * 1024;
pub const max_headers = 128;
pub const max_path_params = 16;

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

pub const HttpVersion = enum {
    http10,
    http11,

    pub fn parse(value: []const u8) !HttpVersion {
        if (std.mem.eql(u8, value, "HTTP/1.0")) return .http10;
        if (std.mem.eql(u8, value, "HTTP/1.1")) return .http11;
        return error.BadRequest;
    }

    pub fn text(self: HttpVersion) []const u8 {
        return switch (self) {
            .http10 => "HTTP/1.0",
            .http11 => "HTTP/1.1",
        };
    }

    pub fn defaultKeepAlive(self: HttpVersion) bool {
        return self == .http11;
    }
};

pub const ByteRange = struct {
    start: ?usize,
    end: ?usize,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderIterator = struct {
    raw: []const u8,
    pos: usize = 0,
    first: bool = true,

    pub fn init(raw: []const u8) HeaderIterator {
        return .{ .raw = raw };
    }

    pub fn next(self: *HeaderIterator) ?Header {
        while (self.nextLine()) |line| {
            if (line.len == 0) return null;
            if (self.first) {
                self.first = false;
                if (isRequestLine(line)) continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            return .{ .name = name, .value = value };
        }
        return null;
    }

    fn nextLine(self: *HeaderIterator) ?[]const u8 {
        if (self.pos > self.raw.len) return null;
        const start = self.pos;
        if (std.mem.indexOfPos(u8, self.raw, start, "\r\n")) |end| {
            self.pos = end + 2;
            return self.raw[start..end];
        }
        self.pos = self.raw.len + 1;
        return self.raw[start..];
    }
};

pub const HeaderMap = struct {
    raw: []const u8,

    pub fn value(self: HeaderMap, header_name: []const u8) ?[]const u8 {
        var it = HeaderIterator.init(self.raw);
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, header_name)) return header.value;
        }
        return null;
    }

    pub fn contentLength(self: HeaderMap) !usize {
        return (try self.contentLengthMaybe()) orelse 0;
    }

    pub fn contentLengthMaybe(self: HeaderMap) !?usize {
        var found: ?usize = null;
        var it = HeaderIterator.init(self.raw);
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
            if (found != null) return error.BadRequest;
            if (header.value.len == 0) return error.BadRequest;
            found = std.fmt.parseUnsigned(usize, header.value, 10) catch return error.BadRequest;
        }
        return found;
    }

    pub fn containsToken(self: HeaderMap, header_name: []const u8, wanted_token: []const u8) bool {
        var it = HeaderIterator.init(self.raw);
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, header_name)) continue;
            if (headerValueContainsToken(header.value, wanted_token)) return true;
        }
        return false;
    }

    pub fn transferEncoding(self: HeaderMap) !BodyEncoding {
        var found = false;
        var it = HeaderIterator.init(self.raw);
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
            if (found) return error.BadRequest;
            found = true;

            var saw_chunked = false;
            var tokens = std.mem.splitScalar(u8, header.value, ',');
            while (tokens.next()) |raw_token| {
                const token = std.mem.trim(u8, raw_token, " \t");
                if (token.len == 0) return error.BadRequest;
                if (std.ascii.eqlIgnoreCase(token, "chunked")) {
                    saw_chunked = true;
                } else if (!std.ascii.eqlIgnoreCase(token, "identity")) {
                    return error.BadRequest;
                }
            }
            if (!saw_chunked) return error.BadRequest;
            return .chunked;
        }
        return .none;
    }
};

pub const BodyEncoding = enum {
    none,
    content_length,
    chunked,
};

pub const ReadPlan = union(BodyEncoding) {
    none: void,
    content_length: usize,
    chunked: void,
};

pub const ChunkedFrame = struct {
    encoded_len: usize,
    decoded_len: usize,
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
    version: HttpVersion = .http11,
    body: []const u8,
    body_owned: ?[]u8 = null,
    headers: HeaderMap,
    query: QueryMap,
    params: ParamMap = ParamMap.empty(),
    range: ?ByteRange = null,

    pub fn parse(raw: []const u8) !Request {
        return parseWithAllocator(null, raw);
    }

    pub fn parseOwned(allocator: Allocator, raw: []const u8) !Request {
        return parseWithAllocator(allocator, raw);
    }

    pub fn deinit(self: *Request, allocator: Allocator) void {
        if (self.body_owned) |owned| allocator.free(owned);
        self.body_owned = null;
    }

    pub fn withParams(self: Request, params: ParamMap) Request {
        var copy = self;
        copy.params = params;
        return copy;
    }

    pub fn headerValue(self: Request, name: []const u8) ?[]const u8 {
        return self.headers.value(name);
    }

    pub fn headerContainsToken(self: Request, name: []const u8, token: []const u8) bool {
        return self.headers.containsToken(name, token);
    }

    pub fn keepAlive(self: Request) bool {
        if (self.headerContainsToken("connection", "close")) return false;
        if (self.version == .http10) return self.headerContainsToken("connection", "keep-alive");
        return true;
    }

    pub fn acceptsGzip(self: Request) bool {
        const value = self.headerValue("accept-encoding") orelse return false;
        var encodings = std.mem.splitScalar(u8, value, ',');
        while (encodings.next()) |raw_encoding| {
            const trimmed = std.mem.trim(u8, raw_encoding, " \t");
            const semicolon = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[0..semicolon], " \t"), "gzip")) return true;
        }
        return false;
    }

    pub fn param(self: Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn queryValueOwned(self: Request, allocator: Allocator, name: []const u8) !?[]u8 {
        return self.query.valueOwned(allocator, name);
    }

    pub fn cookieValueOwned(self: Request, allocator: Allocator, name: []const u8) !?[]u8 {
        const cookie_header = self.headerValue("cookie") orelse return null;
        return cookieHeaderValueOwned(allocator, cookie_header, name);
    }

    pub fn formValues(self: Request, allocator: Allocator) !FormData {
        return FormData.parse(allocator, self.body);
    }
};

fn parseWithAllocator(allocator: ?Allocator, raw: []const u8) !Request {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
    if (header_end > max_http_header) return error.RequestHeaderTooLarge;
    const headers = HeaderMap{ .raw = raw[0..header_end] };

    var lines = std.mem.splitSequence(u8, headers.raw, "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    const request_line_info = try parseRequestLine(request_line);
    try validateHeaderBlock(headers.raw);

    const body_start = header_end + 4;
    const plan = try readPlanFromHeaders(headers);
    var body_owned: ?[]u8 = null;
    errdefer if (body_owned) |owned| if (allocator) |alloc| alloc.free(owned);

    const body = switch (plan) {
        .none => raw[body_start..body_start],
        .content_length => |content_len| blk: {
            if (raw.len < body_start + content_len) return error.BadRequest;
            break :blk raw[body_start .. body_start + content_len];
        },
        .chunked => blk: {
            const alloc = allocator orelse return error.ChunkedBodyRequiresAllocator;
            const decoded = try decodeChunkedBodyOwned(alloc, raw[body_start..], max_http_request);
            body_owned = decoded;
            break :blk decoded;
        },
    };

    const query_start = std.mem.indexOfScalar(u8, request_line_info.target, '?') orelse request_line_info.target.len;
    return .{
        .method = Method.parse(request_line_info.method_text),
        .method_text = request_line_info.method_text,
        .target = request_line_info.target,
        .path = request_line_info.target[0..query_start],
        .version = request_line_info.version,
        .body = body,
        .body_owned = body_owned,
        .headers = headers,
        .query = .{ .target = request_line_info.target },
        .range = parseRangeHeader(headers),
    };
}

const RequestLine = struct {
    method_text: []const u8,
    target: []const u8,
    version: HttpVersion,
};

fn parseRequestLine(line: []const u8) !RequestLine {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method_text = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version_text = parts.next() orelse return error.BadRequest;
    if (parts.next() != null) return error.BadRequest;
    if (!isToken(method_text)) return error.BadRequest;
    if (target.len == 0) return error.BadRequest;
    for (target) |c| {
        if (isCtl(c) or c == ' ') return error.BadRequest;
    }
    return .{
        .method_text = method_text,
        .target = target,
        .version = try HttpVersion.parse(version_text),
    };
}

fn readPlanFromHeaders(headers: HeaderMap) !ReadPlan {
    const transfer_encoding = try headers.transferEncoding();
    const content_len = try headers.contentLengthMaybe();
    if (transfer_encoding == .chunked) {
        if (content_len != null) return error.BadRequest;
        return .{ .chunked = {} };
    }
    if (content_len) |len| return .{ .content_length = len };
    return .{ .none = {} };
}

pub fn readPlan(headers: []const u8) !ReadPlan {
    return readPlanFromHeaders(.{ .raw = headers });
}

pub fn parseContentLength(headers: []const u8) !usize {
    return (HeaderMap{ .raw = headers }).contentLength();
}

pub fn chunkedBodyFrameLength(body: []const u8, max_decoded_len: usize) !?ChunkedFrame {
    var encoded_i: usize = 0;
    var decoded_len: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, body, encoded_i, "\r\n") orelse return null;
        const size_line = body[encoded_i..line_end];
        const chunk_size = try parseChunkSizeLine(size_line);
        encoded_i = line_end + 2;

        if (chunk_size == 0) {
            while (true) {
                const trailer_end = std.mem.indexOfPos(u8, body, encoded_i, "\r\n") orelse return null;
                const trailer = body[encoded_i..trailer_end];
                encoded_i = trailer_end + 2;
                if (trailer.len == 0) return .{ .encoded_len = encoded_i, .decoded_len = decoded_len };
                try validateHeaderLine(trailer);
            }
        }

        if (decoded_len > max_decoded_len - chunk_size) return error.RequestTooLarge;
        decoded_len += chunk_size;
        if (body.len < encoded_i + chunk_size + 2) return null;
        if (!std.mem.eql(u8, body[encoded_i + chunk_size .. encoded_i + chunk_size + 2], "\r\n")) return error.BadRequest;
        encoded_i += chunk_size + 2;
    }
}

pub fn decodeChunkedBodyOwned(allocator: Allocator, encoded: []const u8, max_decoded_len: usize) ![]u8 {
    const frame = (try chunkedBodyFrameLength(encoded, max_decoded_len)) orelse return error.BadRequest;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, frame.decoded_len);

    var encoded_i: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, encoded, encoded_i, "\r\n").?;
        const chunk_size = try parseChunkSizeLine(encoded[encoded_i..line_end]);
        encoded_i = line_end + 2;
        if (chunk_size == 0) break;
        try out.appendSlice(allocator, encoded[encoded_i .. encoded_i + chunk_size]);
        encoded_i += chunk_size + 2;
    }
    return out.toOwnedSlice(allocator);
}

fn parseChunkSizeLine(line: []const u8) !usize {
    const semicolon = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const raw_size = std.mem.trim(u8, line[0..semicolon], " \t");
    if (raw_size.len == 0) return error.BadRequest;
    var size: usize = 0;
    for (raw_size) |c| {
        const nibble: usize = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.BadRequest,
        };
        if (size > (std.math.maxInt(usize) - nibble) / 16) return error.RequestTooLarge;
        size = size * 16 + nibble;
    }
    return size;
}

fn validateHeaderBlock(raw: []const u8) !void {
    var line_count: usize = 0;
    var it = HeaderLineIterator.init(raw);
    var first = true;
    while (it.next()) |line| {
        if (first) {
            first = false;
            if (isRequestLine(line)) continue;
        }
        try validateHeaderLine(line);
        line_count += 1;
        if (line_count > max_headers) return error.BadRequest;
    }
    _ = try (HeaderMap{ .raw = raw }).contentLengthMaybe();
    _ = try (HeaderMap{ .raw = raw }).transferEncoding();
}

pub fn validateHeaderLine(line: []const u8) !void {
    if (line.len == 0) return error.BadRequest;
    if (line[0] == ' ' or line[0] == '\t') return error.BadRequest;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    try validateHeaderName(name);
    try validateHeaderValue(value);
}

pub fn validateHeaderName(name: []const u8) !void {
    if (!isToken(name)) return error.BadHeaderName;
}

pub fn validateHeaderValue(value: []const u8) !void {
    for (value) |c| {
        if (c == '\t') continue;
        if (isCtl(c)) return error.BadHeaderValue;
    }
}

const HeaderLineIterator = struct {
    raw: []const u8,
    pos: usize = 0,

    fn init(raw: []const u8) HeaderLineIterator {
        return .{ .raw = raw };
    }

    fn next(self: *HeaderLineIterator) ?[]const u8 {
        if (self.pos > self.raw.len) return null;
        const start = self.pos;
        if (std.mem.indexOfPos(u8, self.raw, start, "\r\n")) |end| {
            self.pos = end + 2;
            return self.raw[start..end];
        }
        self.pos = self.raw.len + 1;
        return self.raw[start..];
    }
};

fn isRequestLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, " HTTP/1.") != null and std.mem.indexOfScalar(u8, line, ':') == null;
}

fn isToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        '!' => true,
        '#'...'\'',
        '*'...'+',
        '-'...'.',
        '0'...'9',
        'A'...'Z',
        '^'...'z',
        '|'...'~' => true,
        else => false,
    };
}

fn isCtl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

pub fn headerValueContainsToken(value: []const u8, wanted_token: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (std.ascii.eqlIgnoreCase(token, wanted_token)) return true;
    }
    return false;
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

pub fn cookieHeaderValueOwned(allocator: Allocator, cookie_header: []const u8, wanted_name: []const u8) !?[]u8 {
    var fields = std.mem.splitScalar(u8, cookie_header, ';');
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (trimmed.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (std.mem.eql(u8, name, wanted_name)) return try allocator.dupe(u8, value);
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

test "request parser rejects malformed headers and duplicate content length" {
    try std.testing.expectError(error.BadRequest, Request.parse(
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
    ));
    try std.testing.expectError(error.BadRequest, Request.parse(
        "GET / HTTP/1.1\r\n Bad: continuation\r\n\r\n",
    ));
    try std.testing.expectError(error.BadRequest, Request.parse(
        "GET / HTTP/1.1\r\nBad\r\n\r\n",
    ));
}

test "request parser decodes chunked bodies in owned mode" {
    const raw =
        "POST /upload HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n6;ignored=yes\r\n world\r\n0\r\n\r\n";
    var parsed = try Request.parseOwned(std.testing.allocator, raw);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Method.POST, parsed.method);
    try std.testing.expectEqualStrings("hello world", parsed.body);
}

test "request helper parses cookies and keep alive tokens" {
    const raw =
        "GET / HTTP/1.0\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Cookie: sid=abc123; theme=dark\r\n" ++
        "\r\n";
    const parsed = try Request.parse(raw);
    try std.testing.expect(parsed.keepAlive());
    const sid = try parsed.cookieValueOwned(std.testing.allocator, "sid");
    defer if (sid) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("abc123", sid.?);
}

test "form parser decodes url encoded values" {
    const data = try FormData.parse(std.testing.allocator, "title=Hello+World&path=src%2Fmain.zig");
    defer data.deinit();

    try std.testing.expectEqualStrings("Hello World", data.value("title").?);
    try std.testing.expectEqualStrings("src/main.zig", data.value("path").?);
}
