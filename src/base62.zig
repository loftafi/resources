//! Converts an unsigned integer to and from a short uid string.
//!
//! A base62 library could be used in place of this code, but
//! lets avoid an external dependency for something so simple.

/// Read a uid and encode it into a result string. Return a
/// convenience slice into the result string.
///
/// The result buffer can hold all of the digits of a u128, so
/// no buffer overflow is possible unless zig adds a u256.
pub fn encode(comptime I: type, uid: I, result: *[40:0]u8) []const u8 {
    var i: usize = 0;
    var value: I = uid;
    while (value > 0) {
        if (i + 1 == result.len) {
            unreachable;
        }
        const r = @rem(value, 62);
        value = @divFloor(value, 62);
        if (r < 26) {
            result[i] = 'A' + @as(u8, @intCast(r));
        } else if (r < 52) {
            result[i] = 'a' + (@as(u8, @intCast(r)) - 26);
        } else {
            result[i] = '0' + (@as(u8, @intCast(r)) - 52);
        }
        i += 1;
    }
    if (i == 0) {
        if (i + 1 == result.len) {
            unreachable;
        }
        result[i] = 'A';
        i += 1;
    }
    if (i == result.len) {
        unreachable;
    }
    result[i] = 0;
    return result[0..i];
}

pub fn encode_writer(comptime I: type, uid: I) type {
    return struct {
        pub fn format(out: *std.Io.Writer) error{WriteFailed}!void {
            var value: I = uid;

            if (uid == 0) {
                try out.writeByte('A');
                return;
            }
            while (value > 0) {
                const r = @rem(value, 62);
                value = @divFloor(value, 62);
                if (r < 26) {
                    try out.writeByte('A' + @as(u8, @intCast(r)));
                } else if (r < 52) {
                    try out.writeByte('a' + (@as(u8, @intCast(r)) - 26));
                } else {
                    try out.writeByte('0' + (@as(u8, @intCast(r)) - 52));
                }
            }
        }
    };
}

/// Convert a base62 encoded string back to an integer.
pub fn decode(comptime I: type, text: []const u8) error{
    InvalidBase62,
    IntegerOverflow,
}!I {
    var uid: I = 0;
    var i = text.len;
    while (i > 0) {
        if (i == 0) {
            return uid;
        }
        i -= 1;
        uid = std.math.mul(I, uid, 62) catch {
            return error.IntegerOverflow;
        };
        const c = text[i];
        if (c >= 'A' and c <= 'Z') {
            uid = std.math.add(I, uid, c - 'A') catch {
                return error.IntegerOverflow;
            };
        } else if (c >= 'a' and c <= 'z') {
            uid = std.math.add(I, uid, c - 'a' + 26) catch {
                return error.IntegerOverflow;
            };
        } else if (c >= '0' and c <= '9') {
            uid = std.math.add(I, uid, c - '0' + 26 + 26) catch {
                return error.IntegerOverflow;
            };
        } else {
            return error.InvalidBase62;
        }
    }
    return uid;
}

const std = @import("std");
const eq = std.testing.expectEqual;
const seq = std.testing.expectEqualStrings;

test "encode" {
    var result: [40:0]u8 = undefined;
    try seq("A", encode(u64, 0, &result));
    try seq("A", encode(u64, 0, &result));
    try seq("B", encode(u64, 1, &result));
    try seq("9", encode(u64, 61, &result));
    try seq("AB", encode(u64, 62, &result));
    try seq("AAB", encode(u64, 62 * 62, &result));
}

test "encode_stream" {
    const gpa = std.testing.allocator;

    const out = try std.fmt.allocPrint(gpa, "{f}", .{encode_writer(u8, 111)});
    defer gpa.free(out);
    try seq("xB", out);

    const out2 = try std.fmt.allocPrint(gpa, "{f}", .{encode_writer(u8, 3)});
    defer gpa.free(out2);
    try seq("D", out2);

    const out3 = try std.fmt.allocPrint(gpa, "{f}", .{encode_writer(usize, 62 * 62)});
    defer gpa.free(out3);
    try seq("AAB", out3);

    const out4 = try std.fmt.allocPrint(gpa, "{f}", .{encode_writer(usize, 62 * 62 + 1)});
    defer gpa.free(out4);
    try seq("BAB", out4);
}

test "decode" {
    try eq(0, decode(i32, ""));
    try eq(0, decode(i32, "A"));
    try eq(1, decode(i32, "B"));
    try eq(61, decode(u32, "9"));
    try eq(0, decode(u32, "AA"));
    try eq(62, decode(u8, "AB"));
    try eq(63, decode(u8, "BB"));
    try eq(62 * 62, decode(i64, "AAB"));
    try eq(error.InvalidBase62, decode(i64, "AB#"));
    try eq(error.InvalidBase62, decode(usize, "#"));
}
