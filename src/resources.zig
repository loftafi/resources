/// A collection of files may be loaded from a folder or a resource
/// bundle.
///
///  - During development use `load_directory` to load content from
///    a directory on disk.
///  - When preparing for production, create a resource bundle.
///  - Released apps apps use `load_bundle` to load their files from
///    a resource bundle.
pub const Resources = struct {
    /// Lookup resource by UID in metadata file.
    by_uid: std.AutoHashMap(u64, *Resource),

    /// Lookup resource by word found in sentence in metadata file. Or word
    /// found in wav filename
    by_word: SearchIndex(*Resource, lessThan),

    /// Lookup resource by sentence in the metadata, or the the name
    /// component of the filename:
    by_filename: SearchIndex(*Resource, lessThan),

    arena: *std.heap.ArenaAllocator,
    arena_allocator: Allocator,
    parent_allocator: Allocator,
    used_resource_list: ?ArrayListUnmanaged(*Resource),

    folder: []const u8 = "",
    bundle_file: []const u8 = "",

    normalise: Normalize,

    /// Filter searches by resource type
    pub const SearchCategory = enum {
        any,
        audio,
        image,
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
        //json,
        bin,

        pub fn matches(self: SearchCategory, value: Resource.Type) bool {
            return switch (self) {
                .any => true,
                .audio => value == .wav,
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
                .bin => value == .bin,
                //.json => value == .json,
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
    };

    pub fn create(parent_allocator: Allocator) error{OutOfMemory}!*Resources {
        var arena = try parent_allocator.create(std.heap.ArenaAllocator);
        errdefer parent_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(parent_allocator);

        const arena_allocator = arena.allocator();
        const normalise = try Normalize.init(arena_allocator);
        const resources = try parent_allocator.create(Resources);

        resources.* = Resources{
            .normalise = normalise,
            .by_uid = std.AutoHashMap(u64, *Resource).init(arena_allocator),
            .by_word = .empty,
            .by_filename = .empty,
            .arena = arena,
            .arena_allocator = arena_allocator,
            .parent_allocator = parent_allocator,
            .folder = "",
            .bundle_file = "",
            .used_resource_list = .empty,
        };

        return resources;
    }

    pub fn destroy(self: *Resources) void {
        self.normalise.deinit(self.arena_allocator);

        if (self.used_resource_list) |*manifest| {
            manifest.deinit(self.arena_allocator);
        }

        // Iterate over the master resource list to
        // free each resource.
        var i = self.by_uid.iterator();
        while (i.next()) |item| {
            item.value_ptr.*.destroy(self.arena_allocator);
        }
        self.by_uid.deinit();

        // Relese the other indexes into the resources
        self.by_word.deinit(self.arena_allocator);
        self.by_filename.deinit(self.arena_allocator);
        if (self.folder.len > 0) {
            self.arena_allocator.free(self.folder);
        }
        if (self.bundle_file.len > 0) {
            self.arena_allocator.free(self.bundle_file);
        }

        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.parent_allocator.destroy(self);
    }

    // Load the table of contents of a file resource bundle into memory
    // so that files inside can be searched/loaded.
    pub fn load_bundle(self: *Resources, bundle_filename: []const u8) !void {
        var buffer: [300:0]u8 = undefined;
        var rbuffer: [4196:0]u8 = undefined;
        const e = std.builtin.Endian.little;

        var file = try std.fs.cwd().openFile(bundle_filename, .{});
        defer file.close();
        var rb = file.reader(&rbuffer);
        const b1 = try rb.interface.takeInt(u8, e);
        const b2 = try rb.interface.takeInt(u8, e);
        const b3 = try rb.interface.takeInt(u8, e);
        if (b1 + 9 != b2) {
            return error.InvalidBundleFile;
        }
        if (b1 + 1 != b3) {
            return error.InvalidBundleFile;
        }
        const entries = try rb.interface.takeInt(u24, e);
        for (0..entries) |_| {
            var r = try Resource.create(self.arena_allocator);
            errdefer r.destroy(self.arena_allocator);
            const resource_type = try rb.interface.takeInt(u8, e);
            r.resource = @enumFromInt(resource_type);
            r.uid = try rb.interface.takeInt(u64, e);
            r.size = try rb.interface.takeInt(u32, e);
            const sentence_count = try rb.interface.takeInt(u8, e);
            for (0..sentence_count) |_| {
                const name_len: u8 = try rb.interface.takeInt(u8, e);
                try rb.interface.readSliceAll(buffer[0..name_len]);
                const text = try self.arena_allocator.dupe(u8, buffer[0..name_len]);
                try r.sentences.append(self.arena_allocator, text);
            }
            r.bundle_offset = try rb.interface.takeInt(u64, e);

            try self.by_uid.put(r.uid, r);
            for (r.sentences.items) |sentence| {
                try self.by_filename.add(self.arena_allocator, sentence, r);
            }

            var unique = UniqueWords.init(self.arena_allocator);
            defer unique.deinit();
            try unique.addArray(&r.sentences.items);
            var it = unique.words.iterator();
            while (it.next()) |word| {
                if (word.key_ptr.*.len > 0) {
                    try self.by_word.add(self.arena_allocator, word.key_ptr.*, r);
                } else {
                    std.debug.print("empty sentence keyword in {s}\n", .{encode(u64, r.uid, buffer[0..40 :0])});
                }
            }
        }

        self.bundle_file = try self.arena_allocator.dupe(u8, bundle_filename);
    }

    // Save the `manifest` list of resources into a single data data file
    // with a table of contents.
    pub fn save_bundle(self: *Resources, filename: []const u8, manifest: []*Resource) !void {
        const version = 1;
        var header: ArrayListUnmanaged(u8) = .empty;
        defer header.deinit(self.parent_allocator);
        var header_items: ArrayListUnmanaged(BundleResource) = .empty;
        defer header_items.deinit(self.parent_allocator);

        const b1 = @as(u8, @intCast(random(230) + 10));
        try append_u8(&header, b1, self.parent_allocator);
        try append_u8(&header, b1 + 9, self.parent_allocator);
        try append_u8(&header, b1 + version, self.parent_allocator);

        const output = std.fs.cwd().createFile(filename, .{ .truncate = true }) catch |e| {
            log.err("Repo file missing: {s}", .{filename});
            return e;
        };

        // Estimate the size of the header + table of contents so know where the first
        // file byte of the first file is going to appear
        var file_index: usize = 1 + 1 + 1 + 3;

        // Build the table of contents so we can estimate the size of it.
        for (manifest) |resource| {
            if (resource.filename == null) {
                log.err("Resource object missing filename: {d}. Resource probably lives in a bundle.", .{resource.uid});
                continue;
            }
            const file = std.fs.cwd().openFile(resource.filename.?, .{ .mode = .read_only }) catch |e| {
                log.err("Repo file missing: {s}", .{resource.filename.?});
                return e;
            };
            defer file.close();
            const stat = try file.stat();
            if (stat.size > 0xffffffff) {
                log.err("File too large to bundle: {s}", .{resource.filename.?});
            }
            var names = resource.sentences.items;
            if (names.len > 254) {
                names = resource.sentences.items[0..254];
            }
            if (names.len == 0) {
                log.err("Resource has no sentences: {s} {any}", .{
                    resource.filename.?,
                    @tagName(resource.resource),
                });
                continue;
            }
            try header_items.append(self.parent_allocator, .{
                .type = @intFromEnum(resource.resource),
                .uid = resource.uid,
                .size = @as(u32, @intCast(stat.size)),
                .names = names,
            });
            file_index += 1 + 8 + 4 + 1 + 8;
            for (names) |sentence| {
                file_index += 1 + sentence.len;
            }
        }

        try append_u24(&header, @as(u24, @intCast(header_items.items.len)), self.parent_allocator);

        // Add the table of contents
        for (header_items.items) |item| {
            try append_u8(&header, @as(u8, item.type), self.parent_allocator);
            try append_u64(&header, item.uid, self.parent_allocator);
            try append_u32(&header, @intCast(item.size), self.parent_allocator);
            try append_u8(&header, @intCast(item.names.len), self.parent_allocator);
            for (item.names) |sentence| {
                try append_u8(&header, @as(u8, @intCast(sentence.len)), self.parent_allocator);
                try header.appendSlice(self.parent_allocator, sentence);
            }
            try append_u64(&header, file_index, self.parent_allocator);
            file_index += item.size;
        }

        try output.writeAll(header.items);

        // Add the files
        for (manifest) |resource| {
            const data = try self.read_data(resource, self.parent_allocator);
            defer self.parent_allocator.free(data);
            try output.writeAll(data);
        }
    }

    // Load the full list of usable files inside the `folder` along with
    // any associated metadata files so that each file can be searched for
    // and loaded.
    pub fn load_directory(self: *Resources, folder: []const u8) (Error || error{
        OutOfMemory,
        Utf8InvalidStartByte,
        Utf8ExpectedContinuation,
        Utf8OverlongEncoding,
        Utf8EncodesSurrogateHalf,
        Utf8CodepointTooLarge,
    })!bool {
        var dir = std.fs.cwd().openDir(folder, .{ .iterate = true }) catch |e| {
            log.warn(
                "Failed opening resource directory {s}. Error: {any}",
                .{ folder, e },
            );
            return false;
        };
        defer dir.close();

        self.folder = try self.arena_allocator.dupeZ(u8, folder);

        var filename: ArrayListUnmanaged(u8) = .empty;
        defer filename.deinit(self.parent_allocator);

        var i = dir.iterate();
        while (i.next() catch return error.ReadRepoFileFailed) |file| {
            if (file.kind != .file) {
                continue;
            }
            const file_info = get_file_type(file.name);

            if (file_info.extension == .unknown) {
                continue;
            }

            // Check the filename is nfc encoded
            const file_nfc = try self.normalise.nfc(self.parent_allocator, file.name);
            defer file_nfc.deinit(self.parent_allocator);
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
            try filename.appendSlice(self.parent_allocator, folder);
            if (filename.items[filename.items.len - 1] != '/') {
                try filename.append(self.parent_allocator, '/');
            }
            try filename.appendSlice(self.parent_allocator, file.name);

            var resource = try Resource.create(self.arena_allocator);
            try resource.load(
                self.parent_allocator,
                self.arena_allocator,
                &self.normalise,
                filename.items,
                file_info.name,
                file_info.extension,
            );
            if (resource.uid == 0) resource.uid = try self.unique_random_u64();

            if (!resource.visible) {
                resource.destroy(self.arena_allocator);
                continue;
            }

            // Lookup by UID
            if (self.by_uid.contains(resource.uid)) {
                log.err("error: duplicated uid {any} file {s}\n", .{
                    resource.uid,
                    filename.items,
                });
                resource.destroy(self.arena_allocator);
                continue;
            }
            try self.by_uid.put(resource.uid, resource);

            // Lookup by filename or sentence
            self.by_filename.add(
                self.arena_allocator,
                file_info.name,
                resource,
            ) catch |e| {
                log.err("error: invalid metadata in file {any} {s} {any}\n", .{
                    resource.uid,
                    filename.items,
                    e,
                });
                return error.ReadMetadataFailed;
            };
            for (resource.sentences.items) |sentence| {
                if (!std.mem.eql(u8, file_info.name, sentence)) {
                    self.by_filename.add(
                        self.arena_allocator,
                        sentence,
                        resource,
                    ) catch |e| {
                        log.err("error: invalid metadata in file {any} {s} {any}\n", .{
                            resource.uid,
                            filename.items,
                            e,
                        });
                        return error.ReadMetadataFailed;
                    };
                }
            }

            var unique = UniqueWords.init(self.arena_allocator);
            defer unique.deinit();
            try unique.addArray(&resource.sentences.items);
            var it = unique.words.iterator();
            while (it.next()) |word| {
                if (word.key_ptr.*.len > 0) {
                    self.by_word.add(
                        self.arena_allocator,
                        word.key_ptr.*,
                        resource,
                    ) catch |e| {
                        log.err("error: invalid metadata in file {any} {s} {any}\n", .{
                            resource.uid,
                            filename.items,
                            e,
                        });
                        return error.ReadMetadataFailed;
                    };
                } else {
                    var buffer: [40:0]u8 = undefined;
                    std.debug.print("empty sentence keyword in {s}\n", .{encode(
                        u64,
                        resource.uid,
                        &buffer,
                    )});
                }
            }
        }

        return true;
    }

    /// Repeatedly generate a uid until we find a uid that does not exist
    /// in the repo folder. The chance of the random uid generator conflicting
    /// is low, but possible.
    fn unique_random_u64(self: *Resources) error{ReadMetadataFailed}!u64 {
        var retry: usize = 0;
        var dir = std.fs.cwd().openDir(self.folder, .{}) catch |e| {
            log.warn("Resource loader failed opening {s}. Error: {any}", .{ self.folder, e });
            return error.ReadMetadataFailed;
        };
        defer dir.close();
        var ubuffer: [40:0]u8 = undefined; // 40 for UID, more for file extension
        var buffer: [50:0]u8 = undefined; // 40 for UID, more for file extension
        while (true) {
            const uid = random_u64();
            const uid_string = encode(u64, uid, &ubuffer);
            const filename = std.fmt.bufPrint(&buffer, "{s}.txt", .{uid_string}) catch |e| {
                log.warn("unique_random_u64 has unexpected exception: {any}", .{e});
                unreachable;
            };
            _ = dir.statFile(filename) catch |e| {
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
        keywords: []const []const u8,
        category: SearchCategory,
        results: *ArrayListUnmanaged(*Resource),
        allocator: Allocator,
    ) !void {
        for (keywords) |keyword| {
            const r = self.by_word.lookup(keyword);
            if (r != null) {
                for (r.?.exact_accented.items) |x| {
                    if (category.matches(x.resource)) {
                        try results.append(allocator, x);
                    }
                }
                if (results.items.len == 0) {
                    for (r.?.exact_unaccented.items) |x| {
                        if (category.matches(x.resource)) {
                            try results.append(allocator, x);
                        }
                    }
                }
            }
        }
    }

    /// Return all resources where either a sentence or filename associated
    /// with a resource exactly matches. Full stops at the end of sentences.
    /// are ignored. Does not support searching for a single word inside a
    /// filename, use `search()` for single word keyword search.
    pub fn lookup(
        self: *Resources,
        sentence: []const u8,
        category: SearchCategory,
        partial_match: bool,
        results: *ArrayListUnmanaged(*Resource),
        allocator: Allocator,
    ) (error{OutOfMemory} || Error)!void {
        if (sentence.len == 0) return;

        // Normalise to nfc and normalise the characters with index rules.
        const sentence_nfc = try self.normalise.nfc(self.parent_allocator, sentence);
        defer sentence_nfc.deinit(self.parent_allocator);
        var unaccented = BoundedArray(u8, max_word_size + 1){};
        var normalised = BoundedArray(u8, max_word_size + 1){};
        normalise_word(sentence_nfc.slice, &unaccented, &normalised) catch |f| {
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

        const query = normalised.slice();
        const trimmed = sentence_trim(query);

        // Lookup by exact full filename (excluding extension and prefixes)
        const search_results = self.by_filename.lookup(query);
        var trimmed_results: @TypeOf(search_results) = null;
        if (trimmed) |t|
            trimmed_results = self.by_filename.lookup(t);

        if (search_results) |r| {
            for (r.exact_accented.items) |x| {
                if (category.matches(x.resource))
                    try append_if_not_found(results, allocator, x);
            }
        }

        if (trimmed_results) |tr| {
            for (tr.exact_accented.items) |x| {
                if (category.matches(x.resource))
                    try append_if_not_found(results, allocator, x);
            }
        }

        if (results.items.len == 0) {
            if (search_results) |r| {
                for (r.exact_unaccented.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, allocator, x);
                }
            }

            if (trimmed_results) |tr| {
                for (tr.exact_unaccented.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, allocator, x);
                }
            }
        }

        if (partial_match) {
            if (search_results) |r| {
                for (r.partial_match.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, allocator, x);
                }
                if (results.items.len > 0)
                    return;
            }

            if (trimmed_results) |tr| {
                for (tr.partial_match.items) |x| {
                    if (category.matches(x.resource))
                        try append_if_not_found(results, allocator, x);
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
        sentence: []const u8,
        category: SearchCategory,
        allocator: Allocator,
    ) (error{OutOfMemory} || Error)!?*Resource {
        if (sentence.len == 0) return null;

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(allocator);
        try self.lookup(sentence, category, false, &results, allocator);
        if (results.items.len > 0)
            return results.items[0];

        return null;
    }

    // Read the binary data of the requested resource. Depending on
    // where the file was found it might be loaded from a directory or
    // from a resource bundle.
    pub fn read_data(
        self: *Resources,
        resource: *Resource,
        allocator: Allocator,
    ) ![]const u8 {
        if (self.used_resource_list) |*manifest| {
            try manifest.append(self.arena_allocator, resource);
        }
        if (resource.filename) |filename| {
            // Resource has a filename, read a file.
            const data = load_file_bytes(allocator, filename) catch |e| {
                return e;
            };
            resource.size = data.len;
            return data;
        }
        if (resource.bundle_offset) |bundle_offset| {
            // Resource has an offset pointer into a bundle, read the bundle.
            return try load_file_byte_slice(
                allocator,
                self.bundle_file,
                bundle_offset,
                resource.size,
            );
        }
        return Error.ResourceHasNoFilename;
    }
};

/// Convert the extension of the file into an enum, and return both the
/// extension and the name component of a filename. i.e `/etc/jay~info.wav`
/// returns `.{ .name = "jay~info" .extension = .wav}`
fn get_file_type(file: []const u8) struct { name: []const u8, extension: Resource.Type } {
    const ext = read_extension(file);
    if (ext.len == 0)
        return .{ .name = file, .extension = .unknown };

    const full_name = file[0 .. file.len - ext.len - 1];

    var cut = full_name.len;
    while (cut > 0) {
        if (full_name[cut - 1] == '/' or full_name[cut - 1] == '\\') break;
        cut -= 1;
    }
    const name = full_name[cut..];

    if (std.ascii.eqlIgnoreCase(ext, "png"))
        return .{ .name = name, .extension = .png };
    if (std.ascii.eqlIgnoreCase(ext, "svg"))
        return .{ .name = name, .extension = .svg };
    if (std.ascii.eqlIgnoreCase(ext, "jpg"))
        return .{ .name = name, .extension = .jpg };
    if (std.ascii.eqlIgnoreCase(ext, "ttf"))
        return .{ .name = name, .extension = .ttf };
    if (std.ascii.eqlIgnoreCase(ext, "otf"))
        return .{ .name = name, .extension = .otf };
    if (std.ascii.eqlIgnoreCase(ext, "csv"))
        return .{ .name = name, .extension = .csv };
    if (std.ascii.eqlIgnoreCase(ext, "jpx"))
        return .{ .name = name, .extension = .jpx };
    if (std.ascii.eqlIgnoreCase(ext, "bin"))
        return .{ .name = name, .extension = .bin };
    if (std.ascii.eqlIgnoreCase(ext, "xml"))
        return .{ .name = name, .extension = .xml };

    if (!std.ascii.startsWithIgnoreCase(name, "jay~"))
        return .{ .name = name, .extension = .unknown };

    if (std.ascii.eqlIgnoreCase(ext, "wav"))
        return .{ .name = name, .extension = .wav };

    return .{ .name = name, .extension = .unknown };
}

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

/// Placeholder sort function for Resource record.
pub fn lessThan(_: ?[]const u8, self: *Resource, other: *Resource) bool {
    return self.uid < other.uid;
}

inline fn append_if_not_found(
    results: *ArrayListUnmanaged(*Resource),
    allocator: Allocator,
    resource: *Resource,
) error{OutOfMemory}!void {
    for (results.items) |item| {
        if (item.uid == resource.uid) return;
    }
    try results.append(allocator, resource);
}

/// Describes a table of contents entry in a bundle file.
pub const BundleResource = struct {
    uid: u64,
    size: u32,
    type: u8,
    names: []const []const u8,
};

/// Return a slice of a sentence with trailing punctuation removed. This
/// allows searches to find a non punctuated version of the sentence.
pub fn sentence_trim(sentence: []const u8) ?[]const u8 {
    var trimmed: []const u8 = sentence;
    while (true) {
        if (std.mem.endsWith(u8, trimmed, ".")) {
            trimmed.len -= ".".len;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, "·")) {
            trimmed.len -= "·".len;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, ",")) {
            trimmed.len -= ",".len;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, "!")) {
            trimmed.len -= "!".len;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, ":")) {
            trimmed.len -= ":".len;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, ";")) {
            trimmed.len -= ";".len;
            continue;
        }
        break;
    }
    if (trimmed.len == sentence.len)
        return null;
    return trimmed;
}

pub fn write_file_bytes(gpa: Allocator, filename: []const u8, data: []const u8) !void {
    const tmp_filename = try std.fmt.allocPrint(gpa, "{s}.{d}", .{ filename, std.time.milliTimestamp() });
    const file = std.fs.cwd().createFile(tmp_filename, .{ .read = false, .truncate = true }) catch |e| {
        log.err(
            "Failed to open file for writing: {s}. {any}",
            .{ filename, e },
        );
        return e;
    };
    defer file.close();
    try file.writeAll(data);
    try std.fs.cwd().rename(tmp_filename, filename);
}

pub fn load_file_bytes(allocator: Allocator, filename: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(
        filename,
        .{ .mode = .read_only },
    ) catch |e| {
        log.debug("load_file_bytes failed to read file: {s}  {any}", .{ filename, e });
        return e;
    };
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

fn load_file_byte_slice(allocator: Allocator, filename: []const u8, offset: usize, size: usize) ![]u8 {
    const file = std.fs.cwd().openFile(
        filename,
        .{ .mode = .read_only },
    ) catch |e| {
        log.err("Repo file missing: {s}", .{filename});
        return e;
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.size < offset + size) {
        return error.BundleTooShortToExtractFile;
    }
    file.seekTo(offset) catch |e| {
        log.err("Seek file failed: {s} {d} {d} Error: {any}", .{ filename, offset, size, e });
        return e;
    };
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);
    const found = try file.readAll(buffer);
    std.debug.assert(size == found);
    return buffer;
}

test "read_extension" {
    try expectEqualStrings("jpg", read_extension("fish.jpg"));
    try expectEqualStrings("js", read_extension("fish.js"));
    try expectEqualStrings("", read_extension("fish"));
    try expectEqualStrings("js", read_extension("/var/info/fish.js"));
    try expectEqualStrings("", read_extension("fish.jpgabcdefg"));
}

test "resource init" {
    var resources = try Resources.create(std.testing.allocator);
    defer resources.destroy();
    try expectEqual(0, resources.by_filename.slices.items.len);
    try expectEqual(0, resources.by_word.slices.items.len);
    try expectEqual(0, resources.by_uid.count());
    try expectEqual(0, resources.bundle_file.len);
}

test "read resource info" {
    const text = "i:f43ih\nd:202309072345\nc:copy\ns:ὁ ἄρτος.\nv:true\n\n";
    var data = Parser.init(text);
    const element = try settings.next(&data);
    try expect(element != null);
    try expectEqual(.uid, element.?.setting);
    try expectEqualStrings("f43ih", element.?.value);
    const element2 = try settings.next(&data);
    try expect(element2 != null);
    try expectEqual(.date, element2.?.setting);
    try expectEqualStrings("202309072345", element2.?.value);
}

test "read resource info space" {
    const text = " i:f43ih  \n\r\nd:   202309072345   \nc:copy\ns:ὁ ἄρτος.\nv:true\n\n";
    var data = Parser.init(text);
    const element = try settings.next(&data);
    try expect(element != null);
    try expectEqual(.uid, element.?.setting);
    try expectEqualStrings("f43ih", element.?.value);
    const element2 = try settings.next(&data);
    try expect(element2 != null);
    try expectEqual(.date, element2.?.setting);
    try expectEqualStrings("202309072345", element2.?.value);
}

test "load_resource image" {
    const gpa = std.testing.allocator;
    var resources = try Resources.create(gpa);
    defer resources.destroy();

    const file = "./test/repo/GzeBWE.png";
    const info = get_file_type(file);
    var resource: Resource = .empty;
    try resource.load(std.testing.allocator, std.testing.allocator, &resources.normalise, file, info.name, info.extension);
    defer resource.deinit(std.testing.allocator);

    try expectEqual(3989967536, resource.uid);
    try expectEqualStrings(file, resource.filename.?);
    try expectEqual(.png, resource.resource);
    try expectEqual(true, resource.visible);
    try expectEqualStrings("jay", resource.copyright.?);
    //for (resource.sentences.items) |s| std.log.err("sentence >> {s}", .{s});
    try expectEqual(4, resource.sentences.items.len);
    try expectEqualStrings("GzeBWE", resource.sentences.items[0]);
    try expectEqualStrings("κρέα", resource.sentences.items[1]);
}

test "load_resource audio" {
    const gpa = std.testing.allocator;
    var resources = try Resources.create(gpa);
    defer resources.destroy();

    const file = "./test/repo/jay~ἄρτος.wav";
    const info = get_file_type(file);
    try expectEqualStrings("jay~ἄρτος", info.name);
    try expectEqual(.wav, info.extension);

    var resource: Resource = .empty;
    try resource.load(std.testing.allocator, std.testing.allocator, &resources.normalise, file, info.name, info.extension);
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
    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keywords.deinit(gpa);
    try keywords.append(gpa, "ἄγγελος");

    var results: std.ArrayListUnmanaged(*Resource) = .empty;
    defer results.deinit(gpa);

    var resources = try Resources.create(gpa);
    defer resources.destroy();

    _ = try resources.load_directory("./test/repo/");

    //var i = resources.by_filename.index.keyIterator();
    //while (i.next()) |key| {
    //    err("by_filename key = {s}", .{key.*});
    //}

    results.clearRetainingCapacity();
    try resources.search(keywords.items, .any, &results, gpa);
    try expectEqual(0, results.items.len);

    // Test files have this exact string
    try expect(resources.by_filename.index.get("ασεἄρτο") == null);
    try expect(resources.by_filename.index.get("ἄρτος") != null);
    try expect(resources.by_filename.index.get("μάχαιρα") != null);
    try expect(resources.by_filename.index.get("ὁ δαυὶδ λέγει") != null);

    // No test files have this exact string (only mid sentence)
    try expect(resources.by_filename.index.get("δαυὶδ") == null);
    try expect(resources.by_filename.index.get("δαυίδ") == null);
    try expect(resources.by_filename.index.get("ὁ Δαυὶδ λέγει") == null);
    try expect(resources.by_filename.index.get("ὁ Δαυὶδ λέγει·") == null);

    results.clearRetainingCapacity();
    try resources.lookup("fewhfoihsd4565", .any, true, &results, gpa);
    try expectEqual(0, results.items.len);
    try resources.lookup("GzeBWE", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("κρέα", .any, true, &results, gpa);
    try expectEqual(2, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("μάχαιρα", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("μάχαιρα.", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("ὁ δαυὶδ λέγει", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("ὁ Δαυὶδ λέγει", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
    results.clearRetainingCapacity();
    try resources.lookup("ὁ Δαυὶδ λέγει·", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("ὁ Δαυὶδ λέγει·", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);

    // Not the start of a sentence
    results.clearRetainingCapacity();
    try resources.lookup("Δαυὶδ", .any, true, &results, gpa);
    try expectEqual(0, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("πτωχός", .any, true, &results, gpa);
    try expectEqual(2, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("πτωχός.", .any, true, &results, gpa);
    try expectEqual(2, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("ἄρτος", .audio, true, &results, gpa);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("ἄρτος.", .audio, true, &results, gpa);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("ἄρτος;", .audio, true, &results, gpa);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("ἄρτος", .image, true, &results, gpa);
    try expectEqual(0, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("γυναῖκας· βλέψατε!", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);

    results.clearRetainingCapacity();
    try resources.lookup("γυναῖκας· βλέψατε", .any, true, &results, gpa);
    try expectEqual(1, results.items.len);
}

test "file_name_split" {
    const info = get_file_type("fish.jpg");
    try expectEqualStrings("fish", info.name);
    try expectEqual(.jpg, info.extension);

    const info2 = get_file_type("opens.xml");
    try expectEqualStrings("opens", info2.name);
    try expectEqual(.xml, info2.extension);

    const info3 = get_file_type("/fish/hat/opens.xml");
    try expectEqualStrings("opens", info3.name);
    try expectEqual(.xml, info3.extension);
}

test "bundle" {
    const gpa = std.testing.allocator;
    const TEST_BUNDLE_FILENAME: []const u8 = "/tmp/bundle.bd";
    var data1: []const u8 = "";
    var data2: []const u8 = "";
    var data1b: []const u8 = "";
    var data2b: []const u8 = "";

    {
        var resources = try Resources.create(gpa);
        defer resources.destroy();
        _ = try resources.load_directory("./test/repo/");

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(gpa);

        try resources.lookup("1122", .any, true, &results, gpa);
        try expectEqual(1, results.items.len);
        try resources.lookup("2233", .any, true, &results, gpa);
        try expectEqual(2, results.items.len);
        try expectEqualStrings("1122", results.items[0].sentences.items[0]);
        try expectEqualStrings("2233", results.items[1].sentences.items[0]);
        data1 = try resources.read_data(results.items[0], gpa);
        try expectEqual(1, resources.used_resource_list.?.items.len);
        data2 = try resources.read_data(results.items[1], gpa);
        try expectEqual(2, resources.used_resource_list.?.items.len);

        try resources.save_bundle(TEST_BUNDLE_FILENAME, resources.used_resource_list.?.items);
    }
    defer std.testing.allocator.free(data1);
    defer std.testing.allocator.free(data2);

    {
        var resources = try Resources.create(std.testing.allocator);
        defer resources.destroy();
        try resources.load_bundle(TEST_BUNDLE_FILENAME);

        var results: ArrayListUnmanaged(*Resource) = .empty;
        defer results.deinit(gpa);

        try resources.lookup("1122", .any, true, &results, gpa);
        try expectEqual(1, results.items.len);
        try resources.lookup("2233", .any, true, &results, gpa);
        try expectEqual(2, results.items.len);
        try resources.lookup("abcd", .any, true, &results, gpa);
        try expectEqual(2, results.items.len);
        try expectEqualStrings("1122", results.items[0].sentences.items[0]);
        try expectEqualStrings("2233", results.items[1].sentences.items[0]);
        data1b = try resources.read_data(results.items[0], gpa);
        try expectEqual(1, resources.used_resource_list.?.items.len);
        data2b = try resources.read_data(results.items[1], gpa);
        try expectEqual(2, resources.used_resource_list.?.items.len);

        results.clearRetainingCapacity();
        try resources.lookup("1122.", .any, true, &results, gpa);
        try expectEqual(1, results.items.len);
        results.clearRetainingCapacity();
        try resources.lookup("1122·", .any, true, &results, gpa);
        try expectEqual(1, results.items.len);
    }
    defer gpa.free(data1b);
    defer gpa.free(data2b);

    try expectEqualStrings(data1, data1b);
    try expectEqualStrings(data2, data2b);
}

const builtin = @import("builtin");
const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const log = std.log;
const warn = std.log.warn;
const err = std.log.err;
const debug = std.log.debug;
const eql = @import("std").mem.eql;
const Allocator = std.mem.Allocator;
const Normalize = @import("Normalize");

const settings = @import("settings.zig");
pub const Setting = settings.Setting;
pub const UniqueWords = @import("unique_words.zig").UniqueWords;
pub const WordFinder = @import("word_finder.zig").WordFinder;
pub const encode_uid = @import("base62.zig").encode;
pub const decode_uid = @import("base62.zig").decode;
pub const seed = @import("random.zig").seed;
pub const random = @import("random.zig").random;
pub const random_u64 = @import("random.zig").random_u64;
pub const Resource = @import("resource.zig").Resource;
pub const exportImage = @import("export_image.zig").exportImage;

const Parser = @import("praxis").Parser;
const BoundedArray = @import("praxis").BoundedArray;
const SearchIndex = @import("praxis").SearchIndex;
const normalise_word = @import("praxis").normalise_word;
const max_word_size = @import("praxis").MAX_WORD_SIZE;

const encode = @import("base62.zig").encode;
const decode = @import("base62.zig").decode;
const BinaryReader = @import("binary_reader.zig");
const BinaryWriter = @import("binary_writer.zig");
const append_u64 = BinaryWriter.append_u64;
const append_u32 = BinaryWriter.append_u32;
const append_u24 = BinaryWriter.append_u24;
const append_u16 = BinaryWriter.append_u16;
const append_u8 = BinaryWriter.append_u8;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
