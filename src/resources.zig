//! This zig module supports collecting, searching, and bundling resources
//! into a bundle for distribution. The most common use case for this is
//! a game that wishes to pack all game reosurces into an individual bundle
//! file. Attach metadata such as copyright information and an optional link
//! to the source of the original file to make copyright and licence
//! management easier.

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
/// 1. During app runtime, Use `lookupOne()` or `lookup()` to find
///    a `Resource` record, then
/// 2. use `loadResource()` to read file contents.
/// 3. `loadResource()` can be used to build an internal `used_resources`
///    list to remember all required resorces.
/// 4. use `saveBundle()` to export all `used_resources`
///    into a single bundle file.
///
pub const Resources = struct {
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
    bundle_file: []const u8 = "",

    /// A unicode library is used to normalise words and phrases.
    normalise: ?Normalize,

    /// A simple library used to normalise Ancient Greek text.
    normaliser: Normaliser,

    /// When not null, every `Resource` loaded with `loadResource` is
    /// placed into this list.
    used_resources: ?std.AutoHashMapUnmanaged(u64, *const Resource),

    /// Create an empty file bundle including an internal arena allocator.
    /// Follow up with either `loadDirectory()` or `loadBundle()`.
    pub fn init(gpa: Allocator) (Allocator.Error)!Resources {
        return .{
            .arena = .init(gpa),
            .normalise = null,
            .by_uid = .empty,
            .by_word = .empty,
            .by_sentence = .empty,
            .normaliser = .empty,
            .folder = "",
            .bundle_file = "",
            .used_resources = null,
        };
    }

    /// Cleanup the arena and any short lived objects used by this struct.
    pub fn deinit(self: *Resources, gpa: Allocator) void {
        if (self.normalise != null)
            self.normalise.?.deinit(self.arena.allocator());

        self.normaliser.deinit(gpa);

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

        if (self.bundle_file.len > 0)
            self.arena.allocator().free(self.bundle_file);

        self.arena.deinit();
        self.* = undefined;
    }

    /// Load the table of contents of a resource bundle into memory.
    pub fn loadBundle(
        self: *Resources,
        io: std.Io,
        bundle_filename: []const u8,
    ) (Allocator.Error || std.Io.File.OpenError || Error || std.Io.Reader.Error || std.Io.Reader.Error)!void {
        random.seed(io);

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

        self.bundle_file = try self.arena.allocator().dupe(u8, bundle_filename);
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
            err("duplicated uid {any}. bundle_offset={d} filename={s}\n", .{
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
                err(
                    "error: invalid metadata in file {any} {s} {any}\n",
                    .{ r.uid, filename.?, e },
                );
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
            err("invalid sentence content. Resource: {f} Error: {any}", .{ base62.writer(u64, r.uid), f });
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
        std.Io.File.Reader.Error || error{FfmpegFailure} || wav.Error)!void {
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
            var resource: *const Resource = r.*;
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

            if (resource.resource == .wav and options.audio == .ogg) {
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
            } else {
                // TODO: remove stat, we have to load the bytes of the file anyway
                const stat = try file.stat(io);
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
    pub fn loadDirectory(
        self: *Resources,
        gpa: Allocator,
        io: std.Io,
        folder: []const u8,
        filter: ?*const fn (name: []const u8, type: FileType) bool,
    ) (Error || error{
        OutOfMemory,
        Utf8InvalidStartByte,
        Utf8ExpectedContinuation,
        Utf8OverlongEncoding,
        Utf8EncodesSurrogateHalf,
        Utf8CodepointTooLarge,
    } || std.Io.File.OpenError || std.Io.File.StatError || std.fmt.BufPrintError)!bool {
        var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |e| {
            log.warn("Load directory {s} failed. Error: {any}", .{ folder, e });
            return false;
        };
        defer dir.close(io);

        if (self.used_resources == null)
            self.used_resources = .empty;

        if (self.normalise == null)
            self.normalise = try .init(self.arena.allocator());

        self.folder = try self.arena.allocator().dupeZ(u8, folder);

        var filename: ArrayListUnmanaged(u8) = .empty;
        defer filename.deinit(gpa);

        var i = dir.iterate();
        while (i.next(io) catch return error.ReadRepoFileFailed) |file| {
            if (file.kind != .file) continue;

            const file_info = FilenameComponents.split(file.name);

            if (filter) |f| {
                if (f(file_info.name, file_info.extension)) continue;
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
            const file_nfc = try self.normalise.?.nfc(gpa, file.name);
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
                &self.normalise.?,
                filename.items,
                file_info.name,
                file_info.extension,
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
    ///  requested keywords
    pub fn search(
        self: *Resources,
        gpa: Allocator,
        keywords: []const []const u8,
        category: SearchCategory,
        results: *ArrayListUnmanaged(*Resource),
    ) !void {
        var seen: std.AutoHashMapUnmanaged(u64, *Resource) = .empty;
        defer seen.deinit(gpa);
        for (keywords) |keyword| {
            const r = try self.by_word.lookup(keyword);
            if (r == null) continue;
            for (r.?.exact_accented.items) |x| {
                if (category.matches(x.resource)) {
                    var entry = try seen.getOrPut(gpa, x.uid);
                    if (entry.found_existing) continue;
                    entry.value_ptr.* = x;
                    try results.append(gpa, x);
                }
            }
            if (results.items.len == 0) {
                for (r.?.exact_unaccented.items) |x| {
                    if (category.matches(x.resource)) {
                        var entry = try seen.getOrPut(gpa, x.uid);
                        if (entry.found_existing) continue;
                        entry.value_ptr.* = x;
                        try results.append(gpa, x);
                    }
                }
            }
        }
    }

    /// Return all resources which _exactly_ or _partially_ match a filename or
    /// sentence in the metadata file.
    /// with a resource exactly matches. Full stops at the end of sentences.
    /// are ignored. Does not support searching for a single word inside a
    /// filename, use `search()` for single word keyword search.
    pub fn lookup(
        self: *Resources,
        gpa: Allocator,
        sentence: []const u8,
        category: SearchCategory,
        match: Match,
        results: *ArrayListUnmanaged(*Resource),
    ) (error{OutOfMemory} || Error)!void {
        if (sentence.len == 0) return;

        if (self.normalise == null)
            self.normalise = try .init(self.arena.allocator());

        // Normalise to nfc and normalise the characters with index rules.
        const sentence_nfc = try self.normalise.?.nfc(gpa, sentence);
        defer sentence_nfc.deinit(gpa);

        if (sentence.len != sentence_nfc.slice.len) {
            warn("lookup expects nfc encoding.", .{});
        }

        const info = self.normaliser.normalise(sentence_nfc.slice) catch |f| {
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
        const trimmed = sentence_trim(info.accented);

        // Lookup by exact full filename (excluding extension and prefixes)
        const search_results = try self.by_sentence.lookup(query);
        var trimmed_results: @TypeOf(search_results) = null;
        if (trimmed) |t|
            trimmed_results = try self.by_sentence.lookup(t);

        if (search_results) |r| {
            for (r.exact_accented.items) |x| {
                if (category.matches(x.resource))
                    try append_if_not_found(results, gpa, x);
            }
        }

        if (trimmed_results) |tr| {
            for (tr.exact_accented.items) |x| {
                if (category.matches(x.resource))
                    try append_if_not_found(results, gpa, x);
            }
        }

        if (match == .unaccented) {
            if (try self.by_sentence.lookup(info.unaccented)) |r| {
                for (r.exact_unaccented.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, gpa, x);
                }
            }

            if (trimmed_results) |tr| {
                for (tr.exact_unaccented.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, gpa, x);
                }
            }
        }

        if (match == .partial) {
            if (search_results) |r| {
                for (r.partial_match.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, gpa, x);
                }
                if (results.items.len > 0)
                    return;
            }

            if (trimmed_results) |tr| {
                for (tr.partial_match.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, gpa, x);
                }
                if (results.items.len > 0)
                    return;
            }
        }
    }

    /// Return a resource where the filename or attached sentence
    /// exactly matches. Undecided if this should be case-insensitive.
    pub fn lookupOne(
        self: *Resources,
        gpa: Allocator,
        sentence: []const u8,
        category: SearchCategory,
    ) (error{OutOfMemory} || Error)!?*Resource {
        if (sentence.len == 0) {
            debug("lookupOne() called with empty sentence.", .{});
            return null;
        }

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(gpa);

        try self.lookup(gpa, sentence, category, .exact, &results);
        if (results.items.len == 0) {
            debug("lookupOne() name='{s}' found no results.", .{
                sentence,
            });
            return null;
        }

        const choose = random.random(results.items.len);
        return results.items[choose];
    }

    /// Return the binary data of a resource. Depending on where the file
    /// metadata was found the data is read from a directory or from a
    /// resource bundle.
    pub fn loadResource(
        self: *Resources,
        gpa: Allocator,
        io: std.Io,
        resource: *const Resource,
    ) (Resources.Error || Allocator.Error || std.Io.File.OpenError || std.Io.File.StatError || std.Io.Reader.Error || std.Io.File.SeekError || std.Io.Reader.LimitedAllocError)![]const u8 {
        if (self.used_resources) |*manifest| {
            try manifest.put(self.arena.allocator(), resource.uid, resource);
        }

        // If a file was loaded using `loadDirectory` the resources
        // has a filename to use to load the file data.
        if (resource.filename) |filename| {
            // Resource has a filename, read a file.
            return try load_file_bytes(gpa, io, filename);
        }

        // If the file was found in a resource bundle, a byte offset
        // into the bundle is available to use to load the file data.
        if (resource.bundle_offset) |bundle_offset| {
            // Resource has an offset pointer into a bundle, read the bundle.
            return try load_file_byte_slice(
                gpa,
                io,
                self.bundle_file,
                bundle_offset,
                resource.size,
            );
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
        pub fn matches(self: SearchCategory, value: FileType) bool {
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

        /// Request the exact `original` image, or request conversion to `jpg`
        pub const ImageOption = enum {
            /// Do not convert images to jpg.
            original,
            /// Convert images to jpg.
            jpg,
        };

        /// Request that audio files are included as is, or request that `wav`
        /// files should be converted to `ogg` files.
        pub const AudioOption = enum {
            /// Do not process audio files.
            original,
            /// Normalise and convert `wav` files to `ogg` files.
            ogg,
        };
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
        extension: FileType,

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
                .extension = FileType.parse(ext),
            };
        }
    };
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

inline fn append_if_not_found(
    results: *ArrayListUnmanaged(*Resource),
    gpa: Allocator,
    resource: *Resource,
) error{OutOfMemory}!void {
    for (results.items) |item| {
        if (item.uid == resource.uid) return;
    }
    try results.append(gpa, resource);
}

/// Describes a table of contents entry in a bundle file.
const BundleResource = struct {
    uid: u64,
    size: u32,
    type: FileType,
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

test "read_extension" {
    try expectEqualStrings("jpg", read_extension("fish.jpg"));
    try expectEqualStrings("js", read_extension("fish.js"));
    try expectEqualStrings("", read_extension("fish"));
    try expectEqualStrings("js", read_extension("/var/info/fish.js"));
    try expectEqualStrings("", read_extension("fish.jpgabcdefg"));
}

test "resource init" {
    const gpa = std.testing.allocator;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    try expectEqual(0, resources.by_uid.count());
    try expectEqual(0, resources.bundle_file.len);
}

test "load_resource image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    // normalise initialisation was skipped because this
    // test doesn't use loadDirectory.
    resources.normalise = try .init(resources.arena.allocator());

    const file = "./test/repo/GzeBWE.png";
    const info = Resources.FilenameComponents.split(file);
    var resource: Resource = .empty;
    try resource.load(gpa, gpa, io, &resources.normalise.?, file, info.name, info.extension);
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

    // normalise initialisation was skipped because this
    // test doesn't use loadDirectory.
    resources.normalise = try .init(resources.arena.allocator());

    const file = "./test/repo/jay~ἄρτος.wav";
    const info = Resources.FilenameComponents.split(file);
    try expectEqualStrings("jay~ἄρτος", info.name);
    try expectEqual(.wav, info.extension);

    var resource: Resource = .empty;
    try resource.load(gpa, gpa, io, &resources.normalise.?, file, info.name, info.extension);
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

    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keywords.deinit(gpa);
    try keywords.append(gpa, "ἄγγελος");

    var results: std.ArrayListUnmanaged(*Resource) = .empty;
    defer results.deinit(gpa);

    //var i = resources.by_sentence.index.keyIterator();
    //while (i.next()) |key| {
    //    err("by_sentence key = {s}", .{key.*});
    //}

    results.clearRetainingCapacity();
    try resources.search(gpa, keywords.items, .any, &results);
    try expectEqual(0, results.items.len);

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

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "fewhfoihsd4565", .any, .partial, &results);
    try expectEqual(0, results.items.len);
    try resources.lookup(gpa, "GzeBWE", .any, .partial, &results);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup(gpa, "κρέα", .any, .partial, &results);
    try expectEqual(2, results.items.len);
    results.clearRetainingCapacity();

    // A wav file and an image file match this
    try resources.lookup(gpa, "μάχαιρα", .any, .partial, &results);
    try expectEqual(2, results.items.len);
    results.clearRetainingCapacity();

    try resources.lookup(gpa, "μάχαιρα.", .any, .partial, &results);
    try expectEqual(2, results.items.len);
    results.clearRetainingCapacity();

    try resources.lookup(gpa, "ὁ δαυὶδ λέγει", .any, .partial, &results);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ὁ Δαυὶδ λέγει", .any, .partial, &results);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ὁ Δαυὶδ λέγει·", .any, .partial, &results);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ὁ Δαυὶδ λέγει·", .any, .partial, &results);
    try expectEqual(1, results.items.len);

    // Not the start of a sentence
    results.clearRetainingCapacity();
    try resources.lookup(gpa, "Δαυὶδ", .any, .partial, &results);
    try expectEqual(0, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "πτωχός", .any, .partial, &results);
    try expectEqual(2, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "πτωχός.", .any, .partial, &results);
    try expectEqual(2, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ἄρτος", .audio, .partial, &results);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ἄρτος.", .audio, .partial, &results);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ἄρτος;", .audio, .partial, &results);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "ἄρτος", .image, .partial, &results);
    try expectEqual(0, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "γυναῖκας· βλέψατε!", .any, .partial, &results);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup(gpa, "γυναῖκας· βλέψατε", .any, .partial, &results);
    try expectEqual(1, results.items.len);
}

test "ignore_not_visible" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    var results: std.ArrayListUnmanaged(*Resource) = .empty;
    defer results.deinit(gpa);

    {
        // The bean file must be ignored
        try resources.search(gpa, &.{"ὄσπρια"}, .any, &results);
        try expectEqual(0, results.items.len);
        // The bean file must not be in the set of δύο
        results.clearRetainingCapacity();
        try resources.search(gpa, &.{"δύο"}, .any, &results);
        try expectEqual(1, results.items.len);
    }
}

test "font_lookup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var results: std.ArrayListUnmanaged(*Resource) = .empty;
    defer results.deinit(gpa);

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    {
        // Basic search
        try resources.search(gpa, &.{"fakefont"}, .any, &results);
        try expectEqual(1, results.items.len);
        // Basic lookup
        results.clearRetainingCapacity();
        try resources.lookup(gpa, "fakefont", .any, .exact, &results);
        try expectEqual(1, results.items.len);
        // Filtered lookup
        var font = try resources.lookupOne(gpa, "fakefont", .any);
        try expect(font != null);
        // Filtered lookup
        font = try resources.lookupOne(gpa, "fakefont", .font);
        try expect(font != null);
        // Filtered lookup
        font = try resources.lookupOne(gpa, "fakefont", .ttf);
        try expect(font != null);
    }
}

test "file_with_full_stop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);
    _ = try resources.loadDirectory(gpa, io, "./test/repo/", null);

    var results: std.ArrayListUnmanaged(*Resource) = .empty;
    defer results.deinit(gpa);

    {
        try resources.search(gpa, &.{"ἐστιν"}, .any, &results);
        try expectEqual(1, results.items.len);
        results.clearRetainingCapacity();
        try resources.search(gpa, &.{"ἦν"}, .any, &results);
        try expectEqual(1, results.items.len);
        results.clearRetainingCapacity();
        try resources.search(gpa, &.{ "ἐστιν", "ἦν" }, .any, &results);
        try expectEqual(1, results.items.len);
    }

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

        try expectEqual(397, resources.by_sentence.index.count());

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(gpa);

        try resources.lookup(gpa, "ὁ μικρὸς οἶκος", .any, .exact, &results);
        try expectEqual(1, results.items.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results.items[0].uid);
        results.clearRetainingCapacity();

        try resources.lookup(gpa, "ὁ μικρὸς οἶκος", .png, .exact, &results);
        try expectEqual(1, results.items.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results.items[0].uid);
        results.clearRetainingCapacity();

        try resources.lookup(gpa, "ὁ μικρὸς οἶκος", .image, .exact, &results);
        try expectEqual(1, results.items.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results.items[0].uid);
        results.clearRetainingCapacity();

        try resources.lookup(gpa, "ὁ μικρὸς οἶκος", .wav, .exact, &results);
        try expectEqual(0, results.items.len);
        results.clearRetainingCapacity();

        try resources.lookup(gpa, "μικρὸς οἶκος", .any, .exact, &results);
        try expectEqual(1, results.items.len);
        try expectEqual(base62.decode(u64, "p61AOD"), results.items[0].uid);
        results.clearRetainingCapacity();

        try resources.lookup(gpa, "myxml1", .any, .partial, &results);
        try expectEqual(1, results.items.len);
        try expectEqualStrings("myxml1", results.items[0].sentences.items[0]);
        try expectEqualStrings("my xml 1", results.items[0].sentences.items[1]);

        try resources.lookup(gpa, "myxml2", .any, .partial, &results);
        try expectEqual(2, results.items.len);
        try expectEqualStrings("myxml2", results.items[1].sentences.items[0]);
        try expectEqualStrings("abcd", results.items[1].sentences.items[1]);
        data1 = try resources.loadResource(gpa, io, results.items[0]);
        try expectEqual(1, resources.used_resources.?.count());
        data2 = try resources.loadResource(gpa, io, results.items[1]);
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

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(gpa);

        try resources.lookup(gpa, "1122", .any, .partial, &results);
        try expectEqual(1, results.items.len);
        try resources.lookup(gpa, "2233", .any, .partial, &results);
        try expectEqual(2, results.items.len);
        // abcd is already in the results list, so no new results should be added.
        try resources.lookup(gpa, "abcd", .any, .partial, &results);
        try expectEqual(2, results.items.len);

        try expectEqualStrings("myxml1", results.items[0].sentences.items[0]);
        try expectEqualStrings("myxml2", results.items[1].sentences.items[0]);
        data1b = try resources.loadResource(gpa, io, results.items[0]);
        try expectEqual(1, resources.used_resources.?.count());
        data2b = try resources.loadResource(gpa, io, results.items[1]);
        try expectEqual(2, resources.used_resources.?.count());

        results.clearRetainingCapacity();
        try resources.lookup(gpa, "1122.", .any, .partial, &results);
        try expectEqual(1, results.items.len);
        results.clearRetainingCapacity();
        try resources.lookup(gpa, "1122·", .any, .partial, &results);
        try expectEqual(1, results.items.len);
    }
    defer gpa.free(data1b);
    defer gpa.free(data2b);

    try expectEqualStrings(data1, data1b);
    try expectEqualStrings(data2, data2b);
}

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
const Normalize = @import("Normalize");

pub const UniqueWords = @import("unique_words.zig").UniqueWords;
pub const random = @import("random.zig");
pub const Resource = @import("resource.zig").Resource;
const exportImage = @import("export_image.zig").exportImage;
const load_file_bytes = @import("resource.zig").load_file_bytes;
const load_file_byte_slice = @import("resource.zig").load_file_byte_slice;
const load_folder_file_bytes = @import("resource.zig").load_folder_file_bytes;
const write_folder_file_bytes = @import("resource.zig").write_folder_file_bytes;
const cache_has_file = @import("resource.zig").cache_has_file;
const sentence_trim = @import("resource.zig").sentence_trim;
const lessThan = @import("resource.zig").lessThan;

pub const FileType = @import("root.zig").FileType;

const Parser = @import("praxis").Parser;
const BoundedArray = @import("praxis").BoundedArray;
const SearchIndex = @import("praxis").SearchIndex;
const Normaliser = @import("praxis").normaliser.Normaliser;

const generate_ogg_audio = @import("export_audio.zig").generate_ogg_audio;
const Size = @import("export_image.zig").Size;

pub const wav = @import("wav.zig");
pub const base62 = @import("base62.zig");

const BinaryReader = @import("binary_reader.zig");
const BinaryWriter = @import("binary_writer.zig");
const append_u64 = BinaryWriter.append_u64;
const append_u32 = BinaryWriter.append_u32;
const append_u24 = BinaryWriter.append_u24;
const append_u16 = BinaryWriter.append_u16;
const append_u8 = BinaryWriter.append_u8;
