/// Count the appearance of  individual unique words sentences,
pub const UniqueWords = struct {
    words: std.StringHashMap(void) = undefined,

    pub fn init(allocator: std.mem.Allocator) UniqueWords {
        return .{
            .words = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *UniqueWords) void {
        self.words.deinit();
    }

    /// Check an individual sentence for the appearance of unique
    /// words in this sentence.
    pub fn add(self: *UniqueWords, sentence: []const u8) error{ OutOfMemory, Utf8EncodesSurrogateHalf, Utf8CodepointTooLarge, Utf8OverlongEncoding, Utf8ExpectedContinuation, Utf8InvalidStartByte }!void {
        var words = WordFinder.init(sentence);
        while (try words.next()) |word| {
            try self.words.put(word, {});
        }
    }

    /// Check a set of sentence for the appearance of unique
    /// words in these sentence.
    pub fn addArray(self: *UniqueWords, sentences: *[][]const u8) error{ OutOfMemory, Utf8EncodesSurrogateHalf, Utf8CodepointTooLarge, Utf8OverlongEncoding, Utf8ExpectedContinuation, Utf8InvalidStartByte }!void {
        for (sentences.*) |sentence| {
            var words = WordFinder.init(sentence);
            while (try words.next()) |word| {
                try self.words.put(word, {});
            }
        }
    }

    /// Report how many unique words have been found.
    pub fn count(self: *UniqueWords) usize {
        return self.words.count();
    }

    /// Check if a word has appeared in previously seen sentences.
    pub fn contains(self: *UniqueWords, key: []const u8) bool {
        return self.words.contains(key);
    }
};

const std = @import("std");
const unicode = @import("std").unicode;
const WordFinder = @import("word_finder.zig").WordFinder;

const eql = @import("std").mem.eql;
const expect = std.testing.expect;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "unique_words" {
    var unique = UniqueWords.init(std.testing.allocator);
    defer unique.deinit();

    try unique.add("the big fish\n");
    try unique.add("the small fish.");

    try expectEqual(4, unique.count());
    try expectEqual(true, unique.contains("the"));
    try expectEqual(false, unique.contains("art"));

    try unique.add("the small αρτος·");
    try expectEqual(5, unique.count());
    try expectEqual(true, unique.contains("αρτος"));
}
