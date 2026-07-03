const std = @import("std");
const lex = @import("lex.zig");

pub const Parser = struct {
    reader: *std.Io.Reader,
    buffered_exit_event: ?Item,
    next_discard: usize = 0,

    stream_pos: usize,

    // Reader buffer needs to be long enough to hold the largest xml element.
    // Element content is not used here, but comments are included.
    //
    // If your document has unreasonably large comments we should refactor to
    // export comment content into the content writer, or to discard
    pub fn init(reader: *std.Io.Reader) Parser {
        return Parser{
            .reader = reader,
            .next_discard = 0,
            .stream_pos = 0,
            .buffered_exit_event = null,
        };
    }

    pub fn next(self: *Parser, content_writer: *std.Io.Writer) !?Item {
        if (self.buffered_exit_event) |e| {
            defer self.buffered_exit_event = null;
            return e;
        }
        self.reader.toss(self.next_discard);
        self.stream_pos += self.next_discard;
        self.next_discard = 0;

        const streamed_bytes = try self.reader.streamDelimiterEnding(content_writer, '<');
        if (streamed_bytes > 0) {
            defer self.stream_pos += streamed_bytes;
            return .{
                .type = .element_content,
                .stream_start = self.stream_pos,
                .stream_end = self.stream_pos + streamed_bytes,
                .name = &.{},
                .attributes = &.{},
            };
        }

        var tag_content = self.reader.peekDelimiterInclusive('>') catch |e| {
            switch (e) {
                error.EndOfStream => return null,
                else => return e,
            }
        };
        self.next_discard = tag_content.len;

        var buf = lex.Buf.init(tag_content);
        const item_type = try parseElementPrefix(&buf);
        const prefix_len = buf.idx;
        const end_sequence = try item_type.endSequence();

        // If we were looking for --> but found >, we need to keep looking.
        // std.Io.Reader doesn't seem to have a "peek from position", so we just
        // max out the buffer. We could do a first attempt to find the end tag in
        // the existing buffer, but whatever. Feel free to optimize if this is a
        // problem for you later
        if (!std.mem.endsWith(u8, tag_content, end_sequence)) {
            if (self.reader.seek != 0 or self.reader.end != self.reader.buffer.len) {
                // If this fails we still might be able to find the end. e.g.
                // reading from a fixed buffer
                self.reader.fillMore() catch {};
            }
            const buffered_data = self.reader.buffered();
            const end = std.mem.indexOf(u8, buffered_data, end_sequence) orelse return error.NoEndSequence;
            tag_content = buffered_data[0 .. end + end_sequence.len];
            self.next_discard = tag_content.len;
            buf = lex.Buf.init(tag_content);
            buf.idx = prefix_len;
        }

        // From here on out, we may return references to data in
        // self.reader.buffer. Don't touch it!

        const name: []const u8 = if (item_type != .xml_decl) blk: {
            const name_range = buf.takeUntilAny(std.ascii.whitespace ++ "/>") orelse buf.emptyRange();
            break :blk name_range.data(buf);
        } else "";

        const attributes_start = buf.idx;
        var element_end_tag_start = tag_content.len - end_sequence.len;

        // Special case for handling self closing tags
        if (item_type == .element_start and element_end_tag_start > 0 and tag_content[element_end_tag_start - 1] == '/') {
            element_end_tag_start -= 1;
            self.buffered_exit_event = .{
                .type = .element_end,
                .stream_start = self.stream_pos,
                .stream_end = self.stream_pos + self.next_discard,
                .name = name,
                .attributes = &.{},
            };
        }

        const attributes_slice: []const u8 = switch (item_type) {
            .xml_decl, .element_start => tag_content[attributes_start..element_end_tag_start],
            else => &.{},
        };

        return .{
            .type = item_type,
            .stream_start = self.stream_pos,
            .stream_end = self.stream_pos + self.next_discard,
            .name = name,
            .attributes = attributes_slice,
        };
    }
};

pub const Attribute = struct {
    key: []const u8,
    val: []const u8,
};

pub const Item = struct {
    type: ItemType,
    name: []const u8,
    attributes: []const u8,

    stream_start: usize,
    stream_end: usize,

    pub fn attributeIt(self: Item) AttributeIt {
        return .{
            .buf = lex.Buf.init(self.attributes),
        };
    }

    pub fn attributeByKey(self: Item, key: []const u8) !?[]const u8 {
        var it = self.attributeIt();
        while (try it.next()) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.val;
            }
        }

        return null;
    }
};

pub const AttributeIt = struct {
    buf: lex.Buf,

    pub fn next(self: *AttributeIt) !?Attribute {
        _ = self.buf.takeWhileAny(&std.ascii.whitespace);
        if (self.buf.empty()) return null;

        const key_range = self.buf.takeUntilAny(std.ascii.whitespace ++ "=") orelse {
            return error.MalformedAttribute;
        };

        _ = self.buf.takeWhileAny(&std.ascii.whitespace);
        _ = self.buf.takeOne("=") orelse return error.MalformedAttribute;

        _ = self.buf.takeWhileAny(&std.ascii.whitespace);
        _ = self.buf.takeOne("\"") orelse return error.MalformedAttribute;

        // FIXME: What if we see an invalid character
        // FIXME: Escaped quote
        const val_range = self.buf.takeUntilAny("\"") orelse self.buf.emptyRange();
        if (self.buf.empty()) return error.MalformedAttribute;
        _ = self.buf.takeOne("\"");

        return .{
            .key = key_range.data(self.buf),
            .val = val_range.data(self.buf),
        };
    }
};

fn parseElementPrefix(buf: *lex.Buf) !ItemType {
    _ = buf.takeOne("<") orelse return error.NotAnElement;

    if (buf.takeOne("?") != null) {
        _ = buf.takeSequence("xml ") orelse return error.UnexpectedByte;
        return .xml_decl;
    }
    if (buf.takeOne("/") != null) return .element_end;
    if (buf.takeOne("!") != null) {
        _ = buf.takeSequence("--") orelse return error.UnexpectedByte;
        return .comment;
    }
    return .element_start;
}

pub const ItemType = enum {
    xml_decl,
    element_start,
    element_end,
    element_content,
    comment,

    fn endSequence(self: ItemType) ![]const u8 {
        return switch (self) {
            .xml_decl => "?>",
            .element_start, .element_end => ">",
            .comment => "-->",
            .element_content => {
                return error.UnexpectedContent;
            },
        };
    }
};

test "xml parsing sanity test" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<some_tag attr1="hello" attr2="world">
        \\   <content>
        \\        Wow look at this content
        \\   </content>
        \\   <self_closing/>
        \\</some_tag>
    ;

    var reader = std.Io.Reader.fixed(xml);

    var lexer = Parser.init(&reader);

    var discarding = std.Io.Writer.Discarding.init(&.{});

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .xml_decl);
        try std.testing.expectEqualStrings("", decl.name);

        var attrs = decl.attributeIt();
        const version = (try attrs.next()).?;
        try std.testing.expectEqualStrings("version", version.key);
        try std.testing.expectEqualStrings("1.0", version.val);

        const encoding = (try attrs.next()).?;
        try std.testing.expectEqualStrings("encoding", encoding.key);
        try std.testing.expectEqualStrings("UTF-8", encoding.val);

        try std.testing.expectEqual(null, try attrs.next());
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_content);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_start);
        try std.testing.expectEqualStrings("some_tag", decl.name);

        var attrs = decl.attributeIt();
        const version = (try attrs.next()).?;
        try std.testing.expectEqualStrings("attr1", version.key);
        try std.testing.expectEqualStrings("hello", version.val);

        const encoding = (try attrs.next()).?;
        try std.testing.expectEqualStrings("attr2", encoding.key);
        try std.testing.expectEqualStrings("world", encoding.val);
        try std.testing.expectEqual(null, try attrs.next());
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_content);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_start);
        try std.testing.expectEqualStrings("content", decl.name);

        var attrs = decl.attributeIt();
        try std.testing.expectEqual(null, try attrs.next());
    }

    {
        var content_buf: [4096]u8 = undefined;
        var content_writer = std.Io.Writer.fixed(&content_buf);
        const decl = (try lexer.next(&content_writer)).?;
        try std.testing.expectEqual(decl.type, .element_content);

        try std.testing.expectEqualStrings(
            "\n        Wow look at this content\n   ",
            content_writer.buffered(),
        );
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_end);
        try std.testing.expectEqualStrings("content", decl.name);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_content);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_start);
        try std.testing.expectEqualStrings("self_closing", decl.name);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_end);
        try std.testing.expectEqualStrings("self_closing", decl.name);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_content);
    }

    {
        const decl = (try lexer.next(&discarding.writer)).?;
        try std.testing.expectEqual(decl.type, .element_end);
        try std.testing.expectEqualStrings("some_tag", decl.name);
    }
}
