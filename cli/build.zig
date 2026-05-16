const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_dep = b.dependency("sqlite", .{});
    const tree_sitter_dep = b.dependency("tree_sitter", .{});
    const tree_sitter_zig_dep = b.dependency("tree_sitter_zig", .{});
    const package_version = packageVersion(b);
    const executable_version = std.SemanticVersion.parse(package_version) catch |err| {
        std.debug.panic("invalid build.zig.zon version '{s}': {s}", .{ package_version, @errorName(err) });
    };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package_version);

    const mod = createMainModule(b, target, optimize, build_options, sqlite_dep, tree_sitter_dep, tree_sitter_zig_dep);

    const exe = b.addExecutable(.{
        .name = "gt",
        .root_module = mod,
        .version = executable_version,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run gt").dependOn(&run_cmd.step);

    const test_mod = createMainModule(b, target, optimize, build_options, sqlite_dep, tree_sitter_dep, tree_sitter_zig_dep);
    const tests = b.addTest(.{ .root_module = test_mod });
    tests.linkLibC();
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
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_zig_dep: *std.Build.Dependency,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    addSqlite(mod, sqlite_dep);
    addTreeSitter(mod, tree_sitter_dep, tree_sitter_zig_dep);
    return mod;
}

fn addSqlite(module: *std.Build.Module, sqlite_dep: *std.Build.Dependency) void {
    module.addIncludePath(sqlite_dep.path(""));
    module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
}

fn addTreeSitter(
    module: *std.Build.Module,
    tree_sitter_dep: *std.Build.Dependency,
    tree_sitter_zig_dep: *std.Build.Dependency,
) void {
    module.addCSourceFile(.{
        .file = tree_sitter_dep.path("lib/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-D_BSD_SOURCE", "-D_DARWIN_C_SOURCE" },
    });
    module.addCSourceFile(.{
        .file = tree_sitter_zig_dep.path("src/parser.c"),
        .flags = &.{"-std=c11"},
    });

    module.addIncludePath(tree_sitter_dep.path("lib/include"));
    module.addIncludePath(tree_sitter_dep.path("lib/src"));
    module.addIncludePath(tree_sitter_dep.path("lib/src/wasm"));
    module.addIncludePath(tree_sitter_zig_dep.path("src"));
}

const PackageManifest = struct {
    version: []const u8,
};

fn packageVersion(b: *std.Build) []const u8 {
    const manifest = std.zon.parse.fromSlice(PackageManifest, b.allocator, @embedFile("build.zig.zon"), null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.panic("failed to parse build.zig.zon version: {s}", .{@errorName(err)});
    };
    return manifest.version;
}
