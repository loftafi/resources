const max_audio_file_size = 1024 * 1024 * 5;

/// Read a wav file, normalise it, then pass it through ffmpeg to
/// create an ogg data file.
pub fn generate_ogg_audio(gpa: Allocator, resource: *const Resource, resources: *Resources) (wav.Error || Allocator.Error || Resources.Error || error{FfmpegFailure} || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.SeekError || std.Io.Reader.Error)![]const u8 {
    const data = resources.read_data(resource, gpa) catch |f| {
        err("Failed to read wav data for {d}. Error:{any}", .{ resource.uid, f });
        return f;
    };
    defer gpa.free(data);

    var audio = wav.Engine.initWithWav(gpa, data) catch |f| {
        err("Failed to import wav data for {d}. Error:{any}", .{ resource.uid, f });
        return f;
    };
    audio.normalise(0.95);
    audio.faders();
    defer audio.destroy(gpa);

    const argv = [_][]const u8{
        "/opt/homebrew/bin/ffmpeg",
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

    var ffmpeg = std.process.Child.init(&argv, gpa);
    ffmpeg.stdin_behavior = .Pipe;
    ffmpeg.stdout_behavior = .Pipe;
    ffmpeg.stderr_behavior = .Ignore;
    ffmpeg.spawn() catch |f| {
        std.log.err("Error spawning ffmpeg process for {d}. Error:{any}", .{ resource.uid, f });
        return error.FfmpegFailure;
    };
    ffmpeg.stdin.?.writeAll(data) catch |f| {
        std.log.err("Error sending audio to ffmpeg process for {d}. Error:{any}", .{ resource.uid, f });
        return error.FfmpegFailure;
    };
    ffmpeg.stdin.?.close();
    ffmpeg.stdin = null;

    const output = ffmpeg.stdout.?.readToEndAlloc(gpa, max_audio_file_size);
    ffmpeg.stdout.?.close();
    ffmpeg.stdout = null;

    const result = ffmpeg.wait() catch |f| {
        std.log.err("Error waiting ffmpeg process for {d}. Error:{any}", .{ resource.uid, f });
        return error.FfmpegFailure;
    };
    debug("ffmpeg returned {t}", .{result});

    if (result != .Exited)
        err("Build ogg file failed.\n{any}", .{ffmpeg.stderr});

    return output;
}

test "audio_to_ogg" {
    const gpa = std.testing.allocator;
    var resources = try Resources.create(gpa);
    defer resources.destroy();

    _ = try resources.load_directory("./test/repo/");
    const resource = try resources.lookupOne("ἄρτος", .wav, gpa);

    //try expect(0 != resource.uid);
    try expectEqual(true, resource.?.visible);
    try expectEqual(.wav, resource.?.resource);
    try expectEqual(1, resource.?.sentences.items.len);
    try expectEqualStrings("ἄρτος", resource.?.sentences.items[0]);

    const data = try generate_ogg_audio(gpa, resource.?, resources);
    defer gpa.free(data);
    try expectEqual(25954, data.len);

    //try write_file_bytes(gpa, "/tmp/test.ogg", data);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = std.log.debug;
const err = std.log.err;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Resources = @import("resources.zig").Resources;
const Resource = @import("resources.zig").Resource;
//const write_file_bytes = @import("resources.zig").write_file_bytes;

const wav = @import("wav.zig");
