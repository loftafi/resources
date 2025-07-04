//! Facilitate reading binary elements from a data array.

/// Data buffer we are reading
data: []const u8,

/// Original data buffer
original: []const u8,

/// Index of how many bytes we have read
index: usize,

pub const Self = @This();

/// Wrap a string of bytes with a parser. This wrapper does not need
/// `deinit()`. Use `next_element()` to fetch items.
pub fn init(d: []const u8) Self {
    return Self{
        .data = d,
        .original = d,
        .index = 0,
    };
}

pub inline fn eof(self: *Self) bool {
    return self.data.len == 0;
}

pub inline fn peek(self: *Self) u8 {
    if (self.data.len == 0) {
        return 0;
    }
    return self.data[0];
}

/// Read until a separator, 0, US, RS, FS
pub fn string(self: *Self) error{unexpected_eof}![]const u8 {
    if (self.data.len == 0) {
        return error.unexpected_eof;
    }
    var index: usize = 0;
    while (index < self.data.len) {
        const p = self.data[index];
        if (p == 0 or p == US or p == RS or p == FS) {
            const value = self.data[0..index];
            self.move(index + 1);
            return value;
        }
        index += 1;
    }
    const value = self.data[0..index];
    self.move(index);
    return value;
}

/// Read a fixed number of bytes
pub fn slice(self: *Self, size: usize) error{unexpected_eof}![]const u8 {
    if (self.data.len == 0) {
        return error.unexpected_eof;
    }
    if (self.data.len < size) {
        return error.unexpected_eof;
    }
    const value = self.data[0..size];
    self.move(size);
    return value;
}

inline fn move(self: *Self, bytes: usize) void {
    self.data.len -= bytes;
    self.data.ptr += bytes;
    self.index += bytes;
}

//const b1: u32 = self.data[0];
//const b2: u32 = self.data[1];
//const b3: u32 = self.data[2];
//const b4: u32 = self.data[3];
//return b1 + (b2 << 8) + (b3 << 16) + (b4 << 24);
pub fn @"u32"(self: *Self) error{unexpected_eof}!u32 {
    if (self.data.len < 4) {
        return error.unexpected_eof;
    }
    const value = std.mem.readInt(u32, self.data[0..4], .little);
    self.move(4);
    return value;
}

//const b1: u24 = self.data[0];
//const b2: u24 = self.data[1];
//const b3: u24 = self.data[2];
//return b1 + (@as(u24, b2) << 8) + (@as(u24, b3) << 16);
pub fn @"u24"(self: *Self) error{unexpected_eof}!u24 {
    if (self.data.len < 3) {
        return error.unexpected_eof;
    }
    const value = std.mem.readInt(u24, self.data[0..3], .little);
    self.move(3);
    return value;
}

//const b1: u8 = self.data[0];
//const b2: u8 = self.data[1];
//return b1 + (@as(u16, b2) << 8);
pub fn @"u16"(self: *Self) error{unexpected_eof}!u16 {
    if (self.data.len < 2) {
        return error.unexpected_eof;
    }
    const value = std.mem.readInt(u16, self.data[0..2], .little);
    self.move(2);
    return value;
}

pub fn @"u8"(self: *Self) error{unexpected_eof}!u8 {
    if (self.data.len < 1) {
        return error.unexpected_eof;
    }
    const b1: u8 = self.data[0];
    self.move(1);
    return b1;
}

pub inline fn unicode(self: *Self) error{ unexpected_eof, InvalidUtf8 }!u21 {
    if (self.data.len == 0) {
        return error.unexpected_eof;
    }
    const size = @as(usize, std.unicode.utf8ByteSequenceLength(self.data[0]) catch |e| {
        if (e == error.InvalidUtf8) {
            std.debug.print("invalid utf8 at byte index {any}\n", .{self.index});
        }
        return e;
    });
    const c: u21 = std.unicode.utf8Decode(self.data[0..size]) catch |e| {
        if (e == error.InvalidUtf8) {
            std.debug.print("invalid utf8 at byte index {any}\n", .{self.index});
        }
        return e;
    };
    self.index += size;
    return c;
}

pub fn leading_slice(self: *Self, size: usize) []const u8 {
    if (size >= self.index) {
        return self.original[self.index - size .. self.index];
    }
    return self.original[0..self.index];
}

pub fn following_slice(self: *Self, size: usize) []const u8 {
    if (self.data.len == 0) {
        return "";
    }
    if (size + 1 <= self.data.len) {
        return self.original[1 .. size + 1];
    }
    return self.original[1..];
}

const eql = @import("std").mem.eql;

pub const FS = 28; // File separator
pub const GS = 29; // Group (table) separator
pub const RS = 30; // Record separator
pub const US = 31; // Field (record) separator

const std = @import("std");
const expect = std.testing.expect;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "binary_read" {
    var data = init("abc\x00def");
    try expectEqualStrings("abc", try data.string());
    try expectEqualStrings("def", try data.string());

    data = init("abc\x1fdef\x1e");
    try expectEqualStrings("abc", try data.string());
    try expectEqualStrings("def", try data.string());

    data = init("abc\x1f\x80def\x1e\x01\x01");
    try expectEqualStrings("abc", try data.string());
    try expectEqual(128, try data.u8());
    try expectEqualStrings("def", try data.string());
    try expectEqual(257, try data.u16());

    data = init("\x01\x02\x03");
    try expectEqual(1, try data.u8());
    try expectEqual(2, try data.u8());
    try expectEqual(3, try data.u8());

    data = init("\x01\x00\x00\x02\x00\x00\x10\x01\x02");
    try expectEqual(1, try data.u24());
    try expectEqual(2, try data.u24());
    try expectEqual(16, try data.u8());
    try expectEqual(1 + 256 * 2, try data.u16());
}
