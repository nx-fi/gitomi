const std = @import("std");
const middleware = @import("middleware.zig");
const request = @import("request.zig");

pub fn Router(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Handler = *const fn (Context) anyerror!void;

        pub const Action = union(enum) {
            handler: Handler,
            static_asset: middleware.StaticAsset,
        };

        pub const Route = struct {
            method: request.Method,
            path: []const u8,
            action: Action,

            pub fn get(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .GET, .path = path, .action = .{ .handler = handler } };
            }

            pub fn post(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .POST, .path = path, .action = .{ .handler = handler } };
            }

            pub fn put(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .PUT, .path = path, .action = .{ .handler = handler } };
            }

            pub fn patch(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .PATCH, .path = path, .action = .{ .handler = handler } };
            }

            pub fn delete(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .DELETE, .path = path, .action = .{ .handler = handler } };
            }

            pub fn options(comptime path: []const u8, handler: Handler) Route {
                return .{ .method = .OPTIONS, .path = path, .action = .{ .handler = handler } };
            }

            pub fn static(comptime path: []const u8, comptime content_type: []const u8, comptime body: []const u8) Route {
                return .{
                    .method = .GET,
                    .path = path,
                    .action = .{ .static_asset = middleware.textAsset(path, content_type, body) },
                };
            }

            pub fn staticBinary(comptime path: []const u8, comptime content_type: []const u8, comptime body: []const u8) Route {
                return .{
                    .method = .GET,
                    .path = path,
                    .action = .{ .static_asset = middleware.binaryAsset(path, content_type, body) },
                };
            }
        };

        pub const Match = struct {
            route: Route,
            params: request.ParamMap,
        };

        pub const AllowedMethods = struct {
            items: [8]request.Method = undefined,
            len: usize = 0,

            pub fn contains(self: AllowedMethods, method: request.Method) bool {
                for (self.items[0..self.len]) |item| {
                    if (item == method) return true;
                }
                return false;
            }

            fn put(self: *AllowedMethods, method: request.Method) void {
                if (self.contains(method) or self.len >= self.items.len) return;
                self.items[self.len] = method;
                self.len += 1;
            }
        };

        routes: []const Route,

        pub fn init(routes: []const Route) Self {
            return .{ .routes = routes };
        }

        pub fn match(self: Self, method: request.Method, path: []const u8) !?Match {
            for (self.routes) |route| {
                if (route.method != method) continue;
                var params = request.ParamMap.empty();
                if (try matchPath(route.path, path, &params)) {
                    return .{ .route = route, .params = params };
                }
            }
            return null;
        }

        pub fn allowedMethods(self: Self, path: []const u8) !AllowedMethods {
            var allowed = AllowedMethods{};
            for (self.routes) |route| {
                var params = request.ParamMap.empty();
                if (try matchPath(route.path, path, &params)) allowed.put(route.method);
            }
            return allowed;
        }
    };
}

fn matchPath(pattern: []const u8, path: []const u8, params: *request.ParamMap) !bool {
    if (std.mem.eql(u8, pattern, "/")) return std.mem.eql(u8, path, "/");
    if (pattern.len == 0 or path.len == 0) return false;

    var pattern_i: usize = 0;
    var path_i: usize = 0;
    while (true) {
        if (pattern_i == pattern.len and path_i == path.len) return true;
        if (pattern_i == pattern.len or path_i == path.len) return false;
        if (pattern[pattern_i] != '/' or path[path_i] != '/') return false;

        pattern_i += 1;
        path_i += 1;

        const pattern_start = pattern_i;
        while (pattern_i < pattern.len and pattern[pattern_i] != '/') : (pattern_i += 1) {}
        const path_start = path_i;
        while (path_i < path.len and path[path_i] != '/') : (path_i += 1) {}

        const pattern_segment = pattern[pattern_start..pattern_i];
        const path_segment = path[path_start..path_i];
        if (pattern_segment.len == 0 or path_segment.len == 0) return false;

        if (pattern_segment[0] == ':') {
            if (pattern_segment.len == 1) return error.InvalidRoutePattern;
            try params.put(pattern_segment[1..], path_segment);
        } else if (pattern_segment[0] == '*') {
            if (pattern_segment.len == 1) return error.InvalidRoutePattern;
            if (pattern_i != pattern.len) return error.InvalidRoutePattern;
            try params.put(pattern_segment[1..], path[path_start..]);
            return true;
        } else if (!std.mem.eql(u8, pattern_segment, path_segment)) {
            return false;
        }
    }
}

const TestContext = struct {};
const TestRouter = Router(TestContext);

fn noop(_: TestContext) !void {}

test "router extracts path parameters" {
    const routes = [_]TestRouter.Route{
        TestRouter.Route.get("/issues/:ref/edit", noop),
        TestRouter.Route.post("/issues/:ref/:action", noop),
    };
    const router = TestRouter.init(&routes);

    const get_match = (try router.match(.GET, "/issues/abc123/edit")).?;
    try std.testing.expectEqualStrings("abc123", get_match.params.get("ref").?);

    const post_match = (try router.match(.POST, "/issues/abc123/comments")).?;
    try std.testing.expectEqualStrings("abc123", post_match.params.get("ref").?);
    try std.testing.expectEqualStrings("comments", post_match.params.get("action").?);
}

test "router rejects partial segment matches" {
    const routes = [_]TestRouter.Route{
        TestRouter.Route.get("/pulls/:ref", noop),
    };
    const router = TestRouter.init(&routes);

    try std.testing.expect((try router.match(.GET, "/pulls/abc123")) != null);
    try std.testing.expect((try router.match(.GET, "/pulls/abc123/conflicts")) == null);
}

test "router supports wildcard tails and allowed methods" {
    const routes = [_]TestRouter.Route{
        TestRouter.Route.get("/files/*path", noop),
        TestRouter.Route.post("/files/*path", noop),
    };
    const router = TestRouter.init(&routes);

    const route_match = (try router.match(.GET, "/files/src/main.zig")).?;
    try std.testing.expectEqualStrings("src/main.zig", route_match.params.get("path").?);

    const allowed = try router.allowedMethods("/files/src/main.zig");
    try std.testing.expect(allowed.contains(.GET));
    try std.testing.expect(allowed.contains(.POST));
    try std.testing.expect(!allowed.contains(.DELETE));
}
