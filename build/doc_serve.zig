const port = 8080;
const directory = "zig-out/docs/";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var root_dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err|
        fatal("unable to open directory '{s}': {s}", .{ directory, @errorName(err) });
    defer root_dir.close(init.io);

    var static_http_file_server = try Server.init(.{
        .allocator = gpa,
        .io = init.io,
        .root_dir = root_dir,
    });
    defer static_http_file_server.deinit(gpa);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var http_server = try address.listen(init.io, .{
        .reuse_address = true,
    });
    std.log.info("Listening at http://127.0.0.1:{d}/\n", .{port});

    accept: while (true) {
        const connection = try http_server.accept(init.io);
        defer connection.close(init.io);

        //const stream = try tcp_server.accept(io);

        var read_buffer: [1024 * 10]u8 = undefined;
        var reader = connection.reader(init.io, &read_buffer);
        const in = &reader.interface;

        var writer = connection.writer(init.io, &.{});
        const out = &writer.interface;

        var server = std.http.Server.init(in, out);
        //while (server.state == .ready) {
        while (true) {
            var request = server.receiveHead() catch |err| {
                std.log.err("{s}\n", .{@errorName(err)});
                continue :accept;
            };
            try static_http_file_server.serve(&request);
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format ++ "\n", args);
    std.process.exit(1);
}

pub const Server = struct {
    /// The key is index into backing_memory, where a HTTP request path is stored.
    files: File.Table,

    /// Stores file names relative to root directory and file contents, interleaved.
    bytes: std.ArrayListUnmanaged(u8),

    pub const File = struct {
        mime_type: mime.Type,
        name_start: usize,
        name_len: u16,

        /// Stored separately to make aliases work.
        contents_start: usize,
        contents_len: usize,

        pub const Table = std.HashMapUnmanaged(
            File,
            void,
            FileNameContext,
            std.hash_map.default_max_load_percentage,
        );
    };

    pub const Options = struct {
        allocator: std.mem.Allocator,
        io: std.Io,

        /// Must have been opened with iteration permissions.
        root_dir: std.Io.Dir,
        cache_control_header: []const u8 = "max-age=0, must-revalidate",
        max_file_size: usize = std.math.maxInt(usize),

        /// Special alias "404" allows setting a particular file as the file sent
        /// for "not found" errors. If this alias is not provided, `serve` returns
        /// `error.FileNotFound` instead, leaving the response's state unmodified.
        aliases: []const Alias = &.{
            .{ .request_path = "/", .file_path = "/index.html" },
            .{ .request_path = "404", .file_path = "/index.html" },
        },
        ignoreFile: *const fn (path: []const u8) bool = &defaultIgnoreFile,

        pub const Alias = struct {
            request_path: []const u8,
            file_path: []const u8,
        };
    };

    pub const InitError = error{
        OutOfMemory,
        InitFailed,
    };

    pub fn init(options: Options) InitError!Server {
        const gpa = options.allocator;

        var files: File.Table = .{};
        errdefer files.deinit(gpa);

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer bytes.deinit(gpa);

        var it = try options.root_dir.walk(gpa);
        defer it.deinit();

        while (it.next(options.io) catch |err| {
            log.err("unable to scan root directory: {s}", .{@errorName(err)});
            return error.InitFailed;
        }) |entry| {
            std.log.debug("will serve file name: {s}", .{entry.path});
            switch (entry.kind) {
                .file => {
                    if (options.ignoreFile(entry.path)) continue;

                    var file = options.root_dir.openFile(options.io, entry.path, .{}) catch |err| {
                        log.err("unable to open '{s}': {s}", .{ entry.path, @errorName(err) });
                        return error.InitFailed;
                    };
                    defer file.close(options.io);

                    var contents = options.root_dir.readFileAlloc(
                        options.io,
                        entry.path,
                        options.allocator,
                        .unlimited,
                    ) catch |e| {
                        log.err("unable to read '{s}': {s}", .{ entry.path, @errorName(e) });
                        return error.InitFailed;
                    };

                    const name_len = 1 + entry.path.len;
                    try bytes.ensureUnusedCapacity(gpa, name_len + contents.len);

                    // Make the file system path identical independently of
                    // operating system path inconsistencies. This converts
                    // backslashes into forward slashes.
                    const name_start = bytes.items.len;
                    bytes.appendAssumeCapacity(canonical_sep);
                    bytes.appendSliceAssumeCapacity(entry.path);
                    if (fs.path.sep != canonical_sep)
                        normalizePath(bytes.items[name_start..][0..name_len]);

                    const contents_start = bytes.items.len;
                    try bytes.appendSlice(options.allocator, contents);
                    //bytes.items.len += contents.len;

                    const ext = fs.path.extension(entry.basename);

                    try files.putNoClobberContext(gpa, .{
                        .mime_type = mime.extension_map.get(ext) orelse .@"application/octet-stream",
                        .name_start = name_start,
                        .name_len = @intCast(name_len),
                        .contents_start = contents_start,
                        .contents_len = contents.len,
                    }, {}, FileNameContext{
                        .bytes = bytes.items,
                    });
                },
                else => continue,
            }
        }

        try files.ensureUnusedCapacityContext(gpa, @intCast(options.aliases.len), FileNameContext{
            .bytes = bytes.items,
        });

        for (options.aliases) |alias| {
            std.log.debug("aliasing {s} to {s}", .{ alias.request_path, alias.file_path });
            const file = files.getKeyAdapted(alias.file_path, FileNameAdapter{
                .bytes = bytes.items,
            }) orelse {
                log.err("alias '{s}' points to nonexistent file '{s}'", .{
                    alias.request_path, alias.file_path,
                });
                return error.InitFailed;
            };

            const name_start = bytes.items.len;
            try bytes.appendSlice(gpa, alias.request_path);

            if (files.getOrPutAssumeCapacityContext(.{
                .mime_type = file.mime_type,
                .name_start = name_start,
                .name_len = @intCast(alias.request_path.len),
                .contents_start = file.contents_start,
                .contents_len = file.contents_len,
            }, FileNameContext{
                .bytes = bytes.items,
            }).found_existing) {
                log.err("alias '{s}'->'{s}' clobbers existing file or alias", .{
                    alias.request_path, alias.file_path,
                });
                return error.InitFailed;
            }
        }

        return .{
            .files = files,
            .bytes = bytes,
        };
    }

    pub fn deinit(s: *Server, allocator: std.mem.Allocator) void {
        s.files.deinit(allocator);
        s.bytes.deinit(allocator);
        s.* = undefined;
    }

    pub fn serve(
        s: *Server,
        request: *std.http.Server.Request,
    ) (std.Io.Writer.Error || error{ FileNotFound, HttpExpectationFailed })!void {
        std.log.debug("request: {s}", .{request.head.target});
        const path = request.head.target;
        const file_name_adapter: FileNameAdapter = .{ .bytes = s.bytes.items };
        const file, const status: std.http.Status = b: {
            break :b .{
                s.files.getKeyAdapted(path, file_name_adapter) orelse {
                    break :b .{
                        s.files.getKeyAdapted(@as([]const u8, "404"), file_name_adapter) orelse
                            return error.FileNotFound,
                        .not_found,
                    };
                },
                .ok,
            };
        };

        const content = s.bytes.items[file.contents_start..][0..file.contents_len];
        return request.respond(content, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(file.mime_type) },
            },
        });
    }

    pub fn defaultIgnoreFile(path: []const u8) bool {
        const basename = fs.path.basename(path);
        return std.mem.startsWith(u8, basename, ".") or
            std.mem.endsWith(u8, basename, "~");
    }

    const canonical_sep = fs.path.sep_posix;

    fn normalizePath(bytes: []u8) void {
        assert(fs.path.sep != canonical_sep);
        std.mem.replaceScalar(u8, bytes, fs.path.sep, canonical_sep);
    }

    const FileNameContext = struct {
        bytes: []const u8,

        pub fn eql(self: @This(), a: File, b: File) bool {
            const a_name = self.bytes[a.name_start..][0..a.name_len];
            const b_name = self.bytes[b.name_start..][0..b.name_len];
            return std.mem.eql(u8, a_name, b_name);
        }

        pub fn hash(self: @This(), x: File) u64 {
            const name = self.bytes[x.name_start..][0..x.name_len];
            return std.hash_map.hashString(name);
        }
    };

    const FileNameAdapter = struct {
        bytes: []const u8,

        pub fn eql(self: @This(), a_name: []const u8, b: File) bool {
            const b_name = self.bytes[b.name_start..][0..b.name_len];
            return std.mem.eql(u8, a_name, b_name);
        }

        pub fn hash(self: @This(), adapted_key: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(adapted_key);
        }
    };
};

pub const mime = struct {
    /// The integer values backing these enum tags are not protected by the
    /// semantic version of this package but the backing integer type is.
    /// The tags are guaranteed to be sorted by name.
    pub const Type = enum(u16) {
        @"application/epub+zip",
        @"application/gzip",
        @"application/java-archive",
        @"application/javascript",
        @"application/json",
        @"application/ld+json",
        @"application/msword",
        @"application/octet-stream",
        @"application/ogg",
        @"application/pdf",
        @"application/rtf",
        @"application/vnd.amazon.ebook",
        @"application/vnd.apple.installer+xml",
        @"application/vnd.mozilla.xul+xml",
        @"application/vnd.ms-excel",
        @"application/vnd.ms-fontobject",
        @"application/vnd.ms-powerpoint",
        @"application/vnd.oasis.opendocument.presentation",
        @"application/vnd.oasis.opendocument.spreadsheet",
        @"application/vnd.oasis.opendocument.text",
        @"application/vnd.openxmlformats-officedocument.presentationml.presentation",
        @"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        @"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        @"application/vnd.rar",
        @"application/vnd.visio",
        @"application/wasm",
        @"application/x-7z-compressed",
        @"application/x-abiword",
        @"application/x-bzip",
        @"application/x-bzip2",
        @"application/x-cdf",
        @"application/x-csh",
        @"application/x-freearc",
        @"application/x-httpd-php",
        @"application/x-sh",
        @"application/x-shockwave-flash",
        @"application/x-tar",
        @"application/xhtml+xml",
        @"application/xml",
        @"application/zip",
        @"audio/aac",
        @"audio/midi",
        @"audio/mpeg",
        @"audio/ogg",
        @"audio/opus",
        @"audio/wav",
        @"audio/webm",
        @"font/otf",
        @"font/ttf",
        @"font/woff",
        @"font/woff2",
        @"image/bmp",
        @"image/gif",
        @"image/jpeg",
        @"image/png",
        @"image/svg+xml",
        @"image/tiff",
        @"image/vnd.microsoft.icon",
        @"image/webp",
        @"text/calendar",
        @"text/css",
        @"text/csv",
        @"text/html",
        @"text/plain",
        @"video/3gpp",
        @"video/3gpp2",
        @"video/mp2t",
        @"video/mp4",
        @"video/mpeg",
        @"video/ogg",
        @"video/quicktime",
        @"video/webm",
        @"video/x-msvideo",
    };

    /// Maps file extension to mime type.
    pub const extension_map = std.StaticStringMap(Type).initComptime(.{
        .{ ".aac", .@"audio/aac" },
        .{ ".abw", .@"application/x-abiword" },
        .{ ".arc", .@"application/x-freearc" },
        .{ ".avi", .@"video/x-msvideo" },
        .{ ".azw", .@"application/vnd.amazon.ebook" },
        .{ ".bin", .@"application/octet-stream" },
        .{ ".bmp", .@"image/bmp" },
        .{ ".bz", .@"application/x-bzip" },
        .{ ".bz2", .@"application/x-bzip2" },
        .{ ".cda", .@"application/x-cdf" },
        .{ ".csh", .@"application/x-csh" },
        .{ ".css", .@"text/css" },
        .{ ".csv", .@"text/csv" },
        .{ ".doc", .@"application/msword" },
        .{ ".docx", .@"application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
        .{ ".eot", .@"application/vnd.ms-fontobject" },
        .{ ".epub", .@"application/epub+zip" },
        .{ ".gz", .@"application/gzip" },
        .{ ".gif", .@"image/gif" },
        .{ ".htm", .@"text/html" },
        .{ ".html", .@"text/html" },
        .{ ".ico", .@"image/vnd.microsoft.icon" },
        .{ ".ics", .@"text/calendar" },
        .{ ".jar", .@"application/java-archive" },
        .{ ".jpg", .@"image/jpeg" },
        .{ ".jpeg", .@"image/jpeg" },
        .{ ".js", .@"application/javascript" },
        .{ ".json", .@"application/json" },
        .{ ".jsonld", .@"application/ld+json" },
        .{ ".mid", .@"audio/midi" },
        .{ ".mjs", .@"application/javascript" },
        .{ ".mov", .@"video/quicktime" },
        .{ ".mp3", .@"audio/mpeg" },
        .{ ".mp4", .@"video/mp4" },
        .{ ".mpeg", .@"video/mpeg" },
        .{ ".mpkg", .@"application/vnd.apple.installer+xml" },
        .{ ".odp", .@"application/vnd.oasis.opendocument.presentation" },
        .{ ".ods", .@"application/vnd.oasis.opendocument.spreadsheet" },
        .{ ".odt", .@"application/vnd.oasis.opendocument.text" },
        .{ ".oga", .@"audio/ogg" },
        .{ ".ogv", .@"video/ogg" },
        .{ ".ogx", .@"application/ogg" },
        .{ ".opus", .@"audio/opus" },
        .{ ".otf", .@"font/otf" },
        .{ ".png", .@"image/png" },
        .{ ".pdf", .@"application/pdf" },
        .{ ".php", .@"application/x-httpd-php" },
        .{ ".ppt", .@"application/vnd.ms-powerpoint" },
        .{ ".pptx", .@"application/vnd.openxmlformats-officedocument.presentationml.presentation" },
        .{ ".rar", .@"application/vnd.rar" },
        .{ ".rtf", .@"application/rtf" },
        .{ ".sh", .@"application/x-sh" },
        .{ ".svg", .@"image/svg+xml" },
        .{ ".swf", .@"application/x-shockwave-flash" },
        .{ ".tar", .@"application/x-tar" },
        .{ ".tiff", .@"image/tiff" },
        .{ ".ts", .@"video/mp2t" },
        .{ ".ttf", .@"font/ttf" },
        .{ ".txt", .@"text/plain" },
        .{ ".vsd", .@"application/vnd.visio" },
        .{ ".wasm", .@"application/wasm" },
        .{ ".wav", .@"audio/wav" },
        .{ ".weba", .@"audio/webm" },
        .{ ".webm", .@"video/webm" },
        .{ ".webp", .@"image/webp" },
        .{ ".woff", .@"font/woff" },
        .{ ".woff2", .@"font/woff2" },
        .{ ".xhtml", .@"application/xhtml+xml" },
        .{ ".xls", .@"application/vnd.ms-excel" },
        .{ ".xlsx", .@"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
        .{ ".xml", .@"application/xml" },
        .{ ".xul", .@"application/vnd.mozilla.xul+xml" },
        .{ ".zip", .@"application/zip" },
        .{ ".3gp", .@"video/3gpp" },
        .{ ".3g2", .@"video/3gpp2" },
        .{ ".7z", .@"application/x-7z-compressed" },
    });
};

const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const log = std.log.scoped(.@"static-http-files");
