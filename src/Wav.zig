/// Initialize an engine using `Wav.initWithMetadata()` and save any changes to the
/// wav data using `engine.write()`
pub const Wav = @This();

channels: u16 = 0,
sample_rate: u32 = 0,
values: std.ArrayListUnmanaged(f64),

/// Metadata found during audio import
wav: ?*Metadata = undefined,
/// Max value seen during audio import
max: f64 = 0,

/// Setup an engine entity with a wav data file.
pub fn initWithMetadata(allocator: Allocator, data: []const u8) (Allocator.Error || Error)!*Wav {
    var engine = try allocator.create(Wav);
    errdefer engine.destroy(allocator);
    engine.* = .{
        .channels = 0,
        .sample_rate = 0,
        .values = .empty,
        .wav = null,
        .max = 0,
    };
    try Metadata.init(allocator, data, engine);
    return engine;
}

pub fn destroy(self: *Wav, allocator: Allocator) void {
    if (self.wav != null)
        allocator.destroy(self.wav.?);
    self.values.deinit(allocator);
    allocator.destroy(self);
}

/// Write out the current wav data to an output writer.
pub fn write(self: *Wav, w: *std.Io.Writer) (std.Io.Writer.Error || Allocator.Error || Error)!void {
    try self.wav.?.write(w, self);
}

pub fn clearRetainingCapacity(self: *Wav) void {
    self.values.clearRetainingCapacity();
}

/// Heoper function reads the next byte in a wav file and keeps
/// track of the maximum peak value.
inline fn ingest(self: *Wav, allocator: Allocator, n: f64) Allocator.Error!void {
    try self.values.append(allocator, @floatCast(n));
    self.max = @max(self.max, @abs(n));
}

/// To prevent clicks and pops at the start and end of an audio file,
/// a fade in and fade out curve is applied at the start and end of
/// the file for this amount of time
pub const fade_out_time: f64 = 0.02;

/// Add a small fade in and fade out transition to the audio data.
pub fn faders(self: *Wav) void {
    const fadeLengthF: f64 = @as(f64, @floatFromInt(self.sample_rate)) * fade_out_time;
    const fadeLength: usize = @intFromFloat(fadeLengthF);
    if (self.sample_rate == 0) {
        info("sample rate {d}. fade samples {d}.", .{ self.sample_rate, fadeLength });
        info("Sample rate for sound engine is 0. Fade in/out is meaningless.", .{});
        return;
    }
    if (self.values.items.len < fadeLength * 2) {
        info("Sample too sort to apply fade", .{});
        return;
    }
    for (0..fadeLength) |i| {
        self.values.items[i] = self.values.items[i] * (@as(f64, @floatFromInt(i)) / fadeLengthF);
    }
    var v: usize = 0;
    for (self.values.items.len - fadeLength..self.values.items.len) |i| {
        const amp: f64 = @as(f64, @floatFromInt(fadeLength - v)) / fadeLengthF;
        self.values.items[i] = self.values.items[i] * amp;
        v = v + 1;
    }
}

/// Adjust the overall sound level to the requested peak. 0.0 means turn
/// volume down to zero. 1.0 means turn up to maximum volume. If the the
/// sound file is almost silent for the entire time, normalisation is
/// refused because we dont want to turn up the volume on static background
/// noise.
pub fn normalise(self: *Wav, peak: f64) f64 {
    if (self.values.items.len == 0) {
        err("cant normalise empty file", .{});
        return 0;
    }

    if (peak > 1.0 or peak < -1.0) {
        err("invalid normalisation size", .{});
        return 0;
    }

    if (self.max < 0.03) {
        warn("audio data is effectively silent. Abort normalisaiton. (peak={d}%)\n", .{self.max * 100});
        return 0;
    }

    const scale = peak / self.max;

    if (scale < 1.01 and scale > 0.99) {
        debug("audio data does not need scaling. Abort normalisaiton. (peak={d}%, scale={d})\n", .{ self.max * 100, scale });
        return 1;
    }

    //err("normalise. max: {d} peak: {d} scale: {d}\n", .{ self.max, peak, scale });
    if (scale > 1.0) debug("scaling up", .{}) else debug("scaling down", .{});

    self.max = 0;
    for (self.values.items) |*value| {
        value.* = value.* * scale;
        self.max = @max(self.max, @abs(value.*));
    }

    return scale;
}

/// The set of all potential errors that may be returned.
pub const Error = error{
    not_wav_file,
    unsupported_wav_format,
    pcm_wav_only,
    invalid_channel_metadata,
    incomplete_wav_file,
};

/// Holds a representation of a wav file to be read or written.
pub const Metadata = struct {
    chunkID: []const u8,
    chunkSize: u32,
    chunkFormat: []const u8,

    subchunkID: []const u8,
    subchunkSize: u32,
    subchunk2ID: []const u8,
    subchunk2Size: u32,

    AudioFormat: u16,
    Channels: u16,
    SampleRate: u32,
    ByteRate: u32,
    BlockAlign: u16,
    BitsPerSample: u16,

    // Backing data array
    data: []const u8,

    /// Read the contents of a wav file into an engine struct.
    pub fn init(allocator: Allocator, data: []const u8, engine: *Wav) (error{OutOfMemory} || Error)!void {
        var wav = try allocator.create(Metadata);
        errdefer {
            allocator.destroy(wav);
            engine.wav = null;
        }
        wav.data = data;
        try wav.readMetadata();
        engine.wav = wav;
        try wav.read_audio(allocator, engine);
    }

    pub inline fn next_slice(wav: *Metadata, size: usize) Error![]const u8 {
        if (wav.data.len < size) return Error.incomplete_wav_file;
        defer wav.data = wav.data[size..];
        return wav.data[0..size];
    }

    pub inline fn next_u32(wav: *Metadata) Error!u32 {
        if (wav.data.len < 4) return Error.incomplete_wav_file;
        defer wav.data = wav.data[4..];
        return std.mem.readInt(u32, wav.data[0..4], std.builtin.Endian.little);
    }

    pub inline fn next_f32(wav: *Metadata) Error!f32 {
        if (wav.data.len < 4) return Error.incomplete_wav_file;
        defer wav.data = wav.data[4..];
        return @bitCast(std.mem.readInt(u32, wav.data[0..4], std.builtin.Endian.little));
    }

    pub inline fn next_u16(wav: *Metadata) Error!u16 {
        if (wav.data.len < 2) return Error.incomplete_wav_file;
        defer wav.data = wav.data[2..];
        return std.mem.readInt(u16, wav.data[0..2], std.builtin.Endian.little);
    }

    pub inline fn next_i16(wav: *Metadata) Error!i16 {
        if (wav.data.len < 2) return Error.incomplete_wav_file;
        defer wav.data = wav.data[2..];
        return std.mem.readInt(i16, wav.data[0..2], std.builtin.Endian.little);
    }

    pub inline fn next_u8(wav: *Metadata) Error!u8 {
        if (wav.data.len < 1) return Error.incomplete_wav_file;
        defer wav.data = wav.data[1..];
        return wav.data[0];
    }

    pub inline fn append_u32(w: anytype, value: u32) (Allocator.Error || std.Io.Writer.Error)!void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .little);
        try w.writeAll(buffer[0..4]);
    }

    pub inline fn append_f32(w: anytype, value: f32) (Allocator.Error || std.Io.Writer.Error)!void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, @bitCast(value), .little);
        try w.writeAll(buffer[0..4]);
    }

    pub inline fn append_u16(w: anytype, value: u16) (Allocator.Error || std.Io.Writer.Error)!void {
        var buffer: [2]u8 = undefined;
        std.mem.writeInt(u16, &buffer, @as(u16, @intCast(value)), .little);
        try w.writeAll(buffer[0..2]);
    }

    pub inline fn append_i16(w: anytype, value: i16) (Allocator.Error || std.Io.Writer.Error)!void {
        var buffer: [2]u8 = undefined;
        std.mem.writeInt(i16, &buffer, @as(i16, @intCast(value)), .little);
        try w.writeAll(buffer[0..2]);
    }

    pub inline fn append_u8(w: anytype, value: u8) (Allocator.Error || std.Io.Writer.Error)!void {
        try w.writeByte(value);
    }

    pub fn readMetadata(wav: *Metadata) Error!void {
        wav.chunkID = try wav.next_slice(4);
        if (!std.mem.eql(u8, wav.chunkID, "RIFF"))
            return Error.not_wav_file;

        wav.chunkSize = try wav.next_u32();
        //fmt.Println("size", wav.chunkSize) // 36 + data chunk size

        wav.chunkFormat = try wav.next_slice(4);
        //err("found: {s}", .{wav.chunkFormat});
        if (!std.mem.eql(u8, wav.chunkFormat, "WAVE"))
            return Error.not_wav_file;

        // Read subchunk header

        // Skip empty data header
        while (true) {
            wav.subchunkID = try wav.next_slice(4);

            if (skippable_block(wav.subchunkID)) {
                const size = try wav.next_u32();
                //debug("skip {s} bytes {d}", .{wav.subchunkID, size});
                _ = try wav.next_slice(size);
                if (size % 2 == 1) {
                    _ = try wav.next_u8();
                }
                continue;
            }
            break;
        }

        // Read format header
        if (!std.mem.eql(u8, wav.subchunkID, "fmt ")) {
            err("not a wav file. Expect 'fmt ', found '{s}'", .{wav.subchunkID});
            return Error.unsupported_wav_format;
        }
        // 16 = PCM
        wav.subchunkSize = try wav.next_u32();
        if (wav.subchunkSize != 16) {
            err("Expect subchunkSize=16 not {d}'", .{wav.subchunkSize});
            return Error.pcm_wav_only;
        }

        // 1 == 16 bit integer
        // 3 == 32 bit float
        wav.AudioFormat = try wav.next_u16();
        wav.Channels = try wav.next_u16();
        wav.SampleRate = try wav.next_u32();
        wav.ByteRate = try wav.next_u32();
        wav.BlockAlign = try wav.next_u16();
        wav.BitsPerSample = try wav.next_u16();

        //debug("subchunk", .{wav.AudioFormat, wav.Channels, wav.SampleRate, wav.ByteRate, wav.BlockAlign, wav.BitsPerSample});

        wav.subchunk2ID = try wav.next_slice(4);
        while (std.mem.eql(u8, wav.subchunk2ID, "JUNK") or
            std.mem.eql(u8, wav.subchunk2ID, "junk") or
            std.mem.eql(u8, wav.subchunk2ID, "PEAK") or
            std.mem.eql(u8, wav.subchunk2ID, "peak") or
            std.mem.eql(u8, wav.subchunk2ID, "FACT") or
            std.mem.eql(u8, wav.subchunk2ID, "fact") or
            std.mem.eql(u8, wav.subchunk2ID, "FLLR"))
        {
            const size = try wav.next_u32();
            _ = try wav.next_slice(size);
            wav.subchunk2ID = try wav.next_slice(4);
        }

        if (!std.mem.eql(u8, wav.subchunk2ID, "data")) {
            err("not a wav file. Expect 'data', found '{s}'\n", .{wav.subchunk2ID});
            return Error.unsupported_wav_format;
        }
        wav.subchunk2Size = try wav.next_u32();
        debug("subchunk2 size={d}", .{wav.subchunk2Size});

        if (wav.Channels <= 0) {
            err("No channels", .{});
            return Error.invalid_channel_metadata;
        }
        if (wav.BitsPerSample % 8 != 0) {
            err("Inalid bits per sample.", .{});
            return Error.invalid_channel_metadata;
        }
        if (wav.BlockAlign != wav.Channels * wav.BitsPerSample / 8) {
            err("Invalid block align.", .{});
            return Error.invalid_channel_metadata;
        }
    }

    pub fn skippable_block(value: []const u8) bool {
        return std.mem.eql(u8, value, "JUNK") or std.mem.eql(u8, value, "junk") or
            std.mem.eql(u8, value, "FACT") or std.mem.eql(u8, value, "fact");
    }

    pub fn write(wav: *Metadata, w: *std.Io.Writer, e: *Wav) (Error || Allocator.Error || std.Io.Writer.Error)!void {
        try wav.write_header(w, e);
        try wav.write_audio(w, e);
        try w.flush();
    }

    fn write_header(wav: *Metadata, w: *std.Io.Writer, e: *Wav) (Allocator.Error || std.Io.Writer.Error)!void {
        try w.writeAll("RIFF");
        const fileSize: u32 = 36 + @as(u32, @intCast(e.values.items.len * wav.BlockAlign));
        try append_u32(w, fileSize);
        try w.writeAll("WAVE");

        // subchunk 1
        try w.writeAll("fmt ");
        try append_u32(w, 16);
        try append_u16(w, wav.AudioFormat);
        try append_u16(w, wav.Channels);
        try append_u32(w, wav.SampleRate);
        try append_u32(w, wav.ByteRate);
        try append_u16(w, wav.BlockAlign); // Size of each value * channel count
        try append_u16(w, wav.BitsPerSample);

        // subchunk 2
        try w.writeAll("data");
        wav.subchunk2Size = @as(u32, @intCast(e.values.items.len * wav.BlockAlign));
        try append_u32(w, wav.subchunk2Size);
    }

    pub fn read_audio(wav: *Metadata, allocator: Allocator, e: *Wav) (Error || error{OutOfMemory})!void {
        const numSamples = wav.subchunk2Size / wav.BlockAlign;
        const bytesPerSample = wav.BitsPerSample / 8;
        //audioData := b.ReadData(int(channels)*int(numSamples)*bytesPerSample)

        e.sample_rate = wav.SampleRate;
        e.channels = wav.Channels;
        e.clearRetainingCapacity();

        //e.values.ensureTotalCapacity(allocator, data_: usize)
        for (0..(wav.Channels) * numSamples) |_| {
            switch (bytesPerSample) {
                4 => { //32 bit samples over 4 bytes)
                    try e.ingest(allocator, @as(f64, try wav.next_f32()));
                },
                2 => { // 16 bit samples over 2 bytes
                    try e.ingest(allocator, @as(f64, @floatFromInt(try wav.next_i16())) / std.math.maxInt(i16));
                },
                else => return Error.unsupported_wav_format,
            }
        }
    }

    fn write_audio(wav: *Metadata, w: anytype, e: *Wav) (Error || Allocator.Error || std.Io.Writer.Error)!void {
        const bytesPerSample = wav.BitsPerSample / 8;

        for (e.values.items) |value| {
            switch (bytesPerSample) {
                4 => try append_f32(w, @floatCast(value)),
                2 => try append_i16(w, @as(i16, @intFromFloat(value * std.math.maxInt(i16)))),
                else => return Error.unsupported_wav_format,
            }
        }
    }
};

/// Createe an empty placeholder 16 bit integer wav file.
pub fn NewMetadata(channels: u16, sampleRate: u32) *Metadata {
    if (channels == 0 or sampleRate == 0)
        return Error.invalid_channel_metadata;

    const u16Size = 2;
    return &Metadata{
        .AudioFormat = 1,
        .Channels = channels,
        .SampleRate = sampleRate,
        .ByteRate = sampleRate * u16Size * channels,
        .BlockAlign = u16Size * channels,
        .BitsPerSample = u16(u16Size * 8), // 8, 16, 32, etc...
    };
}

/// Createe an empty placeholder 32 bit floating point wav file.
pub fn NewFloatMetadata(channels: u16, sampleRate: u32) *Metadata {
    if (channels == 0 or sampleRate == 0)
        return Error.invalid_channel_metadata;

    const float32Size = 4;
    return &Metadata{
        .AudioFormat = 3,
        .Channels = channels,
        .SampleRate = sampleRate,
        .ByteRate = @as(u32, sampleRate * float32Size * channels),
        .BlockAlign = u16(float32Size * channels),
        .BitsPerSample = u16(float32Size * 8), // 8, 16, 32, etc...
    };
}

test "read_wav_32_mono" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectEqual(Error.incomplete_wav_file, Wav.initWithMetadata(allocator, ""));

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_32");
    const e = try Wav.initWithMetadata(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(1, e.channels);
    try expectEqual(44100, e.sample_rate);

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try e.wav.?.write(&out.writer, e);

    {
        // Read/write and check result
        const e2 = try Wav.initWithMetadata(allocator, out.written());
        defer e2.destroy(allocator);
        var out2 = std.Io.Writer.Allocating.init(allocator);
        defer out2.deinit();
        try e2.wav.?.write(&out2.writer, e2);
        try expectEqual(out.written().len, out2.written().len);
        try expectEqualSlices(u8, out.written(), out2.written());
        var f = try std.Io.Dir.cwd().createFile(io, "/tmp/w1.wav", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, out2.written());
    }

    {
        const scale = e.normalise(0.90);
        try expectApproxEqAbs(4.02, scale, 0.01);
        try expectApproxEqAbs(1, e.normalise(0.9), 0.01);
        e.faders();
        var out3 = std.Io.Writer.Allocating.init(allocator);
        defer out3.deinit();
        try e.wav.?.write(&out3.writer, e);
        try expectEqual(out.written().len, out3.written().len);
        var f = try std.Io.Dir.cwd().createFile(io, "/tmp/w2.wav", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, out3.written());
    }
}

test "read_wav_32_stereo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectEqual(Error.incomplete_wav_file, Wav.initWithMetadata(allocator, ""));

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_32_stereo");
    const e = try Wav.initWithMetadata(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(2, e.channels);
    try expectEqual(44100, e.sample_rate);
    const scale = e.normalise(0.90);
    try expectApproxEqAbs(0.62, scale, 0.01);
    try expectApproxEqAbs(1, e.normalise(0.9), 0.01);
    e.faders();

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try e.wav.?.write(&out.writer, e);

    var f = try std.Io.Dir.cwd().createFile(io, "/tmp/w3.wav", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, out.written());
}

test "read_wav_16" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_16");
    const e = try Wav.initWithMetadata(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(1, e.channels);
    try expectEqual(44100, e.sample_rate);

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    //var writer = out.writer;
    try e.wav.?.write(&out.writer, e);

    var f = try std.Io.Dir.cwd().createFile(io, "/tmp/w4.wav", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, out.written());
}

test "fader_test" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_fade_edges");
    const e = try Wav.initWithMetadata(gpa, data);
    defer e.destroy(gpa);
    try expectEqual(2, e.channels);
    try expectEqual(44100, e.sample_rate);
    const scale = e.normalise(0.90);
    try expectApproxEqAbs(1.11, scale, 0.01);
    try expectApproxEqAbs(1, e.normalise(0.9), 0.01);
    e.faders();

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    //var writer = &out.writer;
    try e.wav.?.write(&out.writer, e);

    var f = try std.Io.Dir.cwd().createFile(io, "/tmp/w5.wav", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, out.written());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const debug = std.log.debug;
const info = std.log.info;
const warn = std.log.warn;
const err = std.log.err;
