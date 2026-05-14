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
    defer freeStringList(allocator, paths);

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
    if (std.ascii.eqlIgnoreCase(language, "bash")) return "Shell";
    if (std.ascii.eqlIgnoreCase(language, "c")) return "C";
    if (std.ascii.eqlIgnoreCase(language, "cpp")) return "C++";
    if (std.ascii.eqlIgnoreCase(language, "csharp")) return "C#";
    if (std.ascii.eqlIgnoreCase(language, "css")) return "CSS";
    if (std.ascii.eqlIgnoreCase(language, "go")) return "Go";
    if (std.ascii.eqlIgnoreCase(language, "html")) return "HTML";
    if (std.ascii.eqlIgnoreCase(language, "ini")) return "INI";
    if (std.ascii.eqlIgnoreCase(language, "javascript")) return "JavaScript";
    if (std.ascii.eqlIgnoreCase(language, "json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(language, "markdown")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(language, "nix")) return "Nix";
    if (std.ascii.eqlIgnoreCase(language, "python")) return "Python";
    if (std.ascii.eqlIgnoreCase(language, "rust")) return "Rust";
    if (std.ascii.eqlIgnoreCase(language, "sql")) return "SQL";
    if (std.ascii.eqlIgnoreCase(language, "toml")) return "TOML";
    if (std.ascii.eqlIgnoreCase(language, "typescript")) return "TypeScript";
    if (std.ascii.eqlIgnoreCase(language, "xml")) return "XML";
    if (std.ascii.eqlIgnoreCase(language, "yaml")) return "YAML";
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

fn freeStringList(allocator: Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "source stats maps hljs aliases to canonical languages" {
    try std.testing.expectEqualStrings("c", languageForPath("src/main.c"));
    try std.testing.expectEqualStrings("c", languageForPath("include/main.h"));
    try std.testing.expectEqualStrings("cpp", languageForPath("include/main.hpp"));
    try std.testing.expectEqualStrings("markdown", languageForPath("README.md"));
    try std.testing.expectEqualStrings("solidity", languageForPath("contracts/Token.sol"));
    try std.testing.expectEqualStrings("tla", languageForPath("spec/Consensus.tla"));
    try std.testing.expectEqualStrings("plaintext", languageForPath("LICENSE"));
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
