/// Old resources might have a uid longer than 10 which does not
/// fit into a u64. These are cleaned up as they are encountered.
pub const max_uid_length = 10;
pub const max_filename_length = 1024 * 2;

/// Describes a resource. This inforation may be loaded from a
/// directory of files or a bundle of files (archive).
pub const Resource = @This();

uid: u64,
visible: bool,
date: usize,
copyright: ?[]const u8,
link: ?[]const u8,
sentences: ArrayListUnmanaged([]const u8),

resource: Type,

// Name of actual file, or bundle filename containing the file.
filename: ?[:0]u8 = null,

// bundle resources has a bundle offset
bundle_offset: ?u64 = null,

size: usize = 0,

pub const empty: Resource = .{
    .uid = 0,
    .visible = true,
    .resource = .unknown,
    .date = 0,
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

    if (self.bundle_offset == null)
        if (self.filename != null)
            allocator.free(self.filename.?);

    self.* = undefined;
}

/// Load a data file from the resources folder into the search index.
/// If the file has an associated metadata file, also load the metadata.
pub fn load(
    self: *Resource,
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    filename: []const u8,
    file_name: []const u8,
    file_type: Type,
    string_bucket: *StringBucket,
) (error{OutOfMemory} || Resources.Error || std.Io.File.StatError || std.Io.File.OpenError || std.fmt.BufPrintError)!void {
    if (filename.len > 0) self.filename = try arena.dupeZ(u8, filename);

    self.resource = file_type;

    if (file_type == .wav) {
        if (extract_wav_name(filename)) |sentence| {
            const sentence_nfc = try Normalize.nfc(gpa, sentence);
            defer sentence_nfc.deinit(gpa);
            try self.addSentence(arena, sentence_nfc.slice);
        }
    }

    // Check if there is a metadata file to load.
    var buf: [max_filename_length]u8 = undefined;
    const metadata_file = std.fmt.bufPrint(&buf, "{s}.txt", .{removeExtension(filename)}) catch return error.FilenameTooLong;
    const data = load_file_bytes(gpa, io, metadata_file) catch |e| {
        if (e == error.FileNotFound) {
            // If no metadata file exists, default to visible
            self.visible = true;
            if (self.uid == 0 and file_type == .wav) {
                self.uid = try hash_uid(io, file_name, filename);
            }
            return;
        } else {
            return error.ReadMetadataFailed;
        }
    };
    defer gpa.free(data);
    const data_nfc = try Normalize.nfc(gpa, data);
    defer data_nfc.deinit(gpa);

    if (data.len != data_nfc.slice.len) {
        warn("metadata file {s} is not nfc.", .{metadata_file});
        write_file_bytes(io, filename, data_nfc.slice) catch {
            warn("update metadata file {s} to nfc failed.", .{metadata_file});
        };
    }

    return self.readMetadata(arena, data_nfc.slice, string_bucket);
}

/// Form a uid from the name of the file and the size of the file. Not
/// perfect, but it is faster than continually hashing entire files
fn hash_uid(
    io: std.Io,
    name: []const u8,
    path_name: []const u8,
) (std.Io.File.StatError || std.Io.File.OpenError)!u64 {
    var buff: [40]u8 = undefined;
    const stat = try std.Io.Dir.cwd().statFile(io, path_name, .{ .follow_symlinks = false });
    const size_info = try std.fmt.bufPrint(&buff, "{d}", .{stat.size});
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    sha256.update(name);
    sha256.update(size_info);
    const data = sha256.finalResult();
    return @bitCast(data[0..8].*);
}

/// Update fields of this object using metadata fileds in a text file.
fn readMetadata(
    self: *Resource,
    allocator: Allocator,
    data: []const u8,
    string_bucket: *StringBucket,
) (error{ InvalidResourceUID, ReadMetadataFailed, MetadataMissing } || Allocator.Error)!void {
    var text = data;
    while (text.len > 0) {

        // Read the field
        while (text.len > 0 and isWhitespace(text[0])) {
            text = text[1..];
        }
        if (text.len == 0) break;
        const field = text[0];
        text = text[1..];
        while (text.len > 0 and (isWhitespace(text[0]) or text[0] == ':' or text[0] == '=')) {
            text = text[1..];
        }

        var eov: usize = 0;
        var end_candidate: usize = 0;
        while (text.len > eov and text[eov] != '\n' and text[eov] != '\r') {
            if (!isWhitespace(text[eov])) end_candidate = eov + 1;
            eov += 1;
        }
        const value = text[0..end_candidate];
        text = text[eov..];
        if (value.len == 0) continue;

        switch (field) {
            's', 'S' => try self.addSentence(allocator, value),
            'c', 'C' => self.copyright = try string_bucket.add(value),
            'v', 'V' => self.visible = isTrue(value),
            'd', 'D' => self.date = std.fmt.parseInt(usize, value, 10) catch return error.ReadMetadataFailed,
            'l', 'L' => self.link = try allocator.dupe(u8, value),
            'i', 'I' => {
                if (value.len > max_uid_length) {
                    self.uid = base62.decode(u64, value[0..max_uid_length]) catch {
                        return error.InvalidResourceUID;
                    };
                    continue;
                } else {
                    self.uid = base62.decode(u64, value) catch {
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
/// sentences are added. If non-significant punctuation is found at the
/// end of this sentence, also attach a non punctuated version.
fn addSentence(
    self: *Resource,
    allocator: Allocator,
    text: []const u8,
) (error{MetadataMissing} || Allocator.Error)!void {
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

    if (trimSentence(text)) |trim| {
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

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn isTrue(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "y") or
        std.ascii.eqlIgnoreCase(text, "1");
}

fn removeExtension(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0) {
        if (end + 6 < path.len) break;
        if (path[end - 1] == '.')
            return path[0 .. end - 1];
        end -= 1;
    }
    return path;
}

/// Compare two `Resource` items by `uid`.
pub fn lessThan(_: ?[]const u8, self: *Resource, other: *Resource) bool {
    return self.uid < other.uid;
}

/// Wav files don't have metadata files, so the metadata is extracted
/// from the file name itself.
fn extract_wav_name(text: []const u8) ?[]const u8 {
    var last_dot: ?usize = null;
    for (0..text.len) |i| {
        if (text[i] == '.') last_dot = i;
    }
    var end = if (last_dot != null) last_dot.? else text.len;
    while (end > 0 and isDigit(text[end - 1])) end = end - 1;

    var first_tilde: ?usize = null;
    for (0..end) |i| {
        if (text[i] == '~') {
            if (first_tilde != null) return null;
            first_tilde = i + 1;
        }
    }
    if (first_tilde != null and first_tilde.? < text.len and isDigit(text[first_tilde.?])) return null;
    var start = if (first_tilde != null) first_tilde.? else 0;

    for (start..end) |i| {
        if (text[i] == '/' or text[i] == '\\')
            start = i + 1;
    }

    if (start == end) return null;
    return text[start..end];
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Remove trailing punctuation that doesn't have meaning impliations.
/// i.e. remove full stop and comma, but leave question mark.
///
/// There may be an argument for keeping exclamation mark.
pub fn trimSentence(sentence: []const u8) ?[]const u8 {
    var trimmed: []const u8 = sentence;
    while (true) {
        const last = trimmed[trimmed.len - 1];

        if (last == '.' or last == ',' or last == '!' or last == ':' or last == ';') {
            trimmed.len -= 1;
            continue;
        }
        if (std.mem.endsWith(u8, trimmed, "·")) {
            trimmed.len -= "·".len;
            continue;
        }
        break;
    }
    if (trimmed.len == sentence.len)
        return null;
    return trimmed;
}

pub fn write_file_bytes(
    io: std.Io,
    filename: []const u8,
    data: []const u8,
) (Allocator.Error || std.Io.Writer.Error || std.Io.File.OpenError || std.Io.Dir.RenameError || std.Io.File.Writer.Error)!void {
    try write_folder_file_bytes(io, std.Io.Dir.cwd(), filename, data);
}

pub fn write_folder_file_bytes(
    io: std.Io,
    folder: std.Io.Dir,
    filename: []const u8,
    data: []const u8,
) (Allocator.Error || std.Io.Writer.Error || std.Io.File.OpenError || std.Io.Dir.RenameError || std.Io.File.Writer.Error)!void {
    var buffer: [16]u8 = undefined;
    const tmp_filename = random.random_string(&buffer);
    const file = folder.createFile(io, tmp_filename, .{ .read = false, .truncate = true }) catch |e| {
        err("Failed to open file for writing: {s}. {any}", .{ filename, e });
        return e;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try std.Io.Dir.rename(folder, tmp_filename, folder, filename, io);
}

pub fn cache_has_file(
    io: std.Io,
    folder: std.Io.Dir,
    filename: []const u8,
) (std.Io.File.StatError || std.Io.Dir.StatFileError)!?usize {
    const stat = folder.statFile(io, filename, .{ .follow_symlinks = false }) catch |f| {
        if (f == error.FileNotFound) return null;
        return f;
    };
    return stat.size;
}

// std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited)
pub fn load_file_bytes(
    allocator: Allocator,
    io: std.Io,
    filename: []const u8,
) (Allocator.Error || std.Io.File.OpenError || std.Io.Reader.Error || std.Io.Reader.LimitedAllocError)![]u8 {
    const file = std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only }) catch |e| {
        if (!std.ascii.endsWithIgnoreCase(filename, ".txt"))
            debug("load_file_bytes failed to read file: {s}  {any}", .{ filename, e });
        return e;
    };
    defer file.close(io);
    var tmp: [1024 * 5]u8 = undefined;
    var reader = file.reader(io, &tmp);
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

// folder.readFileAlloc(io, filename, allocator, .unlimited)
pub fn load_folder_file_bytes(
    allocator: Allocator,
    io: std.Io,
    folder: std.Io.Dir,
    filename: []const u8,
) (Allocator.Error || std.Io.File.OpenError || std.Io.Reader.LimitedAllocError || std.Io.Reader.Error)![]u8 {
    const file = folder.openFile(io, filename, .{ .mode = .read_only }) catch |e| {
        return e;
    };
    defer file.close(io);
    var tmp: [1024 * 5]u8 = undefined;
    var reader = file.reader(io, &tmp);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

pub fn load_file_byte_slice(
    allocator: Allocator,
    io: std.Io,
    filename: []const u8,
    offset: usize,
    size: usize,
) (Allocator.Error || std.Io.File.OpenError || std.Io.Reader.Error || std.Io.File.StatError || std.Io.File.SeekError || Resources.Error)![]u8 {
    const file = std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only }) catch |e| {
        err("Repo file missing: {s}", .{filename});
        return e;
    };
    defer file.close(io);
    var tmp: [1024 * 5]u8 = undefined;
    var reader = file.reader(io, &tmp);
    reader.seekTo(offset) catch |e| {
        err("Seek file failed: {s} {d} {d} Error: {any}", .{ filename, offset, size, e });
        return e;
    };
    return reader.interface.readAlloc(allocator, size);
}

test "read resource info" {
    const text = "i:f43ih\nd:202309072345\nc:copy\ns:ὁ ἄρτος.\nv:true\n\n";
    var data = Parser.init(text);
    const element = try Setting.next(&data);
    try expect(element != null);
    try expectEqual(.uid, element.?.setting);
    try expectEqualStrings("f43ih", element.?.value);
    const element2 = try Setting.next(&data);
    try expect(element2 != null);
    try expectEqual(.date, element2.?.setting);
    try expectEqualStrings("202309072345", element2.?.value);
}

test "read resource info space" {
    const text = " i:f43ih  \n\r\nd:   202309072345   \nc:copy\ns:ὁ ἄρτος.\nv:true\n\n";
    var data = Parser.init(text);
    const element = try Setting.next(&data);
    try expect(element != null);
    try expectEqual(.uid, element.?.setting);
    try expectEqualStrings("f43ih", element.?.value);
    const element2 = try Setting.next(&data);
    try expect(element2 != null);
    try expectEqual(.date, element2.?.setting);
    try expectEqualStrings("202309072345", element2.?.value);
}

test "test_load_file_bytes" {
    const data = try load_file_bytes(std.testing.allocator, std.testing.io, "./test/test.txt");
    defer std.testing.allocator.free(data);
    try expectEqualStrings("simple\n", data);
}

test "test_write_file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "this is a test\n";
    const filename = "test.dat";

    try write_folder_file_bytes(io, tmp.dir, filename, data);
    const read = try load_folder_file_bytes(gpa, io, tmp.dir, filename);
    defer std.testing.allocator.free(read);
    try expectEqualStrings(data, read);
}

test "removeExtension" {
    try expectEqualStrings("fish", removeExtension("fish.a"));
    try expectEqualStrings("fish", removeExtension("fish.aa"));
    try expectEqualStrings("fish", removeExtension("fish.aaa"));
    try expectEqualStrings("fish", removeExtension("fish.aaaa"));
    try expectEqualStrings("fish", removeExtension("fish.aaaaa"));
    try expectEqualStrings("fish2", removeExtension("fish2.aaaaa"));
    try expectEqualStrings("fish22", removeExtension("fish22.aaaaa"));
    try expectEqualStrings("fish", removeExtension("fish"));
    try expectEqualStrings("fish.head", removeExtension("fish.head.txt"));
    try expectEqualStrings("o", removeExtension("o"));
    try expectEqualStrings("/happy/fish", removeExtension("/happy/fish"));
    try expectEqualStrings("/ha.ppy/fish", removeExtension("/ha.ppy/fish"));
    try expectEqualStrings("/happy/fish", removeExtension("/happy/fish.js"));
    try expectEqualStrings("c:\\happy\\fish", removeExtension("c:\\happy\\fish.txt"));
}

test "addSentence" {
    const allocator = std.testing.allocator;

    var r = Resource.empty;
    defer r.deinit(allocator);

    try r.addSentence(allocator, "The fish.");

    try expectEqual(2, r.sentences.items.len);
    try expectEqualStrings("The fish.", r.sentences.items[0]);
    try expectEqualStrings("The fish", r.sentences.items[1]);
}

test "wav_filename" {
    const gpa = std.testing.allocator;

    var resources: Resources = try .init(gpa);
    defer resources.deinit(gpa);

    {
        const name = extract_wav_name("fish9.wav");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("fish9");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("fish");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("fish.wav");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("/bin/fish.wav");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("./bin/fish.wav");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("c:\\bin\\fish.wav");
        try expectEqualStrings("fish", name.?);
    }
    {
        const name = extract_wav_name("ἀρτος.wav");
        try expectEqualStrings("ἀρτος", name.?);
    }
    {
        const name = extract_wav_name("jay~ἀρτος.wav");
        try expectEqualStrings("ἀρτος", name.?);
    }
    {
        const name = extract_wav_name("jay~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = extract_wav_name("jay2~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = extract_wav_name("other~ἀρτος~2.wav");
        try expectEqual(null, name);
    }
    {
        const name = extract_wav_name("other~ἀρτος.wav");
        try expectEqualStrings("ἀρτος", name.?);
    }
    {
        const name = extract_wav_name("jay~εἷς κύων. δύο ἄνδρες.wav");
        try expectEqualStrings("εἷς κύων. δύο ἄνδρες", name.?);
    }
    try expectEqualStrings("dr.wa", extract_wav_name("j~dr.wa.txt").?);
    try expectEqualStrings("dr.wa", extract_wav_name("j~dr.wa2.txt").?);
    try expectEqualStrings("dr.wa", extract_wav_name("/var/j~dr.wa2.txt").?);
    try expectEqual(null, extract_wav_name(""));
    try expectEqual(null, extract_wav_name("2"));
    try expectEqual(null, extract_wav_name("jay~fish~2.txt"));
    try expectEqual(null, extract_wav_name("jay~f ish~2.txt"));
}

test "readMetadata" {
    const gpa = std.testing.allocator;
    var bucket: StringBucket = .init(gpa);
    defer bucket.deinit();

    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.readMetadata(gpa, "v:y\nd:1010\n", &bucket);
        try expectEqual(true, r.visible);
        try expectEqual(1010, r.date);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.readMetadata(gpa, "v:n\nd:1010", &bucket);
        try expectEqual(false, r.visible);
        try expectEqual(1010, r.date);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.readMetadata(gpa, "c:bob\ni:12ab", &bucket);
        try expectEqual(true, r.visible);
        try expect(r.copyright != null);
        try expectEqualStrings("bob", r.copyright.?);
        try expectEqual(6538201, r.uid);
        try expectEqual(0, r.date);
    }

    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.readMetadata(gpa, "v: 0 \nd:20260102030405 ", &bucket);
        try expectEqual(false, r.visible);
        try expectEqual(20260102030405, r.date);
    }
    {
        var r: Resource = .empty;
        defer r.deinit(gpa);
        try r.readMetadata(gpa, "s: fish \rs:cat dog\nv: true \nd:1010 ", &bucket);
        try expectEqual(true, r.visible);
        try expectEqual(1010, r.date);
        try expectEqual(2, r.sentences.items.len);
        try expectEqualStrings("fish", r.sentences.items[0]);
        try expectEqualStrings("cat dog", r.sentences.items[1]);
    }
}

const std = @import("std");
const err = std.log.err;
const debug = std.log.debug;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const warn = std.log.warn;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;

const Normalize = @import("Normalize");

const base62 = @import("base62.zig");

pub const random = @import("random.zig");

const Setting = @import("Setting.zig");
const Type = @import("root.zig").Type;
const Resources = @import("Resources.zig");
const Parser = @import("praxis").Parser;

const StringBucket = @import("StringBucket.zig");
