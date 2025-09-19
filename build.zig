const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // Prepare praxis module
    const praxis = b.dependency("praxis", .{ .target = target, .optimize = optimize });
    const praxis_module = praxis.module("praxis");

    const plutosvg = b.dependency("plutosvg", .{ .target = target, .optimize = optimize });
    const plutosvg_module = plutosvg.module("plutosvg");

    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const zigimg_module = zigimg.module("zigimg");

    const zstbi = b.dependency("zstbi", .{ .target = target, .optimize = optimize });
    const zstbi_module = zstbi.module("root");
    add_imports(b, &target, zstbi_module);

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });

    const lib_mod = b.addModule("resources", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("praxis", praxis_module);
    lib_mod.addImport("plutosvg", plutosvg_module);
    lib_mod.addImport("zigimg", zigimg_module);
    lib_mod.addImport("zstbi", zstbi_module);
    lib_mod.addImport("Normalize", zg.module("Normalize"));

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "resources",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    tests.root_module.addImport("praxis", praxis_module);
    tests.root_module.addImport("plutosvg", zigimg_module);
    tests.root_module.addImport("zigimg", zigimg_module);
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
            const sdk = std.zig.system.darwin.getSdk(b.allocator, target.result) orelse
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
            const sdk = std.zig.system.darwin.getSdk(b.allocator, target.result) orelse
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
            if (FindNDK.find(b.allocator)) |android_ndk| {
                const ndk_location = android_ndk.realpathAlloc(b.allocator, ".") catch {
                    @panic("printing ndk path failed");
                };
                defer b.allocator.free(ndk_location);
                lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                    ndk_location,
                    "toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/",
                }) });
                lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                    ndk_location,
                    "toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/aarch64-linux-android/",
                }) });
            } else {
                @panic("android/linux build requires ndk. Set ANDROID_NDK_HOME");
            }
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

const FindNDK = struct {
    const ndk_versions = [_][]const u8{
        "29.0.13846066", // Pre-release
        "28.2.13676358", // Stable
        "27.3.13750724", // LTS
        "27.0.12077973",
        "25.1.8937393",
        "23.2.8568313",
        "23.1.7779620",
        "21.0.6113669",
        "20.1.5948944",
    };

    pub fn find(gpa: std.mem.Allocator) ?std.fs.Dir {
        const android_ndk_home = find_android_ndk_home(gpa) catch |e| {
            std.log.err("error while searching for ndk: {any}", .{e});
            return null;
        };
        if (android_ndk_home != null) return android_ndk_home.?;

        const android_sdk_root = find_android_sdk_root(gpa) catch |e| {
            std.log.err("error while searching for sdk: {any}", .{e});
            return null;
        };
        if (android_sdk_root != null) {
            if (android_sdk_root.?.openDir("ndk", .{})) |dir| {
                std.log.debug("searching inside ANDROID_SDK_ROOT/ndk", .{});
                const found = search_ndk_folder(gpa, dir);
                if (found != null) return found.?;
            } else |_| {
                std.log.debug("no ndk in ANDROID_SDK_ROOT", .{});
            }
        }

        const home = find_user_home(gpa) catch |e| {
            std.log.err("error while searching for ndk: {any}", .{e});
            return null;
        };
        if (home == null) {
            std.log.err("ndk not found. No HOME or USERPROFILE set.", .{});
            return null;
        }
        const ndk_base = home.?.openDir("Library/Android/sdk/ndk/", .{}) catch |e| {
            std.log.err("ndk not found. Error {any} reading HOME/Library/Android/sdk/ndk/", .{e});
            return null;
        };
        return search_ndk_folder(gpa, ndk_base);
    }

    pub fn search_ndk_folder(_: std.mem.Allocator, ndk_base: std.fs.Dir) ?std.fs.Dir {
        for (ndk_versions) |version| {
            const folder = ndk_base.openDir(version, .{}) catch {
                std.log.debug("ndk version {s} not found", .{version});
                continue;
            };
            std.log.debug("ndk version found: {any}", .{folder});
            return folder;
        }
        return null;
    }

    /// If ANDROID_NDK_HOME is set, just use that
    pub fn find_android_ndk_home(gpa: std.mem.Allocator) !?std.fs.Dir {
        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        var iter = env_map.iterator();
        var home: ?[]const u8 = null;
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase("ANDROID_NDK_HOME", entry.key_ptr.*)) {
                home = entry.value_ptr.*;
                break;
            }
        }
        if (home == null) {
            std.log.warn("ANDROID_NDK_HOME not set.", .{});
            return null;
        }
        const d = std.fs.openDirAbsolute(home.?, .{}) catch {
            std.log.warn("Failed to read ANDROID_NDK_HOME directory {any}", .{home.?});
            return null;
        };
        return d;
    }

    /// If ANDROID_SDK_ROOT is set, just use that
    pub fn find_android_sdk_root(gpa: std.mem.Allocator) !?std.fs.Dir {
        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        var iter = env_map.iterator();
        var home: ?[]const u8 = null;
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase("ANDROID_SDK_ROOT", entry.key_ptr.*)) {
                home = entry.value_ptr.*;
                break;
            }
        }
        if (home == null) {
            std.log.info("ANDROID_SDK_ROOT not set.", .{});
            return null;
        }
        const d = std.fs.openDirAbsolute(home.?, .{}) catch {
            std.log.warn("Failed to read ANDROID_SDK_ROOT directory {any}", .{home.?});
            return null;
        };
        return d;
    }

    /// Sometimes, the NDK is in the users home folder
    pub fn find_user_home(gpa: std.mem.Allocator) !?std.fs.Dir {
        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        var iter = env_map.iterator();
        var home: ?[]const u8 = null;
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase("HOME", entry.key_ptr.*))
                home = entry.value_ptr.*;
            if (std.ascii.eqlIgnoreCase("UserProfile", entry.key_ptr.*))
                home = entry.value_ptr.*;
        }
        if (home != null) {
            const d = std.fs.openDirAbsolute(home.?, .{}) catch {
                std.log.warn("Failed to read directory {any}", .{home.?});
                return null;
            };
            return d;
        }
        return null;
    }
};
