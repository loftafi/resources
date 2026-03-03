var source_dir: ?[]const u8 = null;
var source_bundle: ?[]const u8 = null;
var file_type_filter: SearchCategory = .any;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();

    // An optional -b parameter may be provided to determine where resources
    // are loaded from.
    _ = args.skip();
    var a = args.next();
    if (a != null and std.ascii.eqlIgnoreCase(a.?, "-b")) {
        a = args.next();
        if (a == null) {
            //
        } else if (std.Io.Dir.cwd().statFile(io, a.?, .{})) |stat| {
            if (stat.kind == .file)
                source_bundle = a.?;
            if (stat.kind == .directory)
                source_dir = a.?;
        } else |_| {}
        a = args.next();
    }

    // An optional -b parameter may be provided to determine where resources
    // are loaded from.
    if (a != null and std.ascii.eqlIgnoreCase(a.?, "-t")) {
        a = args.next();
        if (a == null) {
            //
        } else {
            if (std.meta.stringToEnum(SearchCategory, a.?)) |v| {
                file_type_filter = v;
            }
        }
        a = args.next();
    }

    if (a == null) {
        print("Specify a command:\n", .{});
        print("  resources add|search|bundle|help\n\n", .{});
        return;
    }

    const command = a;

    const config = try Config.init(allocator, init.io, init.environ_map, null);
    defer config.deinit(allocator);

    if (std.ascii.eqlIgnoreCase(command.?, "help") or
        std.ascii.eqlIgnoreCase(command.?, "--help") or
        std.ascii.eqlIgnoreCase(command.?, "-h"))
    {
        print("\n", .{});
        print("Add a file to a repository folder:\n", .{});
        print("\n", .{});
        print("  resources add myimage.png\n", .{});
        print("\n", .{});
        print("Search ignoring accents (unaccented) or exactly matching accents:\n", .{});
        print("\n", .{});
        print("  resources search αρτος\n", .{});
        print("  resources search unaccented αρτος\n", .{});
        print("  resources search exact ἄρτος\n", .{});
        print("  resources search partial αρτος\n", .{});
        print("\n", .{});
        print("Search inside a specific folder or bundle:\n", .{});
        print("\n", .{});
        print("  resources -b mybundle.bd search αρτος\n", .{});
        print("  resources -b myfolder/ search αρτος\n", .{});
        print("\n", .{});
        print("Search by a specific file extension or caetgory:\n", .{});
        print("\n", .{});
        print("  resources -t jpg mybundle.bd search αρτος\n", .{});
        print("  resources -t ogg mybundle.bd search αρτος\n", .{});
        print("  resources -t image mybundle.bd search αρτος\n", .{});
        print("  resources -t audio mybundle.bd search αρτος\n", .{});
        print("\n", .{});
        print("The -b flag is requred unless you create a $HOME/.resources.conf", .{});

        return;
    }

    if (std.ascii.eqlIgnoreCase(command.?, "search")) {
        var match: Match = .unaccented;
        var keyword: ?[]const u8 = null;

        // Load resource folder
        var resources = try Resources.create(init.arena.allocator());
        defer resources.destroy();

        try load_resource_set(io, resources, &config);

        if (args.next()) |arg| {
            if (std.ascii.eqlIgnoreCase("exact", arg))
                match = .exact
            else if (std.ascii.eqlIgnoreCase("unaccented", arg))
                match = .unaccented
            else if (std.ascii.eqlIgnoreCase("partial", arg))
                match = .partial
            else
                keyword = arg;
        } else {
            resdump(resources);
            return;
        }

        if (keyword == null) {
            if (args.next()) |arg| {
                keyword = arg;
            }
            if (keyword == null) {
                resdump(resources);
                //std.log.err("specify search keyword.", .{});
                return;
            }
        }

        var size: usize = 0;
        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(init.gpa);
        resources.lookup(keyword.?, file_type_filter, match, &results, init.gpa) catch |e| {
            err("Lookup resources from {s} failed. {any}", .{ config.repo, e });
            return Resources.Error.FailedReadingRepo;
        };
        for (results.items) |result| {
            var first = true;
            for (result.sentences.items) |sentence| {
                var buffer: [40:0]u8 = undefined;
                const uid = base62.encode(u64, result.uid, &buffer);
                if (std.mem.eql(u8, sentence, uid)) continue;
                if (first)
                    std.debug.print("{s: >12} {t: <4} ", .{ uid, result.resource })
                else
                    std.debug.print("                  ", .{});
                first = false;
                size += result.size;
                std.debug.print("{s}\n", .{sentence});
            }
        }
        std.debug.print("found {d} ", .{results.items.len});
        if (file_type_filter != .any)
            std.debug.print("{t} ", .{file_type_filter});
        std.debug.print("resources ({t}).", .{match});
        if (size > 0)
            std.debug.print(" size {Bi:.1}.", .{size});
        std.debug.print("\n\n", .{});
        return;
    }

    // "bundle" the resources required by the quiz file
    if (std.ascii.eqlIgnoreCase(command.?, "bundle")) {
        var bundle_name: ?[]const u8 = null;
        if (args.next()) |arg| {
            bundle_name = arg;
        }
        if (bundle_name == null) {
            std.log.err("Please specify bundle name.", .{});
            return;
        }

        // Load resource folder
        var resources = try Resources.create(init.arena.allocator());
        defer resources.destroy();

        try load_resource_set(io, resources, &config);

        const options: Options = .{
            .image = .jpg,
            .audio = .ogg,
            .max_image_size = .{ .width = 1000, .height = 1000 },
            .normalise_audio = true,
        };

        make_resource_bundle(init.gpa, io, resources, &options, &config, bundle_name.?) catch |e| {
            print("Error making resource bundle. {any}\n", .{e});
        };
        return;
    }

    print("Unknown command: {s}\n\n", .{command.?});
    print("  resources add|search|bundle|help\n\n", .{});
}

pub fn resdump(resources: *Resources) void {
    var count: usize = 0;
    var size: usize = 0;
    var i = resources.by_uid.valueIterator();
    while (i.next()) |resource| {
        if (!file_type_filter.matches(resource.*.resource)) continue;

        size += resource.*.size;
        const name = if (resource.*.sentences.items.len > 0)
            resource.*.sentences.items[0]
        else
            "";
        std.debug.print("{f: >13} {s: >12} {d:8} {t:5}  {s}\n", .{
            base62.uid_writer(u64, resource.*.uid),
            resource.*.date orelse "",
            resource.*.size,
            resource.*.resource,
            name,
        });
        count += 1;
    }
    std.debug.print("found {d} resource(s).", .{count});
    if (size > 0)
        std.debug.print(" size {Bi:.1}.", .{size});
    std.debug.print("\n\n", .{});
}

pub fn load_resource_set(io: std.Io, resources: *Resources, config: *const Config) Resources.Error!void {
    if (source_bundle != null) {
        _ = resources.loadBundle(io, source_bundle.?) catch |e| {
            err("Read resources from bundle {s} failed. {any}", .{ source_bundle.?, e });
            return Resources.Error.FailedReadingRepo;
        };
    } else if (source_dir != null) {
        _ = resources.loadDirectory(io, source_dir.?, null) catch |e| {
            err("Read resources from {s} failed. {any}", .{ source_dir.?, e });
            return Resources.Error.FailedReadingRepo;
        };
    } else {
        _ = resources.loadDirectory(io, config.repo, null) catch |e| {
            err("Read resources from {s} failed. {any}", .{ config.repo, e });
            return Resources.Error.FailedReadingRepo;
        };
    }
}

// Return the name of a file or folder otherwise read
// the name from the configuration file.
fn read_filename_parameter(
    allocator: Allocator,
    config: *const Config,
    args: *std.process.Args.Iterator,
) Allocator.Error![]const u8 {

    // If a folder appears on the command line, use it.
    if (args.next()) |value| {
        return allocator.dupe(u8, value);
    }

    var filename: ArrayListUnmanaged(u8) = .empty;
    defer filename.deinit(allocator);

    // Check the config file for the file/folder location.
    try filename.appendSlice(allocator, config.repo);
    if (filename.items[filename.items.len - 1] != '/') {
        try filename.append(allocator, '/');
    }
    try filename.appendSlice(allocator, "quiz.txt");

    return filename.toOwnedSlice(allocator);
}

fn load_resources(
    io: std.Io,
    config: *const Config,
    arena: *std.heap.ArenaAllocator,
    result: *?*Resources,
) void {
    info("Reading resources: {s}", .{config.repo});
    var resources = Resources.create(arena.*.allocator()) catch |e| {
        err("Read resources from {s} failed. {any}", .{ config.repo, e });
        return;
    };
    _ = resources.loadDirectory(io, config.repo, null) catch |e| {
        err("Read resources from {s} failed. {any}", .{ config.repo, e });
        return;
    };
    info("Read resources: {s} ({d} items)", .{ config.repo, resources.by_uid.count() });
    result.* = resources;
}

/// Read all bytes of a file into memory. Returns a result that must be freed.
fn load_file_bytes(allocator: Allocator, io: std.Io, filename: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited);
}

const std = @import("std");
const err = std.log.err;
const info = std.log.info;
const debug = std.log.debug;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const base62 = @import("resources").base62;
const Resources = @import("resources").Resources;
const Resource = @import("resources").Resource;
const SearchCategory = @import("resources").Resources.SearchCategory;
const Match = @import("resources").Match;
const Options = @import("resources").Options;

const Config = @import("config.zig").Config;

const make_resource_bundle = @import("make_resource_bundle.zig").make_resource_bundle;
