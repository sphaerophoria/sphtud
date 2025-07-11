const std = @import("std");
const Allocator = std.mem.Allocator;
const GlyphAtlas = @import("GlyphAtlas.zig");
const sphmath = @import("sphmath");
const ttf_mod = @import("ttf.zig");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const GlAlloc = sphrender.GlAlloc;

const ShaderProgram = sphrender.xyuvt_program.Program(TextUniforms);
pub const Buffer = sphrender.xyuvt_program.Buffer;
pub const RenderSource = sphrender.xyuvt_program.RenderSource;

program: ShaderProgram,
glyph_atlas: GlyphAtlas,
point_size: f32,
multiplier: f32 = 0.25,

const TextRenderer = @This();

pub const TextLayout = struct {
    pub const empty = TextLayout{
        .glyphs = &.{},
        .min_x = 0,
        .max_x = 0,
        .min_y = 0,
        .max_y = 0,
    };

    pub const GlyphLoc = struct {
        char: u8,
        pixel_x1: i32,
        pixel_x2: i32,
        pixel_y1: i32,
        pixel_y2: i32,
    };

    pub fn width(self: TextLayout) u32 {
        return @intCast(self.max_x - self.min_x);
    }

    pub fn height(self: TextLayout) u32 {
        return @intCast(self.max_y - self.min_y);
    }

    glyphs: []GlyphLoc,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
};

pub fn init(gpa: Allocator, gl_alloc: *GlAlloc, point_size: f32) !TextRenderer {
    if (gl.glIsEnabled(gl.GL_BLEND) != gl.GL_TRUE) {
        std.log.warn("Text rendering requires alpha blending, please enable GL_BLEND and set an appropriate blending function", .{});
    }

    const program = try ShaderProgram.init(gl_alloc, text_fragment_shader);
    const glyph_atlas = try GlyphAtlas.init(gpa, gl_alloc);

    return .{
        .program = program,
        .glyph_atlas = glyph_atlas,
        .point_size = point_size,
    };
}

pub fn resetAtlas(self: *TextRenderer) !void {
    try self.glyph_atlas.reset();
}

const LayoutState = enum {
    in_word,
    between_word,
};

const LayoutBox = struct {
    min_x: i32 = 0,
    max_x: i32 = 0,
    min_y: i32 = 0,
    max_y: i32 = 0,

    fn width(self: LayoutBox) i32 {
        return self.max_x - self.min_x;
    }

    fn merge(a: LayoutBox, b: LayoutBox) LayoutBox {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .max_x = @max(a.max_x, b.max_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_y = @max(a.max_y, b.max_y),
        };
    }
};

const LayoutHelper = struct {
    line_height: i16,
    text: []const u8,
    ttf: *const ttf_mod.Ttf,
    wrap_width_px: u31,
    funit_converter: ttf_mod.FunitToPixelConverter,
    glyphs: std.ArrayList(TextLayout.GlyphLoc),

    funit_cursor_x: i64 = 0,
    funit_cursor_y: i64 = 0,
    text_idx: usize = 0,
    rollback_data: RollbackData = .{},
    bounds: LayoutBox,
    layout_state: LayoutState = .between_word,

    const RollbackData = struct {
        text_idx: usize = 0,
        glyphs_len: usize = 0,
        bounds: LayoutBox = .{},
        start_x: i64 = 0,
    };

    fn init(alloc: Allocator, text: []const u8, ttf: *const ttf_mod.Ttf, wrap_width_px: u31, font_size: f32) LayoutHelper {
        const funit_converter = ttf_mod.FunitToPixelConverter.init(font_size, @floatFromInt(ttf.head.units_per_em));
        const min_y = funit_converter.pixelFromFunit(ttf.hhea.descent);
        const max_y = funit_converter.pixelFromFunit(ttf.hhea.ascent);
        return .{
            .line_height = ttf_mod.lineHeight(ttf.*),
            .text = text,
            .ttf = ttf,
            .wrap_width_px = wrap_width_px,
            .funit_converter = funit_converter,
            .bounds = .{
                .min_x = 0,
                .max_x = 0,
                .min_y = min_y,
                .max_y = max_y,
            },
            .glyphs = std.ArrayList(TextLayout.GlyphLoc).init(alloc),
        };
    }

    fn nextChar(self: *LayoutHelper) ?u8 {
        if (self.text_idx >= self.text.len) return null;
        defer self.text_idx += 1;
        return self.text[self.text_idx];
    }

    fn step(self: *LayoutHelper) !bool {
        const c = self.nextChar() orelse return false;

        self.updateRollbackData(c);

        if (c == '\n') {
            self.advanceLine();
            return true;
        }

        const metrics = ttf_mod.metricsForChar(self.ttf.*, c);

        const glyph_bounds = self.calcCharBounds(metrics.left_side_bearing, c) orelse {
            self.advanceNoGlyphChar(metrics.advance_width);
            return true;
        };

        const new_bounds = self.bounds.merge(glyph_bounds);
        const over_wrap_width = new_bounds.width() >= self.wrap_width_px;

        if (over_wrap_width) {
            self.doTextWrapping();
            return true;
        }

        self.funit_cursor_x += metrics.advance_width;

        try self.glyphs.append(.{
            .char = c,
            .pixel_x1 = glyph_bounds.min_x,
            .pixel_x2 = glyph_bounds.max_x,
            .pixel_y1 = glyph_bounds.min_y,
            .pixel_y2 = glyph_bounds.max_y,
        });

        self.bounds = new_bounds;

        return true;
    }

    fn advanceLine(self: *LayoutHelper) void {
        self.funit_cursor_y -= self.line_height;
        self.funit_cursor_x = 0;
        self.bounds.min_y -= self.funit_converter.pixelFromFunit(self.line_height);
        // If we've moved up a line, rollback data needs to put us back at the
        // start of the line, not wherever we were when the word started
        self.rollback_data.start_x = 0;
    }

    fn updateRollbackData(self: *LayoutHelper, c: u8) void {
        if (std.ascii.isWhitespace(c)) {
            self.layout_state = .between_word;
            return;
        } else if (self.layout_state == .in_word) {
            return;
        }

        // Now guaranteed to be in a word without layout state between word
        self.layout_state = .in_word;
        self.rollback_data.text_idx = self.text_idx - 1;
        self.rollback_data.glyphs_len = self.glyphs.items.len;
        self.rollback_data.bounds = self.bounds;
        self.rollback_data.start_x = self.funit_cursor_x;
    }

    fn advanceNoGlyphChar(self: *LayoutHelper, advance_width: u16) void {
        self.funit_cursor_x += advance_width;
        self.bounds.max_x += self.funit_converter.pixelFromFunit(advance_width);
        // -1 to ensure that we stay BELOW the wrap width, or else future
        // checks will get confused about why the bounding box is >= the
        // wrap width
        self.bounds.max_x = @min(self.wrap_width_px - 1, self.bounds.max_x);
    }

    fn doTextWrapping(self: *LayoutHelper) void {
        const word_at_line_start = self.rollback_data.start_x == 0;
        if (word_at_line_start) {
            // In this case the word itself is longer than the wrap width. We
            // don't have a choice but to split the word up. Move back a
            // character since the character we just laid out is past the end
            // of the line and move to the next line
            self.text_idx -= 1;
        } else {
            self.rollback();
        }

        self.advanceLine();
    }

    fn calcCharBounds(self: *LayoutHelper, left_side_bearing: i16, c: u8) ?LayoutBox {
        const header = ttf_mod.glyphHeaderForChar(self.ttf.*, c) orelse {
            return null;
        };

        const x1 = self.funit_cursor_x + left_side_bearing;
        const x2 = x1 + header.x_max - header.x_min;

        const y1 = self.funit_cursor_y + header.y_min;
        const y2 = y1 + header.y_max - header.y_min;

        const x1_px = self.funit_converter.pixelFromFunit(x1);
        const y1_px = self.funit_converter.pixelFromFunit(y1);
        // Why not just use x2 or header.y_max? We want to make sure no matter
        // how much the cursor has advanced in funits, we always render the
        // glyph aligned to the same number of pixels.
        const x2_px = x1_px + self.funit_converter.pixelFromFunit(x2 - x1);
        const y2_px = y1_px + self.funit_converter.pixelFromFunit(y2 - y1);

        return .{
            .min_x = x1_px,
            .max_x = x2_px,
            .min_y = y1_px,
            .max_y = y2_px,
        };
    }

    fn rollback(self: *LayoutHelper) void {
        self.text_idx = self.rollback_data.text_idx;
        self.glyphs.resize(self.rollback_data.glyphs_len) catch unreachable;
        self.bounds = self.rollback_data.bounds;
        self.funit_cursor_x = self.rollback_data.start_x;
    }
};

pub fn layoutText(self: *TextRenderer, alloc: Allocator, text: []const u8, ttf: ttf_mod.Ttf, wrap_width_px: u31) !TextLayout {
    var layout_helper = LayoutHelper.init(alloc, text, &ttf, wrap_width_px, self.point_size);
    errdefer layout_helper.glyphs.deinit();

    while (try layout_helper.step()) {}

    return .{
        .glyphs = try layout_helper.glyphs.toOwnedSlice(),
        .min_x = layout_helper.bounds.min_x,
        .max_x = layout_helper.bounds.max_x,
        .min_y = layout_helper.bounds.min_y,
        .max_y = layout_helper.bounds.max_y,
    };
}

test "layout text infinite loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    const text = "bannister.jpgasdlfkjasdlkfjaslkdfjklasjf kl";
    var ttf = try ttf_mod.Ttf.init(alloc, @embedFile("res/Hack-Regular.ttf"));

    const point_size = 11;
    const wrap_width_px = 284;

    var layout_helper = LayoutHelper.init(alloc, text, &ttf, wrap_width_px, point_size);
    defer layout_helper.glyphs.deinit();

    const max_steps = 1000;
    var i: usize = 0;
    while (try layout_helper.step()) {
        if (i > max_steps) return error.TooLong;
        i += 1;
    }
}

pub fn updateTextBuffer(self: *TextRenderer, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, text: TextLayout, ttf: ttf_mod.Ttf, distance_field_generator: sphrender.DistanceFieldGenerator, buffer: *Buffer) !void {
    const checkpoint = scratch_alloc.checkpoint();
    defer scratch_alloc.restore(checkpoint);

    const num_points_per_plane = 6;
    const Vertex = sphrender.xyuvt_program.Vertex;
    const new_buffer_data = try scratch_alloc.allocator().alloc(Vertex, text.glyphs.len * num_points_per_plane);

    var buffer_idx: usize = 0;
    const loop_checkpoint = scratch_alloc.checkpoint();
    for (text.glyphs) |glyph| {
        scratch_alloc.restore(loop_checkpoint);
        defer buffer_idx += num_points_per_plane;

        const uv_loc = try self.glyph_atlas.getGlyphLocation(scratch_alloc, scratch_gl, glyph.char, self.point_size, ttf, distance_field_generator);

        // [0, width] -> [-1, 1]
        const clip_x_start = pixToClip(@intCast(glyph.pixel_x1 - text.min_x), text.width());
        const clip_x_end = pixToClip(@intCast(glyph.pixel_x2 - text.min_x), text.width());
        const clip_y_top = pixToClip(@intCast(glyph.pixel_y2 - text.min_y), text.height());
        const clip_y_bottom = pixToClip(@intCast(glyph.pixel_y1 - text.min_y), text.height());

        const bl = Vertex{
            .vPos = .{ clip_x_start, clip_y_bottom },
            .vUv = .{ uv_loc.left, uv_loc.bottom },
        };

        const br = Vertex{
            .vPos = .{
                clip_x_end,
                clip_y_bottom,
            },
            .vUv = .{ uv_loc.right, uv_loc.bottom },
        };

        const tl = Vertex{
            .vPos = .{ clip_x_start, clip_y_top },
            .vUv = .{ uv_loc.left, uv_loc.top },
        };

        const tr = Vertex{
            .vPos = .{ clip_x_end, clip_y_top },
            .vUv = .{ uv_loc.right, uv_loc.top },
        };

        new_buffer_data[buffer_idx + 0] = bl;
        new_buffer_data[buffer_idx + 1] = br;
        new_buffer_data[buffer_idx + 2] = tl;
        new_buffer_data[buffer_idx + 3] = br;
        new_buffer_data[buffer_idx + 4] = tr;
        new_buffer_data[buffer_idx + 5] = tl;
    }

    buffer.updateBuffer(new_buffer_data);
}

pub fn render(self: TextRenderer, render_source: RenderSource, transform: sphmath.Transform) void {
    self.program.render(render_source, .{
        .input_df = self.glyph_atlas.texture,
        .multiplier = self.point_size * self.multiplier,
        .transform = transform.inner,
    });
}

pub const TextUniforms = struct {
    input_df: sphrender.Texture,
    multiplier: f32,
    transform: sphmath.Mat3x3,
};

fn pixToClip(val: u32, max: u32) f32 {
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
    \\    float distance = texture(input_df, uv).r;
    \\    float N = 1.0 / multiplier;
    \\    float alpha = smoothstep(-N, N, distance);
    \\    fragment = vec4(1.0, 1.0, 1.0, alpha);
    \\}
;
