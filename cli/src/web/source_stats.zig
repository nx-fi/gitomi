const std = @import("std");
const git = @import("../git.zig");
const index = @import("../index.zig");
const repo_mod = @import("../repo.zig");
const hljs_languages = @import("hljs_languages.zig");
const sloc_lang_plugins = @import("source_lang_plugins.zig");

const Allocator = std.mem.Allocator;
const Repo = repo_mod.Repo;
const SqliteDb = index.SqliteDb;
const sqlite = index.sqlite;

const max_git_path_output = 128 * 1024 * 1024;
const max_source_file_bytes = 128 * 1024 * 1024;
const max_cached_scope_depth = 2;
const max_commit_oid_output = 1024 * 1024;
const source_stats_cache_file = "source-stats.sqlite";

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

pub const ContributorRow = struct {
    name: []const u8,
    email: []const u8,
    code: u64,
    test_count: u64,
    comment: u64,

    pub fn total(self: ContributorRow) u64 {
        return self.code + self.test_count + self.comment;
    }
};

pub const Contributors = struct {
    rows: []ContributorRow,

    pub fn deinit(self: *Contributors, allocator: Allocator) void {
        freeContributorRows(allocator, self.rows);
        allocator.free(self.rows);
    }

    pub fn total(self: Contributors) u64 {
        var value: u64 = 0;
        for (self.rows) |row| value +|= row.total();
        return value;
    }
};

const SourceScopeResult = struct {
    stats: Stats,
    contributors: Contributors,

    fn deinit(self: *SourceScopeResult, allocator: Allocator) void {
        self.stats.deinit(allocator);
        self.contributors.deinit(allocator);
    }
};

const CacheScope = struct {
    commit_oid: ?[]u8,

    fn deinit(self: *CacheScope, allocator: Allocator) void {
        if (self.commit_oid) |oid| allocator.free(oid);
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

pub fn loadRepositoryContributors(allocator: Allocator, repo: Repo) !?Contributors {
    const paths = try collectTrackedRepositoryPaths(allocator, repo) orelse return null;
    defer git.freeStringList(allocator, paths);

    var rows: std.ArrayList(ContributorRow) = .empty;
    errdefer {
        freeContributorRows(allocator, rows.items);
        rows.deinit(allocator);
    }
    var row_index = std.StringHashMap(usize).init(allocator);
    defer row_index.deinit();

    for (paths) |path| {
        const content = readWorktreeFile(allocator, repo, path) catch continue;
        defer allocator.free(content);

        const counts = countBlob(path, content) orelse continue;
        if (counts.total() == 0) continue;

        const language = languageForPath(path);
        const plugin = pluginForPath(path, language);
        const force_test = sloc_lang_plugins.isTestPath(path, plugin);
        const line_kinds = try sloc_lang_plugins.classifyFileLines(allocator, content, force_test, plugin, .{});
        defer allocator.free(line_kinds);

        const blame = gitMaybe(allocator, repo, &.{ "blame", "--incremental", "--", path }, max_git_path_output) catch continue orelse continue;
        defer allocator.free(blame);

        try parseBlameIncrementalOutput(allocator, &rows, &row_index, line_kinds, blame);
    }

    std.mem.sort(ContributorRow, rows.items, {}, struct {
        fn lessThan(_: void, a: ContributorRow, b: ContributorRow) bool {
            if (a.total() != b.total()) return a.total() > b.total();
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

pub fn loadRepositoryStatsCached(allocator: Allocator, repo: Repo) !?Stats {
    const paths = try collectRepositoryPaths(allocator, repo) orelse return null;
    defer git.freeStringList(allocator, paths);

    var db = openSourceStatsCache(allocator, repo) catch return loadRepositoryStats(allocator, repo);
    defer db.deinit();

    return loadStatsScope(allocator, repo, &db, paths, "", 0) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return loadRepositoryStats(allocator, repo),
    };
}

pub fn loadRepositoryContributorsCached(allocator: Allocator, repo: Repo) !?Contributors {
    const paths = try collectTrackedRepositoryPaths(allocator, repo) orelse return null;
    defer git.freeStringList(allocator, paths);

    var db = openSourceStatsCache(allocator, repo) catch return loadRepositoryContributors(allocator, repo);
    defer db.deinit();

    var result = loadContributorsScope(allocator, repo, &db, paths, "", 0) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return loadRepositoryContributors(allocator, repo),
    };
    result.stats.deinit(allocator);
    return result.contributors;
}

fn loadStatsScope(
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    paths: []const []const u8,
    scope_path: []const u8,
    depth: usize,
) !Stats {
    var cache_scope = try cacheScopeForPath(allocator, repo, scope_path);
    defer cache_scope.deinit(allocator);

    if (cache_scope.commit_oid) |commit_oid| {
        if (try loadCachedStats(allocator, db, scope_path, commit_oid)) |stats| return stats;
    }

    var rows: std.ArrayList(LanguageRow) = .empty;
    errdefer rows.deinit(allocator);
    var row_index = std.StringHashMap(usize).init(allocator);
    defer row_index.deinit();

    var total_code: u64 = 0;
    var total_test: u64 = 0;
    var total_comment: u64 = 0;

    if (depth < max_cached_scope_depth) {
        const child_dirs = try immediateChildScopes(allocator, paths, scope_path);
        defer git.freeStringList(allocator, child_dirs);
        for (child_dirs) |child_scope| {
            var child_stats = try loadStatsScope(allocator, repo, db, paths, child_scope, depth + 1);
            defer child_stats.deinit(allocator);
            try addStatsRows(&rows, &row_index, allocator, child_stats.rows);
            total_code +|= child_stats.total_code;
            total_test +|= child_stats.total_test;
            total_comment +|= child_stats.total_comment;
        }
        try addStatsForFilesInScope(&rows, &row_index, allocator, repo, paths, scope_path, .direct, &total_code, &total_test, &total_comment);
    } else {
        try addStatsForFilesInScope(&rows, &row_index, allocator, repo, paths, scope_path, .recursive, &total_code, &total_test, &total_comment);
    }

    sortLanguageRows(rows.items);

    const stats = Stats{
        .rows = try rows.toOwnedSlice(allocator),
        .total_code = total_code,
        .total_test = total_test,
        .total_comment = total_comment,
    };
    errdefer allocator.free(stats.rows);

    if (cache_scope.commit_oid) |commit_oid| {
        storeCachedStats(db, scope_path, commit_oid, stats) catch {};
    }
    return stats;
}

fn loadContributorsScope(
    allocator: Allocator,
    repo: Repo,
    db: *SqliteDb,
    paths: []const []const u8,
    scope_path: []const u8,
    depth: usize,
) !SourceScopeResult {
    var cache_scope = try cacheScopeForPath(allocator, repo, scope_path);
    defer cache_scope.deinit(allocator);

    if (cache_scope.commit_oid) |commit_oid| {
        if (try loadCachedSourceScope(allocator, db, scope_path, commit_oid)) |result| return result;
    }

    var language_rows: std.ArrayList(LanguageRow) = .empty;
    errdefer language_rows.deinit(allocator);
    var language_index = std.StringHashMap(usize).init(allocator);
    defer language_index.deinit();

    var contributor_rows: std.ArrayList(ContributorRow) = .empty;
    errdefer {
        freeContributorRows(allocator, contributor_rows.items);
        contributor_rows.deinit(allocator);
    }
    var contributor_index = std.StringHashMap(usize).init(allocator);
    defer contributor_index.deinit();

    var total_code: u64 = 0;
    var total_test: u64 = 0;
    var total_comment: u64 = 0;

    if (depth < max_cached_scope_depth) {
        const child_dirs = try immediateChildScopes(allocator, paths, scope_path);
        defer git.freeStringList(allocator, child_dirs);
        for (child_dirs) |child_scope| {
            var child = try loadContributorsScope(allocator, repo, db, paths, child_scope, depth + 1);
            defer child.deinit(allocator);
            try addStatsRows(&language_rows, &language_index, allocator, child.stats.rows);
            try addContributorRows(allocator, &contributor_rows, &contributor_index, child.contributors.rows);
            total_code +|= child.stats.total_code;
            total_test +|= child.stats.total_test;
            total_comment +|= child.stats.total_comment;
        }
        try addContributorFilesInScope(
            &language_rows,
            &language_index,
            &contributor_rows,
            &contributor_index,
            allocator,
            repo,
            paths,
            scope_path,
            .direct,
            &total_code,
            &total_test,
            &total_comment,
        );
    } else {
        try addContributorFilesInScope(
            &language_rows,
            &language_index,
            &contributor_rows,
            &contributor_index,
            allocator,
            repo,
            paths,
            scope_path,
            .recursive,
            &total_code,
            &total_test,
            &total_comment,
        );
    }

    sortLanguageRows(language_rows.items);
    sortContributorRows(contributor_rows.items);

    const stats_rows = try language_rows.toOwnedSlice(allocator);
    errdefer allocator.free(stats_rows);
    const contributor_slice = try contributor_rows.toOwnedSlice(allocator);
    errdefer {
        freeContributorRows(allocator, contributor_slice);
        allocator.free(contributor_slice);
    }

    const result = SourceScopeResult{
        .stats = .{
            .rows = stats_rows,
            .total_code = total_code,
            .total_test = total_test,
            .total_comment = total_comment,
        },
        .contributors = .{ .rows = contributor_slice },
    };

    if (cache_scope.commit_oid) |commit_oid| {
        storeCachedSourceScope(db, scope_path, commit_oid, result) catch {};
    }
    return result;
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
    if (std.ascii.eqlIgnoreCase(language, "zig")) return "var(--sg-color-data-8)";
    if (std.ascii.eqlIgnoreCase(language, "c")) return "var(--sg-color-data-5)";
    if (std.ascii.eqlIgnoreCase(language, "cpp")) return "var(--sg-color-data-7)";
    if (std.ascii.eqlIgnoreCase(language, "javascript")) return "var(--sg-color-data-10)";
    if (std.ascii.eqlIgnoreCase(language, "typescript")) return "var(--sg-color-data-3)";
    if (std.ascii.eqlIgnoreCase(language, "css")) return "var(--sg-color-data-5)";
    if (std.ascii.eqlIgnoreCase(language, "bash") or std.ascii.eqlIgnoreCase(language, "shell")) return "var(--sg-color-data-11)";
    if (std.ascii.eqlIgnoreCase(language, "markdown")) return "var(--sg-color-data-3)";
    if (std.ascii.eqlIgnoreCase(language, "python")) return "var(--sg-color-data-3)";
    if (std.ascii.eqlIgnoreCase(language, "rust")) return "var(--sg-color-data-8)";
    if (std.ascii.eqlIgnoreCase(language, "go")) return "var(--sg-color-data-2)";
    if (std.ascii.eqlIgnoreCase(language, "html")) return "var(--sg-color-data-8)";
    if (std.ascii.eqlIgnoreCase(language, "json")) return "var(--sg-color-data-5)";
    if (std.ascii.eqlIgnoreCase(language, "xml")) return "var(--sg-color-data-2)";
    if (std.ascii.eqlIgnoreCase(language, "yaml")) return "var(--sg-color-data-8)";
    if (std.ascii.eqlIgnoreCase(language, "sql")) return "var(--sg-color-data-9)";
    if (std.ascii.eqlIgnoreCase(language, "nix")) return "var(--sg-color-data-4)";
    if (std.ascii.eqlIgnoreCase(language, "tla")) return "var(--sg-color-data-5)";
    if (std.ascii.eqlIgnoreCase(language, "solidity")) return "var(--sg-color-data-8)";
    return "var(--sg-color-data-5)";
}

pub fn contributorColor(_: []const u8) []const u8 {
    return "var(--sg-color-primary)";
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

fn collectTrackedRepositoryPaths(allocator: Allocator, repo: Repo) !?[][]u8 {
    const tracked = try gitMaybe(allocator, repo, &.{ "ls-files", "-z" }, max_git_path_output) orelse return null;
    defer allocator.free(tracked);

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try appendGitPaths(allocator, &paths, &seen, tracked);
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

const FileScopeMode = enum {
    direct,
    recursive,
};

fn addStatsForFilesInScope(
    rows: *std.ArrayList(LanguageRow),
    row_index: *std.StringHashMap(usize),
    allocator: Allocator,
    repo: Repo,
    paths: []const []const u8,
    scope_path: []const u8,
    mode: FileScopeMode,
    total_code: *u64,
    total_test: *u64,
    total_comment: *u64,
) !void {
    for (paths) |path| {
        if (!pathMatchesScope(path, scope_path, mode)) continue;
        const content = readWorktreeFile(allocator, repo, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(content);

        const counts = countBlob(path, content) orelse continue;
        if (counts.total() == 0) continue;

        const language = languageForPath(path);
        try addLanguageCounts(rows, row_index, allocator, language, counts);
        total_code.* +|= counts.code;
        total_test.* +|= counts.test_count;
        total_comment.* +|= counts.comment;
    }
}

fn addContributorFilesInScope(
    language_rows: *std.ArrayList(LanguageRow),
    language_index: *std.StringHashMap(usize),
    contributor_rows: *std.ArrayList(ContributorRow),
    contributor_index: *std.StringHashMap(usize),
    allocator: Allocator,
    repo: Repo,
    paths: []const []const u8,
    scope_path: []const u8,
    mode: FileScopeMode,
    total_code: *u64,
    total_test: *u64,
    total_comment: *u64,
) !void {
    for (paths) |path| {
        if (!pathMatchesScope(path, scope_path, mode)) continue;
        const content = readWorktreeFile(allocator, repo, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(content);

        const counts = countBlob(path, content) orelse continue;
        if (counts.total() == 0) continue;

        const language = languageForPath(path);
        try addLanguageCounts(language_rows, language_index, allocator, language, counts);
        total_code.* +|= counts.code;
        total_test.* +|= counts.test_count;
        total_comment.* +|= counts.comment;

        const plugin = pluginForPath(path, language);
        const force_test = sloc_lang_plugins.isTestPath(path, plugin);
        const line_kinds = try sloc_lang_plugins.classifyFileLines(allocator, content, force_test, plugin, .{});
        defer allocator.free(line_kinds);

        const blame = gitMaybe(allocator, repo, &.{ "blame", "--incremental", "--", path }, max_git_path_output) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        } orelse continue;
        defer allocator.free(blame);

        try parseBlameIncrementalOutput(allocator, contributor_rows, contributor_index, line_kinds, blame);
    }
}

fn addStatsRows(
    rows: *std.ArrayList(LanguageRow),
    row_index: *std.StringHashMap(usize),
    allocator: Allocator,
    source_rows: []const LanguageRow,
) !void {
    for (source_rows) |row| {
        try addLanguageCounts(rows, row_index, allocator, row.language, .{
            .code = row.code,
            .test_count = row.test_count,
            .comment = row.comment,
        });
    }
}

fn addContributorRows(
    allocator: Allocator,
    rows: *std.ArrayList(ContributorRow),
    row_index: *std.StringHashMap(usize),
    source_rows: []const ContributorRow,
) !void {
    for (source_rows) |row| {
        try addContributorCounts(allocator, rows, row_index, row.name, row.email, .{
            .code = row.code,
            .test_count = row.test_count,
            .comment = row.comment,
        });
    }
}

fn sortLanguageRows(rows: []LanguageRow) void {
    std.mem.sort(LanguageRow, rows, {}, struct {
        fn lessThan(_: void, a: LanguageRow, b: LanguageRow) bool {
            if (a.total() != b.total()) return a.total() > b.total();
            return std.mem.lessThan(u8, a.language, b.language);
        }
    }.lessThan);
}

fn sortContributorRows(rows: []ContributorRow) void {
    std.mem.sort(ContributorRow, rows, {}, struct {
        fn lessThan(_: void, a: ContributorRow, b: ContributorRow) bool {
            if (a.total() != b.total()) return a.total() > b.total();
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn pathMatchesScope(path: []const u8, scope_path: []const u8, mode: FileScopeMode) bool {
    const rest = pathRestInScope(path, scope_path) orelse return false;
    if (rest.len == 0) return false;
    return switch (mode) {
        .recursive => true,
        .direct => std.mem.indexOfScalar(u8, rest, '/') == null,
    };
}

fn immediateChildScopes(allocator: Allocator, paths: []const []const u8, scope_path: []const u8) ![][]u8 {
    var scopes: std.ArrayList([]u8) = .empty;
    errdefer git.freeStringList(allocator, scopes.items);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (paths) |path| {
        const rest = pathRestInScope(path, scope_path) orelse continue;
        if (rest.len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        if (slash == 0) continue;

        const child_name = rest[0..slash];
        const child_scope = if (scope_path.len == 0)
            try allocator.dupe(u8, child_name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scope_path, child_name });
        errdefer allocator.free(child_scope);

        if (seen.contains(child_scope)) {
            allocator.free(child_scope);
            continue;
        }
        try seen.put(child_scope, {});
        try scopes.append(allocator, child_scope);
    }

    std.mem.sort([]u8, scopes.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return try scopes.toOwnedSlice(allocator);
}

fn pathRestInScope(path: []const u8, scope_path: []const u8) ?[]const u8 {
    if (scope_path.len == 0) return path;
    if (!std.mem.startsWith(u8, path, scope_path)) return null;
    if (path.len == scope_path.len) return "";
    if (path[scope_path.len] != '/') return null;
    return path[scope_path.len + 1 ..];
}

fn openSourceStatsCache(allocator: Allocator, repo: Repo) !SqliteDb {
    if (repo.gitomi_dir.len == 0) return error.CacheUnavailable;
    try std.fs.cwd().makePath(repo.gitomi_dir);
    const cache_path = try std.fs.path.join(allocator, &.{ repo.gitomi_dir, source_stats_cache_file });
    defer allocator.free(cache_path);

    var db = try SqliteDb.open(allocator, cache_path, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE, false);
    errdefer db.deinit();
    try createSourceStatsCacheSchema(&db);
    return db;
}

fn createSourceStatsCacheSchema(db: *SqliteDb) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS source_stats_scopes (
        \\  path TEXT PRIMARY KEY,
        \\  commit_oid TEXT NOT NULL,
        \\  sloc_complete INTEGER NOT NULL DEFAULT 0,
        \\  contributors_complete INTEGER NOT NULL DEFAULT 0,
        \\  updated_at INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE TABLE IF NOT EXISTS source_stats_languages (
        \\  path TEXT NOT NULL,
        \\  language TEXT NOT NULL,
        \\  code INTEGER NOT NULL,
        \\  test_count INTEGER NOT NULL,
        \\  comment INTEGER NOT NULL,
        \\  PRIMARY KEY(path, language)
        \\);
        \\CREATE TABLE IF NOT EXISTS source_stats_contributors (
        \\  path TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  email TEXT NOT NULL,
        \\  code INTEGER NOT NULL,
        \\  test_count INTEGER NOT NULL,
        \\  comment INTEGER NOT NULL,
        \\  PRIMARY KEY(path, name, email)
        \\);
    );
}

fn cacheScopeForPath(allocator: Allocator, repo: Repo, path: []const u8) !CacheScope {
    const dirty = scopeHasWorktreeChanges(allocator, repo, path) catch true;
    if (dirty) return .{ .commit_oid = null };
    return .{ .commit_oid = try lastCommitForScope(allocator, repo, path) };
}

fn scopeHasWorktreeChanges(allocator: Allocator, repo: Repo, path: []const u8) !bool {
    const raw = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "status", "--porcelain=v1", "-z" }, max_git_path_output)
    else blk: {
        const pathspec = try std.fmt.allocPrint(allocator, ":(top){s}", .{path});
        defer allocator.free(pathspec);
        break :blk try gitMaybe(allocator, repo, &.{ "status", "--porcelain=v1", "-z", "--", pathspec }, max_git_path_output);
    };
    const text = raw orelse return true;
    defer allocator.free(text);
    return text.len != 0;
}

fn lastCommitForScope(allocator: Allocator, repo: Repo, path: []const u8) !?[]u8 {
    const raw = if (path.len == 0)
        try gitMaybe(allocator, repo, &.{ "rev-parse", "--verify", "HEAD" }, max_commit_oid_output)
    else
        try gitMaybe(allocator, repo, &.{ "log", "-1", "--format=%H", "--end-of-options", "HEAD", "--", path }, max_commit_oid_output);
    const text = raw orelse return null;
    defer allocator.free(text);
    const oid = std.mem.trim(u8, text, " \t\r\n");
    if (oid.len == 0) return null;
    return try allocator.dupe(u8, oid);
}

fn loadCachedStats(allocator: Allocator, db: *SqliteDb, path: []const u8, commit_oid: []const u8) !?Stats {
    if (!(try cachedScopeComplete(db, path, commit_oid, .sloc))) return null;
    return try loadCachedStatsRows(allocator, db, path);
}

fn loadCachedSourceScope(allocator: Allocator, db: *SqliteDb, path: []const u8, commit_oid: []const u8) !?SourceScopeResult {
    if (!(try cachedScopeComplete(db, path, commit_oid, .contributors))) return null;
    var stats = try loadCachedStatsRows(allocator, db, path);
    errdefer stats.deinit(allocator);
    const contributors = try loadCachedContributorRows(allocator, db, path);
    return .{
        .stats = stats,
        .contributors = contributors,
    };
}

const CachedCompleteKind = enum {
    sloc,
    contributors,
};

fn cachedScopeComplete(db: *SqliteDb, path: []const u8, commit_oid: []const u8, kind: CachedCompleteKind) !bool {
    var stmt = try db.prepare(
        \\SELECT sloc_complete, contributors_complete
        \\FROM source_stats_scopes
        \\WHERE path = ? AND commit_oid = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);
    try stmt.bindText(2, commit_oid);
    if (!(try stmt.step())) return false;
    return switch (kind) {
        .sloc => stmt.columnInt(0) != 0,
        .contributors => stmt.columnInt(1) != 0,
    };
}

fn loadCachedStatsRows(allocator: Allocator, db: *SqliteDb, path: []const u8) !Stats {
    var rows: std.ArrayList(LanguageRow) = .empty;
    errdefer rows.deinit(allocator);

    var stmt = try db.prepare(
        \\SELECT language, code, test_count, comment
        \\FROM source_stats_languages
        \\WHERE path = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);

    var total_code: u64 = 0;
    var total_test: u64 = 0;
    var total_comment: u64 = 0;
    while (try stmt.step()) {
        const language_owned = try stmt.columnTextDup(allocator, 0);
        defer allocator.free(language_owned);
        const language = cachedLanguageId(language_owned) orelse continue;
        const code = sqliteUnsigned(stmt.columnInt64(1));
        const test_count = sqliteUnsigned(stmt.columnInt64(2));
        const comment = sqliteUnsigned(stmt.columnInt64(3));
        try rows.append(allocator, .{
            .language = language,
            .code = code,
            .test_count = test_count,
            .comment = comment,
        });
        total_code +|= code;
        total_test +|= test_count;
        total_comment +|= comment;
    }
    sortLanguageRows(rows.items);
    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .total_code = total_code,
        .total_test = total_test,
        .total_comment = total_comment,
    };
}

fn loadCachedContributorRows(allocator: Allocator, db: *SqliteDb, path: []const u8) !Contributors {
    var rows: std.ArrayList(ContributorRow) = .empty;
    errdefer {
        freeContributorRows(allocator, rows.items);
        rows.deinit(allocator);
    }

    var stmt = try db.prepare(
        \\SELECT name, email, code, test_count, comment
        \\FROM source_stats_contributors
        \\WHERE path = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);

    while (try stmt.step()) {
        const name = try stmt.columnTextDup(allocator, 0);
        errdefer allocator.free(name);
        const email = try stmt.columnTextDup(allocator, 1);
        errdefer allocator.free(email);
        try rows.append(allocator, .{
            .name = name,
            .email = email,
            .code = sqliteUnsigned(stmt.columnInt64(2)),
            .test_count = sqliteUnsigned(stmt.columnInt64(3)),
            .comment = sqliteUnsigned(stmt.columnInt64(4)),
        });
    }
    sortContributorRows(rows.items);
    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

fn storeCachedStats(db: *SqliteDb, path: []const u8, commit_oid: []const u8, stats: Stats) !void {
    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    const keep_contributors = try cachedScopeComplete(db, path, commit_oid, .contributors);
    try replaceCachedStatsRows(db, path, stats);
    if (!keep_contributors) try deleteCachedContributorRows(db, path);
    try upsertCachedScope(db, path, commit_oid, true, keep_contributors);
    try db.exec("COMMIT");
    committed = true;
}

fn storeCachedSourceScope(db: *SqliteDb, path: []const u8, commit_oid: []const u8, result: SourceScopeResult) !void {
    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    try replaceCachedStatsRows(db, path, result.stats);
    try replaceCachedContributorRows(db, path, result.contributors);
    try upsertCachedScope(db, path, commit_oid, true, true);
    try db.exec("COMMIT");
    committed = true;
}

fn replaceCachedStatsRows(db: *SqliteDb, path: []const u8, stats: Stats) !void {
    var delete_stmt = try db.prepare("DELETE FROM source_stats_languages WHERE path = ?");
    defer delete_stmt.deinit();
    try delete_stmt.bindText(1, path);
    try delete_stmt.stepDone();

    var insert_stmt = try db.prepare(
        \\INSERT INTO source_stats_languages(path, language, code, test_count, comment)
        \\VALUES (?, ?, ?, ?, ?)
    );
    defer insert_stmt.deinit();
    for (stats.rows) |row| {
        try insert_stmt.reset();
        try insert_stmt.bindText(1, path);
        try insert_stmt.bindText(2, row.language);
        try insert_stmt.bindInt64(3, sqliteCount(row.code));
        try insert_stmt.bindInt64(4, sqliteCount(row.test_count));
        try insert_stmt.bindInt64(5, sqliteCount(row.comment));
        try insert_stmt.stepDone();
    }
}

fn replaceCachedContributorRows(db: *SqliteDb, path: []const u8, contributors: Contributors) !void {
    try deleteCachedContributorRows(db, path);

    var insert_stmt = try db.prepare(
        \\INSERT INTO source_stats_contributors(path, name, email, code, test_count, comment)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer insert_stmt.deinit();
    for (contributors.rows) |row| {
        try insert_stmt.reset();
        try insert_stmt.bindText(1, path);
        try insert_stmt.bindText(2, row.name);
        try insert_stmt.bindText(3, row.email);
        try insert_stmt.bindInt64(4, sqliteCount(row.code));
        try insert_stmt.bindInt64(5, sqliteCount(row.test_count));
        try insert_stmt.bindInt64(6, sqliteCount(row.comment));
        try insert_stmt.stepDone();
    }
}

fn deleteCachedContributorRows(db: *SqliteDb, path: []const u8) !void {
    var delete_stmt = try db.prepare("DELETE FROM source_stats_contributors WHERE path = ?");
    defer delete_stmt.deinit();
    try delete_stmt.bindText(1, path);
    try delete_stmt.stepDone();
}

fn upsertCachedScope(db: *SqliteDb, path: []const u8, commit_oid: []const u8, sloc_complete: bool, contributors_complete: bool) !void {
    var stmt = try db.prepare(
        \\INSERT INTO source_stats_scopes(path, commit_oid, sloc_complete, contributors_complete, updated_at)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(path) DO UPDATE SET
        \\  commit_oid = excluded.commit_oid,
        \\  sloc_complete = excluded.sloc_complete,
        \\  contributors_complete = excluded.contributors_complete,
        \\  updated_at = excluded.updated_at
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);
    try stmt.bindText(2, commit_oid);
    try stmt.bindInt(3, if (sloc_complete) 1 else 0);
    try stmt.bindInt(4, if (contributors_complete) 1 else 0);
    try stmt.bindInt64(5, std.time.timestamp());
    try stmt.stepDone();
}

fn sqliteCount(value: u64) i64 {
    return if (value > @as(u64, @intCast(std.math.maxInt(i64))))
        std.math.maxInt(i64)
    else
        @intCast(value);
}

fn sqliteUnsigned(value: i64) u64 {
    return if (value <= 0) 0 else @intCast(value);
}

fn cachedLanguageId(language: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, language, "markdown")) return "markdown";
    if (std.mem.eql(u8, language, "cmake")) return "cmake";
    if (std.mem.eql(u8, language, "dockerfile")) return "dockerfile";
    if (std.mem.eql(u8, language, "makefile")) return "makefile";
    for (hljs_languages.languages) |entry| {
        if (std.mem.eql(u8, language, entry.id)) return entry.id;
    }
    return null;
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

fn freeContributorRows(allocator: Allocator, rows: []ContributorRow) void {
    for (rows) |row| {
        allocator.free(row.name);
        allocator.free(row.email);
    }
}

fn addCountsToContributor(row: *ContributorRow, counts: Counts) void {
    row.code +|= counts.code;
    row.test_count +|= counts.test_count;
    row.comment +|= counts.comment;
}

fn addContributorCounts(
    allocator: Allocator,
    rows: *std.ArrayList(ContributorRow),
    row_index: *std.StringHashMap(usize),
    raw_name: []const u8,
    raw_email: []const u8,
    counts: Counts,
) !void {
    if (counts.total() == 0) return;
    const name = if (raw_name.len == 0) "Unknown" else raw_name;
    const email = std.mem.trim(u8, raw_email, " \t\r\n<>");
    const key = if (email.len != 0) email else name;
    if (row_index.get(key)) |idx| {
        addCountsToContributor(&rows.items[idx], counts);
        return;
    }

    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const email_copy = try allocator.dupe(u8, email);
    errdefer allocator.free(email_copy);
    try rows.append(allocator, .{
        .name = name_copy,
        .email = email_copy,
        .code = counts.code,
        .test_count = counts.test_count,
        .comment = counts.comment,
    });
    errdefer _ = rows.pop();
    try row_index.put(if (email_copy.len != 0) email_copy else name_copy, rows.items.len - 1);
}

const BlameGroup = struct {
    commit: []const u8,
    result_line: usize,
    line_count: usize,
};

const BlameAuthor = struct {
    name: []const u8,
    email: []const u8,
};

fn parseBlameGroupHeader(line: []const u8) ?BlameGroup {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const commit = fields.next() orelse return null;
    const source_line_s = fields.next() orelse return null;
    const result_line_s = fields.next() orelse return null;
    const line_count_s = fields.next() orelse return null;
    if (commit.len != 40 and commit.len != 64) return null;
    for (commit) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    _ = std.fmt.parseUnsigned(usize, source_line_s, 10) catch return null;
    const result_line = std.fmt.parseUnsigned(usize, result_line_s, 10) catch return null;
    const line_count = std.fmt.parseUnsigned(usize, line_count_s, 10) catch return null;
    return .{
        .commit = commit,
        .result_line = result_line,
        .line_count = line_count,
    };
}

fn countKindsRange(kinds: []const sloc_lang_plugins.LineKind, start_line: usize, line_count: usize) Counts {
    if (start_line == 0 or line_count == 0) return .{ .code = 0, .test_count = 0, .comment = 0 };
    const start = start_line - 1;
    if (start >= kinds.len) return .{ .code = 0, .test_count = 0, .comment = 0 };
    const end = @min(kinds.len, start + line_count);

    var counts = Counts{ .code = 0, .test_count = 0, .comment = 0 };
    for (kinds[start..end]) |kind| {
        switch (kind) {
            .code => counts.code += 1,
            .test_line => counts.test_count += 1,
            .comment => counts.comment += 1,
            .blank, .skipped => {},
        }
    }
    return counts;
}

fn parseBlameIncrementalOutput(
    allocator: Allocator,
    rows: *std.ArrayList(ContributorRow),
    row_index: *std.StringHashMap(usize),
    line_kinds: []const sloc_lang_plugins.LineKind,
    blame: []const u8,
) !void {
    var commit_authors = std.StringHashMap(BlameAuthor).init(allocator);
    defer commit_authors.deinit();

    var current_group: ?BlameGroup = null;
    var current_author: ?[]const u8 = null;
    var current_email: []const u8 = "";

    var it = std.mem.splitScalar(u8, blame, '\n');
    while (it.next()) |line| {
        if (parseBlameGroupHeader(line)) |group| {
            current_group = group;
            if (commit_authors.get(group.commit)) |author| {
                current_author = author.name;
                current_email = author.email;
            } else {
                current_author = null;
                current_email = "";
            }
        } else if (std.mem.startsWith(u8, line, "author ")) {
            current_author = line["author ".len..];
            if (current_group) |group| try commit_authors.put(group.commit, .{ .name = current_author.?, .email = current_email });
        } else if (std.mem.startsWith(u8, line, "author-mail ")) {
            current_email = std.mem.trim(u8, line["author-mail ".len..], " \t\r\n<>");
            if (current_group) |group| {
                if (current_author) |author| try commit_authors.put(group.commit, .{ .name = author, .email = current_email });
            }
        } else if (std.mem.startsWith(u8, line, "filename ")) {
            if (current_group) |group| {
                const author = current_author orelse "Unknown";
                const counts = countKindsRange(line_kinds, group.result_line, group.line_count);
                try addContributorCounts(allocator, rows, row_index, author, current_email, counts);
            }
            current_group = null;
            current_author = null;
            current_email = "";
        }
    }
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

test "source stats scopes root children up to direct files" {
    const allocator = std.testing.allocator;
    const paths = [_][]const u8{
        "build.zig",
        "src/main.zig",
        "src/web/app.zig",
        "src/web/view.zig",
        "docs/readme.md",
    };

    const root_children = try immediateChildScopes(allocator, &paths, "");
    defer git.freeStringList(allocator, root_children);
    try std.testing.expectEqual(@as(usize, 2), root_children.len);
    try std.testing.expectEqualStrings("docs", root_children[0]);
    try std.testing.expectEqualStrings("src", root_children[1]);

    const src_children = try immediateChildScopes(allocator, &paths, "src");
    defer git.freeStringList(allocator, src_children);
    try std.testing.expectEqual(@as(usize, 1), src_children.len);
    try std.testing.expectEqualStrings("src/web", src_children[0]);

    try std.testing.expect(pathMatchesScope("build.zig", "", .direct));
    try std.testing.expect(!pathMatchesScope("src/main.zig", "", .direct));
    try std.testing.expect(pathMatchesScope("src/main.zig", "src", .direct));
    try std.testing.expect(!pathMatchesScope("src/web/app.zig", "src", .direct));
    try std.testing.expect(pathMatchesScope("src/web/app.zig", "src", .recursive));
}

test "source stats cached SLOC populates local sqlite cache" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/src/web");
    try writeTestFile(tmp.dir, "repo/src/main.zig",
        \\const value = 1;
        \\// comment
        \\
    );
    try writeTestFile(tmp.dir, "repo/src/web/app.zig",
        \\pub fn app() void {}
        \\
    );

    const repo_root = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_root);

    try expectGitOk(allocator, repo_root, &.{ "init", "-q" });
    try expectGitOk(allocator, repo_root, &.{ "config", "user.name", "Gitomi Test" });
    try expectGitOk(allocator, repo_root, &.{ "config", "user.email", "gitomi-test@example.invalid" });
    try expectGitOk(allocator, repo_root, &.{ "config", "commit.gpgsign", "false" });
    try expectGitOk(allocator, repo_root, &.{ "add", "src/main.zig", "src/web/app.zig" });
    try expectGitOk(allocator, repo_root, &.{ "commit", "-q", "-m", "initial" });

    const git_dir_raw = try gitCheckedAt(allocator, repo_root, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer allocator.free(git_dir_raw);
    const git_dir = std.mem.trim(u8, git_dir_raw, " \t\r\n");
    const gitomi_dir = try std.fs.path.join(allocator, &.{ git_dir, "gitomi" });
    defer allocator.free(gitomi_dir);

    var repo = Repo{
        .allocator = allocator,
        .root = try allocator.dupe(u8, repo_root),
        .git_dir = try allocator.dupe(u8, git_dir),
        .gitomi_dir = try allocator.dupe(u8, gitomi_dir),
        .config_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "config.toml" }),
        .index_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "index.sqlite" }),
        .cursors_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "cursors.sqlite" }),
        .settings_path = try std.fs.path.join(allocator, &.{ gitomi_dir, "settings.sqlite" }),
    };
    defer repo.deinit();

    var stats = (try loadRepositoryStatsCached(allocator, repo)).?;
    defer stats.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), stats.total_code);
    try std.testing.expectEqual(@as(u64, 1), stats.total_comment);

    var db = try openSourceStatsCache(allocator, repo);
    defer db.deinit();
    var stmt = try db.prepare("SELECT sloc_complete, contributors_complete FROM source_stats_scopes WHERE path = ''");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(c_int, 1), stmt.columnInt(0));
    try std.testing.expectEqual(@as(c_int, 0), stmt.columnInt(1));
}

test "source stats aggregates contributor blame ranges by counted line kind" {
    const allocator = std.testing.allocator;
    const kinds = [_]sloc_lang_plugins.LineKind{ .comment, .code, .test_line, .blank };
    const blame =
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 2
        \\author Alice
        \\filename src/main.zig
        \\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 3 3 2
        \\author Bob
        \\filename src/main.zig
        \\
    ;

    var rows: std.ArrayList(ContributorRow) = .empty;
    defer {
        freeContributorRows(allocator, rows.items);
        rows.deinit(allocator);
    }
    var row_index = std.StringHashMap(usize).init(allocator);
    defer row_index.deinit();

    try parseBlameIncrementalOutput(allocator, &rows, &row_index, &kinds, blame);

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("Alice", rows.items[0].name);
    try std.testing.expectEqual(@as(u64, 1), rows.items[0].code);
    try std.testing.expectEqual(@as(u64, 0), rows.items[0].test_count);
    try std.testing.expectEqual(@as(u64, 1), rows.items[0].comment);
    try std.testing.expectEqualStrings("Bob", rows.items[1].name);
    try std.testing.expectEqual(@as(u64, 0), rows.items[1].code);
    try std.testing.expectEqual(@as(u64, 1), rows.items[1].test_count);
    try std.testing.expectEqual(@as(u64, 0), rows.items[1].comment);
}

fn writeTestFile(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn expectGitOk(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    const output = try gitCheckedAt(allocator, root, args);
    allocator.free(output);
}

fn gitCheckedAt(allocator: Allocator, root: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root);
    for (args) |arg| try argv.append(allocator, arg);

    var result = try git.runCommand(allocator, argv.items, null, git.max_git_output);
    if (result.exitCode() == 0) {
        const stdout = result.stdout;
        allocator.free(result.stderr);
        return stdout;
    }
    result.deinit();
    return error.GitCommandFailed;
}
