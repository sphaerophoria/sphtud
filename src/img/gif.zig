const std = @import("std");
const img_mod = @import("../img.zig");
const color = @import("color.zig");

pub const Reader = @import("gif/Reader.zig");

pub const magic = "GIF89a";

pub fn read(alloc: std.mem.Allocator, r: *std.Io.Reader, options: img_mod.ImageLoadOptions) !img_mod.ImageSequence {
    var gr: Reader = undefined;
    try gr.initPinned(r);

    var loop_count: u16 = 0;

    var graphic_ctrl = Reader.GraphicControl{
        .user_input = false,
        .disposal_method = .none,
        .delay_time_ms = 0,
        .transparent_color_idx = null,
    };

    var atlas_builder = std.ArrayList(u8).empty;

    var timesteps = std.ArrayList(u32).empty;
    var timestep_ms: u32 = 0;

    while (try gr.next()) |item| {
        switch (item) {
            .nab_loop_count => |count| loop_count = count,
            .graphic_control => |ctrl| graphic_ctrl = ctrl,
            .image => |image| {
                try timesteps.append(alloc, timestep_ms);
                timestep_ms += graphic_ctrl.delay_time_ms;
                try appendAtlasFrame(alloc, &atlas_builder, gr.width, gr.height, image, graphic_ctrl, options);
            },
            .unknown_extension => {},
        }
    }

    const color_transform = color.makeColorTransform(.srgb, options.force_color_space);

    const data = img_mod.PixelData.init(pixelFormat(options), atlas_builder.items);

    var converter = color.Converter{
        .data = data,
        .color_transform = color_transform,
    };
    converter.convert(.srgb, options.force_transfer_fn orelse .srgb);

    return .{
        .data = data,
        .loop_count = loop_count,
        .timesteps_ms = timesteps.items,
        .width = gr.width,
        .height = gr.height,
        .colorspace = options.force_color_space orelse .srgb,
        .transfer_fn = options.force_transfer_fn orelse .srgb,
    };
}

const sample_input = @embedFile("gif/res/test_gif.gif");

fn writePpmMemory(alloc: std.mem.Allocator, img: img_mod.Image) ![]const u8 {
    var ppm_data = std.Io.Writer.Allocating.init(alloc);

    try img_mod.ppm.write(img, &ppm_data.writer);
    return ppm_data.written();
}

test "gif sanity" {
    var scratch_buf: [4 * 1024 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);

    var r = std.Io.Reader.fixed(sample_input);

    // Default
    {
        const image = try read(scratch.allocator(), &r, .{});
        const ppm = try writePpmMemory(scratch.allocator(), image.asImage(0));

        const expected = @embedFile("gif/res/first_frame.ppm");
        try std.testing.expectEqualSlices(u8, expected, ppm);
    }

    r.seek = 0;
    scratch.end_index = 0;

    // vflip
    {
        const image = try read(scratch.allocator(), &r, .{
            .vflip = true,
        });
        const ppm = try writePpmMemory(scratch.allocator(), image.asImage(0));

        const expected = @embedFile("gif/res/first_frame_flipped.ppm");
        try std.testing.expectEqualSlices(u8, expected, ppm);
    }

    r.seek = 0;
    scratch.end_index = 0;

    // pixel conversion no flip
    {
        const image = try read(scratch.allocator(), &r, .{
            .force_pixel_format = .rgb_888_packed,
        });
        const ppm = try writePpmMemory(scratch.allocator(), image.asImage(0));

        const expected = @embedFile("gif/res/first_frame.ppm");
        try std.testing.expectEqualSlices(u8, expected, ppm);
    }

    r.seek = 0;
    scratch.end_index = 0;

    // pixel conversion flipped
    {
        const image = try read(scratch.allocator(), &r, .{
            .vflip = true,
            .force_pixel_format = .rgb_888_packed,
        });
        const ppm = try writePpmMemory(scratch.allocator(), image.asImage(0));

        const expected = @embedFile("gif/res/first_frame_flipped.ppm");
        try std.testing.expectEqualSlices(u8, expected, ppm);
    }

    r.seek = 0;
    scratch.end_index = 0;

    // a quick colorspace conversion check
    {
        const image = try read(scratch.allocator(), &r, .{
            .force_color_space = .{
                .chroma = .{
                    .data = .{
                        0.0, 1.0, 0.0,
                        1.0, 0.0, 0.0,
                        0.0, 0.0, 1.0,
                    },
                },
            },
            .force_transfer_fn = .linear,
        });
        const ppm = try writePpmMemory(scratch.allocator(), image.asImage(0));

        const expected = @embedFile("gif/res/rg_flipped_linear.ppm");
        try std.testing.expectEqualSlices(u8, expected, ppm);
    }
}

fn pxAsSlice(px: anytype) []const u8 {
    return std.mem.asBytes(px)[0 .. @bitSizeOf(@TypeOf(px.*)) / 8];
}

fn pixelFormat(options: img_mod.ImageLoadOptions) img_mod.PixelFormat {
    return options.force_pixel_format orelse .rgba_8888;
}

fn appendAtlasFrame(
    alloc: std.mem.Allocator,
    atlas: *std.ArrayList(u8),
    width: usize,
    height: usize,
    image: Reader.Image,
    ctrl: Reader.GraphicControl,
    options: img_mod.ImageLoadOptions,
) !void {
    switch (pixelFormat(options)) {
        inline else => |pixel_format| {
            const OutPx = img_mod.PixelType(pixel_format);

            if (options.vflip) {
                try appendAtlasFrameFlipped(OutPx, alloc, atlas, width, height, image, ctrl);
            } else {
                try appendAtlasFrameUpright(OutPx, alloc, atlas, image, ctrl);
            }
        },
    }
}

fn appendAtlasFrameUpright(
    comptime OutPx: type,
    alloc: std.mem.Allocator,
    atlas: *std.ArrayList(u8),
    image: Reader.Image,
    ctrl: Reader.GraphicControl,
) !void {
    while (try image.data.step()) |pallete_idx| {
        const out_px = gifPxToPx(
            OutPx,
            pallete_idx,
            image.palette,
            ctrl.transparent_color_idx,
        );

        const px_slice = pxAsSlice(&out_px);
        try atlas.appendSlice(alloc, px_slice);
    }
}

fn appendAtlasFrameFlipped(
    comptime OutPx: type,
    alloc: std.mem.Allocator,
    atlas: *std.ArrayList(u8),
    width: usize,
    height: usize,
    image: Reader.Image,
    ctrl: Reader.GraphicControl,
) !void {
    const out_pixel_len = @bitSizeOf(OutPx) / 8;
    const frame_size_bytes = out_pixel_len * width * height;
    try atlas.appendNTimes(alloc, undefined, frame_size_bytes);
    const frame_data = img_mod.PackedData(OutPx){
        .data = atlas.items[atlas.items.len - frame_size_bytes ..],
    };

    for (0..height) |row_idx| {
        const row_data_bytes = frame_data.getByteSlice((height - 1 - row_idx) * width, width);
        const row_data = img_mod.PackedData(OutPx){
            .data = row_data_bytes,
        };

        for (0..width) |x| {
            const pallete_idx = try image.data.step() orelse return error.MissingData;

            const out_px = gifPxToPx(
                OutPx,
                pallete_idx,
                image.palette,
                ctrl.transparent_color_idx,
            );
            row_data.write(x, out_px);
        }
    }
}

fn gifPxToPx(
    comptime OutPx: type,
    idx: u8,
    palette: img_mod.PackedData(img_mod.Rgb888Pixel),
    transparent_idx: ?u8,
) OutPx {
    const rgb = palette.get(idx);

    const alpha: u8 = if (idx == transparent_idx) 0 else 255;

    const in_px = img_mod.Rgba8888Pixel{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
        .a = alpha,
    };

    return OutPx.from(in_px);
}
