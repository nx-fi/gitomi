const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() callconv(.c) *const c.TSLanguage;

const max_symbols = 300;

pub const SymbolKind = enum {
    symbol,
    module,
    class,
    function,
    method,
    property,
    field,
    variable,
    constant,
    type,
    test_case,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .symbol => "sym",
            .module => "mod",
            .class => "class",
            .function => "func",
            .method => "meth",
            .property => "prop",
            .field => "field",
            .variable => "var",
            .constant => "const",
            .type => "type",
            .test_case => "test",
        };
    }
};

pub const Symbol = struct {
    name: []u8,
    kind: SymbolKind,
    line_no: usize,
    depth: usize,

    pub fn deinit(self: Symbol, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const QuerySpec = struct {
    language: *const c.TSLanguage,
    source: []const u8,
};

const TreeSitterLanguage = enum {
    zig,

    fn language(self: TreeSitterLanguage) *const c.TSLanguage {
        return switch (self) {
            .zig => tree_sitter_zig(),
        };
    }

    fn query(self: TreeSitterLanguage) []const u8 {
        return switch (self) {
            .zig => zig_query,
        };
    }
};

const Provider = struct {
    extensions: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    tree_sitter: TreeSitterLanguage,
};

const providers = [_]Provider{
    .{ .extensions = &.{".zig"}, .tree_sitter = .zig },
};

fn providerForPath(path: []const u8) ?*const Provider {
    const name = basename(path);
    for (&providers) |*provider| {
        for (provider.filenames) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return provider;
        }
        for (provider.extensions) |extension| {
            if (endsWithIgnoreCase(path, extension)) return provider;
        }
    }
    return null;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn basename(path: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[index + 1 ..];
}

const zig_query =
    \\(function_declaration
    \\  name: (identifier) @symbol.name) @symbol.function
    \\
    \\(variable_declaration
    \\  (identifier) @symbol.name
    \\  (struct_declaration)) @symbol.type
    \\
    \\(variable_declaration
    \\  (identifier) @symbol.name
    \\  (enum_declaration)) @symbol.type
    \\
    \\(variable_declaration
    \\  (identifier) @symbol.name
    \\  (union_declaration)) @symbol.type
    \\
    \\(variable_declaration
    \\  (identifier) @symbol.name
    \\  (opaque_declaration)) @symbol.type
    \\
    \\(variable_declaration
    \\  (identifier) @symbol.name
    \\  (error_set_declaration)) @symbol.type
    \\
    \\(test_declaration
    \\  [(identifier) (string)] @symbol.name) @symbol.test
;

pub fn extract(allocator: Allocator, path: []const u8, content: []const u8) ![]Symbol {
    return extractTreeSitter(allocator, path, content);
}

pub fn hasProvider(path: []const u8) bool {
    return providerForPath(path) != null;
}

fn extractTreeSitter(allocator: Allocator, path: []const u8, content: []const u8) ![]Symbol {
    const spec = querySpecForPath(path) orelse return allocator.alloc(Symbol, 0);
    return extractWithQuery(allocator, spec, content);
}

pub fn free(allocator: Allocator, items: []Symbol) void {
    for (items) |item| item.deinit(allocator);
    allocator.free(items);
}

fn querySpecForPath(path: []const u8) ?QuerySpec {
    const provider = providerForPath(path) orelse return null;
    return .{
        .language = provider.tree_sitter.language(),
        .source = provider.tree_sitter.query(),
    };
}

fn extractWithQuery(allocator: Allocator, spec: QuerySpec, content: []const u8) ![]Symbol {
    var items: std.ArrayList(Symbol) = .empty;
    errdefer free(allocator, items.items);

    var error_offset: u32 = 0;
    var error_type: c.TSQueryError = undefined;
    const query = c.ts_query_new(spec.language, spec.source.ptr, @intCast(spec.source.len), &error_offset, &error_type) orelse {
        return items.toOwnedSlice(allocator);
    };
    defer c.ts_query_delete(query);

    const parser = c.ts_parser_new() orelse return error.TreeSitterParserUnavailable;
    defer c.ts_parser_delete(parser);

    if (!c.ts_parser_set_language(parser, spec.language)) return error.TreeSitterLanguageUnavailable;

    const tree = c.ts_parser_parse_string(parser, null, content.ptr, @intCast(content.len)) orelse {
        return items.toOwnedSlice(allocator);
    };
    defer c.ts_tree_delete(tree);

    const root = c.ts_tree_root_node(tree);
    const cursor = c.ts_query_cursor_new() orelse return error.TreeSitterQueryCursorUnavailable;
    defer c.ts_query_cursor_delete(cursor);

    c.ts_query_cursor_exec(cursor, query, root);

    var match: c.TSQueryMatch = undefined;
    while (items.items.len < max_symbols and c.ts_query_cursor_next_match(cursor, &match)) {
        var name_node: ?c.TSNode = null;
        var symbol_node: ?c.TSNode = null;
        var kind: ?SymbolKind = null;

        var index: usize = 0;
        while (index < match.capture_count) : (index += 1) {
            const capture = match.captures[index];
            const capture_name = captureName(query, capture.index);
            if (std.mem.eql(u8, capture_name, "symbol.name") or std.mem.eql(u8, capture_name, "name")) {
                name_node = capture.node;
            } else if (kindForCapture(capture_name)) |captured_kind| {
                kind = captured_kind;
                symbol_node = capture.node;
            }
        }

        const name = name_node orelse continue;
        const node = symbol_node orelse name;
        const point = c.ts_node_start_point(node);
        const depth = @as(usize, point.column) / 4;
        const symbol_kind = if (kind == .function and depth > 0) SymbolKind.method else kind orelse continue;

        try appendSymbol(&items, allocator, content, name, symbol_kind, @as(usize, point.row) + 1, depth);
    }

    return items.toOwnedSlice(allocator);
}

fn captureName(query: *const c.TSQuery, index: u32) []const u8 {
    var len: u32 = 0;
    const ptr = c.ts_query_capture_name_for_id(query, index, &len);
    if (ptr == null) return "";
    return ptr[0..len];
}

fn kindForCapture(name: []const u8) ?SymbolKind {
    if (std.mem.eql(u8, name, "symbol.function")) return .function;
    if (std.mem.eql(u8, name, "symbol.method")) return .method;
    if (std.mem.eql(u8, name, "symbol.module")) return .module;
    if (std.mem.eql(u8, name, "symbol.type")) return .type;
    if (std.mem.eql(u8, name, "symbol.constant")) return .constant;
    if (std.mem.eql(u8, name, "symbol.test")) return .test_case;
    if (std.mem.startsWith(u8, name, "definition.function")) return .function;
    if (std.mem.startsWith(u8, name, "definition.method")) return .method;
    if (std.mem.startsWith(u8, name, "definition.module")) return .module;
    if (std.mem.startsWith(u8, name, "definition.constant")) return .constant;
    if (std.mem.startsWith(u8, name, "definition.field")) return .field;
    if (std.mem.startsWith(u8, name, "definition.property")) return .property;
    if (std.mem.startsWith(u8, name, "definition.var")) return .variable;
    if (std.mem.startsWith(u8, name, "definition.class")) return .type;
    if (std.mem.startsWith(u8, name, "definition.interface")) return .type;
    if (std.mem.startsWith(u8, name, "definition.type")) return .type;
    if (std.mem.startsWith(u8, name, "definition.macro")) return .function;
    return null;
}

fn appendSymbol(
    items: *std.ArrayList(Symbol),
    allocator: Allocator,
    content: []const u8,
    name_node: c.TSNode,
    kind: SymbolKind,
    line_no: usize,
    depth: usize,
) !void {
    const raw_name = nodeText(content, name_node);
    const name = cleanSymbolName(raw_name);
    try appendOwnedSymbol(items, allocator, name, kind, line_no, depth);
}

fn nodeText(content: []const u8, node: c.TSNode) []const u8 {
    const start: usize = @intCast(c.ts_node_start_byte(node));
    const end: usize = @intCast(c.ts_node_end_byte(node));
    if (start > end or end > content.len) return "";
    return content[start..end];
}

fn cleanSymbolName(raw: []const u8) []const u8 {
    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') {
        return name[1 .. name.len - 1];
    }
    return name;
}

fn appendOwnedSymbol(
    items: *std.ArrayList(Symbol),
    allocator: Allocator,
    raw_name: []const u8,
    kind: SymbolKind,
    line_no: usize,
    depth: usize,
) !void {
    if (items.items.len >= max_symbols) return;
    const name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (name.len == 0) return;
    try items.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .line_no = line_no,
        .depth = @min(depth, 5),
    });
}

test "web symbols only advertises safe in-process providers" {
    try std.testing.expect(hasProvider("src/main.zig"));
    try std.testing.expect(hasProvider("SRC/MAIN.ZIG"));
    try std.testing.expect(!hasProvider("src/main.rs"));
    try std.testing.expect(!hasProvider("package.json"));
}

test "web symbols extracts zig declarations with tree-sitter" {
    const source =
        \\pub const App = struct {
        \\    pub fn run(self: *App) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\fn helper() void {}
        \\
        \\test "helper works" {}
        \\
    ;
    const found = try extractTreeSitter(std.testing.allocator, "src/main.zig", source);
    defer free(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings("App", found[0].name);
    try std.testing.expectEqual(SymbolKind.type, found[0].kind);
    try std.testing.expectEqualStrings("run", found[1].name);
    try std.testing.expectEqual(SymbolKind.method, found[1].kind);
    try std.testing.expectEqualStrings("helper", found[2].name);
    try std.testing.expectEqual(SymbolKind.function, found[2].kind);
    try std.testing.expectEqualStrings("helper works", found[3].name);
    try std.testing.expectEqual(SymbolKind.test_case, found[3].kind);
}
