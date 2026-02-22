//! A simple random number generator useful when there is no need to
//! to depend upon slower more complex random number algorithms.

/// Holds the next value in the random number sequence.
var value: usize = 99;

/// Track if seeding has occurred.
var seeded: bool = false;

/// Return a number greater than zero, and less than the `limit`. Call `seed()`
/// first if you do not want a predictable sequence of numbers.
pub fn random(limit: usize) usize {
    if (limit == 0) return 0;

    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value % limit;
}

/// Return a random u24 value. Call `seed(io)` first if you do
/// not want a predictable number sequence.
pub inline fn random_u24() u24 {
    return @intCast(random(std.math.maxInt(u24)));
}

/// Return a random u16 value. Call `seed(io)` first if
/// you do not want a predictable number sequence.
pub inline fn random_u16() u16 {
    return @intCast(random(std.math.maxInt(u16)));
}

/// Return a random u64 value. Call `seed(io)` first if you
/// do not want a predictable number sequence.
pub inline fn random_u64() u64 {
    return @as(u64, random(std.math.maxInt(u64)));
}

/// Fill a `buffer` with random uppercase letters, lowercase
/// letters, and numbers.
pub fn random_string(buffer: []u8) []const u8 {
    for (0..buffer.len) |i| {
        buffer[i] = @as(u8, @intCast(switch (random(26 + 26 + 10)) {
            0...25 => |n| 'a' + n,
            26...51 => |n| 'A' + (n - 26),
            52...61 => |n| '0' + (n - 52),
            else => '-',
        }));
    }
    return buffer[0..buffer.len];
}

/// Seed the random number generator with the current time
pub fn seed(io: std.Io) void {
    if (seeded) return;

    const timestamp = std.Io.Timestamp.now(io, .real);
    value = @intCast(timestamp.toMilliseconds());
}

test "random_string" {
    seed(std.testing.io);
    var buffer1: [8]u8 = undefined;
    try expectEqual(buffer1.len, random_string(&buffer1).len);
    var buffer2: [9]u8 = undefined;
    try expectEqual(buffer2.len, random_string(&buffer2).len);
    var buffer3: [4]u8 = undefined;
    try expectEqual(buffer3.len, random_string(&buffer3).len);
    var buffer4: [1]u8 = undefined;
    try expectEqual(buffer4.len, random_string(&buffer4).len);
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;
