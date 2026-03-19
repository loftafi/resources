//! This zig module supports collecting, searching, and bundling resources
//! into a bundle for distribution. The most common use case for this is
//! a game that wishes to pack all game reosurces into an individual bundle
//! file. Attach metadata such as copyright information and an optional link
//! to the source of the original file to make copyright and licence
//! management easier.

pub const Resources = @import("Resources.zig");
pub const Resource = @import("resource.zig").Resource;
pub const Size = Resources.Size;
pub const Type = @import("Type.zig").Type;
pub const ScaleMode = @import("export_image.zig").ScaleMode;

pub const base62 = @import("base62.zig");
pub const random = @import("random.zig");
