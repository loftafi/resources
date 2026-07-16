/// `Resources` holds a collection of `Resource` objects. Each `Resource`
/// represents a file. `Resource` objects are loaded from a _directory_ or a
/// resource _bundle_. A `Resource` record describes not just a file, but
/// also holds metadata information such as: file creation time, url to
/// file origin, and the copyright owner.
///
/// **Development builds** use `loadDirectory` to load `Resource` files
/// from a _resource directory_.
///
/// **Release builds** use `loadBundle` to load `Resource` files
/// from a _bundle file_.
///
/// One convenient method to create a bundle is by using the following proces.
///
/// 1. During app runtime, Use `lookupRandom()` or `lookup()` to find
///    a `Resource` record, then
/// 2. use `loadResource()` to read file contents.
/// 3. `loadResource()` can be used to build an internal `used_resources`
///    list to remember all required resorces.
/// 4. use `saveBundle()` to export all `used_resources`
///    into a single bundle file.
///
pub const Resources = @This();

/// Lookup `Resource` by UID.
by_uid: std.AutoHashMapUnmanaged(u64, *Resource),

/// Lookup `Resource` by the exact sentence string found in an `s:` field
/// in the metadata, or the the original name of the file if placed in
/// an `s:` field.
by_sentence: SearchIndex(*Resource, lessThan),

/// Lookup `Resource` by an individual word found in sentence in
/// the file metadata.
by_word: SearchIndex(*Resource, lessThan),

/// A long living memory arena holds file metadata for the lifetime of the
/// `Resources` struct.
arena: std.heap.ArenaAllocator,

/// If `loadDirectory` was used, this is the path to the folder.
folder: []const u8 = "",

/// If `loadBundle` was used, this is the path to the bundle.
bundle_files: std.ArrayListUnmanaged([]const u8) = .empty,

/// When not null, every `Resource` loaded with `loadResource` is
/// placed into this list.
used_resources: ?std.AutoHashMapUnmanaged(u64, *const Resource),
used_resources_rwlock: std.Io.RwLock,

/// Hold a cache of resource copyright strings in a bucket.
string_bucket: StringBucket,

/// Create an empty file bundle including an internal arena allocator.
/// Follow up with either `loadDirectory()` or `loadBundle()`.
pub fn init(gpa: Allocator) (Allocator.Error)!Resources {
    return .{
        .arena = .init(gpa),
        .by_uid = .empty,
        .by_word = .empty,
        .by_sentence = .empty,
        .folder = "",
        .bundle_files = .empty,
        .used_resources = null,
        .used_resources_rwlock = .init,
        .string_bucket = .init(gpa),
    };
}

/// Cleanup the arena and any short lived objects used by this struct.
pub fn deinit(self: *Resources, _: Allocator) void {
    if (self.used_resources) |*manifest|
        manifest.deinit(self.arena.allocator());

    // Iterate over the master resource list to
    // free each resource.
    var i = self.by_uid.iterator();
    while (i.next()) |item|
        item.value_ptr.*.destroy(self.arena.allocator());

    self.by_uid.deinit(self.arena.allocator());

    // Relese the other indexes into the resources
    self.by_word.deinit(self.arena.allocator());
    self.by_sentence.deinit(self.arena.allocator());
    if (self.folder.len > 0)
        self.arena.allocator().free(self.folder);

    for (self.bundle_files.items) |item|
        self.arena.allocator().free(item);
    self.bundle_files.deinit(self.arena.allocator());

    self.string_bucket.deinit();

    self.arena.deinit();
    self.* = undefined;
}

/// Load the table of contents of a resource bundle into memory.
///
/// Adding resources is not thread safe, so `loadBundle` is not  thread safe.
pub fn loadBundle(
    self: *Resources,
    io: std.Io,
    bundle_file: []const u8,
) (Allocator.Error || std.Io.File.OpenError || Error || std.Io.Reader.Error || std.Io.Reader.Error)!void {
    random.seed(io);

    const bundle_filename: [:0]u8 = try self.arena.allocator().dupeSentinel(u8, bundle_file, 0);
    errdefer self.arena.allocator().free(bundle_filename);

    var buffer: [300:0]u8 = undefined;
    var rbuffer: [4196:0]u8 = undefined;
    const e = std.builtin.Endian.little;

    var file = try std.Io.Dir.cwd().openFile(io, bundle_filename, .{});
    defer file.close(io);
    var rb = file.reader(io, &rbuffer);
    const b1 = try rb.interface.takeInt(u8, e);
    const b2 = try rb.interface.takeInt(u8, e);
    const b3 = try rb.interface.takeInt(u8, e);
    if (b1 + 9 != b2)
        return error.InvalidBundleFile;

    if (b1 + 1 != b3)
        return error.InvalidBundleFile;

    const entries = try rb.interface.takeInt(u24, e);
    for (0..entries) |_| {
        var r = try Resource.create(self.arena.allocator());
        errdefer r.destroy(self.arena.allocator());
        const resource_type = try rb.interface.takeInt(u8, e);
        r.resource = @enumFromInt(resource_type);
        r.uid = try rb.interface.takeInt(u64, e);
        r.size = try rb.interface.takeInt(u32, e);
        r.filename = bundle_filename;
        const sentence_count = try rb.interface.takeInt(u8, e);
        for (0..sentence_count) |_| {
            const name_len: u8 = try rb.interface.takeInt(u8, e);
            try rb.interface.readSliceAll(buffer[0..name_len]);
            const text = try self.arena.allocator().dupe(u8, buffer[0..name_len]);
            try r.sentences.append(self.arena.allocator(), text);
        }
        r.bundle_offset = try rb.interface.takeInt(u64, e);

        try self.registerResource(r, null);
    }

    try self.bundle_files.append(self.arena.allocator(), bundle_filename);
}

/// Internal function that adds a newly loaded resource into the indexes.
///
///  - `r` should contain a fully loaded resource
///  - `filename` contains just the name part of a file with no extension,
///    only if the resource was loaded from a file.
///
pub fn registerResource(
    self: *Resources,
    r: *Resource,
    filename: ?[]const u8,
) error{ OutOfMemory, ReadMetadataFailed }!void {
    if (self.by_uid.contains(r.uid)) {
        err("duplicated uid={f} bundle_offset={d} filename={s}", .{
            base62.writer(u64, r.uid),
            r.bundle_offset orelse 0,
            r.filename orelse "",
        });
        r.destroy(self.arena.allocator());
        return;
    }
    try self.by_uid.put(self.arena.allocator(), r.uid, r);

    if (filename != null) {
        self.by_sentence.add(self.arena.allocator(), filename.?, r) catch |e| {
            err("error: invalid metadata in file {f} {s} {t}", .{
                base62.writer(u64, r.uid),
                filename orelse "",
                e,
            });
            return error.ReadMetadataFailed;
        };
    }

    for (r.sentences.items) |sentence| {
        if (filename != null and std.mem.eql(u8, filename.?, sentence))
            continue;
        self.by_sentence.add(self.arena.allocator(), sentence, r) catch |e| {
            err("invalid metadata in resource {f}. bundle_offset={d} filename={s} Error: {any}\n", .{
                base62.writer(u64, r.uid),
                r.bundle_offset orelse 0,
                r.filename orelse "",
                e,
            });
            return error.ReadMetadataFailed;
        };
    }

    // Insert the resource UID as the last sentence, so that we can search
    // by UID. Insert last so that it is never the first sentence displayed
    // in the UI.
    var buffer: [40:0]u8 = undefined;
    const uid_string = base62.encode(u64, r.uid, &buffer);
    self.by_sentence.add(self.arena.allocator(), uid_string, r) catch |e| {
        err("Error adding resource {f} uid sentence. bundle_offset={d} filename={s} Error: {any}\n", .{
            base62.writer(u64, r.uid),
            r.bundle_offset orelse 0,
            r.filename orelse "",
            e,
        });
        return error.ReadMetadataFailed;
    };

    var unique = UniqueWords.init(self.arena.allocator());
    defer unique.deinit();
    unique.addArray(&r.sentences.items) catch |f| {
        err("invalid sentence content. Resource: {f} Error: {any}", .{
            base62.writer(u64, r.uid),
            f,
        });
        return error.ReadMetadataFailed;
    };
    var it = unique.words.iterator();
    while (it.next()) |word| {
        if (word.key_ptr.*.len > 0) {
            self.by_word.add(self.arena.allocator(), word.key_ptr.*, r) catch |f| {
                err("bundle contains invalid filename. {any}", .{f});
                return error.ReadMetadataFailed;
            };
        } else {
            warn("empty sentence keyword in {f}\n", .{base62.writer(u64, r.uid)});
        }
    }
}

/// Save a `manifest` list of `Resource` files into a single data bundle
/// file along with a table of contents.
pub fn saveBundle(
    self: *Resources,
    gpa: Allocator,
    io: std.Io,
    filename: []const u8,
    resources: std.AutoHashMapUnmanaged(u64, *const Resource),
    options: *const SaveOptions,
    cache: []const u8,
) (Allocator.Error || Resources.Error || std.Io.File.OpenError ||
    std.Io.Writer.Error || std.Io.Writer.Error || std.Io.Reader.Error ||
    std.Io.File.SeekError || std.Io.Reader.Error || std.Io.Writer.Error ||
    std.Io.File.Writer.Error || std.Io.Dir.OpenError || std.Io.Dir.RenameError ||
    std.Io.File.StatError || std.Io.Reader.LimitedAllocError ||
    std.Io.File.Reader.Error || error{FfmpegFailure} || Wav.Error)!void {
    random.seed(io);

    const cache_dir = std.Io.Dir.openDirAbsolute(io, cache, .{ .iterate = false }) catch |f| {
        err("Failed to access cache folder: {s} {any}", .{ cache, f });
        return f;
    };

    // Step 1: Build the table of contents
    var header_items: ArrayListUnmanaged(BundleResource) = .empty;
    defer header_items.deinit(gpa);

    var header_size: usize = 1 + 1 + 1 + 3; // Count the header size
    var file_index: usize = 0; // Count the file index position (after header)
    var buff: [40:0]u8 = undefined;
    var buff2: [100]u8 = undefined; // uid length plus file extension

    var iterator = resources.valueIterator();
    while (iterator.next()) |r| {
        const resource: *const Resource = r.*;
        const uid = base62.encode(u64, resource.uid, &buff);

        if (header_contains(header_items.items, resource.uid)) {
            debug("Skipping duplicated resource: uid={s}", .{uid});
            continue;
        }

        if (resource.visible == false) {
            debug("Skipping non visible resource: uid={s}", .{uid});
            continue;
        }

        if (resource.filename == null) {
            err("Resource object missing filename: {s}. Resource probably lives in a bundle.", .{uid});
            continue;
        }

        const file = std.Io.Dir.cwd().openFile(io, resource.filename.?, .{ .mode = .read_only }) catch |e| {
            err("Repo file missing: {s}", .{uid});
            return e;
        };
        defer file.close(io);

        var add_size: usize = 0;
        var add_type = resource.resource;
        var add_cache = false;

        //std.log.info("output file: {s} size={d}", .{ uid, size });

        const stat = try file.stat(io);
        if (options.preserveResource(resource.uid)) {
            add_size = stat.size;
        } else if (resource.resource == .wav and options.audio == .ogg) {
            const name = try std.fmt.bufPrint(&buff2, "{s}.ogg", .{uid});
            //debug("check cache for: {s}", .{name});
            if (try cache_has_file(io, cache_dir, name)) |cache_size| {
                add_size = cache_size;
            } else {
                std.log.info("generating ogg for {s} wav. {s} normalised={any}", .{ name, uid, options.normalise_audio });
                const processed = generate_ogg_audio(gpa, io, resource, self, options) catch |f| {
                    err("generate_ogg_audio_failed. {any} Skipping {s}. {s}", .{ f, uid, resource.filename.? });
                    continue;
                };
                std.log.info("generated ogg for {s} size={Bi:.2}", .{ name, processed.len });
                defer gpa.free(processed);
                try write_folder_file_bytes(io, cache_dir, name, processed);
                add_size = processed.len;
            }
            add_cache = true;
            add_type = .ogg;
        } else if ((resource.resource == .jpg or resource.resource == .png) and options.image == .jpg) {
            const name = try std.fmt.bufPrint(&buff2, "{s}.jpg", .{uid});
            //debug("check cache for: {s}", .{name});
            if (try cache_has_file(io, cache_dir, name)) |cache_size| {
                add_size = cache_size;
            } else {
                const processed = exportImage(
                    gpa,
                    io,
                    resource,
                    self,
                    .{ .width = 800, .height = 800 },
                    .fill,
                    .jpg,
                ) catch |f| {
                    err("exportImage. {any}  {s}", .{ f, uid });
                    continue;
                };
                defer gpa.free(processed);
                debug("generated jpg {s} for {t} ({d} to {d} bytes)", .{ filename, resource.resource, add_size, processed.len });
                try write_folder_file_bytes(io, cache_dir, name, processed);
                add_size = processed.len;
            }
            add_cache = true;
            add_type = .jpg;
        } else if ((resource.resource == .jpg or resource.resource == .png) and options.image == .large_to_jpg and stat.size > large_image_max_size) {
            const name = try std.fmt.bufPrint(&buff2, "{s}.jpg", .{uid});
            //debug("check cache for: {s}", .{name});
            if (try cache_has_file(io, cache_dir, name)) |cache_size| {
                add_size = cache_size;
            } else {
                const processed = exportImage(
                    gpa,
                    io,
                    resource,
                    self,
                    .{ .width = 800, .height = 800 },
                    .fill,
                    .jpg,
                ) catch |f| {
                    err("exportImage. {any}  {s}", .{ f, uid });
                    continue;
                };
                defer gpa.free(processed);
                debug("generated jpg {s} for {t} ({d} to {d} bytes)", .{ filename, resource.resource, add_size, processed.len });
                try write_folder_file_bytes(io, cache_dir, name, processed);
                add_size = processed.len;
            }
            add_cache = true;
            add_type = .jpg;
        } else {
            add_size = stat.size;
        }

        //debug("adding file: {s} size={d} type={t}", .{ uid, add_size, add_type });

        if (add_size > 0xffffffff) {
            err("File too large to bundle: uid={s} type={t}", .{ uid, resource.resource });
            continue;
        }

        // Up to 254 sentences go into the bundle, except the UID sentence.
        var buffer: [40:0]u8 = undefined;
        const uid_string = base62.encode(u64, resource.uid, &buffer);
        var sentences: ArrayListUnmanaged([]const u8) = .empty;
        defer sentences.deinit(gpa);
        for (resource.sentences.items, 0..) |sentence, count| {
            if (std.mem.eql(u8, uid_string, sentence)) continue;
            if (count > 254) {
                err("Sentence list was shortened to 254 sentences. uid={s} type={t}", .{ uid, resource.resource });
                break;
            }
            // Sentence has a maximum length of 254 characters.
            var name = sentence;
            if (name.len > 254) {
                name = name[0..254];
                err("Sentence was shortened to 255 characters. uid={s} type={t}", .{ uid, resource.resource });
            }

            try sentences.append(gpa, name);
        }

        if (sentences.items.len == 0) {
            err("Resource has no sentences: uid={s} type={t}", .{ uid, resource.resource });
            continue;
        }

        const names = try sentences.toOwnedSlice(gpa);
        try header_items.append(gpa, .{
            .uid = resource.uid,
            .type = add_type,
            .size = @as(u32, @intCast(add_size)),
            .names = names,
            .file_index = file_index,
            .resource = resource,
            .cached = add_cache,
        });

        std.debug.assert(1 == @sizeOf(@FieldType(BundleResource, "type")));
        std.debug.assert(8 == @sizeOf(@FieldType(BundleResource, "uid")));
        std.debug.assert(4 == @sizeOf(@FieldType(BundleResource, "size")));
        std.debug.assert(8 == @sizeOf(@FieldType(BundleResource, "file_index")));

        header_size +=
            @sizeOf(@FieldType(BundleResource, "type")) +
            @sizeOf(@FieldType(BundleResource, "uid")) +
            @sizeOf(@FieldType(BundleResource, "size")) +
            @sizeOf(u8) + // Number of names/sentences
            @sizeOf(@FieldType(BundleResource, "file_index"));
        for (names) |sentence| {
            header_size += @sizeOf(u8) + sentence.len;
        }

        file_index += add_size;
    }

    // Step 2: Write the header and the contents into the bundle

    const version = 1;
    var header: ArrayListUnmanaged(u8) = .empty;
    defer header.deinit(gpa);
    const b1 = @as(u8, @intCast(random.random(230) + 10));
    try append_u8(&header, b1, gpa);
    try append_u8(&header, b1 + 9, gpa);
    try append_u8(&header, b1 + version, gpa);
    try append_u24(&header, @as(u24, @intCast(header_items.items.len)), gpa);

    // Add the table of contents
    for (header_items.items) |item| {
        try append_u8(&header, @as(u8, @intFromEnum(item.type)), gpa);
        try append_u64(&header, item.uid, gpa);
        try append_u32(&header, item.size, gpa);
        try append_u8(&header, @intCast(item.names.len), gpa);
        for (item.names) |sentence| {
            try append_u8(&header, @as(u8, @intCast(sentence.len)), gpa);
            try header.appendSlice(gpa, sentence);
        }
        gpa.free(item.names);
        try append_u64(&header, header_size + item.file_index, gpa);
    }

    const output = std.Io.Dir.cwd().createFile(io, filename, .{ .truncate = true }) catch |e| {
        err("Failed to create repo bundle file: {s} {any}", .{ filename, e });
        return e;
    };
    var buffer: [1024]u8 = undefined;
    var writer = output.writer(io, &buffer);
    try writer.interface.writeAll(header.items);

    // Add the files
    for (header_items.items) |item| {
        const uid = base62.encode(u64, item.uid, &buff);
        var data: []const u8 = &.{};
        if (item.cached) {
            const cache_name = try std.fmt.bufPrint(&buff2, "{s}.{s}", .{ uid, item.type.extension() });
            data = try load_folder_file_bytes(gpa, io, cache_dir, cache_name);
        } else {
            data = try self.loadResource(gpa, io, item.resource);
        }
        defer gpa.free(data);
        if (data.len != item.size) {
            err("Bundle index item size inconsistency: {d} != {d} (uid={s})", .{ data.len, item.size, uid });
            return error.ReadMetadataFailed;
        }

        try writer.interface.writeAll(data);
    }
    try writer.interface.flush();
}

/// Return `true` if a `uid` exists in a `BundleResource` list.
fn header_contains(items: []BundleResource, uid: u64) bool {
    for (items) |item| {
        if (item.uid == uid) return true;
    }
    return false;
}

/// Load the full list of usable files inside the `folder` along with
/// any associated metadata files so that each file can be searched for
/// and loaded.
///
/// Adding resources is not thread safe, so `loadBundle` is not  thread safe.
pub fn loadDirectory(
    self: *Resources,
    gpa: Allocator,
    io: std.Io,
    folder: []const u8,
    filter: ?*const fn (name: []const u8, type: Type) bool,
) (Error || error{
    OutOfMemory,
    Utf8InvalidStartByte,
    Utf8ExpectedContinuation,
    Utf8OverlongEncoding,
    Utf8EncodesSurrogateHalf,
    Utf8CodepointTooLarge,
} || std.Io.File.OpenError || std.Io.File.StatError || std.fmt.BufPrintError || std.Io.Cancelable)!bool {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |e| {
        log.warn("Load directory {s} failed. Error: {any}", .{ folder, e });
        return false;
    };
    defer dir.close(io);

    {
        try self.used_resources_rwlock.lock(io);
        defer self.used_resources_rwlock.unlock(io);
        if (self.used_resources == null)
            self.used_resources = .empty;
    }

    self.folder = try self.arena.allocator().dupeSentinel(u8, folder, 0);

    var filename: ArrayListUnmanaged(u8) = .empty;
    defer filename.deinit(gpa);

    var i = dir.iterate();
    while (i.next(io) catch return error.ReadRepoFileFailed) |file| {
        if (file.kind != .file) continue;

        const file_info = FilenameComponents.split(file.name);

        if (filter) |f| {
            if (f(file_info.name, file_info.extension)) {
                //err("skipping filtered file {s} ({s} {s})", .{
                //    file.name,
                //    file_info.name,
                //    @tagName(file_info.extension),
                //});
                continue;
            }
        }

        if (file_info.extension == .unknown) {
            if (!std.mem.endsWith(u8, file.name, ".txt") and !ignore_file(file.name))
                err("skipping unhandled file {s} ({s} {s})", .{
                    file.name,
                    file_info.name,
                    @tagName(file_info.extension),
                });
            continue;
        }
        //err("handled file {s} ({s} {s})", .{ file.name, file_info.name, @tagName(file_info.extension) });

        // Check the filename is nfc encoded
        const file_nfc = try Normalize.nfc(gpa, file.name);
        defer file_nfc.deinit(gpa);
        if (file.name.len != file_nfc.slice.len) {
            warn("Repo file '{s}' is not nfc ({d}:{d}). mv \"{s}\" \"{s}\"", .{
                file.name,
                file.name.len,
                file_nfc.slice.len,
                file.name,
                file_nfc.slice,
            });
        }

        filename.clearRetainingCapacity();
        try filename.appendSlice(gpa, folder);
        if (filename.items[filename.items.len - 1] != '/') {
            try filename.append(gpa, '/');
        }
        try filename.appendSlice(gpa, file.name);

        var resource = try Resource.create(self.arena.allocator());
        try resource.load(
            gpa,
            self.arena.allocator(),
            io,
            filename.items,
            file_info.name,
            file_info.extension,
            &self.string_bucket,
        );
        if (resource.uid == 0) {
            warn("Assigning random uid to file. {s}", .{file.name});
            resource.uid = try self.unique_random_u64(io);
        }

        if (!resource.visible) {
            resource.destroy(self.arena.allocator());
            continue;
        }

        try self.registerResource(resource, file_info.name);
    }

    return true;
}

/// Repeatedly generate a uid until we find a uid that does not exist
/// in the repo folder. The chance of the random uid generator conflicting
/// is low, but possible.
fn unique_random_u64(self: *Resources, io: std.Io) error{ReadMetadataFailed}!u64 {
    var retry: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(io, self.folder, .{}) catch |e| {
        log.warn("Resource loader failed opening {s}. Error: {any}", .{ self.folder, e });
        return error.ReadMetadataFailed;
    };
    defer dir.close(io);
    var ubuffer: [40:0]u8 = undefined; // 40 for UID, more for file extension
    var buffer: [50:0]u8 = undefined; // 40 for UID, more for file extension
    while (true) {
        const uid = random.random_u64();
        const uid_string = base62.encode(u64, uid, &ubuffer);
        const filename = std.fmt.bufPrint(&buffer, "{s}.txt", .{uid_string}) catch |e| {
            log.warn("unique_random_u64 has unexpected exception: {any}", .{e});
            unreachable;
        };
        _ = dir.statFile(io, filename, .{ .follow_symlinks = false }) catch |e| {
            if (e == error.FileNotFound) {
                return uid;
            }
            return error.ReadMetadataFailed;
        };
        retry += 1;
        log.warn("uid generator generated non-unique uid. retry {d}.", .{retry});
    }
}

/// Search for a resource which has a sentence that contains the
/// requested keywords. Keywords must be normalised with
/// `resources.Normalize.nfc()` if input text is not already normalised.
pub fn search(
    self: *Resources,
    keywords: []const []const u8,
    category: SearchCategory,
    buffer: []*Resource,
) error{ OutOfMemory, NormalisationFailed }![]const *Resource {
    var result_count: usize = 0;

    for (keywords) |keyword| {
        const r = try self.by_word.lookup(keyword);
        if (r == null) continue;
        for (r.?.exact_accented.items) |x| {
            if (category.matches(x.resource)) {
                appendUniqueOnly(buffer, &result_count, x);
                if (result_count == buffer.len) return buffer;
            }
        }
        if (result_count == 0) {
            for (r.?.exact_unaccented.items) |x| {
                if (category.matches(x.resource)) {
                    appendUniqueOnly(buffer, &result_count, x);
                    if (result_count == buffer.len) return buffer;
                }
            }
        }
    }
    return buffer[0..result_count];
}

/// Return all resources which _exactly_ or _partially_ match a filename or
/// sentence in the metadata file. Keywords _must_ be normalised with
/// `resources.Normalize.nfc()` if input text is not already normalised.
/// Full stops at the end of sentences. are ignored. Does not support
/// searching for a single word inside a filename, use `search()` for
/// single word keyword search.
pub fn lookup(
    self: *const Resources,
    sentence: []const u8,
    category: SearchCategory,
    match: Match,
    buffer: []*Resource,
) Error![]const *Resource {
    if (sentence.len == 0) return &.{};

    var n: Normaliser.Keywords(Normaliser.max_word_size) = undefined;
    const info = n.normalise(sentence) catch |f| {
        if (f == error.EmptyWord) return error.QueryEmpty;
        if (f == error.WordTooLong) return error.QueryTooLong;
        if (f == error.Overflow) return error.QueryTooLong;
        if (f == error.InvalidUtf8) return error.QueryEncodingError;
        if (f == error.Utf8ExpectedContinuation) return error.QueryEncodingError;
        if (f == error.Utf8OverlongEncoding) return error.QueryEncodingError;
        if (f == error.Utf8EncodesSurrogateHalf) return error.QueryEncodingError;
        if (f == error.Utf8CodepointTooLarge) return error.QueryEncodingError;
        unreachable; // unexpected error returned
    };

    const query = info.accented;
    const trimmed = trimSentence(info.accented);
    var result_count: usize = 0;

    // Lookup by exact full filename (excluding extension and prefixes)
    const search_results = try self.by_sentence.lookup(query);
    var trimmed_results: @TypeOf(search_results) = null;
    if (trimmed) |t|
        trimmed_results = try self.by_sentence.lookup(t);

    if (search_results) |r| {
        for (r.exact_accented.items) |x| {
            if (category.matches(x.resource)) {
                appendUniqueOnly(buffer, &result_count, x);
                if (result_count == buffer.len) return buffer;
            }
        }
    }

    if (trimmed_results) |tr| {
        for (tr.exact_accented.items) |x| {
            if (category.matches(x.resource)) {
                appendUniqueOnly(buffer, &result_count, x);
                if (result_count == buffer.len) return buffer;
            }
        }
    }

    if (match == .unaccented) {
        if (try self.by_sentence.lookup(info.unaccented)) |r| {
            for (r.exact_unaccented.items) |x| {
                if (category.matches(x.resource)) {
                    appendUniqueOnly(buffer, &result_count, x);
                    if (result_count == buffer.len) return buffer;
                }
            }
        }

        if (trimmed_results) |tr| {
            for (tr.exact_unaccented.items) |x| {
                if (category.matches(x.resource)) {
                    appendUniqueOnly(buffer, &result_count, x);
                    if (result_count == buffer.len) return buffer;
                }
            }
        }
    }

    if (match == .partial) {
        if (search_results) |r| {
            for (r.partial_match.items) |x| {
                if (category.matches(x.resource)) {
                    appendUniqueOnly(buffer, &result_count, x);
                    if (result_count == buffer.len) return buffer;
                }
            }
            if (result_count > 0)
                return buffer[0..result_count];
        }

        if (trimmed_results) |tr| {
            for (tr.partial_match.items) |x| {
                if (category.matches(x.resource)) {
                    appendUniqueOnly(buffer, &result_count, x);
                    if (result_count == buffer.len) return buffer;
                }
            }
            if (result_count > 0)
                return buffer[0..result_count];
        }
    }

    return buffer[0..result_count];
}

/// Return a resource where the filename or attached sentence
/// exactly matches. If more than one resources matches, return
/// one of the matches at random.
///
/// Undecided if this should be case-insensitive.
/// `sentence` _must_ be normalised with `resources.Normalize.nfc()`
/// if input text is not already normalised.
pub fn lookupRandom(
    self: *const Resources,
    sentence: []const u8,
    category: SearchCategory,
) Error!?*Resource {
    if (sentence.len == 0) {
        debug("lookupRandom() called with empty sentence.", .{});
        return null;
    }

    var buffer: [20]*Resource = undefined;
    const results = try self.lookup(sentence, category, .exact, &buffer);
    if (results.len == 0) {
        debug("lookupRandom() name='{s}' category={t} found no results.", .{
            sentence,
            category,
        });
        return null;
    }

    const choose = random.random(results.len);
    return results[choose];
}

/// Return a resource where the filename or attached sentence
/// exactly matches. If more than one resource matches, return the
/// newest record according to the metadata date. Resources without
/// a date are considered the oldest.
///
/// Undecided if this should be case-insensitive.
/// `sentence` _must_ be normalised with `resources.Normalize.nfc()`
/// if input text is not already normalised.
pub fn lookupNewest(
    self: *const Resources,
    sentence: []const u8,
    category: SearchCategory,
) Error!?*Resource {
    if (sentence.len == 0) {
        debug("lookupRandom() called with empty sentence.", .{});
        return null;
    }

    var buffer: [20]*Resource = undefined;
    const results = try self.lookup(sentence, category, .exact, &buffer);
    if (results.len == 0) {
        debug("lookupRandom() name='{s}' category={t} found no results.", .{
            sentence,
            category,
        });
        return null;
    }
    var newest: ?*Resource = null;

    for (results) |result| {
        if (newest == null) {
            newest = result;
            continue;
        }
        if (result.date == 0) continue;
        if (newest.?.date == 0) newest = result;
        if (newest.?.date < result.date) newest = result;
    }

    return newest;
}

/// Return the binary data of a resource. Depending on where the file
/// metadata was found the data is read from a directory or from a
/// resource bundle.
pub fn loadResource(
    self: *Resources,
    gpa: Allocator,
    io: std.Io,
    resource: *const Resource,
) (Resources.Error || Allocator.Error || std.Io.File.OpenError || std.Io.File.StatError || std.Io.Reader.Error || std.Io.File.SeekError || std.Io.Reader.LimitedAllocError || std.Io.Cancelable)![]const u8 {
    {
        try self.used_resources_rwlock.lock(io);
        defer self.used_resources_rwlock.unlock(io);
        if (self.used_resources) |*manifest| {
            try manifest.put(self.arena.allocator(), resource.uid, resource);
        }
    }

    // If the file was found in a resource bundle, a byte offset
    // into the bundle is available to use to load the file data.
    if (resource.bundle_offset) |bundle_offset| {
        // Resource has an offset pointer into a bundle, read the bundle.
        return try load_file_byte_slice(
            gpa,
            io,
            resource.filename.?,
            bundle_offset,
            resource.size,
        );
    }

    // If a file was loaded using `loadDirectory` the resources
    // has a filename to use to load the file data.
    if (resource.filename) |filename| {
        // Resource has a filename, read a file.
        return try load_file_bytes(gpa, io, filename);
    }

    // This should never occur.
    err("Resource has neither a filename or bundle offset.", .{});
    unreachable;
}

/// `SearchCategory` is a search filter option.
///
/// For example, `SearchCategory`.`wav` only `matches` the `wav` file type.
/// `SearchCategory`.`audio` `matches` `wav`, `ogg`, and `mp3`
pub const SearchCategory = enum {
    // All files of any type
    any,
    /// Search for any audio file type such as `wav`, `ogg`, and `mp3`.
    audio,
    /// Search for any image type, such as `jpg` and `png`.
    image,
    /// Search for any font type such as `ttf` and `otf`.
    font,
    wav,
    jpg,
    png,
    svg,
    ttf,
    otf,
    csv,
    jpx,
    xml,
    json,
    bin,
    ogg,
    mp3,
    js,

    /// Return true if this `SearchCateogry` matches a file type.
    pub fn matches(self: SearchCategory, value: Type) bool {
        return switch (self) {
            .any => true,
            .audio => value == .wav or value == .ogg or value == .mp3,
            .image => value == .png or value == .jpg,
            .font => value == .ttf or value == .otf,
            .wav => value == .wav,
            .jpg => value == .jpg,
            .png => value == .png,
            .ttf => value == .ttf,
            .otf => value == .otf,
            .csv => value == .csv,
            .jpx => value == .jpx,
            .svg => value == .svg,
            .xml => value == .xml,
            .json => value == .json,
            .bin => value == .bin,
            .ogg => value == .ogg,
            .mp3 => value == .mp3,
            .js => value == .js,
        };
    }
};

pub const Error = error{
    FailedReadingRepo,
    ReadRepoFileFailed,
    ReadMetadataFailed,
    InvalidResourceUID,
    MetadataMissing,
    FilenameTooLong,
    ResourceHasNoFilename,
    QueryTooLong,
    QueryEmpty,
    QueryEncodingError,
    InvalidBundleFile,
    BundleTooShortToExtractFile,
    UnknownImageOrientation,
    ImageConversionError,
    NormalisationFailed,
};

/// `SaveOptions` provides export configuration options to `saveBundle()`.
pub const SaveOptions = struct {
    /// Request that audio files are included as is, or request that `wav`
    audio: AudioOption = .original,
    /// Request the exact `original` image, or request conversion to `jpg`
    image: ImageOption = .original,

    /// Normalise audio files for consistent volume.
    normalise_audio: bool = false,

    /// Reduce the size of any image that is wider orhigher than this limit.
    max_image_size: Size = .{ .width = 10000, .height = 10000 },

    /// List of resources that should not be downscaled or re-encoded.
    preserve_resource: []const u64 = &.{},

    /// Request the exact `original` image, or request conversion to `jpg`
    pub const ImageOption = enum {
        /// Do not convert images to jpg.
        original,
        /// Convert images to jpg.
        jpg,
        /// Only convert large images to jpg.
        large_to_jpg,
    };

    /// Request that audio files are included as is, or request that `wav`
    /// files should be converted to `ogg` files.
    pub const AudioOption = enum {
        /// Do not process audio files.
        original,
        /// Normalise and convert `wav` files to `ogg` files.
        ogg,
    };

    pub inline fn preserveResource(self: *const SaveOptions, uid: u64) bool {
        for (self.preserve_resource) |value|
            if (uid == value)
                return true;
        return false;
    }
};

/// Used to indicate if a partial or exact search match is needed.
pub const Match = enum {
    /// Return all resources where every single word in the query string
    /// matches every single word in the resource filename/sentence in order.
    exact,

    /// All search results when a match occurs with or without accent.
    unaccented,

    /// Match when each word in the query string is found in
    /// the resource filename/sentence.
    partial,
};

/// Splits a complete filename and path into the basic name and file
/// extension components.
pub const FilenameComponents = struct {
    name: []const u8,
    extension: Type,

    /// Convert a filename with a file extension into a `name`
    /// plus `extension` enum. Any path components are removed.
    /// i.e `/etc/music.wav` becomes `.{ .name = "music" .extension = .wav}`
    pub fn split(file: []const u8) FilenameComponents {
        const ext = read_extension(file);
        if (ext.len == 0)
            return .{ .name = file, .extension = .unknown };

        const full_name = file[0 .. file.len - ext.len - 1];

        var cut = full_name.len;
        while (cut > 0) {
            if (full_name[cut - 1] == '/' or full_name[cut - 1] == '\\') break;
            cut -= 1;
        }

        return .{
            .name = full_name[cut..],
            .extension = Type.parse(ext),
        };
    }
};

/// Return the file extension or null if no file extension exists. File
/// extensions of over 6 charachters are considerd invalid and ignored.
fn read_extension(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) {
        if (end + 6 < path.len)
            break;
        if (path[end - 1] == '.')
            return path[end..];
        end -= 1;
    }
    return "";
}

inline fn appendUniqueOnly(
    buffer: []*Resource,
    count: *usize,
    resource: *Resource,
) void {
    if (count.* == buffer.len) return;
    for (0..count.*) |index| {
        if (buffer[index].uid == resource.uid) return;
    }
    buffer[count.*] = resource;
    count.* += 1;
}

/// Describes a table of contents entry in a bundle file.
const BundleResource = struct {
    uid: u64,
    size: u32,
    type: Type,
    names: []const []const u8,
    resource: *const Resource,
    cached: bool,
    file_index: usize, // Position of file inside bundle not including header size.
};

fn ignore_file(text: []const u8) bool {
    if (std.mem.eql(u8, ".gitignore", text)) return true;
    if (std.mem.eql(u8, ".DS_Store", text)) return true;
    return false;
}

test read_extension {
    try expectEqualStrings("jpg", read_extension("fish.jpg"));
    try expectEqualStrings("js", read_extension("fish.js"));
    try expectEqualStrings("", read_extension("fish"));
    try expectEqualStrings("js", read_extension("/var/info/fish.js"));
    try expectEqualStrings("", read_extension("fish.jpgabcdefg"));
}

test init {
    const gpa = std.testing.allocator;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    try expectEqual(0, resources.by_uid.count());
    try expectEqual(0, resources.bundle_files.items.len);
}

test "load_resource image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    const file = "./test/repo/GzeBWE.png";
    const info = Resources.FilenameComponents.split(file);
    var resource: Resource = .empty;
    try resource.load(
        gpa,
        gpa,
        io,
        file,
        info.name,
        info.extension,
        &resources.string_bucket,
    );
    defer resource.deinit(gpa);

    try expectEqual(3989967536, resource.uid);
    try expectEqualStrings(file, resource.filename.?);
    try expectEqual(.png, resource.resource);
    try expectEqual(true, resource.visible);
    try expectEqualStrings("jay", resource.copyright.?);
    //for (resource.sentences.items) |s| std.log.err("sentence >> {s}", .{s});
    try expectEqual(3, resource.sentences.items.len);
    try expectEqualStrings("κρέα", resource.sentences.items[0]);
    try expectEqualStrings("τὰ κρέα", resource.sentences.items[1]);
}

test "load_resource audio" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    const file = "./test/repo/jay~ἄρτος.wav";
    const info = Resources.FilenameComponents.split(file);
    try expectEqualStrings("jay~ἄρτος", info.name);
    try expectEqual(.wav, info.extension);

    var resource: Resource = .empty;
    try resource.load(
        gpa,
        gpa,
        io,
        file,
        info.name,
        info.extension,
        &resources.string_bucket,
    );
    defer resource.deinit(std.testing.allocator);

    //try expect(0 != resource.uid);
    try expectEqual(true, resource.visible);
    try expectEqual(.wav, resource.resource);
    try expectEqual(1, resource.sentences.items.len);
    try expectEqualStrings(file, resource.filename.?);
    try expectEqualStrings("ἄρτος", resource.sentences.items[0]);
}

test "search resources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    var buffer: [10]*Resource = undefined;
    var results = try resources.search(&.{"ἄγγελος"}, .any, &buffer);
    try expectEqual(0, results.len);

    // Test files have this exact string
    try expect(resources.by_sentence.index.get("ασεἄρτο") == null);
    try expect(resources.by_sentence.index.get("ἄρτος") != null);
    try expect(resources.by_sentence.index.get("μάχαιρα") != null);
    try expect(resources.by_sentence.index.get("ὁ δαυίδ λέγει") != null);

    // No test files have this exact string (only mid sentence)
    try expect(resources.by_sentence.index.get("δαυὶδ") == null);
    try expect(resources.by_sentence.index.get("δαυίδ") == null);
    try expect(resources.by_sentence.index.get("ὁ Δαυίδ λέγει") == null);
    try expect(resources.by_sentence.index.get("ὁ Δαυίδ λέγει·") == null);

    results = try resources.lookup("fewhfoihsd4565", .any, .partial, &buffer);
    try expectEqual(0, results.len);

    results = try resources.lookup("GzeBWE", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("κρέα", .any, .partial, &buffer);
    try expectEqual(2, results.len);

    // A wav file and an image file match this
    results = try resources.lookup("μάχαιρα", .any, .partial, &buffer);
    try expectEqual(2, results.len);

    results = try resources.lookup("μάχαιρα.", .any, .partial, &buffer);
    try expectEqual(2, results.len);

    results = try resources.lookup("ὁ δαυὶδ λέγει", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ὁ Δαυὶδ λέγει", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ὁ Δαυὶδ λέγει·", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ὁ Δαυὶδ λέγει·", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    // Not the start of a sentence
    results = try resources.lookup("Δαυὶδ", .any, .partial, &buffer);
    try expectEqual(0, results.len);

    results = try resources.lookup("πτωχός", .any, .partial, &buffer);
    try expectEqual(2, results.len);

    results = try resources.lookup("πτωχός.", .any, .partial, &buffer);
    try expectEqual(2, results.len);

    results = try resources.lookup("ἄρτος", .audio, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ἄρτος.", .audio, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ἄρτος;", .audio, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("ἄρτος", .image, .partial, &buffer);
    try expectEqual(0, results.len);

    results = try resources.lookup("γυναῖκας· βλέψατε!", .any, .partial, &buffer);
    try expectEqual(1, results.len);

    results = try resources.lookup("γυναῖκας· βλέψατε", .any, .partial, &buffer);
    try expectEqual(1, results.len);
}

test "ignore_not_visible" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    var buffer: [10]*Resource = undefined;

    // The bean file must be ignored
    var results = try resources.search(&.{"ὄσπρια"}, .any, &buffer);
    try expectEqual(0, results.len);
    // The bean file must not be in the set of δύο

    results = try resources.search(&.{"δύο"}, .any, &buffer);
    try expectEqual(1, results.len);
}

test "font_lookup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var buffer: [10]*Resource = undefined;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    {
        // Basic search
        var results = try resources.search(&.{"fakefont"}, .any, &buffer);
        try expectEqual(1, results.len);

        // Basic lookup
        results = try resources.lookup("fakefont", .any, .exact, &buffer);
        try expectEqual(1, results.len);

        // Filtered lookup
        var font = try resources.lookupRandom("fakefont", .any);
        try expect(font != null);
        // Filtered lookup
        font = try resources.lookupRandom("fakefont", .font);
        try expect(font != null);
        // Filtered lookup
        font = try resources.lookupRandom("fakefont", .ttf);
        try expect(font != null);
    }
}

test "lookup_newest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    {
        // Filtered lookup
        var resource = try resources.lookupNewest("edmond", .any);
        try expect(resource != null);
        try expectEqual(base62.decode(u64, "11aba"), resource.?.uid);

        // Filtered lookup
        resource = try resources.lookupNewest("edmond", .font);
        try expect(resource == null);

        // Filtered lookup
        resource = try resources.lookupNewest("edmond", .xml);
        try expect(resource != null);
        try expectEqual(base62.decode(u64, "1122"), resource.?.uid);

        // Filtered lookup
        resource = try resources.lookupNewest("edmond", .jpg);
        try expect(resource != null);
        try expectEqual(base62.decode(u64, "11aba"), resource.?.uid);
    }
}

test "file_with_full_stop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    var buffer: [10]*Resource = undefined;

    var results = try resources.search(&.{"ἐστιν"}, .any, &buffer);
    try expectEqual(1, results.len);

    results = try resources.search(&.{"ἦν"}, .any, &buffer);
    try expectEqual(1, results.len);

    results = try resources.search(&.{ "ἐστιν", "ἦν" }, .any, &buffer);
    try expectEqual(1, results.len);

    try expect(resources.by_sentence.index.get("ἐστιν. ἦν") != null);
    try expect(resources.by_word.index.get("ἦν") != null);
    try expect(resources.by_word.index.get("ἐστιν") != null);
}

test "file_name_split" {
    const info = Resources.FilenameComponents.split("fish.jpg");
    try expectEqualStrings("fish", info.name);
    try expectEqual(.jpg, info.extension);

    const info2 = Resources.FilenameComponents.split("opens.xml");
    try expectEqualStrings("opens", info2.name);
    try expectEqual(.xml, info2.extension);

    const info3 = Resources.FilenameComponents.split("/fish/hat/opens.xml");
    try expectEqualStrings("opens", info3.name);
    try expectEqual(.xml, info3.extension);

    const info4 = Resources.FilenameComponents.split("1122.xml");
    try expectEqualStrings("1122", info4.name);
    try expectEqual(.xml, info4.extension);
}

test "bundle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const TEST_BUNDLE_FILENAME: []const u8 = "/tmp/bundle.bd";
    var data1: []const u8 = "";
    var data2: []const u8 = "";
    var data1b: []const u8 = "";
    var data2b: []const u8 = "";

    {
        var resources: Resources = try .init(gpa);
        defer resources.deinit(gpa);
        _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

        try expectEqual(402, resources.by_sentence.index.count());

        var buffer: [10]*Resource = undefined;

        var results = try resources.lookup("ὁ μικρὸς οἶκος", .any, .exact, &buffer);
        try expectEqual(1, results.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results[0].uid);

        results = try resources.lookup("ὁ μικρὸς οἶκος", .png, .exact, &buffer);
        try expectEqual(1, results.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results[0].uid);

        results = try resources.lookup("ὁ μικρὸς οἶκος", .image, .exact, &buffer);
        try expectEqual(1, results.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results[0].uid);

        results = try resources.lookup("ὁ μικρὸς οἶκος", .wav, .exact, &buffer);
        try expectEqual(0, results.len);

        results = try resources.lookup("μικρὸς οἶκος", .any, .exact, &buffer);
        try expectEqual(1, results.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results[0].uid);

        results = try resources.lookup("myxml1", .any, .partial, &buffer);
        try expectEqual(1, results.len);
        try expectEqualStrings("myxml1", results[0].sentences.items[0]);
        try expectEqualStrings("my xml 1", results[0].sentences.items[1]);
        data1 = try resources.loadResource(gpa, io, results[0]);
        try expectEqual(1, resources.used_resources.?.count());

        results = try resources.lookup("myxml2", .any, .partial, &buffer);
        try expectEqual(1, results.len);
        try expectEqualStrings("myxml2", results[0].sentences.items[0]);
        try expectEqualStrings("abcd", results[0].sentences.items[1]);
        data2 = try resources.loadResource(gpa, io, results[0]);
        try expectEqual(2, resources.used_resources.?.count());

        try resources.saveBundle(
            gpa,
            io,
            TEST_BUNDLE_FILENAME,
            resources.used_resources.?,
            &.{},
            "/tmp/",
        );
    }

    defer gpa.free(data1);
    defer gpa.free(data2);

    {
        var resources: Resources = try .init(gpa);
        defer resources.deinit(gpa);
        resources.used_resources = .empty;
        try resources.loadBundle(io, TEST_BUNDLE_FILENAME);

        var buffer: [10]*Resource = undefined;

        var results = try resources.lookup("1122", .any, .partial, &buffer);
        try expectEqual(1, results.len);
        const first = results[0];

        results = try resources.lookup("2233", .any, .partial, &buffer);
        try expectEqual(1, results.len);
        const second = results[0];

        // abcd is already in the results list, so no new results should be added.
        results = try resources.lookup("abcd", .any, .partial, &buffer);
        try expectEqual(1, results.len);
        try expectEqual(second.uid, results[0].uid);

        try expectEqualStrings("myxml1", first.sentences.items[0]);
        try expectEqualStrings("myxml2", second.sentences.items[0]);
        data1b = try resources.loadResource(gpa, io, first);
        try expectEqual(1, resources.used_resources.?.count());
        data2b = try resources.loadResource(gpa, io, second);
        try expectEqual(2, resources.used_resources.?.count());

        results = try resources.lookup("1122.", .any, .partial, &buffer);
        try expectEqual(1, results.len);

        results = try resources.lookup("1122·", .any, .partial, &buffer);
        try expectEqual(1, results.len);
    }
    defer gpa.free(data1b);
    defer gpa.free(data2b);

    try expectEqualStrings(data1, data1b);
    try expectEqualStrings(data2, data2b);
}

const large_image_max_size = 50 * 1024;

const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;

const ArrayListUnmanaged = std.ArrayListUnmanaged;
const log = std.log;
const warn = std.log.warn;
const err = std.log.err;
const debug = std.log.debug;
const eql = @import("std").mem.eql;
const Allocator = std.mem.Allocator;
pub const Normalize = @import("Normalize");

pub const UniqueWords = @import("UniqueWords.zig");
pub const random = @import("random.zig");
const exportImage = @import("export_image.zig").exportImage;

pub const Resource = @import("Resource.zig");
const load_file_bytes = Resource.load_file_bytes;
const load_file_byte_slice = Resource.load_file_byte_slice;
const load_folder_file_bytes = Resource.load_folder_file_bytes;
const write_folder_file_bytes = Resource.write_folder_file_bytes;
const cache_has_file = Resource.cache_has_file;
const trimSentence = Resource.trimSentence;
const lessThan = Resource.lessThan;

pub const Type = @import("Type.zig").Type;

const Parser = @import("praxis").Parser;
const BoundedArray = @import("praxis").BoundedArray;
const SearchIndex = @import("praxis").SearchIndex;
const Normaliser = @import("praxis").Normaliser;

const generate_ogg_audio = @import("export_audio.zig").generate_ogg_audio;
const Size = @import("export_image.zig").Size;

const StringBucket = @import("StringBucket.zig");

pub const Wav = @import("Wav.zig");
pub const base62 = @import("base62.zig");

const BinaryReader = @import("binary_reader.zig");
const BinaryWriter = @import("binary_writer.zig");
const append_u64 = BinaryWriter.append_u64;
const append_u32 = BinaryWriter.append_u32;
const append_u24 = BinaryWriter.append_u24;
const append_u16 = BinaryWriter.append_u16;
const append_u8 = BinaryWriter.append_u8;
