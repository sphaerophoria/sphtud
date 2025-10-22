const std = @import("std");

pub const Parser = struct {
    reader: *std.Io.Reader,
    buffered_exit_event: ?Item,
    next_discard: usize = 0,

    // Reader buffer needs to be long enough to hold the largest xml element.
    // Element content is not used here, but comments are included.
    //
    // If your document has unreasonably large comments we should refactor to
    // export comment content into the content writer, or to discard
    pub fn init(reader: *std.Io.Reader) Parser {
        return Parser{
            .reader = reader,
            .next_discard = 0,
            .buffered_exit_event = null,
        };
    }

    pub fn next(self: *Parser, content_writer: *std.Io.Writer) !?Item {
        if (self.buffered_exit_event) |e| {
            defer self.buffered_exit_event = null;
            return e;
        }
        self.reader.toss(self.next_discard);
        self.next_discard = 0;

        const streamed_bytes = try self.reader.streamDelimiterEnding(content_writer, '<');
        if (streamed_bytes > 0) {
            return .{
                .type = .element_content,
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

        const prefix = try parseElementPrefix(tag_content);

        const end_sequence = try prefix.type.endSequence();

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
        }

        // From here on out, we may return references to data in
        // self.reader.buffer. Don't touch it!

        const name_start = prefix.prefix_end;
        var name_end = name_start;

        // xml decl has no name
        if (prefix.type != .xml_decl) {
            name_end = std.mem.indexOfAnyPos(u8, tag_content, name_start, std.ascii.whitespace ++ "/>") orelse return error.NoNameEnd;
        }

        var element_end_tag_start = std.mem.indexOfPos(u8, tag_content, name_end, end_sequence) orelse return error.NoEndSequence;
        var element_end_tag_len = end_sequence.len;

        // Special case for handling self closing tags
        if (prefix.type == .element_start and tag_content[element_end_tag_start - 1] == '/') {
            element_end_tag_start -= 1;
            element_end_tag_len += 1;
            self.buffered_exit_event = .{
                .type = .element_end,
                .name = tag_content[name_start..name_end],
                .attributes = &.{},
            };
        }

        const attributes_slice = switch (prefix.type) {
            .xml_decl, .element_start => tag_content[name_end..element_end_tag_start],
            else => &.{},
        };

        return .{
            .type = prefix.type,
            .name = tag_content[name_start..name_end],
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

    pub fn attributeIt(self: Item) AttributeIt {
        return .{
            .data = self.attributes,
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
    data: []const u8,

    pub fn next(self: *AttributeIt) !?Attribute {
        if (self.data.len == 0) {
            return null;
        }

        var it = SliceCursor{
            .data = self.data,
        };

        const key = try parseKey(&it);
        try validateEq(&it);
        try validateQuote(&it);
        const val = try parseVal(&it);

        defer self.data = self.data[it.idx + 1 .. self.data.len];

        return .{
            .key = key,
            .val = val,
        };
    }

    fn parseKey(it: *SliceCursor) ![]const u8 {
        const key_start = it.consumeWhileAny(&std.ascii.whitespace);
        const key_end = it.consumeWhileNone(std.ascii.whitespace ++ "=");
        if (key_end == it.data.len) {
            std.log.err("Cannot find key end in attribute", .{});
            return error.MalformedAttribute;
        }

        return it.data[key_start..key_end];
    }

    fn validateEq(it: *SliceCursor) !void {
        _ = it.consumeWhileAny(&std.ascii.whitespace);
        if (it.peekByte() != '=') {
            std.log.err("Attribute is missing an = between key/val", .{});
            return error.MalformedAttribute;
        }
        it.consume(1);
    }

    fn validateQuote(it: *SliceCursor) !void {
        _ = it.consumeWhileAny(&std.ascii.whitespace);

        if (it.peekByte() != '"') {
            std.log.err("Attribute is missing a \" for the value start", .{});
            return error.MalformedAttribute;
        }
        it.consume(1);
    }

    fn parseVal(it: *SliceCursor) ![]const u8 {
        // FIXME: What if we see an invalid character
        // FIXME: Escaped quote
        const val_start = it.idx;
        const val_end = it.consumeWhileNone("\"");
        if (val_end == it.data.len) {
            std.log.err("Attribute value does not end with a \"", .{});
            return error.MalformedAttribute;
        }

        return it.data[val_start..val_end];
    }
};

const ParsedElementPrefix = struct {
    type: ItemType,
    prefix_end: usize,
};

fn parseElementPrefix(tag_content: []const u8) !ParsedElementPrefix {
    var token_type: ItemType = .element_start;
    var prefix_end: usize = 1;

    var matcher_buf = [_]ItemTypeMatcher{
        .{ .token = .xml_decl },
        .{ .token = .element_end },
        .{ .token = .comment },
    };

    var prefixes = std.ArrayList(ItemTypeMatcher).fromOwnedSlice(&matcher_buf);

    var buf_slice_idx: usize = 0;

    // Check each matcher for every byte we read. We want to keep the
    // longest match. Because of this we can just keep re-assigning the
    // same output token_type variable as the longer ones will assign
    // later.
    //
    // As matchers reject/accept sequences, we remove them from the
    // list of matchers for next bytes. The scheme of removal was written
    // thinking there would be a lot more than 3 types to match against.
    // It's possible there's something simpler, but this seems fine
    while (prefixes.items.len > 0) {
        defer buf_slice_idx += 1;
        const b = tag_content[buf_slice_idx];

        var to_remove_buf: [matcher_buf.len]usize = undefined;
        var to_remove = std.ArrayList(usize).initBuffer(&to_remove_buf);

        for (prefixes.items, 0..) |*prefix, prefix_idx| {
            switch (try prefix.push(b)) {
                .matched => {
                    token_type = prefix.token;
                    prefix_end = (try prefix.token.startSequence()).len;
                    try to_remove.appendBounded(prefix_idx);
                },
                .not_a_match => {
                    try to_remove.appendBounded(prefix_idx);
                },
                .feeding => {},
            }
        }

        while (to_remove.pop()) |idx| {
            _ = prefixes.swapRemove(idx);
        }
    }

    return .{
        .type = token_type,
        .prefix_end = prefix_end,
    };
}

const ItemTypeMatcher = struct {
    token: ItemType,
    pos: u8 = 0,

    const State = enum {
        feeding,
        matched,
        not_a_match,
    };

    fn push(self: *ItemTypeMatcher, b: u8) !State {
        const string = try self.token.startSequence();
        const byte_matches = self.pos < string.len and string[self.pos] == b;
        self.pos += 1;
        if (byte_matches and self.pos == string.len) {
            return .matched;
        } else if (byte_matches) {
            return .feeding;
        } else {
            return .not_a_match;
        }
    }
};

pub const ItemType = enum {
    xml_decl,
    element_start,
    element_end,
    element_content,
    comment,

    fn startSequence(self: ItemType) ![]const u8 {
        return switch (self) {
            .xml_decl => "<?xml ",
            .element_start => "<",
            .element_end => "</",
            .comment => "<!--",
            .element_content => {
                return error.UnexpectedContent;
            },
        };
    }

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

const SliceCursor = struct {
    data: []const u8,
    idx: usize = 0,

    fn consumeWhileAny(
        self: *SliceCursor,
        chars: []const u8,
    ) usize {
        self.idx = std.mem.indexOfNonePos(u8, self.data, self.idx, chars) orelse self.data.len;
        return self.idx;
    }

    fn consumeWhileNone(
        self: *SliceCursor,
        chars: []const u8,
    ) usize {
        self.idx = std.mem.indexOfAnyPos(u8, self.data, self.idx, chars) orelse self.data.len;
        return self.idx;
    }

    fn consume(self: *SliceCursor, amount: usize) void {
        self.idx += amount;
    }

    fn peekByte(self: *SliceCursor) u8 {
        return self.data[self.idx];
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
