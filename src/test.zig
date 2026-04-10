const std = @import("std");

test {
    std.testing.refAllDecls(@import("Resource.zig"));
    std.testing.refAllDecls(@import("Resources.zig"));
    std.testing.refAllDecls(@import("export_image.zig"));
    std.testing.refAllDecls(@import("base62.zig"));
}
