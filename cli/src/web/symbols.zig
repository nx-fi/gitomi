const std = @import("std");
const json_writer = @import("../json_writer.zig");

const Allocator = std.mem.Allocator;
const appendJsonString = json_writer.appendJsonString;

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() callconv(.c) *const c.TSLanguage;

const max_symbols = 300;
const max_lsp_output = 4 * 1024 * 1024;

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
    @"type",
    test_case,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .symbol => "Symbol",
            .module => "Module",
            .class => "Class",
            .function => "Function",
            .method => "Method",
            .property => "Property",
            .field => "Field",
            .variable => "Variable",
            .constant => "Constant",
            .@"type" => "Type",
            .test_case => "Test",
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

const LspLanguage = enum {
    zig,
    rust,
    python,
    javascript,
    typescript,
    bash,
    css,
    html,
    json,
    yaml,
    solidity,

    fn id(self: LspLanguage) []const u8 {
        return switch (self) {
            .zig => "zig",
            .rust => "rust",
            .python => "python",
            .javascript => "javascript",
            .typescript => "typescript",
            .bash => "shellscript",
            .css => "css",
            .html => "html",
            .json => "json",
            .yaml => "yaml",
            .solidity => "solidity",
        };
    }
};

const zls_cmd = [_][]const u8{"zls"};
const rust_analyzer_cmd = [_][]const u8{"rust-analyzer"};
const pylsp_cmd = [_][]const u8{"pylsp"};
const pyright_cmd = [_][]const u8{ "pyright-langserver", "--stdio" };
const basedpyright_cmd = [_][]const u8{ "basedpyright-langserver", "--stdio" };
const typescript_language_server_cmd = [_][]const u8{ "typescript-language-server", "--stdio" };
const bash_language_server_cmd = [_][]const u8{ "bash-language-server", "start" };
const css_language_server_cmd = [_][]const u8{ "vscode-css-language-server", "--stdio" };
const html_language_server_cmd = [_][]const u8{ "vscode-html-language-server", "--stdio" };
const json_language_server_cmd = [_][]const u8{ "vscode-json-language-server", "--stdio" };
const yaml_language_server_cmd = [_][]const u8{ "yaml-language-server", "--stdio" };
const solidity_ls_cmd = [_][]const u8{ "solidity-ls", "--stdio" };
const solidity_language_server_cmd = [_][]const u8{ "solidity-language-server", "--stdio" };

const zig_lsp_commands = [_][]const []const u8{&zls_cmd};
const rust_lsp_commands = [_][]const []const u8{&rust_analyzer_cmd};
const python_lsp_commands = [_][]const []const u8{ &basedpyright_cmd, &pyright_cmd, &pylsp_cmd };
const javascript_lsp_commands = [_][]const []const u8{&typescript_language_server_cmd};
const typescript_lsp_commands = [_][]const []const u8{&typescript_language_server_cmd};
const bash_lsp_commands = [_][]const []const u8{&bash_language_server_cmd};
const css_lsp_commands = [_][]const []const u8{&css_language_server_cmd};
const html_lsp_commands = [_][]const []const u8{&html_language_server_cmd};
const json_lsp_commands = [_][]const []const u8{&json_language_server_cmd};
const yaml_lsp_commands = [_][]const []const u8{&yaml_language_server_cmd};
const solidity_lsp_commands = [_][]const []const u8{ &solidity_ls_cmd, &solidity_language_server_cmd };

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

pub fn extract(allocator: Allocator, repo_root: []const u8, path: []const u8, content: []const u8) ![]Symbol {
    if (try extractFromLsp(allocator, repo_root, path, content)) |items| return items;
    return extractTreeSitter(allocator, path, content);
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
    if (std.mem.endsWith(u8, path, ".zig")) {
        return .{
            .language = tree_sitter_zig(),
            .source = zig_query,
        };
    }
    return null;
}

fn extractFromLsp(allocator: Allocator, repo_root: []const u8, path: []const u8, content: []const u8) !?[]Symbol {
    const language = lspLanguageForPath(path) orelse return null;
    const commands = lspCommands(language);
    for (commands) |command| {
        if (try extractFromLspCommand(allocator, command, repo_root, path, language, content)) |items| {
            return items;
        }
    }
    return null;
}

fn lspLanguageForPath(path: []const u8) ?LspLanguage {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash") or std.mem.endsWith(u8, path, "Makefile")) return .bash;
    if (std.mem.endsWith(u8, path, ".css")) return .css;
    if (std.mem.endsWith(u8, path, ".html")) return .html;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".sol")) return .solidity;
    return null;
}

fn lspCommands(language: LspLanguage) []const []const []const u8 {
    return switch (language) {
        .zig => &zig_lsp_commands,
        .rust => &rust_lsp_commands,
        .python => &python_lsp_commands,
        .javascript => &javascript_lsp_commands,
        .typescript => &typescript_lsp_commands,
        .bash => &bash_lsp_commands,
        .css => &css_lsp_commands,
        .html => &html_lsp_commands,
        .json => &json_lsp_commands,
        .yaml => &yaml_lsp_commands,
        .solidity => &solidity_lsp_commands,
    };
}

fn extractFromLspCommand(
    allocator: Allocator,
    command: []const []const u8,
    repo_root: []const u8,
    path: []const u8,
    language: LspLanguage,
    content: []const u8,
) !?[]Symbol {
    const input = try buildLspInput(allocator, repo_root, path, language.id(), content);
    defer allocator.free(input);

    var result = runLspCommand(allocator, command, input, repo_root) catch return null;
    defer result.deinit();

    if (try parseLspDocumentSymbols(allocator, result.stdout)) |items| return items;
    return null;
}

fn buildLspInput(
    allocator: Allocator,
    repo_root: []const u8,
    path: []const u8,
    language_id: []const u8,
    content: []const u8,
) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);

    var root_uri: std.ArrayList(u8) = .empty;
    defer root_uri.deinit(allocator);
    try appendFileUri(&root_uri, allocator, repo_root, "");

    var file_uri: std.ArrayList(u8) = .empty;
    defer file_uri.deinit(allocator);
    try appendFileUri(&file_uri, allocator, repo_root, path);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":
    );
    try appendJsonString(&body, allocator, root_uri.items);
    try body.appendSlice(allocator,
        \\,"workspaceFolders":[{"uri":
    );
    try appendJsonString(&body, allocator, root_uri.items);
    try body.appendSlice(allocator,
        \\,"name":"workspace"}],"capabilities":{"textDocument":{"documentSymbol":{"dynamicRegistration":false,"hierarchicalDocumentSymbolSupport":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]}}}}}}
    );
    try appendRpcMessage(&input, allocator, body.items);
    body.clearRetainingCapacity();

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try appendRpcMessage(&input, allocator, body.items);
    body.clearRetainingCapacity();

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":
    );
    try appendJsonString(&body, allocator, file_uri.items);
    try body.appendSlice(allocator,
        \\,"languageId":
    );
    try appendJsonString(&body, allocator, language_id);
    try body.appendSlice(allocator,
        \\,"version":1,"text":
    );
    try appendJsonString(&body, allocator, content);
    try body.appendSlice(allocator, "}}}");
    try appendRpcMessage(&input, allocator, body.items);
    body.clearRetainingCapacity();

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":
    );
    try appendJsonString(&body, allocator, file_uri.items);
    try body.appendSlice(allocator, "}}}");
    try appendRpcMessage(&input, allocator, body.items);
    body.clearRetainingCapacity();

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
    );
    try appendRpcMessage(&input, allocator, body.items);
    body.clearRetainingCapacity();

    try body.appendSlice(allocator,
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try appendRpcMessage(&input, allocator, body.items);

    return input.toOwnedSlice(allocator);
}

fn appendRpcMessage(buf: *std.ArrayList(u8), allocator: Allocator, body: []const u8) !void {
    try std.fmt.format(buf.writer(allocator), "Content-Length: {d}\r\n\r\n", .{body.len});
    try buf.appendSlice(allocator, body);
}

fn appendFileUri(buf: *std.ArrayList(u8), allocator: Allocator, root: []const u8, path: []const u8) !void {
    try buf.appendSlice(allocator, "file://");
    try appendUriPath(buf, allocator, root);
    if (path.len != 0) {
        if (root.len == 0 or root[root.len - 1] != '/') try buf.append(allocator, '/');
        try appendUriPath(buf, allocator, path);
    }
}

fn appendUriPath(buf: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    for (value) |byte| {
        if (isUriPathChar(byte)) {
            try buf.append(allocator, byte);
        } else {
            try std.fmt.format(buf.writer(allocator), "%{X:0>2}", .{byte});
        }
    }
}

fn isUriPathChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        byte == '/' or
        byte == '-' or
        byte == '_' or
        byte == '.' or
        byte == '~';
}

const ProcessOutput = struct {
    allocator: Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *ProcessOutput) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

fn runLspCommand(
    allocator: Allocator,
    argv: []const []const u8,
    input: []const u8,
    cwd: []const u8,
) !ProcessOutput {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    try child.spawn();
    errdefer _ = child.kill() catch {};

    try child.stdin.?.writeAll(input);
    child.stdin.?.close();
    child.stdin = null;

    try child.collectOutput(allocator, &stdout, &stderr, max_lsp_output);
    const term = try child.wait();

    return .{
        .allocator = allocator,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = term,
    };
}

fn parseLspDocumentSymbols(allocator: Allocator, bytes: []const u8) !?[]Symbol {
    var cursor: usize = 0;
    while (nextLspBody(bytes, &cursor)) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch continue;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse continue;
        const id = jsonInteger(root.get("id")) orelse continue;
        if (id != 2) continue;
        return try parseLspSymbolResult(allocator, root.get("result"));
    }
    return null;
}

fn nextLspBody(bytes: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < bytes.len) {
        const header_end_offset = std.mem.indexOf(u8, bytes[cursor.*..], "\r\n\r\n") orelse return null;
        const header_start = cursor.*;
        const header_end = cursor.* + header_end_offset;
        const body_start = header_end + 4;
        const content_length = lspContentLength(bytes[header_start..header_end]) orelse {
            cursor.* = body_start;
            continue;
        };
        const body_end = body_start + content_length;
        if (body_end > bytes.len) return null;
        cursor.* = body_end;
        return bytes[body_start..body_end];
    }
    return null;
}

fn lspContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseUnsigned(usize, value, 10) catch null;
    }
    return null;
}

fn parseLspSymbolResult(allocator: Allocator, value: ?std.json.Value) ![]Symbol {
    var items: std.ArrayList(Symbol) = .empty;
    errdefer free(allocator, items.items);

    const result = value orelse return items.toOwnedSlice(allocator);
    const array = jsonArray(result) orelse return items.toOwnedSlice(allocator);
    for (array.items) |item| {
        try appendLspSymbolValue(&items, allocator, item, 0);
        if (items.items.len >= max_symbols) break;
    }

    std.mem.sort(Symbol, items.items, {}, symbolLessThan);
    return items.toOwnedSlice(allocator);
}

fn appendLspSymbolValue(items: *std.ArrayList(Symbol), allocator: Allocator, value: std.json.Value, depth: usize) !void {
    if (items.items.len >= max_symbols) return;
    const object = jsonObject(value) orelse return;
    const name = jsonString(object.get("name")) orelse return;
    const kind_raw = jsonInteger(object.get("kind")) orelse 0;
    const line_no = lspSymbolLine(object) orelse return;
    try appendOwnedSymbol(items, allocator, name, lspSymbolKind(kind_raw), line_no + 1, depth);

    if (jsonArray(object.get("children"))) |children| {
        for (children.items) |child| {
            try appendLspSymbolValue(items, allocator, child, depth + 1);
            if (items.items.len >= max_symbols) break;
        }
    }
}

fn lspSymbolLine(object: std.json.ObjectMap) ?usize {
    if (jsonObject(object.get("range"))) |range| {
        return lspRangeStartLine(range);
    }
    const location = jsonObject(object.get("location")) orelse return null;
    const range = jsonObject(location.get("range")) orelse return null;
    return lspRangeStartLine(range);
}

fn lspRangeStartLine(range: std.json.ObjectMap) ?usize {
    const start = jsonObject(range.get("start")) orelse return null;
    const line = jsonInteger(start.get("line")) orelse return null;
    if (line < 0) return null;
    return @intCast(line);
}

fn lspSymbolKind(kind: i64) SymbolKind {
    return switch (kind) {
        2, 3, 4 => .module,
        5 => .class,
        6, 9 => .method,
        7 => .property,
        8, 22 => .field,
        10, 11, 23, 26 => .@"type",
        12 => .function,
        13 => .variable,
        14 => .constant,
        else => .symbol,
    };
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

fn symbolLessThan(_: void, a: Symbol, b: Symbol) bool {
    if (a.line_no != b.line_no) return a.line_no < b.line_no;
    return a.depth < b.depth;
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
            if (std.mem.eql(u8, capture_name, "symbol.name")) {
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
    if (std.mem.eql(u8, name, "symbol.type")) return .@"type";
    if (std.mem.eql(u8, name, "symbol.test")) return .test_case;
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

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    if (value) |v| {
        return switch (v) {
            .object => |object| object,
            else => null,
        };
    }
    return null;
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    if (value) |v| {
        return switch (v) {
            .array => |array| array,
            else => null,
        };
    }
    return null;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        return switch (v) {
            .string => |string| string,
            else => null,
        };
    }
    return null;
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        return switch (v) {
            .integer => |integer| integer,
            else => null,
        };
    }
    return null;
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
    try std.testing.expectEqual(SymbolKind.@"type", found[0].kind);
    try std.testing.expectEqualStrings("run", found[1].name);
    try std.testing.expectEqual(SymbolKind.method, found[1].kind);
    try std.testing.expectEqualStrings("helper", found[2].name);
    try std.testing.expectEqual(SymbolKind.function, found[2].kind);
    try std.testing.expectEqualStrings("helper works", found[3].name);
    try std.testing.expectEqual(SymbolKind.test_case, found[3].kind);
}

test "web symbols parses LSP document symbol responses" {
    const body =
        \\{"jsonrpc":"2.0","id":2,"result":[{"name":"App","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":1}},"children":[{"name":"run","kind":6,"range":{"start":{"line":1,"character":4},"end":{"line":3,"character":5}}}]},{"name":"helper","kind":12,"location":{"uri":"file:///repo/src/main.zig","range":{"start":{"line":6,"character":0},"end":{"line":6,"character":19}}}}]}
    ;
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(std.testing.allocator);
    try appendRpcMessage(&framed, std.testing.allocator, body);

    const found = (try parseLspDocumentSymbols(std.testing.allocator, framed.items)).?;
    defer free(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("App", found[0].name);
    try std.testing.expectEqual(SymbolKind.@"type", found[0].kind);
    try std.testing.expectEqual(@as(usize, 1), found[0].line_no);
    try std.testing.expectEqualStrings("run", found[1].name);
    try std.testing.expectEqual(SymbolKind.method, found[1].kind);
    try std.testing.expectEqual(@as(usize, 1), found[1].depth);
    try std.testing.expectEqualStrings("helper", found[2].name);
    try std.testing.expectEqual(SymbolKind.function, found[2].kind);
}
