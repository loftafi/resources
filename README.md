# 📦 Resources

This zig module supports collecting, searching, and bundling resources
into a bundle for distribution. The most common use case for this is
a game that wishes to pack all game reosurces into an individual bundle file.
Attach metadata such as copyright information and an optional link to the source
of the original file to make copyright and licence management easier.

This project provides a command line tool for collecting resources, and a zig
api for in game access to these resources.

See the Zig [API documentation](https://loftafi.github.io/resources/docs/) for
API details.

## ⚡️ Introduction

Build the helper command line tool `resources` using `zig build`, and create
a repository folder. Use the `resources` command to add resources to the repo.

    $ resources add mysprite.png "player1" "Author Name"
    added 'mysprite.png' to repo as 'ym92DE.png' and 'ym92DE.txt'.

     $ ls $PROJECT/repo
    -rw-r--r--@   1 user  staff   6.8M May 26  2024 ym92DE.png
    -rw-r--r--@   1 user  staff    68B May 26  2024 ym92DE.txt
    -rw-r--r--@   1 user  staff   4.3M May 26  2024 UpG9eB.wav
    -rw-r--r--@   1 user  staff    70B May 26  2024 UpG9eB.txt
    -rw-r--r--    1 user  staff   2.8M Jul 30  2024 0ATUYC.jpg
    -rw-r--r--@   1 user  staff    60B Jul 30  2024 0ATUYC.txt
    -rwxr-xr-x@   1 user  staff    19M Jul 30  2024 GHQLDn.ttf
    -rwxr-xr-x@   1 user  staff    94B Jul 30  2024 GHQLDn.txt

The metadata `txt` file is designed to be human editable. You can `git add`
and `git commit` your repo folder.

    more $PROJECT/repo/ym92DE.txt
    i:ym92DE
    d:202603041202
    v:true
    c:Author Name
    s:mysprite.png
    s:player1
    s:player 1

Search resources using the `resource serch` command, i.e.

    $ resources search player
    ym92DE png  player1
                player 1
                mysprite.png
    Pkm2Fm png  player2
                player 2
                baddie.png
    found 2 resources.


Why is the filename changed to a uid? There are two main reasons.

Firstly, it makes it possible to insert the same image file twice.
An older version of a game might use the older version of `player1`
and a newer version of a game might use the newer version of `player1`. Non
techincal people can open and see both versions of the image in the folder.
Secondly, non-English speaking developers and designers might use filenames
in their own language, but these filenames can not be safely represented and
or managed across platforms. The original filename is stored in utf-8 in the
metadata text file.


## 📝 Example Zig Usage

During development, use `loadDirectory` to source files from the
resository folder.

```zig
// Load a repository folder of files (with metadata files)
var bucket = try Resources.create(gpa);
defer bucket.destroy();

_ = bucket.loadDirectory(folder) catch |e| {
    std.debug.print("error {any} while loading {s}\n", .{ e, folder });
    return Error.FailedReadingRepo;
};
// Tell the bucket to track which resources your game loaded by initialising
// the `used_resources` array list in the bucket.
bucket.used_resources = .empty;
```

In the final release, bundle your resorces and load them from the bundle.

```zig
// Load a resource bundle of files.
var bucket = try Resources.create(gpa);
defer bucket.destroy();
_ = bucket.loadBundle("/path/to/bundle.bd") catch |e|;
    std.debug.print("error {any} while loading bundle\n", .{ e });
    return Error.FailedReadingRepo;
};
```

To load the contents of file, first get the `Resource` record,
then load the data for that resource. It is important to note
that `lookupOne` can remember that this resource was loaded by
adding it to the `resources.used_resources`

```zig
if (try bucket.lookupOne("payer1", .jpg, gpa)) |image| {
    const data = bucket.loadResource(io, image, gpa) catch |e| switch(e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.ResourceNotFound,
        else => error.ResourceReadError,
    };
}
```

Optionally, you can search for resources using a keyword `search` or file
name `lookup`, i.e:

```zig
// Search for a resource by filename or word in a filename
var results: std.ArrayListUnmanaged(*Resource) = .empty;
defer results.deinit(allocator);
try bucket.search(keywords.items, .any, &results);
for (results.items) |resource| {
    std.debug.print(" {d}  {s}\n", .{resource.uid, sentence});
}
```

During development, after all of the `lookupOne` calls, you may optionally
call `saveBundle` to write a bundle file containing all of the resources that
were loaded while the game was running.

```zig
// Save the contents of a list of resources into a bundle
buket.saveBundle(
    io,
    "/path/to/bundle.bd",
    resources.used_resources,
    .{
        .audio = .original, // choose `ogg` for wav to ogg conversion.
        .image = .original, // choose `jpg` to convert png to jpg.
        .normalise_audio = false,
        .max_image_size = .{ .width = 10000, .height = 10000 },
    },
    "/tmp/",
);

```

## 💻 Command Line Tool

`zig build` creates a binary `zig-out/bin/resources` with commands that you
can use to add and search a resource bundle file or resource folder.

Add a file to a repository folder:

    resources add myimage.png

Search ignoring accents (unaccented) or exactly matching accents:

    resources search "my tile set"
    resources search unaccented "my tile set"

Search inside a specific folder or bundle:

    resources -b mybundle.bd search "level complete sound"
    resources -b myfolder/ search "level complete sound"

Search by a specific file extension or caetgory:

    resources -t jpg search "enemy"
    resources -t ogg search "walking sound"
    resources -t image search "character sheet"
    resources -t audio search "game over"

The -b flag is requred unless you create a $HOME/.resources.conf:

    {
        "repo":"/path/to/repo/",
        "repo_cache":"/path/to/repo.cache/"
    }

## 🔒 License

This code is released under the terms of the MIT license. This
code is useful for my purposes. No warrantee is given or implied
that this library will be suitable for your purpose and no warantee
is given or implied that this code is free from defects.

This package depends upon third party libraries, with potentially
different licences. See [praxis](https://github.com/loftafi/praxis),
[zg](https://codeberg.org/atman/zg) and
[zstbi](https://github.com/zig-gamedev/zstbi) for details.

## 📨 Contributing

Contributions under the MIT license are welcome. Consider raising an issue
first to discuss the proposed change.
