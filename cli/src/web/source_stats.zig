const std = @import("std");
const git = @import("../git.zig");
const repo_mod = @import("../repo.zig");
const hljs_languages = @import("hljs_languages.zig");
const sloc_lang_plugins = @import("source_lang_plugins.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;

const max_git_path_output = 128 * 1024 * 1024;
const max_source_file_bytes = 128 * 1024 * 1024;

const empty_strings = [_][]const u8{};
const empty_blocks = [_]sloc_lang_plugins.BlockComment{};
const no_comment_plugin = sloc_lang_plugins.Plugin{
    .name = "no-comment",
    .line_comment_prefixes = &empty_strings,
    .block_comments = &empty_blocks,
    .test_filename_prefixes = &empty_strings,
    .test_filename_suffixes = &empty_strings,
    .dotted_test_markers = &empty_strings,
    .exact_test_basenames = &empty_strings,
    .inline_test_mode = .none,
};

const LanguageDisplayName = struct {
    id: []const u8,
    name: []const u8,
};

const language_display_names = [_]LanguageDisplayName{
    .{ .id = "actionscript", .name = "ActionScript" },
    .{ .id = "angelscript", .name = "AngelScript" },
    .{ .id = "apache", .name = "Apache config" },
    .{ .id = "autohotkey", .name = "AutoHotkey" },
    .{ .id = "autoit", .name = "AutoIt" },
    .{ .id = "avrasm", .name = "AVR Assembly" },
    .{ .id = "awk", .name = "Awk" },
    .{ .id = "bash", .name = "Shell" },
    .{ .id = "basic", .name = "BASIC" },
    .{ .id = "bnf", .name = "Backus-Naur Form" },
    .{ .id = "c", .name = "C" },
    .{ .id = "cal", .name = "C/AL" },
    .{ .id = "capnproto", .name = "Cap'n Proto" },
    .{ .id = "ceylon", .name = "Ceylon" },
    .{ .id = "clean", .name = "Clean" },
    .{ .id = "clojure-repl", .name = "Clojure REPL" },
    .{ .id = "clojure", .name = "Clojure" },
    .{ .id = "cmake", .name = "CMake" },
    .{ .id = "coffeescript", .name = "CoffeeScript" },
    .{ .id = "coq", .name = "Coq" },
    .{ .id = "cos", .name = "Cache Object Script" },
    .{ .id = "cpp", .name = "C++" },
    .{ .id = "crystal", .name = "Crystal" },
    .{ .id = "csharp", .name = "C#" },
    .{ .id = "csp", .name = "CSP" },
    .{ .id = "css", .name = "CSS" },
    .{ .id = "d", .name = "D" },
    .{ .id = "dns", .name = "DNS Zone" },
    .{ .id = "dockerfile", .name = "Dockerfile" },
    .{ .id = "dust", .name = "Dust" },
    .{ .id = "elixir", .name = "Elixir" },
    .{ .id = "erb", .name = "ERB" },
    .{ .id = "erlang-repl", .name = "Erlang REPL" },
    .{ .id = "excel", .name = "Excel" },
    .{ .id = "fix", .name = "FIX" },
    .{ .id = "flix", .name = "Flix" },
    .{ .id = "fsharp", .name = "F#" },
    .{ .id = "gams", .name = "GAMS" },
    .{ .id = "gauss", .name = "GAUSS" },
    .{ .id = "gherkin", .name = "Gherkin" },
    .{ .id = "glsl", .name = "GLSL" },
    .{ .id = "gml", .name = "GML" },
    .{ .id = "go", .name = "Go" },
    .{ .id = "golo", .name = "Golo" },
    .{ .id = "gradle", .name = "Gradle" },
    .{ .id = "haml", .name = "HAML" },
    .{ .id = "haskell", .name = "Haskell" },
    .{ .id = "haxe", .name = "Haxe" },
    .{ .id = "html", .name = "HTML" },
    .{ .id = "hsp", .name = "HSP" },
    .{ .id = "hy", .name = "Hy" },
    .{ .id = "inform7", .name = "Inform 7" },
    .{ .id = "ini", .name = "INI" },
    .{ .id = "javascript", .name = "JavaScript" },
    .{ .id = "jboss-cli", .name = "JBoss CLI" },
    .{ .id = "json", .name = "JSON" },
    .{ .id = "julia-repl", .name = "Julia REPL" },
    .{ .id = "julia", .name = "Julia" },
    .{ .id = "kotlin", .name = "Kotlin" },
    .{ .id = "lasso", .name = "Lasso" },
    .{ .id = "ldif", .name = "LDIF" },
    .{ .id = "leaf", .name = "Leaf" },
    .{ .id = "less", .name = "Less" },
    .{ .id = "lisp", .name = "Lisp" },
    .{ .id = "livecodeserver", .name = "LiveCode" },
    .{ .id = "makefile", .name = "Makefile" },
    .{ .id = "markdown", .name = "Markdown" },
    .{ .id = "mathematica", .name = "Mathematica" },
    .{ .id = "matlab", .name = "MATLAB" },
    .{ .id = "maxima", .name = "Maxima" },
    .{ .id = "mel", .name = "MEL" },
    .{ .id = "mercury", .name = "Mercury" },
    .{ .id = "mipsasm", .name = "MIPS Assembly" },
    .{ .id = "mizar", .name = "Mizar" },
    .{ .id = "mojolicious", .name = "Mojolicious" },
    .{ .id = "n1ql", .name = "N1QL" },
    .{ .id = "nestedtext", .name = "Nested Text" },
    .{ .id = "nginx", .name = "NGINX config" },
    .{ .id = "nim", .name = "Nim" },
    .{ .id = "nix", .name = "Nix" },
    .{ .id = "node-repl", .name = "Node REPL" },
    .{ .id = "ocaml", .name = "OCaml" },
    .{ .id = "perl", .name = "Perl" },
    .{ .id = "pf", .name = "Packet Filter config" },
    .{ .id = "php-template", .name = "PHP Template" },
    .{ .id = "php", .name = "PHP" },
    .{ .id = "plaintext", .name = "Plain text" },
    .{ .id = "pony", .name = "Pony" },
    .{ .id = "powershell", .name = "PowerShell" },
    .{ .id = "profile", .name = "Python profiler" },
    .{ .id = "prolog", .name = "Prolog" },
    .{ .id = "purebasic", .name = "PureBASIC" },
    .{ .id = "python", .name = "Python" },
    .{ .id = "q", .name = "Q" },
    .{ .id = "reasonml", .name = "ReasonML" },
    .{ .id = "rib", .name = "RenderMan RIB" },
    .{ .id = "ruby", .name = "Ruby" },
    .{ .id = "ruleslanguage", .name = "Oracle Rules Language" },
    .{ .id = "rust", .name = "Rust" },
    .{ .id = "scheme", .name = "Scheme" },
    .{ .id = "shell", .name = "Shell Session" },
    .{ .id = "sml", .name = "SML (Standard ML)" },
    .{ .id = "sqf", .name = "SQF" },
    .{ .id = "sql", .name = "SQL" },
    .{ .id = "stata", .name = "Stata" },
    .{ .id = "step21", .name = "STEP Part 21" },
    .{ .id = "subunit", .name = "SubUnit" },
    .{ .id = "taggerscript", .name = "Tagger Script" },
    .{ .id = "tap", .name = "Test Anything Protocol" },
    .{ .id = "thrift", .name = "Thrift" },
    .{ .id = "toml", .name = "TOML" },
    .{ .id = "tp", .name = "TP" },
    .{ .id = "typescript", .name = "TypeScript" },
    .{ .id = "vala", .name = "Vala" },
    .{ .id = "vbscript-html", .name = "VBScript in HTML" },
    .{ .id = "vim", .name = "Vim Script" },
    .{ .id = "wasm", .name = "Wasm" },
    .{ .id = "x86asm", .name = "Intel x86 Assembly" },
    .{ .id = "xml", .name = "XML" },
    .{ .id = "xquery", .name = "XQuery" },
    .{ .id = "yaml", .name = "YAML" },
};

pub const Counts = struct {
    code: u64,
    test_count: u64,
    comment: u64,

    pub fn total(self: Counts) u64 {
        return self.code + self.test_count + self.comment;
    }
};

pub const LanguageRow = struct {
    language: []const u8,
    code: u64,
    test_count: u64,
    comment: u64,

    pub fn total(self: LanguageRow) u64 {
        return self.code + self.test_count + self.comment;
    }
};

pub const Stats = struct {
    rows: []LanguageRow,
    total_code: u64,
    total_test: u64,
    total_comment: u64,

    pub fn deinit(self: *Stats, allocator: Allocator) void {
        allocator.free(self.rows);
    }

    pub fn total(self: Stats) u64 {
        return self.total_code + self.total_test + self.total_comment;
    }
};

pub fn loadRepositoryStats(allocator: Allocator, repo: Repo) !?Stats {
    const paths = try collectRepositoryPaths(allocator, repo) orelse return null;
    defer git.freeStringList(allocator, paths);

    var rows: std.ArrayList(LanguageRow) = .empty;
    errdefer rows.deinit(allocator);
    var row_index = std.StringHashMap(usize).init(allocator);
    defer row_index.deinit();

    var total_code: u64 = 0;
    var total_test: u64 = 0;
    var total_comment: u64 = 0;

    for (paths) |path| {
        const content = readWorktreeFile(allocator, repo, path) catch continue;
        defer allocator.free(content);

        const counts = countBlob(path, content) orelse continue;
        if (counts.total() == 0) continue;

        const language = languageForPath(path);
        try addLanguageCounts(&rows, &row_index, allocator, language, counts);
        total_code +|= counts.code;
        total_test +|= counts.test_count;
        total_comment +|= counts.comment;
    }

    std.mem.sort(LanguageRow, rows.items, {}, struct {
        fn lessThan(_: void, a: LanguageRow, b: LanguageRow) bool {
            if (a.total() != b.total()) return a.total() > b.total();
            return std.mem.lessThan(u8, a.language, b.language);
        }
    }.lessThan);

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .total_code = total_code,
        .total_test = total_test,
        .total_comment = total_comment,
    };
}

pub fn countBlob(path: []const u8, content: []const u8) ?Counts {
    const language = languageForPath(path);
    if (std.mem.eql(u8, language, "plaintext")) return null;

    const plugin = pluginForPath(path, language);
    const force_test = sloc_lang_plugins.isTestPath(path, plugin);
    const counted = sloc_lang_plugins.countFile(content, force_test, plugin, .{});
    return .{
        .code = counted.code_count,
        .test_count = counted.test_count,
        .comment = counted.comment_count,
    };
}

pub fn languageForPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (isReadmeName(base) or hasExtension(path, "markdown") or hasExtension(path, "md") or
        hasExtension(path, "mkdown") or hasExtension(path, "mkd"))
    {
        return "markdown";
    }
    if (std.ascii.eqlIgnoreCase(base, "CMakeLists.txt")) return "cmake";
    if (std.ascii.startsWithIgnoreCase(base, "Dockerfile.")) return "dockerfile";
    if (std.ascii.startsWithIgnoreCase(base, "Makefile.")) return "makefile";

    if (languageForDottedSuffix(base)) |language| return language;
    if (hljs_languages.languageForToken(base)) |language| return language;
    if (pathExtension(base)) |ext| {
        if (hljs_languages.languageForToken(ext)) |language| return language;
    }
    return "plaintext";
}

pub fn languageDisplayName(language: []const u8) []const u8 {
    for (language_display_names) |entry| {
        if (std.ascii.eqlIgnoreCase(language, entry.id)) return entry.name;
    }
    return hljs_languages.displayName(language);
}

pub fn languageColor(language: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(language, "zig")) return "#ec915c";
    if (std.ascii.eqlIgnoreCase(language, "c")) return "#555555";
    if (std.ascii.eqlIgnoreCase(language, "cpp")) return "#f34b7d";
    if (std.ascii.eqlIgnoreCase(language, "javascript")) return "#f1e05a";
    if (std.ascii.eqlIgnoreCase(language, "typescript")) return "#3178c6";
    if (std.ascii.eqlIgnoreCase(language, "css")) return "#563d7c";
    if (std.ascii.eqlIgnoreCase(language, "bash") or std.ascii.eqlIgnoreCase(language, "shell")) return "#89e051";
    if (std.ascii.eqlIgnoreCase(language, "markdown")) return "#083fa1";
    if (std.ascii.eqlIgnoreCase(language, "python")) return "#3572a5";
    if (std.ascii.eqlIgnoreCase(language, "rust")) return "#dea584";
    if (std.ascii.eqlIgnoreCase(language, "go")) return "#00add8";
    if (std.ascii.eqlIgnoreCase(language, "html")) return "#e34c26";
    if (std.ascii.eqlIgnoreCase(language, "json")) return "#292929";
    if (std.ascii.eqlIgnoreCase(language, "xml")) return "#0060ac";
    if (std.ascii.eqlIgnoreCase(language, "yaml")) return "#cb171e";
    if (std.ascii.eqlIgnoreCase(language, "sql")) return "#e38c00";
    if (std.ascii.eqlIgnoreCase(language, "nix")) return "#7e7eff";
    if (std.ascii.eqlIgnoreCase(language, "tla")) return "#4c4f69";
    if (std.ascii.eqlIgnoreCase(language, "solidity")) return "#aa6746";
    return "#8b949e";
}

fn collectRepositoryPaths(allocator: Allocator, repo: Repo) !?[][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var found_any = false;
    const tracked = try gitMaybe(allocator, repo, &.{ "ls-files", "-z" }, max_git_path_output);
    defer if (tracked) |bytes| allocator.free(bytes);
    if (tracked) |bytes| {
        found_any = true;
        try appendGitPaths(allocator, &paths, &seen, bytes);
    }

    const untracked = try gitMaybe(allocator, repo, &.{ "ls-files", "--others", "--exclude-standard", "-z" }, max_git_path_output);
    defer if (untracked) |bytes| allocator.free(bytes);
    if (untracked) |bytes| {
        found_any = true;
        try appendGitPaths(allocator, &paths, &seen, bytes);
    }

    if (!found_any) return null;
    return try paths.toOwnedSlice(allocator);
}

fn appendGitPaths(
    allocator: Allocator,
    paths: *std.ArrayList([]u8),
    seen: *std.StringHashMap(void),
    output: []const u8,
) !void {
    var entries = std.mem.splitScalar(u8, output, 0);
    while (entries.next()) |path| {
        if (path.len == 0) continue;
        if (std.mem.eql(u8, languageForPath(path), "plaintext")) continue;
        if (seen.contains(path)) continue;
        const copy = try allocator.dupe(u8, path);
        try paths.append(allocator, copy);
        try seen.put(copy, {});
    }
}

fn addLanguageCounts(
    rows: *std.ArrayList(LanguageRow),
    row_index: *std.StringHashMap(usize),
    allocator: Allocator,
    language: []const u8,
    counts: Counts,
) !void {
    if (row_index.get(language)) |idx| {
        rows.items[idx].code +|= counts.code;
        rows.items[idx].test_count +|= counts.test_count;
        rows.items[idx].comment +|= counts.comment;
        return;
    }

    try rows.append(allocator, .{
        .language = language,
        .code = counts.code,
        .test_count = counts.test_count,
        .comment = counts.comment,
    });
    try row_index.put(language, rows.items.len - 1);
}

fn readWorktreeFile(allocator: Allocator, repo: Repo, path: []const u8) ![]u8 {
    const absolute_path = try std.fs.path.join(allocator, &.{ repo.root, path });
    defer allocator.free(absolute_path);

    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_source_file_bytes);
}

fn gitMaybe(allocator: Allocator, repo: Repo, git_args: []const []const u8, max_output_bytes: usize) !?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, repo.root);
    for (git_args) |arg| try argv.append(allocator, arg);

    var result = try git.runCommand(allocator, argv.items, null, max_output_bytes);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }

    result.deinit();
    return null;
}

fn pluginForPath(path: []const u8, language: []const u8) ?*const sloc_lang_plugins.Plugin {
    if (pluginKeyForPath(path, language)) |key| {
        if (sloc_lang_plugins.resolve(key)) |plugin| return plugin;
    }
    return &no_comment_plugin;
}

fn pluginKeyForPath(path: []const u8, language: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(base, "CMakeLists.txt")) return "cmake";
    if (std.ascii.eqlIgnoreCase(language, "makefile")) return "mk";
    if (std.ascii.eqlIgnoreCase(language, "dockerfile")) return "sh";
    if (pathExtension(base)) |ext| return ext;
    return language;
}

fn languageForDottedSuffix(base: []const u8) ?[]const u8 {
    var i = hljs_languages.languages.len;
    while (i > 0) {
        i -= 1;
        const language = hljs_languages.languages[i];
        if (std.mem.indexOfScalar(u8, language.id, '.') != null and basenameMatchesToken(base, language.id)) return language.id;
        for (language.aliases) |alias| {
            if (std.mem.indexOfScalar(u8, alias, '.') != null and basenameMatchesToken(base, alias)) return language.id;
        }
    }
    return null;
}

fn basenameMatchesToken(base: []const u8, token: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(base, token)) return true;
    if (base.len <= token.len + 1) return false;
    const start = base.len - token.len;
    return base[start - 1] == '.' and std.ascii.eqlIgnoreCase(base[start..], token);
}

fn pathExtension(base: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0 or dot == base.len - 1) return null;
    return base[dot + 1 ..];
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    const found = pathExtension(std.fs.path.basename(path)) orelse return false;
    return std.ascii.eqlIgnoreCase(found, ext);
}

fn isReadmeName(base: []const u8) bool {
    return std.ascii.eqlIgnoreCase(base, "README");
}

test "source stats maps hljs aliases to canonical languages" {
    try std.testing.expectEqualStrings("c", languageForPath("src/main.c"));
    try std.testing.expectEqualStrings("c", languageForPath("include/main.h"));
    try std.testing.expectEqualStrings("cpp", languageForPath("include/main.hpp"));
    try std.testing.expectEqualStrings("javascript", languageForPath("assets/app.js"));
    try std.testing.expectEqualStrings("typescript", languageForPath("src/app.ts"));
    try std.testing.expectEqualStrings("typescript", languageForPath("src/app.tsx"));
    try std.testing.expectEqualStrings("svelte", languageForPath("src/App.svelte"));
    try std.testing.expectEqualStrings("markdown", languageForPath("README.md"));
    try std.testing.expectEqualStrings("solidity", languageForPath("contracts/Token.sol"));
    try std.testing.expectEqualStrings("tla", languageForPath("spec/Consensus.tla"));
    try std.testing.expectEqualStrings("plaintext", languageForPath("LICENSE"));
}

test "source stats display names use language capitalization" {
    try std.testing.expectEqualStrings("Dockerfile", languageDisplayName("dockerfile"));
    try std.testing.expectEqualStrings("Elixir", languageDisplayName("elixir"));
    try std.testing.expectEqualStrings("Wasm", languageDisplayName("wasm"));
    try std.testing.expectEqualStrings("CMake", languageDisplayName("cmake"));
    try std.testing.expectEqualStrings("Makefile", languageDisplayName("makefile"));
    try std.testing.expectEqualStrings("PHP", languageDisplayName("php"));
    try std.testing.expectEqualStrings("Ruby", languageDisplayName("ruby"));
    try std.testing.expectEqualStrings("unknownlang", languageDisplayName("unknownlang"));
}

test "source stats counts blob lines without the sloc binary" {
    const counts = countBlob("include/example.h",
        \\// public API
        \\int value;
        \\
    ).?;
    try std.testing.expectEqual(@as(u64, 1), counts.code);
    try std.testing.expectEqual(@as(u64, 0), counts.test_count);
    try std.testing.expectEqual(@as(u64, 1), counts.comment);
    try std.testing.expect(countBlob("LICENSE", "plain text\n") == null);
}
