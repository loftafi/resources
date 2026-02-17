const max_audio_file_size = 1024 * 1024 * 5;

var ffmpeg_binary: ?[]const u8 = null;

/// Read a wav file, normalise it, then pass it through ffmpeg to
/// create an ogg data file.
pub fn generate_ogg_audio(
    gpa: Allocator,
    io: std.Io,
    resource: *const Resource,
    resources: *Resources,
    options: Options,
) (wav.Error || Allocator.Error || Resources.Error || error{FfmpegFailure} ||
    std.Io.File.OpenError || std.Io.Reader.Error || std.Io.File.SeekError ||
    std.Io.Writer.Error || std.Io.Reader.LimitedAllocError ||
    std.Io.Dir.StatFileError || std.process.RunError)![]const u8 {
    var data = resources.loadResource(gpa, io, resource) catch |f| {
        err("Failed to read wav data for {d}. Error:{any}", .{ resource.uid, f });
        return f;
    };
    defer gpa.free(data);

    if (options.normalise_audio) {
        var clean = std.Io.Writer.Allocating.init(gpa);
        errdefer clean.deinit();
        var audio = wav.Engine.initWithWav(gpa, data) catch |f| {
            err("Failed to import wav data for {d}. Error:{any}", .{ resource.uid, f });
            return f;
        };
        defer audio.destroy(gpa);
        if (audio.max < 0.95) {
            std.log.debug("Normalising {f} volume from {d} to {d}", .{ uid_writer(u64, resource.uid), audio.max, 0.95 });
            _ = audio.normalise(0.95);
        }
        audio.faders();
        try audio.write(&clean.writer);

        gpa.free(data);
        data = try clean.toOwnedSlice();
    }

    return wav_to_ogg(gpa, io, data);
}

/// Search for the ffmpeg binary in the standard locations.
fn locate_ffmpeg(io: std.Io) error{FfmpegFailure}![]const u8 {
    if (ffmpeg_binary != null) return ffmpeg_binary.?;

    if (std.Io.Dir.cwd().statFile(io, "/usr/bin/ffmpeg", .{})) |_| {
        ffmpeg_binary = "/usr/bin/ffmpeg";
        return ffmpeg_binary.?;
    } else |_| {}
    if (std.Io.Dir.cwd().statFile(io, "/opt/homebrew/bin/ffmpeg", .{})) |_| {
        ffmpeg_binary = "/opt/homebrew/bin/ffmpeg";
        return ffmpeg_binary.?;
    } else |_| {}
    if (std.Io.Dir.cwd().statFile(io, "/usr/local/bin/ffmpeg", .{})) |_| {
        ffmpeg_binary = "/usr/local/bin/ffmpeg";
        return ffmpeg_binary.?;
    } else |_| {}

    err("ffmpeg not found in '/usr/bin/' or '/opt/homebrew/bin'", .{});
    return error.FfmpegFailure;
}

/// Send the bytes of a wav file to ffmpeg, and return the bytes of an ogg file.
fn wav_to_ogg(
    gpa: Allocator,
    io: std.Io,
    wav_data: []const u8,
) (std.process.RunError || error{FfmpegFailure} || std.Io.Writer.Error)![]const u8 {
    const argv = [_][]const u8{
        try locate_ffmpeg(io),
        "-i",
        "pipe:0", //infile,
        "-filter:a",
        "speechnorm,loudnorm",
        "-c:a",
        "libvorbis",
        "-q:a",
        "7",
        "-f",
        "ogg",
        "-", //outfile,
    };

    info("ffmpeg starting (sending {d} bytes)", .{wav_data.len});

    var ffmpeg = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |f| {
        err("Error spawning ffmpeg process. Error:{any}", .{f});
        return error.FfmpegFailure;
    };

    const output = try pipe_data(
        gpa,
        io,
        &ffmpeg,
        wav_data,
    );
    errdefer gpa.free(output.stdout);
    defer gpa.free(output.stderr);

    if (output.term.exited != 0) {
        err("Build ogg file failed exit code {d}", .{output.term.exited});
        err("Build ogg file failed. {any}", .{output.stderr});
        return error.FfmpegFailure;
    }

    return output.stdout;
}

pub fn pipe_data(
    allocator: Allocator,
    io: std.Io,
    child: *std.process.Child,
    stream: []const u8,
) (std.process.RunError || error{FfmpegFailure} || std.Io.Writer.Error)!std.process.RunResult {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(100) } };
    var buffer: [10 * 1024]u8 = undefined;
    var writer = child.stdin.?.writer(io, &buffer);

    var data = stream;

    const x = if (data.len < block_size) data.len else block_size;
    try writer.interface.writeAll(data[0..x]);
    data = data[block_size..];
    try writer.interface.flush();

    while (true) {
        //std.log.info("do fill. current stderr = {s}", .{multi_reader.reader(1).buffered()});
        _ = multi_reader.fill(9 * 1024, timeout) catch |f| switch (f) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => |e| return e,
        };
        //std.log.err("multireader returned (max bytes = {d})", .{max_output_bytes});
        if (data.len > 0) {
            const l = if (data.len < block_size) data.len else block_size;
            //std.log.info("send {d} bytes", .{l});
            writer.interface.writeAll(data[0..l]) catch |f| {
                err("Error sending audio to ffmpeg. Error:{any}", .{f});
                return error.FfmpegFailure;
            };
            try writer.interface.flush();
            if (data.len < block_size) {
                //std.log.info("all data now sent", .{});
                data.len = 0;
                child.stdin.?.close(io);
                child.stdin = null;
            } else {
                //std.log.info("continuing to next block", .{});
                data = data[block_size..];
            }
        } else {
            //std.log.info("all data sent", .{});
        }
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
    };
}

const block_size = 50000;

test "audio_to_ogg" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var resources = try Resources.create(gpa);
    defer resources.destroy();

    _ = try resources.loadDirectory(io, "./test/repo/", null);
    const resource = try resources.lookupOne("ἄρτος", .wav, gpa);

    try expectEqual(true, resource.?.visible);
    try expectEqual(.wav, resource.?.resource);
    try expectEqual(1, resource.?.sentences.items.len);
    try expectEqualStrings("ἄρτος", resource.?.sentences.items[0]);

    const data = try generate_ogg_audio(gpa, io, resource.?, resources, .{ .normalise_audio = true });
    defer gpa.free(data);

    // Different versions of ffmpeg create a slightly different sized file.
    try expect(data.len < 25954 + 1000);
    try expect(data.len > 25954 - 1000);

    var tmp = try std.Io.Dir.cwd().openDir(io, "/tmp/", .{});
    defer tmp.close(io);
    try write_folder_file_bytes(io, tmp, "test.ogg", data);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const info = std.log.info;
const debug = std.log.debug;
const err = std.log.err;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Resources = @import("resources.zig").Resources;
const Resource = @import("resources.zig").Resource;
const Options = @import("resources.zig").Options;
const uid_writer = @import("base62.zig").uid_writer;
const write_folder_file_bytes = @import("resources.zig").write_folder_file_bytes;

const wav = @import("wav.zig");
