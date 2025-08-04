const std = @import("std");

test {
    const resources = @import("resources.zig");
    std.testing.refAllDecls(resources);

    const resource = @import("resource.zig");
    std.testing.refAllDecls(resource);
}
