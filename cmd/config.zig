const config_file = ".resources.conf";

/// Configuration information for the resources command line tool. Place a
/// file named `.resources.conf` into the zig project folder, or into your
/// $HOME or %USERPROFILE% folder.
///
///    {
///        "repo":          "/Volumes/drive/myapp/data/repo/",
///        "repo_cache":    "/Volumes/drive/myapp/data/repo_cache/",
///    }
///
pub const Config = struct {
    repo: []const u8,
    repo_cache: []const u8,

    parsed: std.json.Parsed(Info),

    const Info = struct {
        repo: []const u8,
        repo_cache: []const u8,
    };

    // Load the contents of the app config file. By default this will search
    // the `cwd`, `HOME`, then `USERPROFILE`. Specify the `override_path` to
    // search in only one specific custom local folder.
    pub fn init(
        allocator: Allocator,
        io: std.Io,
        env: *std.process.Environ.Map,
        override_path: ?[]const u8,
    ) error{ OutOfMemory, InvalidConfigJson, OverrideConfigPathNotFound, ErrorReadingConfigFile }!Config {
        var dir = std.Io.Dir.cwd();

        if (override_path != null and override_path.?.len > 0) {
            dir = dir.openDir(io, override_path.?, .{}) catch {
                log.err("No config in {s}.", .{override_path.?});
                return error.OverrideConfigPathNotFound;
            };
            _ = dir.openFile(io, config_file, .{}) catch {
                log.err("No config in {s}.", .{override_path.?});
                return error.OverrideConfigPathNotFound;
            };
        } else {
            if (env.get("HOME")) |home| {
                if (dir.openDir(io, home, .{})) |d| {
                    dir = d;
                } else |_| {}
            } else if (env.get("USERPROFILE")) |home| {
                if (dir.openDir(io, home, .{})) |d| {
                    dir = d;
                } else |_| {}
            }
        }

        const f = dir.openFile(io, config_file, .{}) catch {
            log.err("No config in $HOME or %USERPROFILE% or current folder.", .{});
            return error.ErrorReadingConfigFile;
        };
        defer f.close(io);

        // Read the file contents. Up to 10k sized file.
        const data = dir.readFileAlloc(io, config_file, allocator, .unlimited) catch {
            log.err("Error reading config file.", .{});
            return error.ErrorReadingConfigFile;
        };
        defer allocator.free(data);
        return loadTextConfig(allocator, data);
    }

    fn loadTextConfig(
        allocator: Allocator,
        data: []const u8,
    ) error{ErrorReadingConfigFile}!Config {
        // Parse fields
        const parsed = std.json.parseFromSlice(Info, allocator, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |e| {
            if (e == error.MissingField) {
                std.log.err("Error reading {s}. {any}", .{ config_file, e });
            }
            return error.ErrorReadingConfigFile;
        };

        return Config{
            .parsed = parsed,
            .repo = parsed.value.repo,
            .repo_cache = parsed.value.repo_cache,
        };
    }

    pub fn deinit(config: *const Config, _: Allocator) void {
        config.parsed.deinit();
    }
};

const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;
