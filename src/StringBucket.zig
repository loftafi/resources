pub const StringBucket = @This();

const max_fmt_buffer = 1000;

/// Allocate memory for a string if needed, or return a pointer to a
/// prior-allocated version.
bucket: StringHashMapUnmanaged(void),
allocator: Allocator,

pub fn init(allocator: Allocator) StringBucket {
    return .{
        .allocator = allocator,
        .bucket = .empty,
    };
}

pub fn deinit(self: *StringBucket) void {
    var it = self.bucket.iterator();
    while (it.next()) |*iv|
        self.allocator.free(iv.key_ptr.*);
    self.bucket.deinit(self.allocator);
    self.* = undefined;
}

/// Create a copy of the input text (if needed), or return a copy we
/// already created previously.
pub fn add(self: *StringBucket, text: []const u8) error{OutOfMemory}![]const u8 {
    if (text.len == 0) return "";

    const entry = try self.bucket.getOrPut(self.allocator, text);
    if (entry.found_existing) {
        return entry.key_ptr.*;
    } else {
        entry.key_ptr.* = "";
        entry.key_ptr.* = try self.allocator.dupe(u8, text);
        return entry.key_ptr.*;
    }
}

pub fn addZ(self: *StringBucket, text: []const u8) error{OutOfMemory}![:0]const u8 {
    if (text.len >= max_fmt_buffer - 1) return error.OutOfMemory;
    if (text.len == 0) return "";

    var buffer: [max_fmt_buffer]u8 = undefined;
    @memcpy(buffer[0..text.len], text.ptr);
    buffer[text.len] = 0;
    const updated: []u8 = buffer[0 .. text.len + 1];

    const entry = try self.bucket.getOrPut(self.allocator, updated);
    if (entry.found_existing) {
        return @ptrCast(entry.key_ptr.*);
    } else {
        entry.key_ptr.* = "";
        entry.key_ptr.* = try self.allocator.dupe(u8, updated);
        const value = entry.key_ptr.*;
        return @ptrCast(value[0 .. value.len - 1]);
    }
}

/// Build and add a string to the bucket using a zig fmt string pattern.
pub fn addFmt(
    self: *StringBucket,
    comptime fmt: []const u8,
    args: anytype,
) error{ OutOfMemory, NoSpaceLeft }![]const u8 {
    var buff: [max_fmt_buffer]u8 = undefined;
    const str = try std.fmt.bufPrint(&buff, fmt, args);
    return self.add(str);
}

/// Build a string to put into the bucket by replacing fields in the
/// `fmt` string with contents of the  `args` struct. i.e.
/// `addFields("my name is {name}", .{.name = "Frank"});
pub fn addFields(
    self: *StringBucket,
    fmt: []const u8,
    args: anytype,
) error{ OutOfMemory, NoSpaceLeft }![]const u8 {
    var buff: [max_fmt_buffer]u8 = undefined;
    const str = try tagFormat(fmt, args, &buff);
    return self.add(str);
}

/// Replace fields in the `fmt` string with contents of the  `args` struct. i.e.
/// `tagFormat("my name is {name}", .{.name = "Frank"}, &buffer);
pub fn addRemoveCRLF(self: *StringBucket, string: []const u8, buf: []u8) error{ NoSpaceLeft, OutOfMemory }![]const u8 {
    var w: std.Io.Writer = .fixed(buf);

    var data = string;
    var previous: u8 = 0;
    while (data.len > 0) {
        const c = data[0];
        if (c == CR or c == LF) {
            if (previous != SPACE) w.writeByte(SPACE) catch return error.NoSpaceLeft;
            previous = SPACE;
            data = data[1..];
            continue;
        }
        if (c == '\\' and data.len > 1 and (data[1] == 'n' or data[1] == 'r')) {
            if (previous != SPACE) w.writeByte(SPACE) catch return error.NoSpaceLeft;
            previous = SPACE;
            data = data[2..];
            continue;
        }
        w.writeByte(c) catch return error.NoSpaceLeft;
        previous = c;
        data = data[1..];
    }

    return try self.add(w.buffered());
}

const CR = '\r';
const LF = '\n';
const SPACE = ' ';
const TAB = '\t';

/// Replace fields in the `fmt` string with contents of the  `args` struct. i.e.
/// `tagFormat("my name is {name}", .{.name = "Frank"}, &buffer);
pub fn tagFormat(fmt: []const u8, args: anytype, buf: []u8) error{NoSpaceLeft}![]u8 {
    var w: std.Io.Writer = .fixed(buf);

    var start: usize = 0;
    while (start < fmt.len) {
        var c = fmt[start];
        if (c == '{') {
            start += 1;
            var end = start;
            while (c != '}') {
                if (end >= fmt.len) unreachable;
                c = fmt[end];
                end += 1;
            }
            if (start == end) unreachable;

            const field_name = fmt[start .. end - 1];

            var found = false;
            inline for (std.meta.fields(@TypeOf(args))) |field| {
                if (std.ascii.eqlIgnoreCase(field.name, field_name)) {
                    found = true;
                    const value = @field(args, field.name);
                    if (@typeInfo(field.type) == .pointer) {
                        w.print("{s}", .{value}) catch |e| switch (e) {
                            error.WriteFailed => return error.NoSpaceLeft,
                        };
                    } else {
                        w.print("{any}", .{value}) catch |e| switch (e) {
                            error.WriteFailed => return error.NoSpaceLeft,
                        };
                    }
                }
            }
            if (!found) {
                w.print("{s}", .{field_name}) catch |e| switch (e) {
                    error.WriteFailed => return error.NoSpaceLeft,
                };
            }

            start = end;
        } else {
            var end = start;
            while (c != '{' and end < fmt.len) {
                c = fmt[end];
                end += 1;
            }
            if (c == '{') {
                end -= 1;
                w.print("{s}", .{fmt[start..end]}) catch |e| switch (e) {
                    error.WriteFailed => return error.NoSpaceLeft,
                };
                start = end;
            } else {
                w.print("{s}", .{fmt[start..end]}) catch |e| switch (e) {
                    error.WriteFailed => return error.NoSpaceLeft,
                };
                start = end;
            }
        }
    }

    return w.buffered();
}

test "string_bucket" {
    var bucket = StringBucket.init(std.testing.allocator);
    defer bucket.deinit();

    const a = try bucket.add("a");
    const a2 = try bucket.add("a");
    const a3 = try bucket.addZ("a");
    try expectEqual(a.ptr, a2.ptr);
    try expectEqualDeep(a, a2);
    try expectEqual(1, a3.len);
    const a3z: [:0]const u8 = "a";
    try expectEqualDeep(a3z, a3);
}

test "string_bucket_fmt" {
    var bucket = StringBucket.init(std.testing.allocator);
    defer bucket.deinit();

    const a = try bucket.addFmt("a{d}", .{1});
    const a2 = try bucket.addFmt("a{d}", .{1});
    try expectEqual(a.ptr, a2.ptr);
    try expectEqualDeep(a, a2);
}

test "string_bucket_nocrlf" {
    var bucket = StringBucket.init(std.testing.allocator);
    defer bucket.deinit();

    var buffer: [100]u8 = undefined;

    const a = try bucket.addRemoveCRLF("a\nb", &buffer);
    const a2 = try bucket.addRemoveCRLF("a\nb\n", &buffer);
    const a3 = try bucket.addRemoveCRLF("a\\nb", &buffer);
    const a4 = try bucket.addRemoveCRLF("a\\rb", &buffer);
    try expectEqualDeep("a b", a);
    try expectEqualDeep("a b ", a2);
    try expectEqualDeep("a b", a3);
    try expectEqualDeep("a b", a4);
}

test "large_string_bucket" {
    var bucket = StringBucket.init(std.testing.allocator);
    defer bucket.deinit();

    for (0..26) |a| {
        for (0..26) |b| {
            var buffer: [2]u8 = undefined;
            buffer[0] = @intCast(a + 'a');
            buffer[1] = @intCast(b + 'a');
            const v = try bucket.add(&buffer);
            _ = try bucket.add(&buffer);
            try expectEqualDeep(v, &buffer);
        }
    }
    try expectEqual(26 * 26, bucket.bucket.count());
}

test "tag_format" {
    var buffer: [20000]u8 = undefined;

    try expectEqualStrings("name=james", try tagFormat("name={name}", .{ .name = "james" }, &buffer));
    try expectEqualStrings("name=james", try tagFormat("name={NAME}", .{ .name = "james" }, &buffer));
    try expectEqualStrings("name=james", try tagFormat("name={name}", .{ .NAME = "james" }, &buffer));
    try expectEqualStrings("name", try tagFormat("name", .{}, &buffer));
    try expectEqualStrings("james", try tagFormat("{name}", .{ .NAME = "james" }, &buffer));
    try expectEqualStrings("namejames", try tagFormat("{field}{name}", .{ .field = "name", .name = "james" }, &buffer));
    try expectEqualStrings("name=james", try tagFormat("{field}={name}", .{ .field = "name", .name = "james" }, &buffer));
}

pub const std = @import("std");
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectEqualDeep = std.testing.expectEqualDeep;
pub const Allocator = std.mem.Allocator;
pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
