/// Initialize an engine using `Engine.initWithWav()` and save any changes to the
/// wav data using `engine.write()`
pub const Engine = struct {
    channels: u16 = 0,
    sample_rate: u32 = 0,
    values: std.ArrayListUnmanaged(f64),

    /// Metadata found during audio import
    wav: ?*Wav = undefined,
    /// Max value seen during audio import
    max: f64 = 0,

    pub fn initWithWav(allocator: Allocator, data: []const u8) (Allocator.Error || Error)!*Engine {
        var engine = try allocator.create(Engine);
        errdefer engine.destroy(allocator);
        engine.* = .{
            .channels = 0,
            .sample_rate = 0,
            .values = .empty,
            .wav = null,
            .max = 0,
        };
        try Wav.init(allocator, data, engine);
        return engine;
    }

    pub fn destroy(engine: *Engine, allocator: Allocator) void {
        if (engine.wav != null)
            allocator.destroy(engine.wav.?);
        engine.values.deinit(allocator);
        allocator.destroy(engine);
    }

    pub fn write(e: *Engine, w: anytype) (std.Io.Writer.Error)!void {
        try e.wav.?.write(w, e);
    }

    pub fn clearRetainingCapacity(engine: *Engine) void {
        engine.values.clearRetainingCapacity();
    }

    pub fn ingest(e: *Engine, allocator: Allocator, n: f64) Allocator.Error!void {
        try e.values.append(allocator, @floatCast(n));
        e.max = @max(e.max, @abs(n));
    }

    pub const fade_out_time: f64 = 0.02;

    /// Add a small fade in and fade out transition to the audio data.
    pub fn faders(e: *Engine) void {
        const fadeLengthF: f64 = @as(f64, @floatFromInt(e.sample_rate)) * fade_out_time;
        const fadeLength: usize = @intFromFloat(fadeLengthF);
        if (e.sample_rate == 0) {
            info("sample rate {d}. fade samples {d}.", .{ e.sample_rate, fadeLength });
            info("Sample rate for sound engine is 0. Fade in/out is meaningless.", .{});
            return;
        }
        if (e.values.items.len < fadeLength * 2) {
            info("Sample too sort to apply fade", .{});
            return;
        }
        for (0..fadeLength) |i| {
            e.values.items[i] = e.values.items[i] * (@as(f64, @floatFromInt(i)) / fadeLengthF);
        }
        var v: usize = 0;
        for (e.values.items.len - fadeLength..e.values.items.len) |i| {
            const amp: f64 = @as(f64, @floatFromInt(fadeLength - v)) / fadeLengthF;
            e.values.items[i] = e.values.items[i] * amp;
            v = v + 1;
        }
    }

    /// Adjust the overall sound level to the requested peak. 0.0 means turn
    /// volume down to zero. 1.0 means turn up to maximum volume. If the the
    /// sound file is almost silent for the entire time, normalisation is
    /// refused because we dont want to turn up the volume on static background
    /// noise.
    pub fn normalise(e: *Engine, peak: f64) void {
        if (e.values.items.len == 0) {
            debug("cant normalise empty file", .{});
            return;
        }

        if (peak > 1.0 or peak < -1.0)
            err("invalid normalisation size", .{});

        if (e.max < 0.03) {
            info("audio data is effectively silent. Abort normalisaiton. (peak={d}%)\n", .{e.max * 100});
            return;
        }

        const scale = peak / e.max;
        debug("max: {d} peak: {d} scale: {d}\n", .{ e.max, peak, scale });
        if (scale > 1.0) debug("scaling up", .{}) else debug("scaling down", .{});

        for (e.values.items) |*value| {
            value.* = value.* * scale;
        }
    }
};

pub const Error = error{
    not_wav_file,
    unsupported_wav_format,
    pcm_wav_only,
    invalid_channel_metadata,
    incomplete_wav_file,
};

/// Holds a representation of a wav file to be read or written.
pub const Wav = struct {
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
    pub fn init(allocator: Allocator, data: []const u8, engine: *Engine) (error{OutOfMemory} || Error)!void {
        var wav = try allocator.create(Wav);
        errdefer {
            allocator.destroy(wav);
            engine.wav = null;
        }
        wav.data = data;
        try wav.read_metadata();
        engine.wav = wav;
        try wav.read_audio(allocator, engine);
    }

    pub inline fn next_slice(wav: *Wav, size: usize) Error![]const u8 {
        if (wav.data.len < size) return Error.incomplete_wav_file;
        defer wav.data = wav.data[size..];
        return wav.data[0..size];
    }

    pub inline fn next_u32(wav: *Wav) Error!u32 {
        if (wav.data.len < 4) return Error.incomplete_wav_file;
        defer wav.data = wav.data[4..];
        return std.mem.readInt(u32, wav.data[0..4], std.builtin.Endian.little);
    }

    pub inline fn next_f32(wav: *Wav) Error!f32 {
        if (wav.data.len < 4) return Error.incomplete_wav_file;
        defer wav.data = wav.data[4..];
        return @bitCast(std.mem.readInt(u32, wav.data[0..4], std.builtin.Endian.little));
    }

    pub inline fn next_u16(wav: *Wav) Error!u16 {
        if (wav.data.len < 2) return Error.incomplete_wav_file;
        defer wav.data = wav.data[2..];
        return std.mem.readInt(u16, wav.data[0..2], std.builtin.Endian.little);
    }

    pub inline fn next_i16(wav: *Wav) Error!i16 {
        if (wav.data.len < 2) return Error.incomplete_wav_file;
        defer wav.data = wav.data[2..];
        return std.mem.readInt(i16, wav.data[0..2], std.builtin.Endian.little);
    }

    pub inline fn next_u8(wav: *Wav) Error!u8 {
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

    pub fn read_metadata(wav: *Wav) Error!void {
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

    pub fn write(wav: *Wav, w: anytype, e: *Engine) (Error || Allocator.Error || std.Io.Writer.Error)!void {
        try wav.write_header(w, e);
        try wav.write_audio(w, e);
    }

    fn write_header(wav: *Wav, w: anytype, e: *Engine) (Allocator.Error || std.Io.Writer.Error)!void {
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

    pub fn read_audio(wav: *Wav, allocator: Allocator, e: *Engine) (Error || error{OutOfMemory})!void {
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

    fn write_audio(wav: *Wav, w: anytype, e: *Engine) (Error || Allocator.Error || std.Io.Writer.Error)!void {
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

pub fn NewWave16BitInt(channels: u16, sampleRate: u32) *Wav {
    if (channels == 0 or sampleRate == 0)
        return Error.invalid_channel_metadata;

    const u16Size = 2;
    return &Wav{
        .AudioFormat = 1,
        .Channels = channels,
        .SampleRate = sampleRate,
        .ByteRate = sampleRate * u16Size * channels,
        .BlockAlign = u16Size * channels,
        .BitsPerSample = u16(u16Size * 8), // 8, 16, 32, etc...
    };
}

pub fn NewWave32BitFloat(channels: u16, sampleRate: u32) *Wav {
    if (channels == 0 or sampleRate == 0)
        return Error.invalid_channel_metadata;

    const float32Size = 4;
    return &Wav{
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
    try std.testing.expectEqual(Error.incomplete_wav_file, Engine.initWithWav(allocator, ""));

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_32");
    const e = try Engine.initWithWav(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(1, e.channels);
    try expectEqual(44100, e.sample_rate);

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    try e.wav.?.write(out.writer(allocator), e);

    {
        // Read/write and check result
        const e2 = try Engine.initWithWav(allocator, out.items);
        defer e2.destroy(allocator);
        var out2 = std.ArrayListUnmanaged(u8).empty;
        defer out2.deinit(allocator);
        try e2.wav.?.write(out2.writer(allocator), e2);
        try expectEqual(out.items.len, out2.items.len);
        try expectEqualSlices(u8, out.items, out2.items);
        var f = try std.fs.cwd().createFile("/tmp/w1.wav", .{});
        try f.writeAll(out2.items);
        f.close();
    }

    {
        e.normalise(0.90);
        e.faders();
        var out3 = std.ArrayListUnmanaged(u8).empty;
        defer out3.deinit(allocator);
        try e.wav.?.write(out3.writer(allocator), e);
        try expectEqual(out.items.len, out3.items.len);
        var f = try std.fs.cwd().createFile("/tmp/w2.wav", .{});
        try f.writeAll(out3.items);
        f.close();
    }
}

test "read_wav_32_stereo" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(Error.incomplete_wav_file, Engine.initWithWav(allocator, ""));

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_32_stereo");
    const e = try Engine.initWithWav(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(2, e.channels);
    try expectEqual(44100, e.sample_rate);
    e.normalise(0.90);
    e.faders();

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    try e.wav.?.write(out.writer(allocator), e);

    var f = try std.fs.cwd().createFile("/tmp/w3.wav", .{});
    try f.writeAll(out.items);
    f.close();
}

test "read_wav_16" {
    const allocator = std.testing.allocator;

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_16");
    const e = try Engine.initWithWav(allocator, data);
    defer e.destroy(allocator);
    try expectEqual(1, e.channels);
    try expectEqual(44100, e.sample_rate);

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    try e.wav.?.write(out.writer(allocator), e);

    var f = try std.fs.cwd().createFile("/tmp/w4.wav", .{});
    try f.writeAll(out.items);
    f.close();
}

test "fader_test" {
    const gpa = std.testing.allocator;

    // Read a simple wav file. Ignore unused headers.
    const data = @embedFile("wav_fade_edges");
    const e = try Engine.initWithWav(gpa, data);
    defer e.destroy(gpa);
    try expectEqual(2, e.channels);
    try expectEqual(44100, e.sample_rate);
    e.normalise(0.90);
    e.faders();

    // Output the simple wave file. Unused headers will not be emitted.
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(gpa);
    try e.wav.?.write(out.writer(gpa), e);

    var f = try std.fs.cwd().createFile("/tmp/w5.wav", .{});
    try f.writeAll(out.items);
    f.close();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const debug = std.log.debug;
const err = std.log.err;
const info = std.log.info;
