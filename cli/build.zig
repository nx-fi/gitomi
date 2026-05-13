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
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
}
