var buffer: [1024 * 10]u8 = undefined;
var ndk: ?[]const u8 = null;

/// Attempt to find the location of the NDK. Searches ANDROID_NDK_HOME,
/// ANDROID_SDK_ROOT, and standard locations inside the user home folder.
pub const FindNDK = struct {
    pub fn find(io: std.Io, env: *const std.process.Environ.Map) !?[]const u8 {
        if (ndk != null) return ndk;

        // Firstly just check ANDROID_NDK_HOME
        if (find_android_ndk_home(io, env)) |found| {
            if (found == null) {
                debug("ANDROID_NDK_HOME not set, try ANDROID_SDK_ROOT", .{});
            } else {
                ndk = found;
                return ndk;
            }
        } else |e| {
            err("error reading ANDROID_NDK_HOME: {t}", .{e});
        }

        // If ANDROID_NDK_HOME, see if we can find ndk in the ANDROID_SDK_ROOT
        if (find_android_sdk_root(io, env)) |d| {
            if (d == null) {
                debug("ANDROID_SDK_ROOT not set, try known locations.", .{});
            } else {
                debug("ANDROID_SDK_ROOT is set", .{});
                defer d.?.close(io);
                if (d.?.openDir(io, "ndk", .{})) |dir| {
                    // check for ndk inside ANDROID_SDK_ROOT
                    const found = try search_ndk_folder(io, dir);
                    if (found != null) {
                        ndk = found.?;
                        return found.?;
                    }
                } else |e| {
                    err("no ndk in ANDROID_SDK_ROOT: {t}", .{e});
                }
            }
        } else |e| {
            err("error reading ANDROID_SDK_ROOT: {t}", .{e});
        }

        // NDK not found by checking environment variables. Can we find
        // it in the user home folder?

        const home = find_user_home(io, env) catch |e| {
            err("error detecting user home folder: {t}", .{e});
            return null;
        };
        if (home == null) {
            err("ndk not found. No HOME or USERPROFILE set.", .{});
            return null;
        }
        const base = "Library/Android/sdk/ndk/";
        const ndk_base = home.?.openDir(io, base, .{}) catch |e| {
            err("ndk not found. Error {any} reading user home base={s}", .{ e, base });
            return null;
        };
        defer ndk_base.close(io);

        ndk = try search_ndk_folder(io, ndk_base);
        if (ndk) |path| {
            debug("ndk found in known location {s}", .{path});
        }
        return ndk;
    }

    fn search_ndk_folder(io: std.Io, ndk_base: std.Io.Dir) !?[]const u8 {
        for (ndk_versions) |version| {
            if (ndk_base.openDir(io, version, .{})) |d| {
                defer d.close(io);
                ndk = buffer[0..try d.realPath(io, &buffer)];
                return ndk;
            } else |_| {
                //debug("ndk version {s} not found", .{version});
                continue;
            }
        }
        return null;
    }

    /// If ANDROID_NDK_HOME is set, just use that
    fn find_android_ndk_home(
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) !?[]const u8 {
        const home = env.get("ANDROID_NDK_HOME");
        if (home == null) {
            return null;
        }
        const d = std.Io.Dir.openDirAbsolute(io, home.?, .{}) catch {
            warn("Failed to read ANDROID_NDK_HOME directory {s}", .{home.?});
            return null;
        };
        defer d.close(io);
        return buffer[0..try d.realPath(io, &buffer)];
    }

    /// If ANDROID_SDK_ROOT is set, just use that
    fn find_android_sdk_root(
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) !?std.Io.Dir {
        const home = env.get("ANDROID_SDK_ROOT");
        if (home == null) {
            return null;
        }
        const d = std.Io.Dir.openDirAbsolute(io, home.?, .{}) catch {
            warn("Failed to read ANDROID_SDK_ROOT directory {s}", .{home.?});
            return null;
        };
        return d;
    }

    /// Sometimes, the NDK is in the users home folder
    fn find_user_home(
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) !?std.Io.Dir {
        const home = env.get("HOME");
        if (home != null) {
            const d = std.Io.Dir.openDirAbsolute(io, home.?, .{}) catch {
                warn("Failed to read directory {s}", .{home.?});
                return null;
            };
            return d;
        }

        const up = env.get("UserProfile");
        if (up != null) {
            const d = std.Io.Dir.openDirAbsolute(io, up.?, .{}) catch {
                warn("Failed to read directory {s}", .{up.?});
                return null;
            };
            return d;
        }
        return null;
    }

    const ndk_versions = [_][]const u8{
        "30.0.16248370", // release
        "30.0.16138531", // rc2
        "29.0.14206865", // release
        "29.0.13846066", // rc3
        "28.2.13676358", // release
        "27.3.13750724", // release
        "27.0.12077973", // release
        "25.1.8937393",
        "23.2.8568313",
        "23.1.7779620",
        "21.0.6113669",
        "20.1.5948944",
    };
};

const std = @import("std");
const err = std.log.err;
const warn = std.log.warn;
const debug = std.log.debug;
