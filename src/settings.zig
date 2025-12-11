//! Read each `Setting` line-by-line from a `Parser`.

pub const Self = @This();

pub const Setting = struct {
    setting: Type,
    value: []const u8,
};

/// Read a setting from a `Parser`. Returns null if the data contains no
/// more bytes, or bytes exist, but the bytes don't represent a correctly
/// formatted setting line could not be read.
pub fn next(parser: *Parser) error{InvalidUtf8}!?Setting {
    _ = parser.skip_whitespace_and_lines();
    const c = try parser.next_unicode();
    if (c == 0) return null;

    const d = Type.parse(c);
    if (d == .unknown) {
        const text = parser.read_until_eol(); // Read until cr,lf,eof, or ~
        return .{
            .setting = d,
            .value = text,
        };
    }
    _ = parser.skip_whitespace_and_lines();
    const separator = parser.next();
    if (separator != ':') {
        return null;
    }
    _ = parser.skip_whitespace_and_lines();
    const text = parser.read_until_eol(); // Read until cr,lf,eof, or ~
    return .{
        .setting = d,
        .value = text,
    };
}

pub const Type = enum {
    unknown,
    uid,
    date,
    copyright,
    visible,
    link,
    sentence,

    pub fn parse(value: u21) Type {
        return switch (value) {
            'i', 'ι', 'I', 'Ι' => .uid,
            'd', 'δ', 'D', 'Δ' => .date,
            'c', 'C' => .copyright,
            's', 'σ', 'S', 'Σ' => .sentence,
            'v', 'V' => .visible,
            'l', 'L', 'λ', 'Λ' => .link,
            else => .unknown,
        };
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "read settings" {
    var data = Parser.init("i:1234\nd:20002010\ns:hello sentence");
    {
        const setting = try Self.next(&data);
        try expect(setting != null);
        try expectEqual(.uid, setting.?.setting);
    }
    {
        const setting = try Self.next(&data);
        try expect(setting != null);
        try expectEqual(.date, setting.?.setting);
    }
    {
        const setting = try Self.next(&data);
        try expect(setting != null);
        try expectEqual(.sentence, setting.?.setting);
    }
    {
        const setting = try Self.next(&data);
        try expect(setting == null);
    }
}

const std = @import("std");
const Parser = @import("praxis").Parser;
