const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    //lib_unit_tests.root_module.addAnonymousImport("byz_parsing", .{
    //    .root_source_file = b.path("./test/byz-parsing.txt"),
    //});

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
