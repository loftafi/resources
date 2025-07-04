var value: usize = 99;

/// Return a number greate than zero, and less than the `limit`
pub fn random(limit: usize) usize {
    if (limit == 0) {
        return 0;
    }
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return value % limit;
}

pub inline fn random_u64() u64 {
    return @as(u64, random(std.math.maxInt(u64)));
}

/// Seed the random number generator with the current time
pub fn seed() void {
    value = @intCast(std.time.milliTimestamp());
}

const std = @import("std");
