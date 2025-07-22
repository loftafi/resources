pub const ScaleMode = enum {
    keep_within_bounds,
    expand_over_bounds,
    cover,
};

pub const Size = struct {
    width: f64,
    height: f64,
};

inline fn size_difference(x: f64, y: f64) f64 {
    return switch (x > y) {
        true => x - y,
        false => y - x,
    };
}

pub fn expand_over_bounds(size: Size, preferred: Size) Size {
    var scale: f64 = undefined;

    const x_diff = size_difference(size.width, preferred.width);
    const y_diff = size_difference(size.height, preferred.height);

    if (x_diff > y_diff) {
        scale = preferred.height / size.height;
    } else {
        scale = preferred.width / size.width;
    }

    return .{
        .width = size.width * scale,
        .height = size.height * scale,
    };
}

pub fn keep_within_bounds(original: Size, preferred: Size) Size {
    var size = original;

    if (size.width <= preferred.width and size.height <= preferred.height) {
        return size;
    }

    var new_size: Size = undefined;
    var scale: f64 = 0;

    if (size.width > preferred.width) {
        scale = preferred.width / size.width;
        new_size.width = preferred.width;
        new_size.height = size.height * scale;
        size.width = new_size.width;
        size.height = new_size.height;
    }

    if (size.height > preferred.height) {
        scale = preferred.height / size.height;
        new_size.height = preferred.height;
        new_size.width = size.width * scale;
    }

    return new_size;
}

fn get_orientation(_: []const u8) !u32 {
    //var file = std.fs.file.open(file_data) catch |e| {
    //    err("Failed opening file {s} {any}", .{ file_data, e });
    //    return e;
    //};
    //var exif_reader = exif_reader.init();
    //const exif = exif_reader.read_from_container(data) catch |f| {
    //    return error.ReadExifFailed;
    //};

    //if (exif.get_field(Tag.Orientation, In.PRIMARY)) |field| {
    //    const value = orientation.value.get_uint(0);
    //    if (value >= 0 and value <= 8) {
    //        return value;
    //    }
    //}
    return error.UnknownOrientation;
}

test "size_difference" {
    try expectEqual(10, size_difference(5, 15));
    try expectEqual(10, size_difference(15, 5));
}

test "test_expand_over_bounds" {
    var size = expand_over_bounds(
        .{ .width = 100, .height = 120 }, // actual size
        .{ .width = 100, .height = 100 }, // preferred size
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 120);

    size = expand_over_bounds(
        .{ .width = 120, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 120);
    try expectEqual(size.height, 100);

    size = expand_over_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 80, .height = 100 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 100);

    size = expand_over_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 80 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 100);

    size = expand_over_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 100);
}

test "test_keep_within_bounds" {
    var size = keep_within_bounds(
        .{ .width = 100, .height = 120 }, // actual size
        .{ .width = 100, .height = 100 }, // preferred size
    );
    try expectEqual(size.width, 83);
    try expectEqual(size.height, 100);

    size = keep_within_bounds(
        .{ .width = 120, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 83);

    size = keep_within_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 100);

    size = keep_within_bounds(
        .{ .width = 60, .height = 60 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 60);
    try expectEqual(size.height, 60);

    size = keep_within_bounds(
        .{ .width = 160, .height = 160 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(size.width, 100);
    try expectEqual(size.height, 100);

    size = keep_within_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 80, .height = 100 },
    );
    try expectEqual(size.width, 80);
    try expectEqual(size.height, 80);

    size = keep_within_bounds(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 80 },
    );
    try expectEqual(size.width, 80);
    try expectEqual(size.height, 80);
}

const std = @import("std");
const err = std.log.err;
const expectEqual = std.testing.expectEqual;
const Resource = @import("resources.zig").Resource;
