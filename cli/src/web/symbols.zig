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
    type,
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
            .type => "Type",
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
    language_id: []const u8,
    extensions: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    lsp_commands: []const []const []const u8 = &.{},
    tree_sitter: ?TreeSitterLanguage = null,
};

const zls_cmd = [_][]const u8{"zls"};
const rust_analyzer_cmd = [_][]const u8{"rust-analyzer"};
const rustup_stable_rust_analyzer_cmd = [_][]const u8{ "rustup", "run", "stable", "rust-analyzer" };
const clangd_cmd = [_][]const u8{"clangd"};
const ccls_cmd = [_][]const u8{"ccls"};
const gopls_cmd = [_][]const u8{"gopls"};
const jdtls_cmd = [_][]const u8{"jdtls"};
const csharp_ls_cmd = [_][]const u8{"csharp-ls"};
const omnisharp_cmd = [_][]const u8{ "omnisharp", "--languageserver" };
const pylsp_cmd = [_][]const u8{"pylsp"};
const pyright_cmd = [_][]const u8{ "pyright-langserver", "--stdio" };
const basedpyright_cmd = [_][]const u8{ "basedpyright-langserver", "--stdio" };
const typescript_language_server_cmd = [_][]const u8{ "typescript-language-server", "--stdio" };
const vscode_css_language_server_cmd = [_][]const u8{ "vscode-css-language-server", "--stdio" };
const vscode_html_language_server_cmd = [_][]const u8{ "vscode-html-language-server", "--stdio" };
const vscode_json_language_server_cmd = [_][]const u8{ "vscode-json-language-server", "--stdio" };
const yaml_language_server_cmd = [_][]const u8{ "yaml-language-server", "--stdio" };
const bash_language_server_cmd = [_][]const u8{ "bash-language-server", "start" };
const lua_language_server_cmd = [_][]const u8{"lua-language-server"};
const ruby_lsp_cmd = [_][]const u8{"ruby-lsp"};
const solargraph_cmd = [_][]const u8{ "solargraph", "stdio" };
const intelephense_cmd = [_][]const u8{ "intelephense", "--stdio" };
const phpactor_cmd = [_][]const u8{ "phpactor", "language-server" };
const docker_langserver_cmd = [_][]const u8{ "docker-langserver", "--stdio" };
const docker_language_server_cmd = [_][]const u8{ "docker-language-server", "start", "--stdio" };
const nil_cmd = [_][]const u8{"nil"};
const nixd_cmd = [_][]const u8{"nixd"};
const terraform_ls_cmd = [_][]const u8{ "terraform-ls", "serve" };
const marksman_cmd = [_][]const u8{ "marksman", "server" };
const markdown_oxide_cmd = [_][]const u8{"markdown-oxide"};
const taplo_cmd = [_][]const u8{ "taplo", "lsp", "stdio" };
const sql_language_server_cmd = [_][]const u8{ "sql-language-server", "up", "--method", "stdio" };
const graphql_lsp_cmd = [_][]const u8{ "graphql-lsp", "server", "-m", "stream" };
const elixir_ls_cmd = [_][]const u8{"elixir-ls"};
const erlang_ls_cmd = [_][]const u8{"erlang_ls"};
const haskell_language_server_cmd = [_][]const u8{ "haskell-language-server-wrapper", "--lsp" };
const ocamllsp_cmd = [_][]const u8{"ocamllsp"};
const sourcekit_lsp_cmd = [_][]const u8{"sourcekit-lsp"};
const dart_language_server_cmd = [_][]const u8{ "dart", "language-server" };
const kotlin_language_server_cmd = [_][]const u8{"kotlin-language-server"};
const metals_cmd = [_][]const u8{"metals"};
const fsautocomplete_cmd = [_][]const u8{ "fsautocomplete", "--adaptive-lsp-server-enabled" };
const solidity_ls_cmd = [_][]const u8{ "solidity-ls", "--stdio" };
const solidity_language_server_cmd = [_][]const u8{ "solidity-language-server", "--stdio" };

const providers = [_]Provider{
    .{ .language_id = "zig", .extensions = &.{".zig"}, .lsp_commands = &.{&zls_cmd}, .tree_sitter = .zig },
    .{ .language_id = "rust", .extensions = &.{".rs"}, .lsp_commands = &.{ &rust_analyzer_cmd, &rustup_stable_rust_analyzer_cmd } },
    .{ .language_id = "c", .extensions = &.{ ".c", ".h" }, .lsp_commands = &.{ &clangd_cmd, &ccls_cmd } },
    .{ .language_id = "cpp", .extensions = &.{ ".cc", ".cpp", ".cxx", ".c++", ".hh", ".hpp", ".hxx", ".h++" }, .lsp_commands = &.{ &clangd_cmd, &ccls_cmd } },
    .{ .language_id = "objective-c", .extensions = &.{ ".m", ".mm" }, .lsp_commands = &.{&clangd_cmd} },
    .{ .language_id = "csharp", .extensions = &.{".cs"}, .lsp_commands = &.{ &csharp_ls_cmd, &omnisharp_cmd } },
    .{ .language_id = "go", .extensions = &.{".go"}, .lsp_commands = &.{&gopls_cmd} },
    .{ .language_id = "java", .extensions = &.{".java"}, .lsp_commands = &.{&jdtls_cmd} },
    .{ .language_id = "javascript", .extensions = &.{ ".js", ".mjs", ".cjs", ".jsx" }, .lsp_commands = &.{&typescript_language_server_cmd} },
    .{ .language_id = "typescript", .extensions = &.{ ".ts", ".mts", ".cts" }, .lsp_commands = &.{&typescript_language_server_cmd} },
    .{ .language_id = "typescriptreact", .extensions = &.{".tsx"}, .lsp_commands = &.{&typescript_language_server_cmd} },
    .{ .language_id = "python", .extensions = &.{ ".py", ".pyw" }, .lsp_commands = &.{ &basedpyright_cmd, &pyright_cmd, &pylsp_cmd } },
    .{ .language_id = "ruby", .extensions = &.{ ".rb", ".rake" }, .filenames = &.{ "Gemfile", "Rakefile" }, .lsp_commands = &.{ &ruby_lsp_cmd, &solargraph_cmd } },
    .{ .language_id = "lua", .extensions = &.{".lua"}, .lsp_commands = &.{&lua_language_server_cmd} },
    .{ .language_id = "shellscript", .extensions = &.{ ".sh", ".bash", ".zsh", ".ksh" }, .filenames = &.{ ".bashrc", ".bash_profile", ".zshrc" }, .lsp_commands = &.{&bash_language_server_cmd} },
    .{ .language_id = "nix", .extensions = &.{".nix"}, .lsp_commands = &.{ &nil_cmd, &nixd_cmd } },
    .{ .language_id = "solidity", .extensions = &.{".sol"}, .lsp_commands = &.{ &solidity_ls_cmd, &solidity_language_server_cmd } },
    .{ .language_id = "php", .extensions = &.{ ".php", ".phtml" }, .lsp_commands = &.{ &intelephense_cmd, &phpactor_cmd } },
    .{ .language_id = "html", .extensions = &.{ ".html", ".htm" }, .lsp_commands = &.{&vscode_html_language_server_cmd} },
    .{ .language_id = "css", .extensions = &.{".css"}, .lsp_commands = &.{&vscode_css_language_server_cmd} },
    .{ .language_id = "scss", .extensions = &.{".scss"}, .lsp_commands = &.{&vscode_css_language_server_cmd} },
    .{ .language_id = "less", .extensions = &.{".less"}, .lsp_commands = &.{&vscode_css_language_server_cmd} },
    .{ .language_id = "json", .extensions = &.{ ".json", ".jsonc" }, .lsp_commands = &.{&vscode_json_language_server_cmd} },
    .{ .language_id = "yaml", .extensions = &.{ ".yaml", ".yml" }, .lsp_commands = &.{&yaml_language_server_cmd} },
    .{ .language_id = "toml", .extensions = &.{".toml"}, .lsp_commands = &.{&taplo_cmd} },
    .{ .language_id = "dockerfile", .filenames = &.{ "Dockerfile", "Containerfile" }, .lsp_commands = &.{ &docker_language_server_cmd, &docker_langserver_cmd } },
    .{ .language_id = "terraform", .extensions = &.{ ".tf", ".tfvars" }, .lsp_commands = &.{&terraform_ls_cmd} },
    .{ .language_id = "markdown", .extensions = &.{ ".md", ".markdown" }, .lsp_commands = &.{ &marksman_cmd, &markdown_oxide_cmd } },
    .{ .language_id = "sql", .extensions = &.{".sql"}, .lsp_commands = &.{&sql_language_server_cmd} },
    .{ .language_id = "graphql", .extensions = &.{ ".graphql", ".gql" }, .lsp_commands = &.{&graphql_lsp_cmd} },
    .{ .language_id = "elixir", .extensions = &.{ ".ex", ".exs" }, .lsp_commands = &.{&elixir_ls_cmd} },
    .{ .language_id = "erlang", .extensions = &.{ ".erl", ".hrl" }, .lsp_commands = &.{&erlang_ls_cmd} },
    .{ .language_id = "haskell", .extensions = &.{ ".hs", ".lhs" }, .lsp_commands = &.{&haskell_language_server_cmd} },
    .{ .language_id = "ocaml", .extensions = &.{ ".ml", ".mli" }, .lsp_commands = &.{&ocamllsp_cmd} },
    .{ .language_id = "swift", .extensions = &.{".swift"}, .lsp_commands = &.{&sourcekit_lsp_cmd} },
    .{ .language_id = "dart", .extensions = &.{".dart"}, .lsp_commands = &.{&dart_language_server_cmd} },
    .{ .language_id = "kotlin", .extensions = &.{ ".kt", ".kts" }, .lsp_commands = &.{&kotlin_language_server_cmd} },
    .{ .language_id = "scala", .extensions = &.{ ".scala", ".sbt" }, .lsp_commands = &.{&metals_cmd} },
    .{ .language_id = "fsharp", .extensions = &.{ ".fs", ".fsi", ".fsx" }, .lsp_commands = &.{&fsautocomplete_cmd} },
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

pub fn extract(allocator: Allocator, repo_root: []const u8, path: []const u8, content: []const u8) ![]Symbol {
    if (try extractFromLsp(allocator, repo_root, path, content)) |items| return items;
    return extractTreeSitter(allocator, path, content);
}

pub fn hasProvider(path: []const u8) bool {
    const provider = providerForPath(path) orelse return false;
    return provider.lsp_commands.len != 0 or provider.tree_sitter != null;
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
    const tree_sitter = provider.tree_sitter orelse return null;
    return .{
        .language = tree_sitter.language(),
        .source = tree_sitter.query(),
    };
}

fn extractFromLsp(allocator: Allocator, repo_root: []const u8, path: []const u8, content: []const u8) !?[]Symbol {
    const provider = providerForPath(path) orelse return null;
    for (provider.lsp_commands) |command| {
        if (try extractFromLspCommand(allocator, command, repo_root, path, provider.language_id, content)) |items| {
            return items;
        }
    }
    return null;
}

fn extractFromLspCommand(
    allocator: Allocator,
    command: []const []const u8,
    repo_root: []const u8,
    path: []const u8,
    language_id: []const u8,
    content: []const u8,
) !?[]Symbol {
    const workspace_root = try lspWorkspaceRoot(allocator, repo_root, path);
    defer allocator.free(workspace_root);

    const input = try buildLspInput(allocator, workspace_root, repo_root, path, language_id, content);
    defer allocator.free(input);

    var result = runLspCommand(allocator, command, input, workspace_root) catch return null;
    defer result.deinit();

    if (try parseLspDocumentSymbols(allocator, result.stdout)) |items| return items;
    return null;
}

fn buildLspInput(
    allocator: Allocator,
    workspace_root: []const u8,
    repo_root: []const u8,
    path: []const u8,
    language_id: []const u8,
    content: []const u8,
) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(allocator);

    var root_uri: std.ArrayList(u8) = .empty;
    defer root_uri.deinit(allocator);
    try appendFileUri(&root_uri, allocator, workspace_root, "");

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
        \\,"rootPath":
    );
    try appendJsonString(&body, allocator, workspace_root);
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

    return input.toOwnedSlice(allocator);
}

fn lspWorkspaceRoot(allocator: Allocator, repo_root: []const u8, path: []const u8) ![]u8 {
    const full_path = try std.fs.path.join(allocator, &.{ repo_root, path });
    defer allocator.free(full_path);

    const start_dir = std.fs.path.dirname(full_path) orelse repo_root;
    var dir = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(dir);

    while (true) {
        if (try hasWorkspaceMarker(allocator, dir)) return dir;
        if (std.mem.eql(u8, dir, repo_root)) return dir;

        const parent = std.fs.path.dirname(dir) orelse return dir;
        if (parent.len < repo_root.len or !std.mem.startsWith(u8, parent, repo_root)) {
            allocator.free(dir);
            return allocator.dupe(u8, repo_root);
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = next;
    }
}

fn hasWorkspaceMarker(allocator: Allocator, dir: []const u8) !bool {
    const markers = [_][]const u8{
        "Cargo.toml",
        "package.json",
        "tsconfig.json",
        "deno.json",
        "deno.jsonc",
        "pyproject.toml",
        "setup.py",
        "go.mod",
        "pom.xml",
        "build.gradle",
        "build.gradle.kts",
        "compile_commands.json",
        "Gemfile",
        "composer.json",
        "flake.nix",
        "mix.exs",
        "stack.yaml",
        "cabal.project",
        "pubspec.yaml",
    };
    for (markers) |marker| {
        const marker_path = try std.fs.path.join(allocator, &.{ dir, marker });
        defer allocator.free(marker_path);
        std.fs.cwd().access(marker_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => continue,
        };
        return true;
    }
    return false;
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
        if (root.get("method") != null) continue;
        if (root.get("error") != null) return null;
        if (root.get("result") == null) continue;
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
        10, 11, 23, 26 => .type,
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
    try std.testing.expectEqual(SymbolKind.type, found[0].kind);
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
    try std.testing.expectEqual(SymbolKind.type, found[0].kind);
    try std.testing.expectEqual(@as(usize, 1), found[0].line_no);
    try std.testing.expectEqualStrings("run", found[1].name);
    try std.testing.expectEqual(SymbolKind.method, found[1].kind);
    try std.testing.expectEqual(@as(usize, 1), found[1].depth);
    try std.testing.expectEqualStrings("helper", found[2].name);
    try std.testing.expectEqual(SymbolKind.function, found[2].kind);
}

test "web symbols ignores server requests before document symbol responses" {
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(std.testing.allocator);
    try appendRpcMessage(
        &framed,
        std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/configuration","params":{"items":[]}}
    );
    try appendRpcMessage(
        &framed,
        std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"result":[{"name":"Config","kind":23,"range":{"start":{"line":4,"character":0},"end":{"line":9,"character":1}}}]}
    );

    const found = (try parseLspDocumentSymbols(std.testing.allocator, framed.items)).?;
    defer free(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Config", found[0].name);
    try std.testing.expectEqual(@as(usize, 5), found[0].line_no);
}
