const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // Prepare praxis module
    const praxis = b.dependency("praxis", .{});
    const praxis_module = praxis.module("praxis");

    const zstbi = b.dependency("zstbi", .{});
    const zstbi_module = zstbi.module("root");
    add_imports(b, &target, zstbi_module);

    const zg = b.dependency("zg", .{});

    const lib_mod = b.addModule("resources", .{
        .root_source_file = b.path("src/resources.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("praxis", praxis_module);
    lib_mod.addImport("zstbi", zstbi_module);
    lib_mod.addImport("Normalize", zg.module("Normalize"));

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
    tests.root_module.addImport("zstbi", zstbi_module);
    tests.root_module.addImport("Normalize", zg.module("Normalize"));

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

pub fn add_imports(
    b: *std.Build,
    target: *const std.Build.ResolvedTarget,
    lib: *std.Build.Module,
) void {
    // For TranslateC to work, we need the system library headers
    switch (target.result.os.tag) {
        .macos => {
            const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.host.result) orelse
                @panic("macOS SDK is missing");
            lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                sdk,
                "/usr/include",
            }) });
            lib.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{
                sdk,
                "/System/Library/Frameworks",
            }) });
        },
        .ios => {
            const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.host.result) orelse
                @panic("macOS SDK is missing");
            lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                sdk,
                "/usr/include",
            }) });
            lib.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{
                sdk,
                "/System/Library/Frameworks",
            }) });
        },
        .linux => {
            // When building for android, we need to use the android linux headers
            const android_ndk = "/Users/macuser/Library/Android/sdk/ndk/27.0.12077973/";
            lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                android_ndk,
                "toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/",
            }) });
            lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                android_ndk,
                "toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/aarch64-linux-android/",
            }) });
        },
        else => {
            std.log.debug(
                "add_imports not supported on {s}",
                .{@tagName(target.result.os.tag)},
            );
            @panic("add_imports only supports macos, ios, and linux. Please add windows support");
        },
    }
}
