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
        print("usage: ", .{});
        print("resources [-b folder] [-t any] add|search|bundle|help\n\n", .{});
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
        print("Add a file to a repository:\n", .{});
        print("\n", .{});
        print("    resources add myimage.png \"Author name\" \"character sheet\"\n", .{});
        print("    resources add myimage.jpg\n", .{});
        print("\n", .{});
        print("Search ignoring accents (unaccented) or exactly matching accents:\n", .{});
        print("\n", .{});
        print("    resources search αρτος\n", .{});
        print("    resources search unaccented αρτος\n", .{});
        print("    resources search exact ἄρτος\n", .{});
        print("    resources search partial αρτος\n", .{});
        print("\n", .{});
        print("Search inside a specific folder or bundle:\n", .{});
        print("\n", .{});
        print("    resources -b mybundle.bd search αρτος\n", .{});
        print("    resources -b myfolder/ search αρτος\n", .{});
        print("\n", .{});
        print("Search by a specific file extension or caetgory:\n", .{});
        print("\n", .{});
        print("    resources -t jpg search αρτος\n", .{});
        print("    resources -t ogg search αρτος\n", .{});
        print("    resources -t image search αρτος\n", .{});
        print("    resources -t audio search αρτος\n", .{});
        print("\n", .{});
        print("The -b flag is requred unless you create a $HOME/.resources.conf:\n\n", .{});

        print("    {{\n", .{});
        print("        \"repo\":\"/path/to/repo/\",\n", .{});
        print("        \"repo_cache\":\"/path/to/repo.cache/\"\n", .{});
        print("    }}\n", .{});

        return;
    }

    if (std.ascii.eqlIgnoreCase(command.?, "search")) {
        var match: Resources.Match = .unaccented;
        var keyword: ?[]const u8 = null;

        var resources = try Resources.init(init.arena.allocator());
        defer resources.deinit(init.arena.allocator());

        try load_resource_set(init.gpa, io, &resources, &config);

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
            try resdump(init.io, &resources);
            return;
        }

        if (keyword == null) {
            if (args.next()) |arg| {
                keyword = arg;
            }
            if (keyword == null) {
                try resdump(init.io, &resources);
                //std.log.err("specify search keyword.", .{});
                return;
            }
        }

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(init.gpa);
        resources.lookup(init.gpa, keyword.?, file_type_filter, match, &results) catch |e| {
            err("Lookup resources from {s} failed. {any}", .{ config.repo, e });
            return Resources.Error.FailedReadingRepo;
        };

        try show_search_results(io, results.items, match);

        return;
    }

    // "bundle" the resources required by the quiz file
    if (std.ascii.eqlIgnoreCase(command.?, "add")) {
        try generate_uid_metadata(allocator, io, &config, &args, init.environ_map);
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

        var resources = try Resources.init(init.arena.allocator());
        defer resources.deinit(init.arena.allocator());

        try load_resource_set(init.gpa, io, &resources, &config);

        const options: SaveOptions = .{
            .image = .jpg,
            .audio = .ogg,
            .max_image_size = .{ .width = 1000, .height = 1000 },
            .normalise_audio = true,
        };

        make_resource_bundle(init.gpa, io, &resources, &options, &config, bundle_name.?) catch |e| {
            print("Error making resource bundle. {any}\n", .{e});
        };
        return;
    }

    print("Unknown command: {s}\n\n", .{command.?});
    print("usage: resources [-b directory] [-t any] add|search|bundle|help\n\n", .{});
}

pub fn resdump(io: std.Io, resources: *Resources) std.Io.Writer.Error!void {
    var write: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &write);
    defer out.flush() catch {};
    var stdout = &out.interface;

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
        try stdout.print("{f: >13} {s: >12} {d:8} {t:5}  {s}\n", .{
            base62.writer(u64, resource.*.uid),
            resource.*.date orelse "",
            resource.*.size,
            resource.*.resource,
            name,
        });
        count += 1;
    }
    try stdout.print("found {d} resource(s).", .{count});
    if (size > 0)
        try stdout.print(" size {Bi:.1}.", .{size});
    try stdout.print("\n\n", .{});
}

pub fn show_search_results(
    io: std.Io,
    results: []*Resource,
    match: ?Resources.Match,
) std.Io.Writer.Error!void {
    var size: usize = 0;

    var write: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &write);
    defer out.flush() catch {};
    var stdout = &out.interface;

    for (results) |result| {
        var first = true;
        for (result.sentences.items) |sentence| {
            var buffer: [40:0]u8 = undefined;
            const uid = base62.encode(u64, result.uid, &buffer);
            if (std.mem.eql(u8, sentence, uid)) continue;
            if (first)
                try stdout.print("{s: >12} {t: <4} ", .{ uid, result.resource })
            else
                try stdout.print("                  ", .{});
            first = false;
            size += result.size;
            try stdout.print("{s}\n", .{sentence});
        }
    }
    try stdout.print("found {d} ", .{results.len});
    if (file_type_filter != .any)
        try stdout.print("{t} ", .{file_type_filter});
    if (match != null)
        try stdout.print("resources ({t}).", .{match.?});
    if (size > 0)
        try stdout.print(" size {Bi:.1}.", .{size});
    try stdout.print("\n\n", .{});
}

pub fn load_resource_set(gpa: Allocator, io: std.Io, resources: *Resources, config: *const Config) Resources.Error!void {
    if (source_bundle != null) {
        _ = resources.loadBundle(io, source_bundle.?) catch |e| {
            err("Read resources from bundle {s} failed. {any}", .{ source_bundle.?, e });
            return Resources.Error.FailedReadingRepo;
        };
    } else if (source_dir != null) {
        _ = resources.loadDirectory(gpa, io, source_dir.?, null) catch |e| {
            err("Read resources from {s} failed. {any}", .{ source_dir.?, e });
            return Resources.Error.FailedReadingRepo;
        };
    } else {
        _ = resources.loadDirectory(gpa, io, config.repo, null) catch |e| {
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

/// Genereate a uid metadata file to place in the file repo folder described
/// in the config file.
pub fn generate_uid_metadata(
    allocator: Allocator,
    io: std.Io,
    config: *const Config,
    args: *std.process.Args.Iterator,
    env: *std.process.Environ.Map,
) !void {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();

    var source_filename: []const u8 = "";
    if (args.next()) |arg| {
        source_filename = arg;
    } else {
        print("A source filename must be specified.\n\n", .{});
        print("    resources add myimage.jpg creator description\n", .{});
        print("    resources add myimage.jpg\n", .{});
        return;
    }

    var copyright: []const u8 = "";
    if (args.next()) |arg| {
        copyright = arg;
    }

    var sentence: []const u8 = "";
    if (args.next()) |arg| {
        sentence = arg;
    }

    random.seed(io);
    var out = &buffer.writer;

    var buf: [40:0]u8 = undefined;
    var buf2: [200]u8 = undefined;

    var uid: []const u8 = "";
    var filename: []const u8 = "";
    var dir = try std.Io.Dir.openDirAbsolute(
        io,
        if (source_dir != null) source_dir.? else config.repo,
        .{},
    );
    while (true) {
        uid = base62.encode(u32, @intCast(random.random(std.math.maxInt(u32))), &buf);
        filename = try std.fmt.bufPrint(&buf2, "{s}.txt", .{uid});
        dir.access(io, filename, .{}) catch |e| switch (e) {
            error.FileNotFound => break,
            else => return e,
        };
    }

    const file_info = Resources.FilenameComponents.split(source_filename);

    const target_filename = try std.fmt.allocPrint(allocator, "{s}.{t}", .{ uid, file_info.extension });
    defer allocator.free(target_filename);

    try out.print("i:{s}\n", .{uid});
    try out.print("d:", .{});
    try timestamp(allocator, io, env, out);
    try out.print("\n", .{});
    try out.print("v:true\n", .{});
    try out.print("c:{s}\n", .{copyright});
    try out.print("s:{s}\n", .{sentence});

    var file = try dir.createFile(io, filename, .{});
    defer file.close(io);
    _ = try file.writeStreamingAll(io, buffer.written());

    std.Io.Dir.cwd().copyFile(source_filename, dir, target_filename, io, .{}) catch |e| {
        print("Failed to copy '{s}' to '{s}'. Error: {any}", .{ source_filename, target_filename, e });
        return;
    };

    print("added '{s}' to repo as '{s}' and '{s}'", .{ source_filename, filename, target_filename });
}

fn timestamp(
    allocator: Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    writer: *std.Io.Writer,
) !void {
    _ = env;
    const now = try zeit.instant(io, .{});
    const local = try zeit.local(allocator, io, .{});
    defer local.deinit();
    const now_local = now.in(&local);
    const dt = now_local.time();
    try dt.gofmt(writer, "200601021504");
}

const std = @import("std");
const err = std.log.err;
const info = std.log.info;
const debug = std.log.debug;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zeit = @import("zeit");

const base62 = @import("resources").base62;
const random = @import("resources").random;
const Resources = @import("resources").Resources;
const SaveOptions = Resources.SaveOptions;
const Resource = @import("resources").Resource;
const SearchCategory = @import("resources").Resources.SearchCategory;

const Config = @import("config.zig").Config;

const make_resource_bundle = @import("make_resource_bundle.zig").make_resource_bundle;
