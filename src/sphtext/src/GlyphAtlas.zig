const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const ttf_mod = @import("ttf.zig");
const sphmath = @import("sphmath");
const gl = sphrender.gl;
const GlAlloc = sphrender.GlAlloc;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;

const Texture = sphrender.Texture;

const PlaneRenderProgram = sphrender.xyuvt_program.Program(sphrender.xyuvt_program.ImageSamplerUniforms);
const PlaneRenderBuffer = sphrender.xyuvt_program.Buffer;

program: PlaneRenderProgram,
glyph_buffer: PlaneRenderBuffer,
texture: Texture,
tex_width: u31,
tex_height: u31,
//FIXME: Utf8 codepoints
glyph_locations: std.AutoHashMap(u8, UVBBox),
x_cursor_px: u16 = 0,
y_cursor_px: u16 = 0,
row_max_height: u16 = 0,

const GlyphAtlas = @This();

pub const UVBBox = struct {
    const empty = UVBBox{
        .left = 0.0,
        .right = 0.0,
        .top = 0.0,
        .bottom = 0.0,
    };
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
};

pub const PixelBBox = struct {
    left: u16,
    right: u16,
    top: u16,
    bottom: u16,

    fn toUv(self: PixelBBox, tex_width: usize, tex_height: usize) UVBBox {
        const tex_width_f: f32 = @floatFromInt(tex_width);
        const tex_height_f: f32 = @floatFromInt(tex_height);
        return .{
            .left = @as(f32, @floatFromInt(self.left)) / tex_width_f,
            .right = @as(f32, @floatFromInt(self.right)) / tex_width_f,
            .top = @as(f32, @floatFromInt(self.top)) / tex_height_f,
            .bottom = @as(f32, @floatFromInt(self.bottom)) / tex_height_f,
        };
    }
};

pub fn init(gpa: Allocator, gl_alloc: *GlAlloc) !GlyphAtlas {
    const program = try PlaneRenderProgram.init(gl_alloc, sphrender.xyuvt_program.image_sampler_frag);

    var c_max_texture_size: c_int = 0;
    gl.glGetIntegerv(gl.GL_MAX_TEXTURE_SIZE, &c_max_texture_size);

    const tex_width: u31 = @intCast(c_max_texture_size);
    const tex_height: u31 = @intCast(c_max_texture_size);

    const texture = try sphrender.makeTextureOfSize(gl_alloc, tex_width, tex_height, .rf32);
    try clearTexture(texture, tex_width, tex_height);

    return .{
        .program = program,
        .glyph_locations = std.AutoHashMap(u8, UVBBox).init(gpa),
        .glyph_buffer = try program.makeFullScreenPlane(gl_alloc),
        .texture = texture,
        .tex_width = tex_width,
        .tex_height = tex_height,
    };
}

pub fn reset(self: *GlyphAtlas) !void {
    self.glyph_locations.clearRetainingCapacity();
    try clearTexture(self.texture, self.tex_width, self.tex_height);
}

pub fn getGlyphLocation(
    self: *GlyphAtlas,
    scratch_alloc: *ScratchAlloc,
    scratch_gl: *GlAlloc,
    char: u8,
    point_size: f32,
    ttf: ttf_mod.Ttf,
    distance_field_renderer: sphrender.DistanceFieldGenerator,
) !UVBBox {
    const gop = try self.glyph_locations.getOrPut(char);
    if (!gop.found_existing) {
        gop.value_ptr.* = try self.addCharToAtlas(
            scratch_alloc,
            scratch_gl,
            char,
            point_size,
            ttf,
            distance_field_renderer,
        );
    }
    return gop.value_ptr.*;
}

fn addCharToAtlas(self: *GlyphAtlas, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, char: u8, point_size: f32, ttf: ttf_mod.Ttf, distance_field_renderer: sphrender.DistanceFieldGenerator) !UVBBox {
    const gl_checkpoint = scratch_gl.checkpoint();
    defer scratch_gl.restore(gl_checkpoint);

    const heap_checkpoint = scratch_alloc.checkpoint();
    defer scratch_alloc.restore(heap_checkpoint);

    const glyph = try ttf_mod.glyphForChar(scratch_alloc.allocator(), ttf, char) orelse return UVBBox.empty;

    var canvas, const bbox = try ttf_mod.renderGlyphAt1PxPerFunit(scratch_alloc.allocator(), glyph);

    const width = canvas.width;
    const height: usize = @intCast(canvas.calcHeight());

    const mask = try sphrender.makeTextureFromR(scratch_gl, canvas.pixels, canvas.width);

    // NOTE: This is rendered at 1px/funit. This is probably unnecessary, but
    // early attempts at rendering directly at the atlas resolution resulted in
    // mis-matched mask/distance fields. Likely solvable, but not bothering for
    // now
    const distance_field = try makeDistanceField(
        scratch_alloc,
        scratch_gl,
        ttf,
        char,
        width,
        height,
        mask,
        bbox,
        distance_field_renderer,
    );

    const bounds = try self.allocateGlyphSpace(point_size, @floatFromInt(ttf.head.units_per_em), glyph.common);

    try self.renderTextureIntoAtlas(bounds, distance_field);
    return bounds.toUv(self.tex_width, self.tex_height);
}

fn allocateGlyphSpace(self: *GlyphAtlas, point_size: f32, units_per_em: f32, glyph_header: ttf_mod.GlyphTable.GlyphCommon) !PixelBBox {
    const funit_converter = ttf_mod.FunitToPixelConverter.init(point_size, units_per_em);
    const pixel_size = funit_converter.pixelBoundsForGlyph(glyph_header);

    // As far as I can tell, there are slight inconsistencies between the
    // approach of sampling the texture atlas with UV coords, and rendering the
    // image into the atlas with viewport coords. Add a 1 pixel border around
    // each glyph to avoid interpolating SDFs of an adjacent glyph in the atlas
    const padding = 1;
    if (self.x_cursor_px + pixel_size[0] > self.tex_width) {
        self.y_cursor_px += self.row_max_height + padding;
        self.x_cursor_px = 0;
        self.row_max_height = 0;
    }

    if (self.x_cursor_px + pixel_size[0] > self.tex_width or self.y_cursor_px + pixel_size[1] > self.tex_height) {
        return error.OutOfMemory;
    }

    const x_start = self.x_cursor_px;
    self.x_cursor_px += pixel_size[0] + padding;
    self.row_max_height = @max(self.row_max_height, pixel_size[1]);

    return .{
        .left = x_start,
        .right = self.x_cursor_px - padding,
        .top = self.y_cursor_px + pixel_size[1],
        .bottom = self.y_cursor_px,
    };
}

fn renderTextureIntoAtlas(self: *GlyphAtlas, bounds: PixelBBox, distance_field: sphrender.Texture) !void {
    const render_context = try sphrender.FramebufferRenderContext.init(self.texture, null);
    defer render_context.reset();

    const temp_viewport = sphrender.TemporaryViewport.init();
    defer temp_viewport.reset();

    const temp_scissor = sphrender.TemporaryScissor.init();
    defer temp_scissor.reset();

    temp_viewport.setViewportOffset(
        bounds.left,
        bounds.bottom,
        bounds.right - bounds.left,
        bounds.top - bounds.bottom,
    );

    temp_scissor.setAbsolute(bounds.left, bounds.bottom, bounds.right - bounds.left, bounds.top - bounds.bottom);

    self.program.render(self.glyph_buffer, .{
        .input_image = distance_field,
    });
}

// Adapter iterator to convert from glyph line segments into the format
// expected by the distance field renderer (line points tagged with line segment)
// Note that this means beziers are cut up into sampled line segments
const LinePointIter = struct {
    inner: ttf_mod.GlyphSegmentIter,
    last: ?ttf_mod.GlyphSegmentIter.Output = null,
    // How many points have we returned from the cached output
    idx: usize = 0,
    scale: sphmath.Vec2,
    bottom_left_fcoord: FCoord,

    const Output = union(enum) {
        new_line: sphmath.Vec2,
        line_point: sphmath.Vec2,
    };

    fn init(inner: ttf_mod.GlyphSegmentIter, width: usize, height: usize, bbox: ttf_mod.BBox) LinePointIter {
        return .{
            .inner = inner,
            .scale = .{ @floatFromInt(width), @floatFromInt(height) },
            .bottom_left_fcoord = .{ bbox.min_x, bbox.min_y },
        };
    }

    const FCoord = @Vector(2, i16);

    fn toClip(self: LinePointIter, in: FCoord) sphmath.Vec2 {
        const in_f: sphmath.Vec2 = @floatFromInt(in - self.bottom_left_fcoord);
        return in_f / self.scale * vec2Scalar(2.0) - vec2Scalar(1.0);
    }

    fn vec2Scalar(v: f32) sphmath.Vec2 {
        return @splat(v);
    }

    fn nextStored(self: *LinePointIter) ?Output {
        const last = self.last orelse return null;
        defer self.idx += 1;
        switch (last) {
            .line => |l| {
                switch (self.idx) {
                    0 => {
                        return .{ .new_line = self.toClip(l.a) };
                    },
                    1 => {
                        return .{ .line_point = self.toClip(l.b) };
                    },
                    else => return null,
                }
            },
            .bezier => |b| {
                const num_segments = 50;
                if (self.idx > num_segments) {
                    return null;
                }

                if (self.idx == 0) {
                    return .{ .new_line = self.toClip(b.a) };
                }

                var t: f32 = @floatFromInt(self.idx);
                t /= @floatFromInt(num_segments);

                const point = ttf_mod.sampleQuadBezierCurve(
                    @floatFromInt(b.a),
                    @floatFromInt(b.b),
                    @floatFromInt(b.c),
                    t,
                );

                return .{ .line_point = self.toClip(@intFromFloat(@round(point))) };
            },
        }
    }

    pub fn next(self: *LinePointIter) ?Output {
        while (true) {
            if (self.nextStored()) |val| {
                return val;
            }
            self.last = self.inner.next() orelse return null;
            self.idx = 0;
        }
    }
};

fn makeDistanceField(
    scratch_alloc: *ScratchAlloc,
    gl_alloc: *GlAlloc,
    ttf: ttf_mod.Ttf,
    c: u8,
    width: usize,
    height: usize,
    mask_texture: sphrender.Texture,
    bbox: ttf_mod.BBox,
    distance_field_renderer: sphrender.DistanceFieldGenerator,
) !sphrender.Texture {
    const simple_glyph = try ttf_mod.glyphForChar(scratch_alloc.allocator(), ttf, c) orelse return sphrender.Texture.invalid;

    const iter = ttf_mod.GlyphSegmentIter.init(simple_glyph);
    var line_iter = LinePointIter.init(iter, width, height, bbox);

    const ret = try sphrender.makeTextureCommon(gl_alloc);
    try distance_field_renderer.renderDistanceFieldToTexture(
        scratch_alloc,
        gl_alloc,
        &line_iter,
        mask_texture,
        @intCast(width),
        @intCast(height),
        ret,
    );
    gl.glTextureParameteri(ret.inner, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTextureParameteri(ret.inner, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    return ret;
}

fn clearTexture(texture: Texture, tex_width: u31, tex_height: u31) !void {
    const render_context = try sphrender.FramebufferRenderContext.init(texture, null);
    defer render_context.reset();

    const temp_viewport = sphrender.TemporaryViewport.init();
    defer temp_viewport.reset();

    temp_viewport.setViewport(tex_width, tex_height);

    const temp_scissor = sphrender.TemporaryScissor.init();
    defer temp_scissor.reset();

    temp_scissor.setAbsolute(0, 0, tex_width, tex_height);

    gl.glClearColor(
        -std.math.inf(f32),
        -std.math.inf(f32),
        -std.math.inf(f32),
        -std.math.inf(f32),
    );
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
}
