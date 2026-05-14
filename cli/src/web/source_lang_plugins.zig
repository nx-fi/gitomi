const std = @import("std");

pub const CountOptions = struct {
    show_comments: bool = true,
    show_blanks: bool = false,
    count_symbol_only: bool = false,
};

pub const LineCount = struct {
    test_count: u64,
    comment_count: u64,
    blank_count: u64,
    code_count: u64,
};

pub const LineKind = enum {
    skipped,
    code,
    test_line,
    comment,
    blank,
};

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
};

pub const InlineTestMode = enum {
    none,
    rust_cfg_mod,
    zig_test_block,
};

const empty_strings = [_][]const u8{};
const empty_blocks = [_]BlockComment{};

pub const Plugin = struct {
    name: []const u8,
    line_comment_prefixes: []const []const u8 = &empty_strings,
    block_comments: []const BlockComment = &empty_blocks,
    test_filename_prefixes: []const []const u8 = &empty_strings,
    test_filename_suffixes: []const []const u8 = &empty_strings,
    dotted_test_markers: []const []const u8 = &empty_strings,
    exact_test_basenames: []const []const u8 = &empty_strings,
    inline_test_mode: InlineTestMode = .none,
};

const generic_line_comment_prefixes = [_][]const u8{ "//", "--", "#", "'" };
const default_test_path_dirs = [_][]const u8{
    "test", "tests",   "spec",       "specs",   "__tests__",
    "e2e",  "cypress", "playwright", "testing", "fixtures",
};
const default_test_prefixes = [_][]const u8{ "test_", "tests_" };
const default_test_suffixes = [_][]const u8{ "_test", "_tests", "_spec" };
const default_dotted_test_markers = [_][]const u8{ "test", "spec" };
const default_exact_test_basenames = [_][]const u8{"conftest.py"};
const jvm_test_suffixes = [_][]const u8{ "Test", "Tests", "IT", "ITCase" };
const zig_exact_test_basenames = [_][]const u8{ "test.zig", "tests.zig" };

const c_block_comments = [_]BlockComment{
    .{ .start = "/*", .end = "*/" },
};
const markup_block_comments = [_]BlockComment{
    .{ .start = "<!--", .end = "-->" },
};
const haskell_block_comments = [_]BlockComment{
    .{ .start = "{-", .end = "-}" },
};
const lua_block_comments = [_]BlockComment{
    .{ .start = "--[[", .end = "]]" },
};
const ml_block_comments = [_]BlockComment{
    .{ .start = "(*", .end = "*)" },
};
const racket_block_comments = [_]BlockComment{
    .{ .start = "#|", .end = "|#" },
};
const julia_block_comments = [_]BlockComment{
    .{ .start = "#=", .end = "=#" },
};
const lilypond_block_comments = [_]BlockComment{
    .{ .start = "%{", .end = "%}" },
};
const ruby_block_comments = [_]BlockComment{
    .{ .start = "=begin", .end = "=end" },
};
const handlebars_block_comments = [_]BlockComment{
    .{ .start = "{{!--", .end = "--}}" },
    .{ .start = "<!--", .end = "-->" },
};
const svelte_block_comments = [_]BlockComment{
    .{ .start = "<!--", .end = "-->" },
    .{ .start = "/*", .end = "*/" },
};

const slash_prefixes = [_][]const u8{"//"};
const slash_hash_prefixes = [_][]const u8{ "//", "#" };
const hash_prefixes = [_][]const u8{"#"};
const dash_prefixes = [_][]const u8{"--"};
const apostrophe_prefixes = [_][]const u8{"'"};
const semicolon_prefixes = [_][]const u8{";"};
const percent_prefixes = [_][]const u8{"%"};
const bang_prefixes = [_][]const u8{"!"};
const slash_dash_prefixes = [_][]const u8{ "//-", "//" };
const handlebars_prefixes = [_][]const u8{"{{!"};

const c_family_plugin = Plugin{
    .name = "c-family",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &c_block_comments,
};

const go_like_plugin = Plugin{
    .name = "go-like",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &c_block_comments,
};

const css_plugin = Plugin{
    .name = "css",
    .block_comments = &c_block_comments,
};

const html_plugin = Plugin{
    .name = "html",
    .block_comments = &markup_block_comments,
};

const svelte_plugin = Plugin{
    .name = "svelte",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &svelte_block_comments,
};

const jvm_plugin = Plugin{
    .name = "jvm",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &c_block_comments,
    .test_filename_suffixes = &jvm_test_suffixes,
};

const rust_plugin = Plugin{
    .name = "rust",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &c_block_comments,
    .inline_test_mode = .rust_cfg_mod,
};

const zig_plugin = Plugin{
    .name = "zig",
    .line_comment_prefixes = &slash_prefixes,
    .exact_test_basenames = &zig_exact_test_basenames,
    .inline_test_mode = .zig_test_block,
};

const terraform_plugin = Plugin{
    .name = "terraform",
    .line_comment_prefixes = &slash_hash_prefixes,
    .block_comments = &c_block_comments,
};

const nix_plugin = Plugin{
    .name = "nix",
    .line_comment_prefixes = &hash_prefixes,
    .block_comments = &c_block_comments,
};

const lua_plugin = Plugin{
    .name = "lua",
    .line_comment_prefixes = &dash_prefixes,
    .block_comments = &lua_block_comments,
};

const sql_plugin = Plugin{
    .name = "sql",
    .line_comment_prefixes = &dash_prefixes,
    .block_comments = &c_block_comments,
};

const haskell_plugin = Plugin{
    .name = "haskell",
    .line_comment_prefixes = &dash_prefixes,
    .block_comments = &haskell_block_comments,
};

const julia_plugin = Plugin{
    .name = "julia",
    .line_comment_prefixes = &hash_prefixes,
    .block_comments = &julia_block_comments,
};

const ml_plugin = Plugin{
    .name = "ml",
    .line_comment_prefixes = &slash_prefixes,
    .block_comments = &ml_block_comments,
};

const clojure_plugin = Plugin{
    .name = "clojure",
    .line_comment_prefixes = &semicolon_prefixes,
};

const racket_plugin = Plugin{
    .name = "racket",
    .line_comment_prefixes = &semicolon_prefixes,
    .block_comments = &racket_block_comments,
};

const erlang_plugin = Plugin{
    .name = "erlang",
    .line_comment_prefixes = &percent_prefixes,
};

const percent_block_plugin = Plugin{
    .name = "percent-block",
    .line_comment_prefixes = &percent_prefixes,
    .block_comments = &lilypond_block_comments,
};

const percent_only_plugin = Plugin{
    .name = "percent-only",
    .line_comment_prefixes = &percent_prefixes,
};

const bang_plugin = Plugin{
    .name = "bang",
    .line_comment_prefixes = &bang_prefixes,
};

const basic_plugin = Plugin{
    .name = "basic",
    .line_comment_prefixes = &apostrophe_prefixes,
};

const php_plugin = Plugin{
    .name = "php",
    .line_comment_prefixes = &slash_hash_prefixes,
    .block_comments = &c_block_comments,
};

const pug_plugin = Plugin{
    .name = "pug",
    .line_comment_prefixes = &slash_dash_prefixes,
};

const handlebars_plugin = Plugin{
    .name = "handlebars",
    .line_comment_prefixes = &handlebars_prefixes,
    .block_comments = &handlebars_block_comments,
};

const ruby_plugin = Plugin{
    .name = "ruby",
    .line_comment_prefixes = &hash_prefixes,
    .block_comments = &ruby_block_comments,
};

const hash_only_plugin = Plugin{
    .name = "hash-only",
    .line_comment_prefixes = &hash_prefixes,
};

const apostrophe_only_plugin = Plugin{
    .name = "apostrophe-only",
    .line_comment_prefixes = &apostrophe_prefixes,
};

const dash_only_plugin = Plugin{
    .name = "dash-only",
    .line_comment_prefixes = &dash_prefixes,
};

const semicolon_only_plugin = Plugin{
    .name = "semicolon-only",
    .line_comment_prefixes = &semicolon_prefixes,
};

const c_family_exts = [_][]const u8{
    "c",   "cpp",   "h",     "hpp",   "cc",   "cxx",    "hh",     "hxx",
    "js",  "jsx",   "ts",    "tsx",   "mjs",  "cjs",    "proto",  "cs",
    "csx", "dart",  "hx",    "swift", "sol",  "move",   "mo",     "m",
    "mm",  "scala", "kt",    "kts",   "java", "groovy", "gradle", "gvy",
    "gy",  "gsh",   "v",     "vh",    "sv",   "svh",    "sc",     "bs",
    "nut", "php",   "phtml", "php3",  "php4", "php5",   "phps",
};

const go_like_exts = [_][]const u8{
    "go",
};

const css_exts = [_][]const u8{
    "css", "scss", "sass", "less", "styl", "stylus",
};

const html_exts = [_][]const u8{
    "htm", "html", "htmx", "xhtml", "xml", "svg", "shtml",
};

const hash_only_exts = [_][]const u8{
    "bzl",       "cmake",   "mk",  "py",   "sh",    "yml",  "yaml", "gql",
    "coffee",    "cr",      "ex",  "exs",  "nim",   "nims", "prql", "r",
    "rpy",       "pyi",     "pyw", "rpym", "rpymc", "pl",   "pm",   "ls",
    "litcoffee", "liticed",
};

const dash_only_exts = [_][]const u8{
    "vhd", "vhdl",
};

const haskell_exts = [_][]const u8{
    "hs", "agda", "lagda", "lhs", "fut",
};

const ml_exts = [_][]const u8{
    "fs", "fsi", "fsx", "fsscript", "ml", "mli", "mll", "mly",
};

const clojure_exts = [_][]const u8{
    "clj", "cljs", "cljc", "hy",
};

const erlang_exts = [_][]const u8{
    "erl", "hrl", "escript", "xrl", "yrl", "app.src",
};

const percent_block_exts = [_][]const u8{
    "ly", "ily", "lyi",
};

const bang_exts = [_][]const u8{
    "f", "for", "f90", "f95", "f03", "f08",
};

const basic_exts = [_][]const u8{
    "vb", "bas", "cls", "frm", "brs",
};

const semicolon_only_exts = [_][]const u8{
    "asm", "s",
};

pub fn resolve(ext: []const u8) ?*const Plugin {
    if (hasExt(&[_][]const u8{"svelte"}, ext)) return &svelte_plugin;
    if (hasExt(&[_][]const u8{"rs"}, ext)) return &rust_plugin;
    if (hasExt(&[_][]const u8{"zig"}, ext)) return &zig_plugin;
    if (hasExt(&[_][]const u8{"sql"}, ext)) return &sql_plugin;
    if (hasExt(&[_][]const u8{"lua"}, ext)) return &lua_plugin;
    if (hasExt(&[_][]const u8{"nix"}, ext)) return &nix_plugin;
    if (hasExt(&[_][]const u8{"tf"}, ext)) return &terraform_plugin;
    if (hasExt(&[_][]const u8{ "rkt", "rktd", "rktl" }, ext)) return &racket_plugin;
    if (hasExt(&[_][]const u8{"jl"}, ext)) return &julia_plugin;
    if (hasExt(&[_][]const u8{ "pug", "jade" }, ext)) return &pug_plugin;
    if (hasExt(&[_][]const u8{ "hbs", "handlebars", "mustache" }, ext)) return &handlebars_plugin;
    if (hasExt(&[_][]const u8{ "java", "kt", "kts", "scala", "groovy", "gradle", "gvy", "gy", "gsh" }, ext)) {
        return &jvm_plugin;
    }
    if (hasExt(&html_exts, ext)) return &html_plugin;
    if (hasExt(&css_exts, ext)) return &css_plugin;
    if (hasExt(&haskell_exts, ext)) return &haskell_plugin;
    if (hasExt(&ml_exts, ext)) return &ml_plugin;
    if (hasExt(&clojure_exts, ext)) return &clojure_plugin;
    if (hasExt(&erlang_exts, ext)) return &erlang_plugin;
    if (hasExt(&percent_block_exts, ext)) return &percent_block_plugin;
    if (hasExt(&[_][]const u8{"tex"}, ext)) return &percent_only_plugin;
    if (hasExt(&bang_exts, ext)) return &bang_plugin;
    if (hasExt(&basic_exts, ext)) return &basic_plugin;
    if (hasExt(&semicolon_only_exts, ext)) return &semicolon_only_plugin;
    if (hasExt(&[_][]const u8{ "php", "phtml", "php3", "php4", "php5", "phps" }, ext)) return &php_plugin;
    if (hasExt(&[_][]const u8{"rb"}, ext)) return &ruby_plugin;
    if (hasExt(&go_like_exts, ext)) return &go_like_plugin;
    if (hasExt(&c_family_exts, ext)) return &c_family_plugin;
    if (hasExt(&hash_only_exts, ext)) return &hash_only_plugin;
    if (hasExt(&dash_only_exts, ext)) return &dash_only_plugin;
    return null;
}

pub fn isTestPath(path: []const u8, plugin: ?*const Plugin) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    var parts_buf: [256][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= parts_buf.len) break;
        parts_buf[n] = part;
        n += 1;
    }
    if (n == 0) return false;

    if (n >= 2) {
        for (parts_buf[0 .. n - 1]) |comp| {
            for (default_test_path_dirs) |dir| {
                if (asciiEqlIgnoreCase(comp, dir)) return true;
            }
        }
    }

    const base = parts_buf[n - 1];
    for (default_exact_test_basenames) |name| {
        if (asciiEqlIgnoreCase(base, name)) return true;
    }
    if (plugin) |lang| {
        for (lang.exact_test_basenames) |name| {
            if (asciiEqlIgnoreCase(base, name)) return true;
        }
    }

    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    if (dot == 0) return false;

    const name = base[0..dot];
    if (name.len == 0) return false;

    for (default_test_prefixes) |prefix| {
        if (asciiStartsWithIgnoreCase(name, prefix) and name.len > prefix.len) return true;
    }
    if (plugin) |lang| {
        for (lang.test_filename_prefixes) |prefix| {
            if (asciiStartsWithIgnoreCase(name, prefix) and name.len > prefix.len) return true;
        }
    }

    for (default_test_suffixes) |suffix| {
        if (name.len > suffix.len and asciiEndsWithIgnoreCase(name, suffix)) return true;
    }
    if (plugin) |lang| {
        for (lang.test_filename_suffixes) |suffix| {
            if (name.len > suffix.len and asciiEndsWithIgnoreCase(name, suffix)) return true;
        }
    }

    if (std.mem.lastIndexOfScalar(u8, name, '.')) |inner| {
        const marker = name[inner + 1 ..];
        for (default_dotted_test_markers) |candidate| {
            if (asciiEqlIgnoreCase(marker, candidate)) return true;
        }
        if (plugin) |lang| {
            for (lang.dotted_test_markers) |candidate| {
                if (asciiEqlIgnoreCase(marker, candidate)) return true;
            }
        }
    }

    return false;
}

pub fn countFile(
    content: []const u8,
    force_test: bool,
    plugin: ?*const Plugin,
    opts: CountOptions,
) LineCount {
    var tc: u64 = 0;
    var mc: u64 = 0;
    var bc: u64 = 0;
    var cc: u64 = 0;
    var state = CountState{};

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        updateInlineTestStateBeforeLine(line, plugin, force_test, &state);
        const analysis = analyzeLine(line, plugin, &state);

        if (analysis.blank) {
            if (opts.show_blanks) bc += 1;
        } else if (analysis.comment) {
            if (opts.show_comments) mc += 1;
        } else {
            const logical_lines = @as(u64, analysis.countable) +
                if (opts.count_symbol_only) @as(u64, analysis.symbol) else 0;
            if (force_test or state.in_test) {
                tc += logical_lines;
            } else {
                cc += logical_lines;
            }
        }

        updateInlineTestStateAfterLine(plugin, &state);
    }

    return .{
        .test_count = tc,
        .comment_count = mc,
        .blank_count = bc,
        .code_count = cc,
    };
}

pub fn classifyFileLines(
    allocator: std.mem.Allocator,
    content: []const u8,
    force_test: bool,
    plugin: ?*const Plugin,
    opts: CountOptions,
) ![]LineKind {
    var out: std.ArrayList(LineKind) = .empty;
    var state = CountState{};

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        try out.append(allocator, classifyLine(line, force_test, plugin, opts, &state));
    }

    return out.toOwnedSlice(allocator);
}

const CountState = struct {
    active_block_comment_end: ?[]const u8 = null,
    in_test: bool = false,
    test_depth: i64 = 0,
    pending_rust_cfg: bool = false,
    pending_zig_test: bool = false,
};

fn classifyLine(
    line: []const u8,
    force_test: bool,
    plugin: ?*const Plugin,
    opts: CountOptions,
    state: *CountState,
) LineKind {
    updateInlineTestStateBeforeLine(line, plugin, force_test, state);
    const analysis = analyzeLine(line, plugin, state);
    const in_test = force_test or state.in_test;

    const kind: LineKind = if (analysis.blank)
        if (opts.show_blanks) .blank else .skipped
    else if (analysis.comment)
        if (opts.show_comments) .comment else .skipped
    else blk: {
        const logical_lines = @as(u64, analysis.countable) +
            if (opts.count_symbol_only) @as(u64, analysis.symbol) else 0;
        if (logical_lines == 0) break :blk .skipped;
        break :blk if (in_test) .test_line else .code;
    };

    updateInlineTestStateAfterLine(plugin, state);
    return kind;
}

const LineAnalysis = struct {
    blank: bool = false,
    comment: bool = false,
    countable: u32 = 0,
    symbol: u32 = 0,
};

fn analyzeLine(
    line: []const u8,
    plugin: ?*const Plugin,
    state: *CountState,
) LineAnalysis {
    if (!needsBlockScan(line, plugin, state)) {
        return classifySimpleLine(line, plugin);
    }

    var i: usize = 0;
    var saw_comment = false;
    var has_non_ws = false;
    var has_code = false;

    while (i < line.len) {
        if (state.active_block_comment_end) |end| {
            saw_comment = true;
            if (std.mem.indexOf(u8, line[i..], end)) |close_rel| {
                i += close_rel + end.len;
                state.active_block_comment_end = null;
                continue;
            }
            break;
        }

        while (i < line.len and isWhitespaceByte(line[i])) : (i += 1) {}
        if (i >= line.len) break;

        if (matchLineCommentPrefix(line[i..], plugin) != null) {
            saw_comment = true;
            break;
        }

        if (matchBlockComment(line[i..], plugin)) |block| {
            saw_comment = true;
            i += block.start.len;
            if (std.mem.indexOf(u8, line[i..], block.end)) |close_rel| {
                i += close_rel + block.end.len;
            } else {
                state.active_block_comment_end = block.end;
                break;
            }
            continue;
        }

        has_non_ws = true;
        if (isCodeByte(line[i])) has_code = true;
        i += 1;
    }

    if (!has_non_ws) {
        if (saw_comment) return .{ .comment = true };
        return .{ .blank = true };
    }

    return if (has_code)
        .{ .countable = 1 }
    else
        .{ .symbol = 1 };
}

fn needsBlockScan(
    line: []const u8,
    plugin: ?*const Plugin,
    state: *const CountState,
) bool {
    if (state.active_block_comment_end != null) return true;
    const lang = plugin orelse return false;
    for (lang.block_comments) |block| {
        if (std.mem.indexOf(u8, line, block.start) != null) return true;
    }
    return false;
}

fn classifySimpleLine(line: []const u8, plugin: ?*const Plugin) LineAnalysis {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return .{ .blank = true };
    if (matchLineCommentPrefix(trimmed, plugin) != null) return .{ .comment = true };
    return if (isSymbolOnlyTrimmed(trimmed))
        .{ .symbol = 1 }
    else
        .{ .countable = 1 };
}

fn isSymbolOnlyTrimmed(trimmed: []const u8) bool {
    for (trimmed) |c| {
        if (isCodeByte(c)) return false;
    }
    return true;
}

fn matchLineCommentPrefix(
    text: []const u8,
    plugin: ?*const Plugin,
) ?usize {
    const prefixes = if (plugin) |lang| lang.line_comment_prefixes else generic_line_comment_prefixes[0..];
    var best: ?usize = null;
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, text, prefix)) continue;
        if (best == null or prefix.len > best.?) best = prefix.len;
    }
    return best;
}

fn matchBlockComment(
    text: []const u8,
    plugin: ?*const Plugin,
) ?BlockComment {
    const lang = plugin orelse return null;
    var best: ?BlockComment = null;
    for (lang.block_comments) |block| {
        if (!std.mem.startsWith(u8, text, block.start)) continue;
        if (best == null or block.start.len > best.?.start.len) best = block;
    }
    return best;
}

fn isCodeByte(c: u8) bool {
    return c >= 128 or std.ascii.isAlphanumeric(c) or c == '_';
}

fn updateInlineTestStateBeforeLine(
    line: []const u8,
    plugin: ?*const Plugin,
    force_test: bool,
    state: *CountState,
) void {
    if (force_test) return;
    const lang = plugin orelse return;

    switch (lang.inline_test_mode) {
        .none => {},
        .rust_cfg_mod => {
            if (std.mem.indexOf(u8, line, "#[cfg(test)]") != null) {
                state.pending_rust_cfg = true;
            }
            if (state.pending_rust_cfg and containsTestModDecl(line)) {
                state.in_test = true;
                state.pending_rust_cfg = false;
            }
            if (state.in_test) {
                for (line) |c| {
                    if (c == '{') {
                        state.test_depth += 1;
                    } else if (c == '}') {
                        state.test_depth -= 1;
                    }
                }
            }
            if (state.pending_rust_cfg and !isCfgContinuation(line)) {
                state.pending_rust_cfg = false;
            }
        },
        .zig_test_block => {
            if (!state.in_test and startsWithZigTestDecl(line)) {
                state.in_test = true;
                state.pending_zig_test = true;
            }
            if (state.in_test) {
                updateZigTestDepthFromLine(line, state);
            }
        },
    }
}

fn updateInlineTestStateAfterLine(
    plugin: ?*const Plugin,
    state: *CountState,
) void {
    const lang = plugin orelse return;
    switch (lang.inline_test_mode) {
        .none => {},
        .rust_cfg_mod => {
            if (state.in_test and state.test_depth <= 0) {
                state.in_test = false;
                state.test_depth = 0;
            }
        },
        .zig_test_block => {
            if (state.in_test and !state.pending_zig_test and state.test_depth <= 0) {
                state.in_test = false;
                state.test_depth = 0;
            }
        },
    }
}

fn startsWithZigTestDecl(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "test")) return false;
    if (trimmed.len == 4) return true;
    const next = trimmed[4];
    return isWhitespaceByte(next) or next == '{';
}

fn updateZigTestDepthFromLine(line: []const u8, state: *CountState) void {
    const trimmed = std.mem.trimLeft(u8, line, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return;

    var in_string = false;
    var in_char = false;
    var escaped = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string or in_char) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (in_string and c == '"') {
                in_string = false;
            } else if (in_char and c == '\'') {
                in_char = false;
            }
            continue;
        }

        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '\'') {
            in_char = true;
            continue;
        }
        if (c == '{') {
            state.test_depth += 1;
            state.pending_zig_test = false;
        } else if (c == '}') {
            state.test_depth -= 1;
        }
    }
}

fn isCfgContinuation(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t\r");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "#[")) return true;
    if (std.mem.startsWith(u8, trimmed, "mod")) {
        if (trimmed.len == 3) return true;
        if (isWhitespaceByte(trimmed[3])) return true;
    }
    return false;
}

fn containsTestModDecl(line: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= line.len) : (i += 1) {
        if (i > 0) {
            const prev = line[i - 1];
            if (!isWhitespaceByte(prev)) continue;
        }
        if (line[i] != 'm' or line[i + 1] != 'o' or line[i + 2] != 'd') continue;
        var j = i + 3;
        if (j >= line.len) return false;
        if (!isWhitespaceByte(line[j])) continue;
        while (j < line.len and isWhitespaceByte(line[j])) : (j += 1) {}
        if (j >= line.len) return false;
        const first = line[j];
        if (!(first == '_' or std.ascii.isAlphabetic(first))) continue;
        j += 1;
        while (j < line.len) : (j += 1) {
            const c = line[j];
            if (!(c == '_' or std.ascii.isAlphanumeric(c))) break;
        }
        while (j < line.len and isWhitespaceByte(line[j])) : (j += 1) {}
        if (j < line.len and line[j] == '{') return true;
    }
    return false;
}

fn isWhitespaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn hasExt(list: []const []const u8, ext: []const u8) bool {
    for (list) |candidate| {
        if (asciiEqlIgnoreCase(candidate, ext)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and asciiEqlIgnoreCase(haystack[0..needle.len], needle);
}

fn asciiEndsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and asciiEqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

test "resolve - audited defaults attach plugins" {
    try std.testing.expect(resolve("js") != null);
    try std.testing.expect(resolve("rs") != null);
    try std.testing.expect(resolve("clj") != null);
    try std.testing.expect(resolve("html") != null);
    try std.testing.expect(std.mem.eql(u8, resolve("rb").?.name, "ruby"));
    try std.testing.expect(std.mem.eql(u8, resolve("brs").?.name, "basic"));
}

test "isTestPath - jvm suffix plugin" {
    try std.testing.expect(isTestPath("src/FooIT.scala", resolve("scala")));
    try std.testing.expect(!isTestPath("src/FooIT.py", resolve("py")));
}

test "isTestPath - zig exact test basenames" {
    try std.testing.expect(isTestPath("test.zig", resolve("zig")));
    try std.testing.expect(isTestPath("src/tests.zig", resolve("zig")));
    try std.testing.expect(!isTestPath("src/contest.zig", resolve("zig")));
}

test "countFile - js block comments without semicolon splitting" {
    const src =
        \\/* header */
        \\const a = 1; const b = 2;
        \\const c = 3;
    ;
    const result = countFile(src, false, resolve("js"), .{});
    try std.testing.expectEqual(@as(u64, 1), result.comment_count);
    try std.testing.expectEqual(@as(u64, 2), result.code_count);
}

test "countFile - block comment state survives inline openings" {
    const src =
        \\const a = 1; /* begin
        \\still comment
        \\*/
        \\const b = 2;
    ;
    const result = countFile(src, false, resolve("js"), .{});
    try std.testing.expectEqual(@as(u64, 2), result.code_count);
    try std.testing.expectEqual(@as(u64, 2), result.comment_count);
}

test "countFile - html comments" {
    const src =
        \\<!-- note -->
        \\<div></div>
    ;
    const result = countFile(src, false, resolve("html"), .{});
    try std.testing.expectEqual(@as(u64, 1), result.comment_count);
    try std.testing.expectEqual(@as(u64, 1), result.code_count);
}

test "countFile - clojure reader macro is code" {
    const src = "#?(:clj foo :cljs bar)\n";
    const result = countFile(src, false, resolve("clj"), .{});
    try std.testing.expectEqual(@as(u64, 0), result.comment_count);
    try std.testing.expectEqual(@as(u64, 1), result.code_count);
}

test "countFile - c semicolons do not split physical lines" {
    const src = "for (i = 0; i < n; i++) foo();\n";
    const result = countFile(src, false, resolve("c"), .{});
    try std.testing.expectEqual(@as(u64, 1), result.code_count);
}

test "countFile - rust cfg test plugin" {
    const src =
        \\fn real() { 1 }
        \\
        \\#[cfg(test)]
        \\mod tests {
        \\    fn t1() {}
        \\    fn t2() {}
        \\}
        \\
        \\fn more() { 2 }
    ;
    const result = countFile(src, false, resolve("rs"), .{});
    try std.testing.expect(result.code_count >= 2);
    try std.testing.expect(result.test_count >= 2);
}

test "countFile - zig inline test blocks" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn add(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\
        \\test "add works" {
        \\    try std.testing.expectEqual(@as(u8, 3), add(1, 2));
        \\}
        \\
        \\pub fn more() void {}
    ;
    const result = countFile(src, false, resolve("zig"), .{});
    try std.testing.expectEqual(@as(u64, 4), result.code_count);
    try std.testing.expectEqual(@as(u64, 2), result.test_count);
}

test "countFile - zig test block brace tracking ignores strings and comments" {
    const src =
        \\fn real() void {}
        \\
        \\test "brace } in name" // comment {
        \\{
        \\    try std.testing.expect(true);
        \\}
        \\
        \\fn after() void {}
    ;
    const result = countFile(src, false, resolve("zig"), .{});
    try std.testing.expectEqual(@as(u64, 2), result.code_count);
    try std.testing.expectEqual(@as(u64, 2), result.test_count);
}
