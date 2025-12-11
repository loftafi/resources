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
    json = 10,
    bin = 11,
    ogg = 12,
    mp3 = 13,
    js = 14,

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
            .json => "json",
            .bin => "bin",
            .ogg => "ogg",
            .mp3 => "mp3",
            .js => "js",
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
            .json => ".json",
            .bin => ".bin",
            .ogg => ".ogg",
            .mp3 => ".mp3",
            .js => ".js",
            else => ".unknown",
        };
    }

    pub fn parse(text: []const u8) Type {
        var ext = text;
        if (text.len > 0 and text[0] == '.')
            ext = text[1..];
        if (ext.len == 0) return .unknown;

        if (std.ascii.eqlIgnoreCase(ext, "png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, "svg")) return .svg;
        if (std.ascii.eqlIgnoreCase(ext, "jpg")) return .jpg;
        if (std.ascii.eqlIgnoreCase(ext, "ogg")) return .ogg;
        if (std.ascii.eqlIgnoreCase(ext, "mp3")) return .mp3;
        if (std.ascii.eqlIgnoreCase(ext, "wav")) return .wav;
        if (std.ascii.eqlIgnoreCase(ext, "ttf")) return .ttf;
        if (std.ascii.eqlIgnoreCase(ext, "otf")) return .otf;
        if (std.ascii.eqlIgnoreCase(ext, "csv")) return .csv;
        if (std.ascii.eqlIgnoreCase(ext, "jpx")) return .jpx;
        if (std.ascii.eqlIgnoreCase(ext, "bin")) return .bin;
        if (std.ascii.eqlIgnoreCase(ext, "xml")) return .xml;
        if (std.ascii.eqlIgnoreCase(ext, "js")) return .js;
        if (std.ascii.eqlIgnoreCase(ext, "json")) return .json;

        return .unknown;
    }
};

test "file_type" {
    try expectEqual(.csv, Type.parse("csv"));
    try expectEqual(.csv, Type.parse(".csv"));
    try expectEqual(.png, Type.parse(".PNG"));
    try expectEqual(.png, Type.parse("Png"));
    try expectEqual(.png, Type.parse("pNG"));
    try expectEqual(.unknown, Type.parse("aeihriuhrew"));
    try expectEqual(.unknown, Type.parse(""));
    try expectEqual(.unknown, Type.parse("."));
    try expectEqual(.unknown, Type.parse("-"));
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;
