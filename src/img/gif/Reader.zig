const std = @import("std");
const img_mod = @import("../../img.zig");
const SubDataReader = @import("SubDataReader.zig");
const LzwDecompressor = @import("LzwDecompressor.zig");

input: *std.Io.Reader,
width: u16,
height: u16,
global_packed: GlobalPackedInfo,
background_color: u8,
pixel_aspect: u8,
global_ct_buf: [256 * 3]u8,
local_ct_buf: [256 * 3]u8,
global_ct: img_mod.PackedData(img_mod.Rgb888Pixel),

sub_reader_buf: [4096]u8 = undefined,
sub_reader: ?SubDataReader = null,
lzw_reader: ?LzwDecompressor = null,

const GifReader = @This();

pub const Item = union(enum) {
    nab_loop_count: u16,
    graphic_control: GraphicControl,
    unknown_extension: struct {
        label: u8,
        data: *std.Io.Reader,
    },
    image: Image,
};

pub const Image = struct {
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    interlace: bool,
    palette: img_mod.PackedData(img_mod.Rgb888Pixel),
    data: *LzwDecompressor,
};

pub const GraphicControl = struct {
    user_input: bool,
    disposal_method: enum(u3) {
        none = 0,
        do_not_dispose = 1,
        restore_background = 2,
        restore_previous = 3,
        _,
    },
    delay_time_ms: u32,
    transparent_color_idx: ?u8,
};

pub const GlobalPackedInfo = packed struct {
    ct_size: u3,
    sort: bool,
    color_res: u3,
    ct_present: bool,
};

pub fn initPinned(self: *GifReader, r: *std.Io.Reader) !void {
    const sig = try r.take(3);
    const version = try r.take(3);

    if (!std.mem.eql(u8, sig, "GIF")) {
        return error.InvalidSig;
    }

    if (!std.mem.eql(u8, version, "89a")) {
        return error.InvalidVersion;
    }

    const width = try r.takeInt(u16, .little);
    const height = try r.takeInt(u16, .little);

    const global_packed = try r.takeStruct(GlobalPackedInfo, .little);
    const background_color = try r.takeByte();
    const pixel_aspect = try r.takeByte();

    self.* = .{
        .input = r,
        .width = width,
        .height = height,
        .global_packed = global_packed,
        .background_color = background_color,
        .pixel_aspect = pixel_aspect,
        .global_ct_buf = undefined,
        .local_ct_buf = undefined,
        .global_ct = .{ .data = &.{} },
    };

    if (global_packed.ct_present) {
        self.global_ct = try readColorTable(&self.global_ct_buf, r, global_packed.ct_size);
    }
}

pub fn next(self: *GifReader) !?Item {
    if (self.sub_reader) |*s| {
        _ = try s.interface.discardRemaining();
        self.sub_reader = null;
    }
    self.lzw_reader = null;

    const r = self.input;
    const block_type = try r.takeByte();

    switch (block_type) {
        '!' => {
            const label = try r.takeByte();

            self.sub_reader = SubDataReader.init(self.input, &self.sub_reader_buf);

            if (label == 0xff) {
                const extension_header = try self.sub_reader.?.interface.peek(11);

                if (std.mem.eql(u8, extension_header, "NETSCAPE2.0")) {
                    self.sub_reader.?.interface.toss(11);
                    const sub_block_id = try self.sub_reader.?.interface.take(1);
                    _ = sub_block_id;
                    const loop_amount = try self.sub_reader.?.interface.takeInt(u16, .little);
                    return .{
                        .nab_loop_count = loop_amount,
                    };
                }
            } else if (label == 0xf9) {
                const GCPacked = packed struct {
                    transparent: bool,
                    user_input: bool,
                    disposal_method: u3,
                    reserved: u3,
                };

                const gc_packed = try self.sub_reader.?.interface.takeStruct(GCPacked, .little);
                const delay_time_cs = try self.sub_reader.?.interface.takeInt(u16, .little);
                const transparent_color_idx = try self.sub_reader.?.interface.takeByte();
                return .{
                    .graphic_control = .{
                        .user_input = gc_packed.user_input,
                        .disposal_method = @enumFromInt(gc_packed.disposal_method),
                        .delay_time_ms = @as(u32, delay_time_cs) * 10,
                        .transparent_color_idx = if (gc_packed.transparent) transparent_color_idx else null,
                    },
                };
            }

            return .{
                .unknown_extension = .{
                    .label = label,
                    .data = &self.sub_reader.?.interface,
                },
            };
        },
        ',' => {
            const left = try r.takeInt(u16, .little);
            const top = try r.takeInt(u16, .little);
            const image_width = try r.takeInt(u16, .little);
            const image_height = try r.takeInt(u16, .little);

            const ImageDescriptorOptions = packed struct {
                lct_size: u3,
                reserved: u2,
                sort: bool,
                interlace: bool,
                lct_present: bool,
            };

            const options = try r.takeStruct(ImageDescriptorOptions, .little);

            var color_table = self.global_ct;
            if (options.lct_present) {
                color_table = try readColorTable(&self.local_ct_buf, r, options.lct_size);
            }

            if (!self.global_packed.ct_present and !options.lct_present) return error.Unimplemented;

            const lzw_min_code_size = try r.takeByte();
            self.sub_reader = SubDataReader.init(r, &self.sub_reader_buf);

            self.lzw_reader = @as(LzwDecompressor, undefined);
            try self.lzw_reader.?.initPinned(lzw_min_code_size, &self.sub_reader.?.interface);

            return .{
                .image = .{
                    .left = left,
                    .top = top,
                    .width = image_width,
                    .height = image_height,
                    .interlace = options.interlace,
                    .palette = color_table,
                    .data = &self.lzw_reader.?,
                },
            };
        },
        ';' => return null,
        else => {
            return error.InvalidBlockType;
        },
    }
}

fn readColorTable(buf: []u8, r: *std.Io.Reader, size_flag: u8) !img_mod.PackedData(img_mod.Rgb888Pixel) {
    const ct_size_bytes = 3 * @as(usize, 1) << @intCast(@as(u8, size_flag) + 1);

    try r.readSliceAll(buf[0..ct_size_bytes]);

    return .{
        .data = buf[0..ct_size_bytes],
    };
}
