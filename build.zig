const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // Prepare praxis module
    const praxis = b.dependency("praxis", .{});
    const praxis_module = praxis.module("praxis");

    const lib_mod = b.addModule("resources", .{
        .root_source_file = b.path("src/resources.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("praxis", praxis_module);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "resources",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const tests = b.addTest(.{
        //.root_module = lib_mod,
        .root_source_file = b.path("src/test.zig"),
        .filters = test_filters,
    });
    tests.root_module.addImport("praxis", praxis_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
