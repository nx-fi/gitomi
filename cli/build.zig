const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_dep = b.dependency("sqlite", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(mod, sqlite_dep);
    addTreeSitter(mod, b);

    const exe = b.addExecutable(.{
        .name = "gt",
        .root_module = mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run gt").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(test_mod, sqlite_dep);
    addTreeSitter(test_mod, b);
    const tests = b.addTest(.{ .root_module = test_mod });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);

    const integration = b.addSystemCommand(&.{"bash"});
    integration.addFileArg(b.path("tests/integration.sh"));
    integration.addArtifactArg(exe);

    const integration_step = b.step("integration-test", "Run integration tests with real Git repositories");
    integration_step.dependOn(&integration.step);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&integration.step);
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

fn addTreeSitter(module: *std.Build.Module, b: *std.Build) void {
    module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE", "-D_BSD_SOURCE", "-D_DARWIN_C_SOURCE" },
    });
    module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-zig/src/parser.c"),
        .flags = &.{"-std=c11"},
    });

    module.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    module.addIncludePath(b.path("vendor/tree-sitter/lib/src"));
    module.addIncludePath(b.path("vendor/tree-sitter/lib/src/wasm"));
    module.addIncludePath(b.path("vendor/tree-sitter-zig/src"));
}
