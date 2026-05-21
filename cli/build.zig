const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_dep = b.dependency("sqlite", .{});
    const tree_sitter = treeSitterConfig(b);
    const package_version = packageVersion(b);
    const executable_version = std.SemanticVersion.parse(package_version) catch |err| {
        std.debug.panic("invalid build.zig.zon version '{s}': {s}", .{ package_version, @errorName(err) });
    };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package_version);

    const mod = createMainModule(b, target, optimize, build_options, sqlite_dep, tree_sitter);

    const exe = b.addExecutable(.{
        .name = "gt",
        .root_module = mod,
        .version = executable_version,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run gt").dependOn(&run_cmd.step);

    const test_mod = createMainModule(b, target, optimize, build_options, sqlite_dep, tree_sitter);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const unit_test_step = b.step("unit-test", "Run unit tests");
    unit_test_step.dependOn(&run_tests.step);

    const integration = b.addSystemCommand(&.{"bash"});
    integration.addFileArg(b.path("tests/integration.sh"));
    integration.addArtifactArg(exe);

    const integration_step = b.step("integration-test", "Run integration tests with real Git repositories");
    integration_step.dependOn(&integration.step);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&integration.step);
}

fn createMainModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    sqlite_dep: *std.Build.Dependency,
    tree_sitter: TreeSitterConfig,
) *std.Build.Module {
    const compat_mod = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("compat", compat_mod);
    mod.addOptions("build_options", build_options);
    addSqlite(mod, sqlite_dep);
    addTreeSitter(mod, tree_sitter);
    return mod;
}

fn addSqlite(module: *std.Build.Module, sqlite_dep: *std.Build.Dependency) void {
    module.addIncludePath(sqlite_dep.path(""));
    module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    module.addCSourceFile(.{
        .file = .{ .src_path = .{ .owner = module.owner, .sub_path = "src/index/sqlite_helpers.c" } },
        .flags = &.{},
    });
}

const TreeSitterConfig = struct {
    prefix: []const u8,
    zig_src: []const u8,
};

fn treeSitterConfig(b: *std.Build) TreeSitterConfig {
    const prefix = b.option([]const u8, "tree-sitter-prefix", "Path to the Tree-sitter package prefix") orelse
        b.graph.environ_map.get("TREE_SITTER_PREFIX") orelse
        @panic("missing Tree-sitter prefix; enter the flake dev shell or pass -Dtree-sitter-prefix=/path/to/tree-sitter");
    const zig_src = b.option([]const u8, "tree-sitter-zig-src", "Path to the tree-sitter-zig source checkout") orelse
        b.graph.environ_map.get("TREE_SITTER_ZIG_SRC") orelse
        @panic("missing tree-sitter-zig source; enter the flake dev shell or pass -Dtree-sitter-zig-src=/path/to/tree-sitter-zig");
    return .{ .prefix = prefix, .zig_src = zig_src };
}

fn addTreeSitter(module: *std.Build.Module, config: TreeSitterConfig) void {
    const b = module.owner;
    const tree_sitter_include = b.pathJoin(&.{ config.prefix, "include" });
    const tree_sitter_lib = b.pathJoin(&.{ config.prefix, "lib" });
    const tree_sitter_zig_src = b.pathJoin(&.{ config.zig_src, "src" });

    module.linkSystemLibrary("tree-sitter", .{});
    module.addIncludePath(.{ .cwd_relative = tree_sitter_include });
    module.addLibraryPath(.{ .cwd_relative = tree_sitter_lib });
    module.addRPath(.{ .cwd_relative = tree_sitter_lib });
    module.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ tree_sitter_zig_src, "parser.c" }) },
        .flags = &.{"-std=c11"},
    });
    module.addIncludePath(.{ .cwd_relative = tree_sitter_zig_src });
}

fn packageVersion(b: *std.Build) []const u8 {
    _ = b;
    const manifest = @import("build.zig.zon");
    return manifest.version;
}
