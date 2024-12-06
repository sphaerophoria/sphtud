const std = @import("std");
const Allocator = std.mem.Allocator;
const GlyphAtlas = @import("GlyphAtlas.zig");
const sphmath = @import("sphmath");
const ttf_mod = @import("ttf.zig");
const sphrender = @import("sphrender");

pub const Buffer = sphrender.PlaneRenderProgram.Buffer;

program: sphrender.PlaneRenderProgram,
glyph_atlas: GlyphAtlas,
point_size: f32,

const TextRenderer = @This();

pub const TextLayout = struct {
    const GlyphLoc = struct {
        char: u8,
        pixel_x1: u32,
        pixel_x2: u32,
        pixel_y1: u32,
        pixel_y2: u32,
    };

    pub fn deinit(self: TextLayout, alloc: Allocator) void {
        alloc.free(self.glyphs);
    }

    glyphs: []GlyphLoc,
    width_px: u32,
    height_px: u32,
};

pub fn init(alloc: Allocator, point_size: f32) !TextRenderer {
    const program = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, text_fragment_shader, TextReservedIndex);
    errdefer program.deinit(alloc);

    const glyph_atlas = try GlyphAtlas.init(alloc);
    errdefer glyph_atlas.deinit(alloc);

    return .{
        .program = program,
        .glyph_atlas = glyph_atlas,
        .point_size = point_size,
    };
}

pub fn deinit(self: *TextRenderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.glyph_atlas.deinit(alloc);
}

pub fn layoutText(self: *TextRenderer, alloc: Allocator, text: []const u8, ttf: ttf_mod.Ttf) !TextLayout {
    var width: u32 = 0;
    var height: u32 = 0;

    var glyphs = std.ArrayList(TextLayout.GlyphLoc).init(alloc);
    defer glyphs.deinit();

    for (text) |c| {
        const header = ttf_mod.glyphHeaderForChar(ttf, c) orelse continue;

        const pixel_size = ttf_mod.pixelSizeFromGlyphHeader(self.point_size, @floatFromInt(ttf.head.units_per_em), header);

        try glyphs.append(.{
            .char = c,
            .pixel_x1 = width,
            .pixel_x2 = width + @as(u32, @intCast(pixel_size[0])),
            .pixel_y1 = 0,
            .pixel_y2 = @intCast(pixel_size[1]),
        });

        width += @intCast(pixel_size[0]);
        height = @intCast(@max(height, pixel_size[1]));
    }

    return .{
        .glyphs = try glyphs.toOwnedSlice(),
        .width_px = width,
        .height_px = height,
    };
}

pub fn makeTextBuffer(self: *TextRenderer, alloc: Allocator, text: TextLayout, ttf: ttf_mod.Ttf, distance_field_generator: sphrender.DistanceFieldGenerator) !Buffer {
    const num_points_per_plane = 6;
    const new_buffer_data = try alloc.alloc(sphrender.PlaneRenderProgram.Buffer.BufferPoint, text.glyphs.len * num_points_per_plane);
    defer alloc.free(new_buffer_data);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var buffer_idx: usize = 0;
    for (text.glyphs) |glyph| {
        _ = arena.reset(.retain_capacity);
        defer buffer_idx += num_points_per_plane;

        const uv_loc = try self.glyph_atlas.getGlyphLocation(alloc, arena.allocator(), glyph.char, self.point_size, ttf, distance_field_generator);

        // [0, width] -> [-1, 1]
        const clip_x_start = pixToClip(glyph.pixel_x1, text.width_px);
        const clip_x_end = pixToClip(glyph.pixel_x2, text.width_px);
        const clip_y_top = pixToClip(glyph.pixel_y2, text.height_px);
        const clip_y_bottom = pixToClip(glyph.pixel_y1, text.height_px);

        const BufferPoint = sphrender.PlaneRenderProgram.Buffer.BufferPoint;

        const bl = BufferPoint{
            .clip_x = clip_x_start,
            .clip_y = clip_y_bottom,
            .uv_x = uv_loc.left,
            .uv_y = uv_loc.bottom,
        };

        const br = BufferPoint{
            .clip_x = clip_x_end,
            .clip_y = clip_y_bottom,
            .uv_x = uv_loc.right,
            .uv_y = uv_loc.bottom,
        };

        const tl = BufferPoint{
            .clip_x = clip_x_start,
            .clip_y = clip_y_top,
            .uv_x = uv_loc.left,
            .uv_y = uv_loc.top,
        };

        const tr = BufferPoint{
            .clip_x = clip_x_end,
            .clip_y = clip_y_top,
            .uv_x = uv_loc.right,
            .uv_y = uv_loc.top,
        };

        new_buffer_data[buffer_idx + 0] = bl;
        new_buffer_data[buffer_idx + 1] = br;
        new_buffer_data[buffer_idx + 2] = tl;
        new_buffer_data[buffer_idx + 3] = br;
        new_buffer_data[buffer_idx + 4] = tl;
        new_buffer_data[buffer_idx + 5] = tr;
    }

    var buf = self.program.makeDefaultBuffer();
    buf.updateBuffer(new_buffer_data);

    return buf;
}

pub fn render(self: TextRenderer, buf: Buffer, transform: sphmath.Transform) !void {
    self.program.render(buf, &.{}, &.{
        .{
            .idx = TextReservedIndex.input_df.asIndex(),
            .val = .{ .image = self.glyph_atlas.texture.inner },
        },
        .{
            .idx = TextReservedIndex.multiplier.asIndex(),
            .val = .{ .float = self.point_size / 2.0 },
        },
    }, transform);
}

pub const TextReservedIndex = enum {
    input_df,
    multiplier,

    fn asIndex(self: TextReservedIndex) usize {
        return @intFromEnum(self);
    }
};

fn pixToClip(val: usize, max: usize) f32 {
    const val_f: f32 = @floatFromInt(val);
    const max_f: f32 = @floatFromInt(max);

    return val_f / max_f * 2.0 - 1.0;
}

pub const text_fragment_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D input_df;
    \\uniform float multiplier = 100.0;
    \\void main()
    \\{
    \\    float distance = texture(input_df, vec2(uv.x, uv.y)).r;
    \\    float N = 1.0 / multiplier;
    \\    float val = (distance + N) / 2.0 / N;
    \\    float alpha = clamp(val, 0.0, 1.0);
    \\    fragment = vec4(1.0, 1.0, 1.0, alpha);
    \\}
;
