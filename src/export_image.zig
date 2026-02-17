pub const ScaleMode = enum {
    /// fit. Decrease the image size if it is too wide or high.
    fit,

    /// fill. Increase the image size if there is width and height we can grow into.
    fill,

    /// Expand to fill the entire bounding box and crop edges.
    cover,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

//pub fn generate_ogg_audio(gpa: Allocator, resource: *const Resource, resources: *Resources)
/// export an image resource into a specific `dst` folder bounded to a specific
/// width and height.
pub fn exportImage(
    allocator: Allocator,
    io: std.Io,
    resource: *const Resource,
    resources: *Resources,
    bounded: Size,
    mode: ScaleMode,
    image_type: FileType,
) (Allocator.Error || Resources.Error || error{ ExportsJpgOrPngOnly, ImageConversionError } || std.Io.File.OpenError || std.Io.Reader.Error || std.Io.File.SeekError || std.Io.Writer.Error || std.Io.File.StatError || std.Io.Reader.LimitedAllocError)![]const u8 {
    zstbi.init(allocator, io);
    defer zstbi.deinit();

    if (image_type != .png and image_type != .jpg)
        return error.ExportsJpgOrPngOnly;

    // Read the raw image data
    const data = try resources.loadResource(allocator, io, resource);
    defer allocator.free(data);
    var img = Image.loadFromMemory(data, 0) catch |f| {
        err("Image load failed. {any}", .{f});
        return error.ImageConversionError;
    };
    defer img.deinit();

    if (img.width < 300 or img.height < 300)
        warn("WARNING: Exporting very small image. {d}x{d}", .{
            img.width,
            img.height,
        });

    debug("Exporting image {d} as {t}", .{ resource.uid, image_type });

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

    // Expand or shrink image image if needed
    var size = Size{ .width = img.width, .height = img.height };
    const target = switch (mode) {
        .fit => fit(size, bounded),
        .fill => fill(size, bounded),
        .cover => fill(size, bounded),
    };
    if (target) |new_size| {
        //debug("resize {d}x{d} to {d}x{d}", .{ img.width, img.height, new_size.width, new_size.height });
        const new_img = img.resize(
            new_size.width,
            new_size.height,
        );
        img.deinit();
        img = new_img;
        size = Size{ .width = img.width, .height = img.height };
    }

    if (mode == .cover) {
        // Additionally, if cover mode requested, also crop the image if needed.
        var x: usize = 0;
        var y: usize = 0;
        if (size.width > bounded.width)
            x = (size.width - bounded.width) / 2;
        if (size.height > bounded.height)
            y = (size.height - bounded.height) / 2;

        const cropped_img = crop(img, x, y, bounded.width, bounded.height);
        img.deinit();
        img = cropped_img;
    }

    switch (image_type) {
        .jpg => {
            var buffer: Buffer = .{ .allocator = allocator };
            Image.writeToFn(img, write_fn, &buffer, .{ .jpg = .{ .quality = 75 } }) catch |f| {
                err("Image write failed. {any}", .{f});
                return error.ImageConversionError;
            };
            if (buffer.failed) return error.ImageConversionError;
            return buffer.data.toOwnedSlice(allocator);
        },
        .png => {
            var buffer: Buffer = .{ .allocator = allocator };
            Image.writeToFn(img, write_fn, &buffer, .png) catch |f| {
                err("Image write failed. {any}", .{f});
                return error.ImageConversionError;
            };
            if (buffer.failed) return error.ImageConversionError;
            return buffer.data.toOwnedSlice(allocator);
        },
        else => unreachable, // only jpg and png should reach this point.
    }

    return error.ImageConversionError;
}

const Buffer = struct {
    allocator: Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,
    failed: bool = false,
};

fn write_fn(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    var buffer: *Buffer = @ptrCast(@alignCast(context));
    var block: [*]const u8 = @ptrCast(data);
    if (buffer.failed) return;
    buffer.data.appendSlice(buffer.allocator, block[0..@as(usize, @intCast(size))]) catch |f| {
        err("Failed appending image data. {any}", .{f});
        buffer.failed = true;
    };
}

inline fn size_difference(x: f64, y: f64) f64 {
    return switch (x > y) {
        true => x - y,
        false => y - x,
    };
}

/// Return a larger width and height if the image needs to be increased in size.
pub fn fill(size: Size, preferred: Size) ?Size {
    var scale: f64 = @as(f64, @floatFromInt(preferred.width)) / @as(f64, @floatFromInt(size.width));

    const scale2: f64 = @as(f64, @floatFromInt(preferred.height)) / @as(f64, @floatFromInt(size.height));
    if (scale2 > scale) scale = scale2;

    const result = Size{
        .width = @as(u32, @intFromFloat(@as(f64, @floatFromInt(size.width)) * scale)),
        .height = @as(u32, @intFromFloat(@as(f64, @floatFromInt(size.height)) * scale)),
    };

    if (result.width == size.width and result.height == size.height)
        return null;

    return result;
}

/// If the image is too high or too wide for the bounding box, then reduce the
/// image to fit the bounding box. Does not increase image size. May leave
/// blank space on the sides of the image.
pub fn fit(size: Size, preferred: Size) ?Size {
    if (size.width <= preferred.width and size.height <= preferred.height)
        return null;

    // Reduce width if needed
    var scale: f64 = 1.0;

    if (size.width > preferred.width)
        scale = @as(f64, @floatFromInt(preferred.width)) / @as(f64, @floatFromInt(size.width));

    if (size.height > preferred.height) {
        const scale2: f64 = @as(f64, @floatFromInt(preferred.height)) / @as(f64, @floatFromInt(size.height));
        if (scale2 < scale) scale = scale2;
    }

    const result = Size{
        .width = @as(u32, @intFromFloat(@as(f64, @floatFromInt(size.width)) * scale)),
        .height = @as(u32, @intFromFloat(@as(f64, @floatFromInt(size.height)) * scale)),
    };

    if (result.width == size.width and result.height == size.height)
        return null;

    return result;
}

fn crop(
    img: Image,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
) zstbi.Image {
    var new_img = try zstbi.Image.createEmpty(@intCast(width), @intCast(height), img.num_components, .{
        .bytes_per_component = img.bytes_per_component,
        .bytes_per_row = @intCast(width * img.bytes_per_component * img.num_components),
    });

    const n: usize = img.bytes_per_component * img.num_components;
    std.debug.assert(img.width * img.height * img.num_components * img.bytes_per_component == img.data.len);
    std.debug.assert(width * height * n == new_img.data.len);

    for (0..height) |row| {
        const src = (y + row) * img.width * n + x * n;
        const source = img.data[src .. src + new_img.bytes_per_row];
        const dst = row * new_img.bytes_per_row;
        const destination = new_img.data[dst .. dst + new_img.bytes_per_row];
        @memcpy(destination, source);
    }

    return new_img;
}

fn get_orientation(_: []const u8) Resources.Error!u32 {
    //var file = std.Io.file.open(file_data) catch |e| {
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
    return error.UnknownImageOrientation;
}

test "size_difference" {
    try expectEqual(10, size_difference(5, 15));
    try expectEqual(10, size_difference(15, 5));
}

test "test_fill" {
    const size = fill(
        .{ .width = 100, .height = 120 }, // actual size
        .{ .width = 100, .height = 100 }, // preferred size
    );
    //try expectEqual(size.width, 100);
    //try expectEqual(size.height, 120);
    try expectEqual(null, size);

    const size2 = fill(
        .{ .width = 120, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    //try expectEqual(size.width, 120);
    //try expectEqual(size.height, 100);
    try expectEqual(null, size2);

    const size3 = fill(
        .{ .width = 100, .height = 100 },
        .{ .width = 80, .height = 100 },
    );
    //try expectEqual(size.width, 100);
    //try expectEqual(size.height, 100);
    try expectEqual(null, size3);

    const size4 = fill(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 80 },
    );
    //try expectEqual(size.width, 100);
    //try expectEqual(size.height, 100);
    try expectEqual(null, size4);

    const size5 = fill(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    //try expectEqual(size.width, 100);
    //try expectEqual(size.height, 100);
    try expectEqual(null, size5);

    const size6 = fill(
        .{ .width = 80, .height = 80 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(size6.width, 100);
    try expectEqual(size6.height, 100);

    const size7 = fill(
        .{ .width = 80, .height = 100 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(size7.width, 100);
    try expectEqual(size7.height, 125);

    const size8 = fill(
        .{ .width = 100, .height = 80 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(size8.width, 125);
    try expectEqual(size8.height, 100);

    const size9 = fill(
        .{ .width = 90, .height = 80 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(112, size9.width); // 112.5
    try expectEqual(100, size9.height);

    const size9a = fill(
        .{ .width = 91, .height = 80 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(113, size9a.width);
    try expectEqual(100, size9a.height);

    const size10 = fill(
        .{ .width = 200, .height = 200 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(100, size10.width);
    try expectEqual(100, size10.height);

    const size11 = fill(
        .{ .width = 200, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(null, size11);

    const size12 = fill(
        .{ .width = 100, .height = 200 },
        .{ .width = 100, .height = 100 },
    );
    try expectEqual(null, size12);

    const size13 = fill(
        .{ .width = 150, .height = 200 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(100, size13.width);
    try expectEqual(133, size13.height);
}

test "test_fit" {
    const size = fit(
        .{ .width = 100, .height = 120 }, // actual size
        .{ .width = 100, .height = 100 }, // preferred size
    ).?;
    try expectEqual(size.width, 83);
    try expectEqual(size.height, 100);

    const size2 = fit(.{ .width = 120, .height = 100 }, .{ .width = 100, .height = 100 }).?;
    try expectEqual(size2.width, 100);
    try expectEqual(size2.height, 83);

    const size3 = fit(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 100 },
    );
    //try expectEqual(size.width, 100);
    //try expectEqual(size.height, 100);
    try expectEqual(null, size3);

    const size4 = fit(
        .{ .width = 60, .height = 60 },
        .{ .width = 100, .height = 100 },
    );
    //try expectEqual(size.width, 60);
    //try expectEqual(size.height, 60);
    try expectEqual(null, size4);

    const size5 = fit(
        .{ .width = 160, .height = 160 },
        .{ .width = 100, .height = 100 },
    ).?;
    try expectEqual(size5.width, 100);
    try expectEqual(size5.height, 100);

    const size6 = fit(
        .{ .width = 100, .height = 100 },
        .{ .width = 80, .height = 100 },
    ).?;
    try expectEqual(size6.width, 80);
    try expectEqual(size6.height, 80);

    const size7 = fit(
        .{ .width = 100, .height = 100 },
        .{ .width = 100, .height = 80 },
    ).?;
    try expectEqual(size7.width, 80);
    try expectEqual(size7.height, 80);

    const size8 = fit(
        .{ .width = 100, .height = 100 },
        .{ .width = 80, .height = 100 },
    ).?;
    try expectEqual(size8.width, 80);
    try expectEqual(size8.height, 80);
}

test "export_image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources = try Resources.create(std.testing.allocator);
    defer resources.destroy();
    _ = try resources.loadDirectory(io, "./test/repo/", null);

    var tmp = try std.Io.Dir.cwd().openDir(io, "/tmp/", .{});
    defer tmp.close(io);

    {
        const resource = try resources.lookupOne("μάχαιρα", .image, gpa);
        try expect(resource != null);

        const data = try exportImage(
            gpa,
            io,
            resource.?,
            resources,
            .{ .width = 800, .height = 800 },
            .cover,
            .jpg,
        );
        defer gpa.free(data);

        try expectEqual(22611, data.len);
        try write_folder_file_bytes(io, tmp, "test.jpg", data);
    }

    {
        const resource = try resources.lookupOne("δύο κρέα", .image, gpa);
        try expect(resource != null);

        const data2 = try exportImage(
            gpa,
            io,
            resource.?,
            resources,
            .{ .width = 300, .height = 120 },
            .cover,
            .png,
        );
        defer gpa.free(data2);

        try expectEqual(9774, data2.len);

        try write_folder_file_bytes(io, tmp, "test.png", data2);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const err = std.log.err;
const warn = std.log.warn;
const info = std.log.info;
const debug = std.log.debug;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Resource = @import("resources.zig").Resource;
const Resources = @import("resources.zig").Resources;
const FileType = @import("root.zig").FileType;
const zstbi = @import("zstbi");
const Image = zstbi.Image;

const write_folder_file_bytes = @import("resources.zig").write_folder_file_bytes;
