/// Trim and tokenize a sentence.
pub const WordFinder = struct {
    data: []const u8 = "",

    pub fn init(data: []const u8) WordFinder {
        return .{
            .data = data,
        };
    }

    /// Skip over any punctuation characters and return the next
    /// string value in the data. Returns null when no more words are
    /// available.
    pub fn next(self: *WordFinder) error{
        Utf8EncodesSurrogateHalf,
        Utf8CodepointTooLarge,
        Utf8OverlongEncoding,
        Utf8ExpectedContinuation,
        Utf8InvalidStartByte,
    }!?[]const u8 {
        if (self.data.len == 0) return null;

        while (self.data.len > 0 and is_not_word(self.data[0])) {
            self.data.ptr += 1;
            self.data.len -= 1;
        }

        while (self.data.len > 0) {
            const l: usize = try unicode.utf8ByteSequenceLength(self.data[0]);
            const c: u21 = try unicode.utf8Decode(self.data[0..l]);
            if (!is_not_word(c)) break;
            self.data.ptr += l;
            self.data.len -= l;
        }

        var end: usize = 0;
        while (self.data.len > end) {
            const l: usize = try unicode.utf8ByteSequenceLength(self.data[end]);
            const c: u21 = try unicode.utf8Decode(self.data[end..(end + l)]);
            if (is_not_word(c)) break;
            end += l;
        }
        if (end == 0) return null;

        const token = self.data[0..end];
        self.data.ptr += end;
        self.data.len -= end;
        return token;
    }
};

pub inline fn is_not_word(c: u21) bool {
    return c < '0' or (c > '9' and c < 'A') or (c > 'Z' and c < 'a') or
        c == '·' or c == '•' or c == '–' or c == '—';
}

const std = @import("std");
const eql = std.mem.eql;
const unicode = std.unicode;
const expect = std.testing.expect;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "read_chunks" {
    var data = WordFinder.init("the fish");
    try expectEqualStrings("the", (try data.next()).?);
    try expectEqualStrings("fish", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("");
    try expectEqual(null, data.next());

    data = WordFinder.init("τίς βλέπει");
    try expectEqualStrings("τίς", (try data.next()).?);
    try expectEqualStrings("βλέπει", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("God, god.");
    try expectEqualStrings("God", (try data.next()).?);
    try expectEqualStrings("god", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("fish\ncat\n");
    try expectEqualStrings("fish", (try data.next()).?);
    try expectEqualStrings("cat", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("  'fish'   \n     [cat]      \n");
    try expectEqualStrings("fish", (try data.next()).?);
    try expectEqualStrings("cat", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("fish  \n\n cat");
    try expectEqualStrings("fish", (try data.next()).?);
    try expectEqualStrings("cat", (try data.next()).?);
    try expectEqual(null, data.next());

    data = WordFinder.init("fish\r\n\n\rcat? hello! αρτος·");
    try expectEqualStrings("fish", (try data.next()).?);
    try expectEqualStrings("cat", (try data.next()).?);
    try expectEqualStrings("hello", (try data.next()).?);
    try expectEqualStrings("αρτος", (try data.next()).?);
    try expectEqual(null, data.next());
}
