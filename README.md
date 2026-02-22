# Resources

This zig module supports loading, searching, and bundling resources
into a bundle for distribution. The Zig
[API documentation](https://loftafi.github.io/resources/docs/) is available
[here](https://loftafi.github.io/resources/docs/)

## Example usage

```zig
// Load a repository folder of files (with metadata files)
var bucket = try Resources.create(allocator);
defer bucket.destroy();
seed(); // If a uid is generated, make sure it is unique.
_ = bucket.loadDirectory(folder) catch |e| {
    std.debug.print("error {any} while loading {s}\n", .{ e, folder });
    return Error.FailedReadingRepo;
};

// Load a resource bundle of files.
bucket.loadBundle("/path/to/bundle");

// Search for a resource by filename or word in a filename
var results: std.ArrayListUnmanaged(*Resource) = .empty.
defer results.deinit(allocator);
try bucket.search(keywords.items, .any, &results);
for (results.items) |resource| {
    std.debug.print(" {d}  {s}\n", .{resource.uid, sentence});
}

// Load a file from the resource bucket
const data = resources.loadResource(resource, allocator) catch |e| {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    if (e == error.FileNotFound) return error.ResourceNotFound;
    return error.ResourceReadError;
};

// Save the contents of a list of resources into a bundle
buket.saveBundle("/path/to/bundle", results);

```

## Unicode filenames

On mac, some files may accidentally become NFD. You can convert all filenames
to NFD usinc convmv:

    convmv -r -f utf8 -t utf8 --nfc --notest .

## License

This code is released under the terms of the MIT license. This
code is useful for my purposes. No warrantee is given or implied
that this library will be suitable for your purpose and no warantee
is given or implied that this code is free from defects.
