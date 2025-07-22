pub const ScaleMode = enum {
    keep_within_bounds,
    expand_over_bounds,
    cover,
};

pub const Size = struct {
    width: f64,
    height: f64,
};

/// export an image resource into a specific `dst` folder bounded to a specific
/// width and height.
pub fn exportImage(
    allocator: Allocator,
    resources: *Resources,
    resource: *Resource,
    to_dir: std.fs.Dir,
    to_name: []const u8,
    bounded: Size,
    mode: ScaleMode,
) ![]const u8 {
    zstbi.init(allocator);
    defer zstbi.deinit();

    const data = try resources.read_data(resource, allocator);

    var out_file = PathBuf.from(dst);
    var out_ext = out_file.extension();
    if (out_ext.is_none()) {
        err("destination file must have file extension", .{});
        return error.ExportFilenameMissingExtension;
    }

    var img = try zstbi.Image.loadFromMemory(data, 0);
    defer img.deinit();

    const original = img.info();
    if (original.width < 300 or original.height < 300) {
        warn("WARNING: Exporting very small image. {d}x{d}", .{ original.width, original.height });
    }
    //println!("Reading image: {:?} colour type is: {:?}", src, img.color());

    // JPEG files sometimes need rotation
    //if (resource.type == .jpg) {
    //    if (get_orientation(src)) |orientation| {
    //        if (orientation > 8) {
    //            // invalid orientation
    //        }

    //        if (orientation >= 5) {
    //            img = image.DynamicImage.ImageRgba8(imageops.rotate90(img));
    //            imageops.flip_horizontal_in_place(img);
    //        }

    //        if (orientation == 3 or orientation == 4 or orientation == 7 or orientation == 8) {
    //            imageops.rotate180_in_place(img);
    //        }

    //        if (orientation % 2 == 0) {
    //            imageops.flip_horizontal_in_place(img);
    //        }
    //        original = img.dimensions();
    //    }
    //}

    var target = switch (mode) {
        .keep_within_bounds => keep_within_bounds(original, bounded),
        .expand_over_bounds => expand_over_bounds(original, bounded),
        .cover => expand_over_bounds(original, bounded),
    };

    // Expand image if needed
    if (original.width != target.width or original.height != target.height) {
        const new_img = img.resize(
            target.width,
            target.height,
            //image.imageops.FilterType.Lanczos3,
        );
        original = img.info();
    }

    // Crop image if in cover mode
    if (mode == .cover) {
        var x: u32 = 0;
        var y: u32 = 0;
        if (size.width > bounded.width) {
            x += @intCast(@as(f64, @floatCast((size.width - bounded.width))) / 2.0);
        }
        if (size.height > bounded.height) {
            y += @intCast(@as(f64, @floatCast((height - bounded.height))) / 2.0);
        }
        @panic("crop not yet supported");
        //img = img.crop(img, x, y, bounded.width, bounded.height);
    }

    const actual = img.info();

    var file = File.create(dst) catch |f| {
        err("save image failed. {any}", .{f});
        return f;
    };

    //let encoder = PngEncoder::new_with_quality(&mut out, CompressionType::Best, FilterType::NoFilter);
    //encoder.encode(&imbuf.into_raw(), target_width, target_height, ColorType::Rgba8);
    if (out_ext == "jpg") {
        const format = zstbi.ImageWriteFormat{};
        zstbi.Image.writeToFile(img, to_filename, format);
        //var ist = img.to_rgba8();
        //var encoder = JpegEncoder.new_with_quality(file, 75);
        //var x = encoder.encode(&ist, actual_width, actual_height, ColorType.Rgba8) catch |f| {
        //    err("save image failed. {any}", .{f});
        //    return f;
        //};
    } else {
        const pr = switch (img.as_rgba8()) {
            .none => {
                // Fails here
                return err("img convert failed in={:?} out={:?}", .{ in_ext, out_ext });
            },
            .some => pr,
        };
        const pixels_rgba = pr.as_rgba();
        var size = img.dimensions();
        var ist = Img.new(pixels_rgba, size.width, size.height);
        Encoder.new()
            .with_quality(75)
            .with_speed(1)
            .encode_rgba(ist) catch |f| {
            return err("save image failed. {:?}", .{e});
        };
        fi.write_all(res.avif_file.as_slice());
    }

    return;
}

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
const Allocator = std.mem.Allocator;
const err = std.log.err;
const expectEqual = std.testing.expectEqual;
const Resource = @import("resources.zig").Resource;
const Resources = @import("resources.zig").Resources;
const zstbi = @import("zstbi");
