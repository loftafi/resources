/// Describes a resource. This inforation may be loaded from a
/// directory of files or a bundle of files (archive).
pub const Resource = struct {
    uid: u64,
    visible: bool,
    resource: Type,
    date: ?[]const u8,
    copyright: ?[]const u8,
    sentences: ArrayList([]const u8),

    // on disk resource has a filename
    filename: ?[:0]u8 = null,

    // bundle resources has a bundle offset
    bundle_offset: ?u64 = null,
    size: usize = 0,

    pub fn create(arena_allocator: Allocator) error{OutOfMemory}!*Resource {
        const resource = try arena_allocator.create(Resource);
        errdefer arena_allocator.destroy(resource);
        resource.* = .{
            .uid = 0,
            .resource = .unknown,
            .sentences = ArrayList([]const u8).init(arena_allocator),
            .filename = null,
            .bundle_offset = null,
            .visible = true,
            .size = 0,
            .date = null,
            .copyright = null,
        };
        return resource;
    }

    pub fn load(
        parent_allocator: Allocator,
        arena_allocator: Allocator,
        filename: []u8,
        file_type: Resource.Type,
        sentence_text: ?[]const u8,
        normalise: *Normalize,
    ) error{
        OutOfMemory,
        ReadRepoFileFailed,
        MetadataMissing,
        ReadMetadataFailed,
        InvalidResourceUID,
    }!*Resource {
        var resource = try Resource.create(arena_allocator);
        errdefer resource.destroy(arena_allocator);

        switch (file_type) {
            .svg, .jpx, .csv, .xml, .png, .jpg, .bin => {
                if (filename.len > 0) {
                    resource.filename = try arena_allocator.dupeZ(u8, filename);
                }
                try load_metadata(normalise, resource, filename, arena_allocator, parent_allocator);
            },
            .wav => {
                if (sentence_text == null) {
                    return error.MetadataMissing;
                }
                if (filename.len > 0) {
                    resource.filename = try arena_allocator.dupeZ(u8, filename);
                }
                try resource.sentences.append(try arena_allocator.dupe(u8, sentence_text.?));
                resource.visible = true;
            },
            .ttf, .otf => {
                if (sentence_text == null) {
                    return error.MetadataMissing;
                }
                if (filename.len > 0) {
                    resource.filename = try arena_allocator.dupeZ(u8, filename);
                }
                try resource.sentences.append(try arena_allocator.dupe(u8, sentence_text.?));
                resource.visible = true;
            },
            .unknown => {
                return error.MetadataMissing;
            },
        }

        return resource;
    }

    pub fn destroy(self: *Resource, allocator: Allocator) void {
        for (self.sentences.items) |s| {
            if (s.len > 0) allocator.free(s);
        }
        self.sentences.deinit();

        if (self.filename != null) allocator.free(self.filename.?);
        if (self.copyright != null) allocator.free(self.copyright.?);
        if (self.date != null) allocator.free(self.date.?);

        allocator.destroy(self);
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

fn load_metadata(
    normalise: *Normalize,
    resource: *Resource,
    filename: []u8,
    arena_allocator: Allocator,
    temp_allocator: Allocator,
) error{ OutOfMemory, MetadataMissing, ReadMetadataFailed, InvalidResourceUID }!void {
    const l = filename.len - 3;
    filename[l + 0] = 't';
    filename[l + 1] = 'x';
    filename[l + 2] = 't';
    const data = load_file_bytes(temp_allocator, filename) catch |e| {
        std.debug.print("load_metadata failed reading {s}. Error: {any}\n", .{ filename, e });
        if (e == error.FileNotFound) {
            return error.MetadataMissing;
        } else {
            return error.ReadMetadataFailed;
        }
    };
    defer temp_allocator.free(data);

    const data_nfc = try normalise.nfc(temp_allocator, data);
    defer data_nfc.deinit(temp_allocator);

    if (data.len != data_nfc.slice.len) {
        warn("metadata file {s} is not nfc.", .{filename});
        write_file_bytes(temp_allocator, filename, data_nfc.slice) catch {
            warn("update metadata file {s} to nfc failed.", .{filename});
        };
    }

    var stream = Parser.init(data_nfc.slice);
    while (!stream.eof()) {
        if (settings.next(&stream) catch return error.ReadMetadataFailed) |entry| {
            switch (entry.setting) {
                .uid => {
                    if (entry.value.len > 10) {
                        resource.uid = decode_uid(u64, entry.value[0..10]) catch {
                            return error.InvalidResourceUID;
                        };
                    } else {
                        resource.uid = decode_uid(u64, entry.value) catch {
                            return error.InvalidResourceUID;
                        };
                    }
                    if (resource.uid == 0) {
                        return error.InvalidResourceUID;
                    }
                },
                .date => {
                    resource.date = try arena_allocator.dupe(u8, entry.value);
                },
                .copyright => {
                    resource.copyright = try arena_allocator.dupe(u8, entry.value);
                },
                .visible => {
                    resource.visible = is_true(entry.value);
                },
                .sentence => {
                    if (entry.value.len > 0)
                        try resource.sentences.append(
                            try arena_allocator.dupe(u8, entry.value),
                        );
                },
                else => {},
            }
        }
    }
}

fn is_true(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "y") or
        std.ascii.eqlIgnoreCase(text, "1");
}

const std = @import("std");
const warn = std.log.warn;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Normalize = @import("Normalize");

pub const encode_uid = @import("base62.zig").encode;
pub const decode_uid = @import("base62.zig").decode;

const settings = @import("settings.zig");
const Resources = @import("resources.zig").Resources;
const Parser = @import("praxis").Parser;
const load_file_bytes = @import("resources.zig").load_file_bytes;
const write_file_bytes = @import("resources.zig").write_file_bytes;
