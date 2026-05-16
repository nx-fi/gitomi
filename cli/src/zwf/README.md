# ZWF

ZWF is Gitomi's small Zig web support layer for the `gt web` local interface. It is intentionally scoped to Gitomi's loopback UI needs, not a general-purpose internet-facing web framework.

## Production Status

Use ZWF for local development and local Gitomi UI traffic only. Bind it to `127.0.0.1` or `localhost`.

Zig does not yet provide HTTP/2 server support, and ZWF is not a production HTTP stack. It does not provide TLS or HTTP/2, and it does not advertise HTTP keep-alive. Workers handle one request per accepted connection and responses send `Connection: close`.

The server has socket read/write timeouts and bounded request parsing, but it should still be kept behind the local-only `gt web` boundary.

## Modules

- `server.zig`: binding, accept loop, worker pool, socket timeouts, and bounded request reads.
- `request.zig`: request-line and header parsing, content-length and chunked body handling, cookies, forms, query parameters, ranges, and request helpers.
- `response.zig`: response writer, typed headers, redirects, cookies, `HEAD` handling, binary/text helpers, and chunked response streaming.
- `router.zig`: method routes, static routes, path parameters, and allowed-method discovery.
- `middleware.zig`: static asset serving with content-hash ETags, cache validators, and structured middleware chains.
- `session.zig`: cookie-backed session ID transport with generated-ID format validation. It does not sign or authorize IDs; the caller owns server-side lookup, rotation on authentication changes, authorization binding, and session data.
- `csrf.zig`: CSRF token generation, extraction, and constant-time verification helpers.
- `html.zig` and `layout.zig`: small HTML rendering helpers used by Gitomi's pages.

## Handler Shape

The web entry point should read one request, parse it, build a response, route it, and then let the server close the stream:

```zig
const std = @import("std");
const zwf = @import("../zwf.zig");

const App = struct {
    // Application state.
};

fn handleConnection(allocator: std.mem.Allocator, app: App, stream: std.net.Stream) !void {
    const raw = try zwf.server.readHttpRequest(allocator, stream);
    defer allocator.free(raw);

    var request = try zwf.Request.parseOwned(allocator, raw);
    defer request.deinit(allocator);

    const response = zwf.Response.initWithRequest(allocator, stream, request);
    _ = app;

    try response.html("<!doctype html><title>OK</title><p>OK</p>");
}
```

Prefer typed response headers over raw header strings:

```zig
const headers = [_]zwf.ResponseHeader{
    .{ .name = "Cache-Control", .value = "no-store" },
};
try response.sendWithHeaders(200, "OK", "text/plain", "done\n", &headers, .{ .charset = true });
```

## Current Protocol Behavior

- Request bodies may be absent, content-length delimited, or chunked.
- Header and body sizes are bounded by the constants in `request.zig`.
- Duplicate `Content-Length`, mixed `Transfer-Encoding: chunked` and `Content-Length`, malformed headers, invalid request targets, and oversized request bodies are rejected.
- Responses validate status text and header names/values before writing.
- Caller-provided response headers may not override framework-managed framing, content type, or hop-by-hop headers.
- Static assets use content-hash ETags and are sent uncompressed so validators identify the exact representation.
- ZWF does not currently provide response compression.
- CSRF form token extraction only parses `application/x-www-form-urlencoded` bodies.

## Maintenance Rules

- Do not advertise keep-alive, TLS, HTTP/2, compression, or production observability unless the implementation and tests enforce the behavior.
- Keep request length arithmetic checked with `std.math.add` or `max - current` comparisons before addition.
- Prefer `[]zwf.ResponseHeader` APIs. Use raw extra-header strings only for legacy call sites that already validate values.
- When adding parser behavior, include malformed, duplicate, oversized, and overflow-shaped tests.
- Keep static asset validators tied to content and representation, not only to byte length.

## Targeted Tests

For quick checks while working on ZWF without rebuilding all of Gitomi:

```sh
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/request.zig
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/response.zig
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/middleware.zig
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/csrf.zig
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/session.zig
env ZIG_GLOBAL_CACHE_DIR=/tmp/gitomi-zig-cache zig test src/zwf/server.zig
```
