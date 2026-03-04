/// Export any audio or picture resources needed by the quiz content.
pub fn make_resource_bundle(
    gpa: Allocator,
    io: std.Io,
    resources: *Resources,
    options: *const SaveOptions,
    config: *const Config,
    bundle_name: []const u8,
) !void {
    info("Bundling resources into {s}.", .{bundle_name});

    var manifest: std.AutoHashMapUnmanaged(u64, *const Resource) = .empty;
    var it = resources.by_uid.valueIterator();
    while (it.next()) |resource| {
        try manifest.put(gpa, resource.*.uid, resource.*);
    }

    info("Start saving bundle {s} with cache {s}.", .{ bundle_name, config.repo_cache });
    try resources.saveBundle(io, bundle_name, manifest, options, config.repo_cache);
    info("Saved bundle {s} with cache {s}.", .{ bundle_name, config.repo_cache });
}

const std = @import("std");
const info = std.log.info;
const Allocator = std.mem.Allocator;

const Resources = @import("resources").Resources;
const Resource = @import("resources").Resource;
const SaveOptions = Resources.SaveOptions;

const Config = @import("config.zig").Config;
