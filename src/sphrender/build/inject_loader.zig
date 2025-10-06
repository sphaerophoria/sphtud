const std = @import("std");
const sphalloc = @import("sphalloc");
const sphutil = @import("sphutil");
const sphxml = @import("sphxml");
const XmlParser = sphxml.Parser;

pub const GlXmlParser = struct {
    xml_parser: XmlParser,
    state: ParserState,
    segment: Segment,
    // We need to keep track of which extension we are in across multiple
    // steps. We cannot directly reference memory from the underlying parser as
    // the attribute field will be invalidated across multiple calls. Write
    // down the extension here so that we can keep it for longer
    extension_buf: [256]u8 = undefined,

    const Segment = union(enum) {
        core: f32,
        extension: []const u8,
        none,
    };

    const ParserState = enum {
        default,
        feature,
        feature_require,
        extension,
        extension_require,
    };

    const ApiItem = struct {
        segment: Segment,
        name: []const u8,
    };

    // Do not assume that slices returned by this call will be valid after the next call
    pub fn step(self: *GlXmlParser, scratch: sphalloc.LinearAllocator) !?ApiItem {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        while (true) {
            var discarding_writer = std.Io.Writer.Discarding.init(&.{});

            const xml_item = try self.xml_parser.next(&discarding_writer.writer) orelse return null;
            switch (self.state) {
                .default => try self.doDefault(scratch, xml_item),
                .feature => try self.doFeature(xml_item),
                .feature_require => if (try self.doFeatureRequire(xml_item)) |item| return item,
                .extension => try self.doExtension(xml_item),
                .extension_require => if (try self.doExtensionRequire(xml_item)) |item| return item,
            }
        }

        return true;
    }

    pub fn init(reader: *std.Io.Reader) GlXmlParser {
        return .{
            .xml_parser = XmlParser.init(reader),
            .state = .default,
            .segment = .none,
        };
    }

    fn doDefault(self: *GlXmlParser, scratch: sphalloc.LinearAllocator, xml_item: sphxml.Item) !void {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        if (shouldEnter(xml_item, "feature")) {
            var attr_it = xml_item.attributeIt();

            var api: ?[]const u8 = null;
            var api_version: ?[]const u8 = null;

            while (try attr_it.next()) |attr| {
                if (std.mem.eql(u8, attr.key, "api")) {
                    api = attr.val;
                } else if (std.mem.eql(u8, attr.key, "number")) {
                    api_version = attr.val;
                }
            }
            if (api) |a| {
                if (std.mem.eql(u8, a, "gl")) {
                    const parsed_version = if (api_version) |s| try std.fmt.parseFloat(f32, s) else std.math.inf(f32);
                    self.segment = .{ .core = parsed_version };
                    self.state = .feature;
                }
            }
        }

        if (shouldEnter(xml_item, "extension")) blk: {
            const name = try findAttrVal(xml_item, "name") orelse break :blk;
            @memcpy(self.extension_buf[0..name.len], name);
            self.segment = .{ .extension = self.extension_buf[0..name.len] };
            self.state = .extension;
        }
    }

    fn doFeature(self: *GlXmlParser, xml_item: sphxml.Item) !void {
        if (shouldEnter(xml_item, "require")) {
            self.state = .feature_require;
        }

        if (shouldLeave(xml_item, "feature")) {
            self.segment = .none;
            self.state = .default;
        }
    }

    fn doFeatureRequire(self: *GlXmlParser, xml_item: sphxml.Item) !?ApiItem {
        if (shouldEnter(xml_item, "command")) {
            if (try self.processCommand(xml_item)) |ret| return ret;
        }

        if (shouldLeave(xml_item, "require")) {
            self.state = .feature;
        }
        return null;
    }

    fn processCommand(self: *GlXmlParser, xml_item: sphxml.Item) !?ApiItem {
        const name = try findAttrVal(xml_item, "name");
        if (name) |n| {
            return .{
                .name = n,
                .segment = self.segment,
            };
        }
        return null;
    }

    fn doExtension(self: *GlXmlParser, xml_item: sphxml.Item) !void {
        if (shouldEnter(xml_item, "require")) {
            self.state = .extension_require;
        }

        if (shouldLeave(xml_item, "extension")) {
            self.segment = .none;
            self.state = .default;
        }
    }

    fn doExtensionRequire(self: *GlXmlParser, xml_item: sphxml.Item) !?ApiItem {
        if (shouldEnter(xml_item, "command")) {
            if (try self.processCommand(xml_item)) |ret| return ret;
        }

        if (shouldLeave(xml_item, "require")) {
            self.state = .extension;
        }
        return null;
    }

    fn shouldEnter(xml_item: sphxml.Item, name: []const u8) bool {
        return xml_item.type == .element_start and std.mem.eql(u8, xml_item.name, name);
    }

    fn shouldLeave(xml_item: sphxml.Item, name: []const u8) bool {
        return xml_item.type == .element_end and std.mem.eql(u8, xml_item.name, name);
    }

    fn findAttrVal(xml_item: sphxml.Item, key: []const u8) !?[]const u8 {
        var attr_it = xml_item.attributeIt();

        while (try attr_it.next()) |attr| {
            if (!std.mem.eql(u8, attr.key, key)) {
                continue;
            }
            return attr.val;
        }
        return null;
    }
};

fn wantsExtension(desired: []const []const u8, extension: []const u8) bool {
    for (desired) |d| {
        if (std.mem.eql(u8, d, extension)) {
            return true;
        }
    }

    return false;
}

fn findDesiredProtos(alloc: std.mem.Allocator, scratch: sphalloc.LinearAllocator, desired_extensions: []const [:0]const u8) ![]const []const u8 {
    const cp = scratch.checkpoint();
    defer scratch.restore(cp);

    const gl_xml = @embedFile("gl.xml");

    var f_reader = std.Io.Reader.fixed(gl_xml);

    var gl_xml_parser = GlXmlParser.init(&f_reader);

    var desired_protos = try sphutil.hash_map.StringHashMapLinear(void).init(
        scratch.allocator(),
        scratch.allocator(),
        1000,
        1000,
    );

    while (try gl_xml_parser.step(scratch)) |item| {
        // Odd case where it's removed then added, so is in the default
        // definitions but also included in later versions
        if (std.mem.eql(u8, item.name, "glGetPointerv")) {
            continue;
        }

        const wants_api = switch (item.segment) {
            // This seems to be the cutoff for where the gl header stops defining fns by default
            .core => |version| version >= 1.5,
            .extension => |extension| wantsExtension(desired_extensions, extension),
            .none => false,
        };

        if (wants_api) {
            const gop = try desired_protos.getOrPut(item.name);
            if (!gop.found_existing) {
                // These will eventually go out to the caller, put them on the
                // output alloc
                const name = try alloc.dupe(u8, item.name);
                gop.key.* = name;
            }
        }
    }

    var ret = try sphutil.RuntimeBoundedArray([]const u8).init(alloc, desired_protos.len);

    var it = desired_protos.iter();
    while (it.next()) |item| {
        ret.append(item.key.*) catch unreachable;
    }

    return ret.items;
}

pub fn main() !void {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var alloc = sphalloc.BufAllocator.init(&alloc_buf);

    const args = try std.process.argsAlloc(alloc.allocator());

    const translated_gl_path = args[1];
    const output_path = args[2];

    const output_f = try std.fs.cwd().createFile(output_path, .{});
    defer output_f.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = output_f.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    {
        const input_f = try std.fs.cwd().openFile(translated_gl_path, .{});
        defer input_f.close();

        const cp = alloc.checkpoint();
        defer alloc.restore(cp);

        var input_buf: [4096]u8 = undefined;
        var f_reader = input_f.reader(&input_buf);

        _ = try f_reader.interface.streamRemaining(stdout);
    }

    const desired_extensions = if (args.len > 3) args[3..] else &.{};

    const desired_protos = try findDesiredProtos(alloc.allocator(), alloc.backLinear(), desired_extensions);

    for (desired_protos) |proto| {
        const cp = alloc.linear().checkpoint();
        defer alloc.linear().restore(cp);

        const upper_proto = try alloc.allocator().alloc(u8, proto.len);
        _ = std.ascii.upperString(upper_proto, proto);
        try stdout.print("pub var {s}: @typeInfo(PFN{s}PROC).optional.child = undefined;\n", .{ proto, upper_proto });
    }

    try stdout.writeAll(
        \\
        \\pub fn load(loader: *const fn ([*c]const u8) callconv(.c) ?*const fn () callconv(.c) void ) !void {
        \\
    );

    for (desired_protos) |proto| {
        try stdout.print("    if (loader(\"{s}\")) |v| {s} = @ptrCast(v);\n", .{ proto, proto });
    }
    try stdout.writeAll("}\n");
    try stdout.flush();
}
