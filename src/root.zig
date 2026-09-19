//! Import, index, search, and bundling a directory of resources.
//! Collects all required resources into a bundle for for distribution.
//!
//! Each resource in the resource folder has an associated `.txt` metadata
//! file containing information about the resource such as copyright
//! information, and an optional link to the original source.

/// Loads and index one or more folders or resource bundles.
pub const Resources = @import("Resources.zig");

/// Describes an on disk or in bundle resource.
pub const Resource = @import("Resource.zig");

pub const Normalize = Resources.Normalize;
pub const Size = Resources.Size;
pub const Type = @import("Type.zig").Type;
pub const ScaleMode = @import("export_image.zig").ScaleMode;

pub const base62 = @import("base62.zig");
pub const random = @import("random.zig");
