/// Old resources might have a uid longer than 10 which does not
/// fit into a u64. These are cleaned up as they are encountered.
pub const max_uid_length = 10;
pub const max_filename_length = 1024 * 2;

/// Describes a resource. This inforation may be loaded from a
/// directory of files or a bundle of files (archive).
pub const Resource = struct {
    uid: u64,
    visible: bool,
    date: ?[]const u8,
    copyright: ?[]const u8,
    link: ?[]const u8,
    sentences: ArrayListUnmanaged([]const u8),

    resource: FileType,

    // on disk resource has a filename
    filename: ?[:0]u8 = null,

    // bundle resources has a bundle offset
    bundle_offset: ?u64 = null,
    size: usize = 0,

    pub const empty: Resource = .{
        .uid = 0,
        .visible = true,
        .resource = .unknown,
        .date = null,
        .copyright = null,
        .link = null,
        .sentences = .empty,
        .filename = null,
        .bundle_offset = null,
        .size = 0,
    };

    /// Create a `Resource` initialised with the `.empty` placeholder settings.
    pub fn create(allocator: Allocator) Allocator.Error!*Resource {
        const resource = try allocator.create(Resource);
        errdefer allocator.destroy(resource);
        resource.* = .empty;
        return resource;
    }

    /// `deinit` and `destroy` a `create`d resource object.
    pub fn destroy(self: *Resource, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// Free any memory allocated by this object.
    pub fn deinit(self: *Resource, allocator: Allocator) void {
        for (self.sentences.items) |s| {
            allocator.free(s);
        }
        self.sentences.deinit(allocator);

        if (self.filename != null) allocator.free(self.filename.?);
        if (self.copyright != null) allocator.free(self.copyright.?);
        if (self.date != null) allocator.free(self.date.?);
    }

    /// Load a data file from the resources folder into the search index.
    /// If the file has an associated metadata file, also load the metadata.
    pub fn load(
        self: *Resource,
        gpa: Allocator,
        arena: Allocator,
        normalise: *const Normalize,
        filename: []const u8,
        file_name: []const u8,
        file_type: FileType,
    ) (error{OutOfMemory} || Resources.Error || std.fs.File.StatError || std.fs.File.OpenError || std.fmt.BufPrintError)!void {
        if (filename.len > 0) self.filename = try arena.dupeZ(u8, filename);

        self.resource = file_type;

        if (file_type == .wav) {
            if (try extract_wav_name(gpa, file_name)) |sentence| {
                defer gpa.free(sentence);
                const sentence_nfc = try normalise.nfc(gpa, sentence);
                defer sentence_nfc.deinit(gpa);
                try self.add_sentence(arena, sentence_nfc.slice);
            }
        } else {
            try self.add_sentence(arena, file_name);
        }

        // Check if there is a metadata file to load.
        var buf: [max_filename_length]u8 = undefined;
        const metadata_file = std.fmt.bufPrint(&buf, "{s}.txt", .{remove_extension(filename)}) catch return error.FilenameTooLong;
        const data = load_file_bytes(gpa, metadata_file) catch |e| {
            if (e == error.FileNotFound) {
                // If no metadata file exists, default to visible
                self.visible = true;
                if (self.uid == 0 and file_type == .wav) {
                    self.uid = try hash_uid(file_name, filename);
                }
                return;
            } else {
                return error.ReadMetadataFailed;
            }
        };
        defer gpa.free(data);
        const data_nfc = try normalise.nfc(gpa, data);
        defer data_nfc.deinit(gpa);

        if (data.len != data_nfc.slice.len) {
            warn("metadata file {s} is not nfc.", .{metadata_file});
            write_file_bytes(gpa, filename, data_nfc.slice) catch {
                warn("update metadata file {s} to nfc failed.", .{metadata_file});
            };
        }

        return self.read_metadata(arena, data_nfc.slice);
    }

    /// Form a uid from the name of the file and the size of the file. Not
    /// perfect, but it is faster than continually hashing entire files
    pub fn hash_uid(name: []const u8, path_name: []const u8) (std.fs.File.StatError || std.fs.File.OpenError)!u64 {
        var buff: [40]u8 = undefined;
        const stat = try std.fs.cwd().statFile(path_name);
        const size_info = try std.fmt.bufPrint(&buff, "{d}", .{stat.size});
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        sha256.update(name);
        sha256.update(size_info);
        const data = sha256.finalResult();
        return @bitCast(data[0..8].*);
    }

    /// Update fields of this object using metadata fileds in a text file.
    pub fn read_metadata(self: *Resource, allocator: Allocator, data: []const u8) (error{ InvalidResourceUID, ReadMetadataFailed, MetadataMissing } || Allocator.Error)!void {
        var text = data;
        while (text.len > 0) {

            // Read the field
            while (text.len > 0 and is_whitespace(text[0])) {
                text = text[1..];
            }
            if (text.len == 0) break;
            const field = text[0];
            text = text[1..];
            while (text.len > 0 and (is_whitespace(text[0]) or text[0] == ':' or text[0] == '=')) {
                text = text[1..];
            }

            var eov: usize = 0;
            var end_candidate: usize = 0;
            while (text.len > eov and text[eov] != '\n' and text[eov] != '\r') {
                if (!is_whitespace(text[eov])) end_candidate = eov + 1;
                eov += 1;
            }
            const value = text[0..end_candidate];
            text = text[eov..];
            if (value.len == 0) continue;

            switch (field) {
                's', 'S' => try self.add_sentence(allocator, value),
                'c', 'C' => self.copyright = try allocator.dupe(u8, value),
                'v', 'V' => self.visible = is_true(value),
                'd', 'D' => self.date = try allocator.dupe(u8, value),
                'l', 'L' => self.link = try allocator.dupe(u8, value),
                'i', 'I' => {
                    if (value.len > max_uid_length) {
                        self.uid = decode_uid(u64, value[0..max_uid_length]) catch {
                            return error.InvalidResourceUID;
                        };
                        continue;
                    } else {
                        self.uid = decode_uid(u64, value) catch {
                            return error.InvalidResourceUID;
                        };
                    }
                    if (self.uid == 0) return error.InvalidResourceUID;
                },
                else => return error.ReadMetadataFailed,
            }
        }
    }

    /// Attach a sentence to this resource, ensuring that no duplicate
    /// sentences are added. If non significant punctuation is found at the
    /// end of this sentence, also attach a non punctuated version.
    fn add_sentence(self: *Resource, allocator: Allocator, text: []const u8) (error{MetadataMissing} || Allocator.Error)!void {
        if (text.len == 0) return error.MetadataMissing;

        var found = false;
        for (self.sentences.items) |i| {
            if (std.mem.eql(u8, text, i)) {
                found = true;
                break;
            }
        }
        if (!found)
            try self.sentences.append(allocator, try allocator.dupe(u8, text));

        if (sentence_trim(text)) |trim| {
            if (trim.len > 0) {
                found = false;
                for (self.sentences.items) |i| {
                    if (std.mem.eql(u8, trim, i)) {
                        found = true;
                        break;
                    }
                }
                if (!found)
                    try self.sentences.append(allocator, try allocator.dupe(u8, trim));
            }
        }
    }
};

fn is_whitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn is_true(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "y") or
        std.ascii.eqlIgnoreCase(text, "1");
}

fn remove_extension(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) {
        if (end + 6 < path.len) break;
        if (path[end - 1] == '.')
            return path[0 .. end - 1];
        end -= 1;
    }
    return path;
}

/// Wav files don't have metadata files, so the metadata is extracted
/// from the file name itself.
fn extract_wav_name(allocator: Allocator, file: []const u8) error{OutOfMemory}!?[]const u8 {
    var start: usize = file.len;
    var end: usize = file.len;

    var c: u8 = 0;
    while (start > 0) {
        c = file[start - 1];
        if ((c == '.') or (c >= '0' and c <= '9')) {
            start -= 1;
            end = start;
            continue;
        }
        if (c == '~' or c == '/' or c == '\\') break;
        start -= 1;
    }

    if (start == file.len) return null;
    if (start == end) return null;

    const name = file[start..end];

    if (c == '~') {
        start -= 1;
        end = start;
        while (start > 0) {
            c = file[start - 1];
            if (c == '~' or c == '/' or c == '\\') break;
            start -= 1;
        }
        if (start == end) return null;
        std.debug.assert(start <= end);
    }

    return try allocator.dupe(u8, name);
}

test "remove_extension" {
    try expectEqualStrings("fish", remove_extension("fish.a"));
    try expectEqualStrings("fish", remove_extension("fish.aa"));
    try expectEqualStrings("fish", remove_extension("fish.aaa"));
    try expectEqualStrings("fish", remove_extension("fish.aaaa"));
    try expectEqualStrings("fish", remove_extension("fish.aaaaa"));
    try expectEqualStrings("fish2", remove_extension("fish2.aaaaa"));
    try expectEqualStrings("fish22", remove_extension("fish22.aaaaa"));
    try expectEqualStrings("fish", remove_extension("fish"));
    try expectEqualStrings("/happy/fish", remove_extension("/happy/fish"));
    try expectEqualStrings("/ha.ppy/fish", remove_extension("/ha.ppy/fish"));
    try expectEqualStrings("/happy/fish", remove_extension("/happy/fish.js"));
    try expectEqualStrings("c:\\happy\\fish", remove_extension("c:\\happy\\fish.txt"));
}

test "add_sentence" {
    const allocator = std.testing.allocator;

    var r = Resource.empty;
    defer r.deinit(allocator);

    try r.add_sentence(allocator, "The fish.");

    try expectEqual(2, r.sentences.items.len);
    try expectEqualStrings("The fish.", r.sentences.items[0]);
    try expectEqualStrings("The fish", r.sentences.items[1]);
}

test "wav_filename" {
    const allocator = std.testing.allocator;
    var resources = try Resources.create(allocator);
    defer resources.destroy();

    {
        const name = try extract_wav_name(allocator, "fish9.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "fish9");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "fish");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "fish.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "/bin/fish.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "./bin/fish.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "c:\\bin\\fish.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "ἀρτος.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("ἀρτος", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "jay~ἀρτος.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("ἀρτος", name.?);
    }
    {
        const name = try extract_wav_name(allocator, "jay~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = try extract_wav_name(allocator, "jay2~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = try extract_wav_name(allocator, "other~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = try extract_wav_name(allocator, "other~ἀρτος.wav");
        defer allocator.free(name.?);
        try expectEqualStrings("ἀρτος", name.?);
    }
}

test "read_metadata" {
    const gpa = std.testing.allocator;
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "v:y\nd:1010\n");
        try expectEqual(true, r.visible);
        try expect(r.date != null);
        try expectEqualStrings("1010", r.date.?);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "v:n\nd:1010");
        try expectEqual(false, r.visible);
        try expect(r.date != null);
        try expectEqualStrings("1010", r.date.?);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "c:bob\ni:12ab");
        try expectEqual(true, r.visible);
        try expect(r.copyright != null);
        try expectEqualStrings("bob", r.copyright.?);
        try expectEqual(6538201, r.uid);
    }

    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "v: 0 \nd:1010 ");
        try expectEqual(false, r.visible);
        try expectEqualStrings("1010", r.date.?);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "s: fish \rs:cat dog\nv: true \nd:1010 ");
        try expectEqual(true, r.visible);
        try expectEqualStrings("1010", r.date.?);
        try expectEqual(2, r.sentences.items.len);
        try expectEqualStrings("fish", r.sentences.items[0]);
        try expectEqualStrings("cat dog", r.sentences.items[1]);
    }
}

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const warn = std.log.warn;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const Normalize = @import("Normalize");

pub const encode_uid = @import("base62.zig").encode;
pub const decode_uid = @import("base62.zig").decode;

const settings = @import("settings.zig");
const FileType = @import("file_type.zig").Type;
const Resources = @import("resources.zig").Resources;
const Parser = @import("praxis").Parser;
const load_file_bytes = @import("resources.zig").load_file_bytes;
const write_file_bytes = @import("resources.zig").write_file_bytes;
const sentence_trim = @import("resources.zig").sentence_trim;
