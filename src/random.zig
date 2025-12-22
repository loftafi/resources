//! A simple random number generator useful for games that do not need
//! cryptographically secure random numbers.

var value: usize = 99;

/// Return a number greater than zero, and less than the `limit`. Call `seed()`
/// first if you do not want a predictable sequence of numbers.
///
/// This is _not_ cryptographically secure.
pub fn random(limit: usize) usize {
    if (limit == 0) {
        return 0;
    }
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value % limit;
}

/// Return a random u64 value. Call `seed()` first if you do not want a
/// predictable number sequence.
///
/// This is _not_ cryptographically secure.
pub inline fn random_u64() u64 {
    return @as(u64, random(std.math.maxInt(u64)));
}

/// Seed the random number generator with the current time
pub fn seed() void {
    value = @intCast(std.time.milliTimestamp());
}

const std = @import("std");
