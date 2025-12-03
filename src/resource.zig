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

    resource: Type,

    // on disk resource has a filename
    filename: ?[:0]u8 = null,

    // bundle resources has a bundle offset
    bundle_offset: ?u64 = null,
    size: usize = 0,

    pub const empty: Resource = .{
        .uid = 0,
        .visible = false,
        .resource = .unknown,
        .date = null,
        .copyright = null,
        .link = null,
        .sentences = .empty,
        .filename = null,
        .bundle_offset = null,
        .size = 0,
    };

    pub fn create(arena: Allocator) error{OutOfMemory}!*Resource {
        const resource = try arena.create(Resource);
        errdefer arena.destroy(resource);
        resource.* = .empty;
        return resource;
    }

    pub fn destroy(self: *Resource, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

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
        file_type: Resource.Type,
    ) (error{OutOfMemory} || Resources.Error)!void {
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

        try self.read_metadata(arena, data_nfc.slice);
    }

    pub fn read_metadata(self: *Resource, arena: Allocator, data: []const u8) (error{ InvalidResourceUID, ReadMetadataFailed, MetadataMissing } || Allocator.Error)!void {
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
                's', 'S' => try self.add_sentence(arena, value),
                'c', 'C' => self.copyright = try arena.dupe(u8, value),
                'v', 'V' => self.visible = is_true(value),
                'd', 'D' => self.date = try arena.dupe(u8, value),
                'l', 'L' => self.link = try arena.dupe(u8, value),
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

    fn add_sentence(self: *Resource, arena: Allocator, text: []const u8) (error{MetadataMissing} || Allocator.Error)!void {
        if (text.len == 0) return error.MetadataMissing;
        try self.sentences.append(arena, try arena.dupe(u8, text));

        if (sentence_trim(text)) |trim|
            if (trim.len > 0)
                try self.sentences.append(arena, try arena.dupe(u8, trim));
    }

    /// Supported resource file types
    pub const Type = enum(u8) {
        unknown = 0,
        wav = 1,
        png = 2,
        jpg = 3,
        svg = 4,
        ttf = 5,
        otf = 6,
        csv = 7,
        jpx = 8,
        xml = 9,
        //json = 10,
        bin = 11,

        pub fn extension(self: Type) [:0]const u8 {
            return switch (self) {
                .wav => "wav",
                .png => "png",
                .jpg => "jpg",
                .svg => "svg",
                .ttf => "ttf",
                .otf => "otf",
                .csv => "csv",
                .jpx => "jpx",
                .xml => "xml",
                //.json => "json",
                .bin => "bin",
                else => "unknown",
            };
        }

        pub fn dot_extension(self: Type) [:0]const u8 {
            return switch (self) {
                .wav => ".wav",
                .png => ".png",
                .jpg => ".jpg",
                .svg => ".svg",
                .ttf => ".ttf",
                .otf => ".otf",
                .csv => ".csv",
                .jpx => ".jpx",
                .xml => ".xml",
                //.json => ".json",
                .bin => ".bin",
                else => ".unknown",
            };
        }
    };
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

// Wav files don't have metadata files, so the metadata is extracted
// from the file name itself.
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
        const voice = file[start..end];
        if (!std.ascii.eqlIgnoreCase("jay", voice)) return null;
    }

    return try allocator.dupe(u8, name);
}

test "remove_extension" {
    try expectEqualStrings("fish", remove_extension("fish.a"));
    try expectEqualStrings("fish", remove_extension("fish.aa"));
    try expectEqualStrings("fish", remove_extension("fish.aaa"));
    try expectEqualStrings("fish", remove_extension("fish.aaaa"));
    try expectEqualStrings("fish", remove_extension("fish.aaaaa"));
    try expectEqualStrings("fish", remove_extension("fish"));
    try expectEqualStrings("/happy/fish", remove_extension("/happy/fish"));
    try expectEqualStrings("/ha.ppy/fish", remove_extension("/ha.ppy/fish"));
    try expectEqualStrings("/happy/fish", remove_extension("/happy/fish.js"));
    try expectEqualStrings("c:\\happy\\fish", remove_extension("c:\\happy\\fish.txt"));
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
        try expectEqual(null, name);
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
        try r.read_metadata(gpa, "v:y\nd:1010");
        try expectEqual(true, r.visible);
        try expect(r.date != null);
        try expectEqualStrings("1010", r.date.?);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "c:bob\ni:12ab");
        try expectEqual(false, r.visible);
        try expect(r.copyright != null);
        try expectEqualStrings("bob", r.copyright.?);
        try expectEqual(6538201, r.uid);
    }

    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.read_metadata(gpa, "v: y \nd:1010 ");
        try expectEqual(true, r.visible);
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
const Resources = @import("resources.zig").Resources;
const Parser = @import("praxis").Parser;
const load_file_bytes = @import("resources.zig").load_file_bytes;
const write_file_bytes = @import("resources.zig").write_file_bytes;
const sentence_trim = @import("resources.zig").sentence_trim;
