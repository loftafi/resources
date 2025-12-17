const max_audio_file_size = 1024 * 1024 * 5;

var ffmpeg_binary: ?[]const u8 = null;

/// Read a wav file, normalise it, then pass it through ffmpeg to
/// create an ogg data file.
pub fn generate_ogg_audio(gpa: Allocator, resource: *const Resource, resources: *Resources, options: Options) (wav.Error || Allocator.Error || Resources.Error || error{FfmpegFailure} || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.SeekError || std.Io.Reader.Error || std.process.Child.RunError || std.Io.Writer.Error)![]const u8 {
    var data = resources.read_data(resource, gpa) catch |f| {
        err("Failed to read wav data for {d}. Error:{any}", .{ resource.uid, f });
        return f;
    };
    defer gpa.free(data);

    if (options.normalise_audio) {
        var clean: std.ArrayListUnmanaged(u8) = .empty;
        errdefer clean.deinit(gpa);
        var audio = wav.Engine.initWithWav(gpa, data) catch |f| {
            err("Failed to import wav data for {d}. Error:{any}", .{ resource.uid, f });
            return f;
        };
        defer audio.destroy(gpa);
        _ = audio.normalise(0.95);
        _ = audio.normalise(0.95);
        _ = audio.normalise(0.95);
        audio.faders();
        try audio.write(clean.writer(gpa));

        gpa.free(data);
        data = try clean.toOwnedSlice(gpa);
    }

    if (ffmpeg_binary == null) {
        if (std.fs.cwd().statFile("/usr/bin/ffmpeg")) |_| {
            ffmpeg_binary = "/usr/bin/ffmpeg";
        } else |_| {}
        if (std.fs.cwd().statFile("/opt/homebrew/bin/ffmpeg")) |_| {
            ffmpeg_binary = "/opt/homebrew/bin/ffmpeg";
        } else |_| {}
        if (ffmpeg_binary == null) {
            return error.FfmpegFailure;
        }
        debug("Found ffmpeg in {s}", .{ffmpeg_binary.?});
    }

    const argv = [_][]const u8{
        ffmpeg_binary.?,
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

    if (resource.filename) |fl| {
        std.log.info("ffmpeg starting with file {s} (sending {d} bytes)", .{ fl, data.len });
    } else {
        std.log.info("ffmpeg starting (sending {d} bytes)", .{data.len});
    }
    var ffmpeg = std.process.Child.init(&argv, gpa);
    ffmpeg.stdin_behavior = .Pipe;
    ffmpeg.stdout_behavior = .Pipe;
    ffmpeg.stderr_behavior = .Pipe;

    ffmpeg.spawn() catch |f| {
        std.log.err("Error spawning ffmpeg process for {d}. Error:{any}", .{ resource.uid, f });
        return error.FfmpegFailure;
    };

    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(gpa);
    defer stderr.deinit(gpa);
    //defer ffmpeg.stdout.?.close();
    //defer ffmpeg.stderr.?.close();

    try send_data(gpa, &ffmpeg, data, &stdout, &stderr, max_audio_file_size);

    const result = ffmpeg.wait() catch |f| {
        std.log.err("Error waiting ffmpeg process for {d}. Error:{any}", .{ resource.uid, f });
        return error.FfmpegFailure;
    };

    if (result != .Exited)
        err("Build ogg file failed.\n{any}", .{ffmpeg.stderr});

    return stdout.toOwnedSlice(gpa);
}

pub fn send_data(
    allocator: Allocator,
    child: *std.process.Child,
    stdin: []const u8,
    stdout: *ArrayListUnmanaged(u8),
    stderr: *ArrayListUnmanaged(u8),
    max_output_bytes: usize,
) !void {
    assert(child.stdin_behavior == .Pipe);
    assert(child.stdout_behavior == .Pipe);
    assert(child.stderr_behavior == .Pipe);

    var data = stdin;

    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const stdout_r = poller.reader(.stdout);
    stdout_r.buffer = stdout.allocatedSlice();
    stdout_r.seek = 0;
    stdout_r.end = stdout.items.len;

    const stderr_r = poller.reader(.stderr);
    stderr_r.buffer = stderr.allocatedSlice();
    stderr_r.seek = 0;
    stderr_r.end = stderr.items.len;

    defer {
        stdout.* = .{
            .items = stdout_r.buffer[0..stdout_r.end],
            .capacity = stdout_r.buffer.len,
        };
        stderr.* = .{
            .items = stderr_r.buffer[0..stderr_r.end],
            .capacity = stderr_r.buffer.len,
        };
        stdout_r.buffer = &.{};
        stderr_r.buffer = &.{};
    }

    while (try poller.pollTimeout(1000 * 1000 * 100)) {
        if (stdout_r.bufferedLen() > max_output_bytes)
            return error.StdoutStreamTooLong;
        if (stderr_r.bufferedLen() > max_output_bytes)
            return error.StderrStreamTooLong;
        if (data.len > 0) {
            const l = if (data.len < block_size) data.len else block_size;
            //debug("sending {d} bytes. {d} bytes left", .{ l, data.len });
            child.stdin.?.writeAll(data[0..l]) catch |f| {
                err("Error sending audio to ffmpeg. Error:{any}", .{f});
                return error.FfmpegFailure;
            };
            if (data.len < block_size) {
                data.len = 0;
                child.stdin.?.close();
                child.stdin = null;
                child.stdin_behavior = .Ignore;
            } else {
                data = data[block_size..];
            }
        }
    }
}

const block_size = 50000;

test "audio_to_ogg" {
    const gpa = std.testing.allocator;
    var resources = try Resources.create(gpa);
    defer resources.destroy();

    _ = try resources.load_directory("./test/repo/", null);
    const resource = try resources.lookupOne("ἄρτος", .wav, gpa);

    //try expect(0 != resource.uid);
    try expectEqual(true, resource.?.visible);
    try expectEqual(.wav, resource.?.resource);
    try expectEqual(1, resource.?.sentences.items.len);
    try expectEqualStrings("ἄρτος", resource.?.sentences.items[0]);

    const data = try generate_ogg_audio(gpa, resource.?, resources, .{});
    defer gpa.free(data);

    // Different versions of ffmpeg create a slightly different sized file.
    try expect(data.len < 25954 + 1000);
    try expect(data.len > 25954 - 1000);

    //try write_file_bytes(gpa, "/tmp/test.ogg", data);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const debug = std.log.debug;
const err = std.log.err;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Resources = @import("resources.zig").Resources;
const Resource = @import("resources.zig").Resource;
const Options = @import("resources.zig").Options;

const wav = @import("wav.zig");
