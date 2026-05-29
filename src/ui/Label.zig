const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("../math.zig");
const gui = @import("../ui.zig");
const sphtext = @import("../text.zig");
const sphrender = @import("../render.zig");
const sphutil = @import("../util.zig");
const RuntimeSegmentedList = sphutil.RuntimeSegmentedList;
const PixelSize = gui.PixelSize;
const TextRenderer = sphtext.TextRenderer;
const sphalloc = @import("../alloc.zig");
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphrender.GlAlloc;

pub const SharedState = struct {
    scratch_alloc: *ScratchAlloc,
    scratch_gl: *GlAlloc,
    text_renderer: *TextRenderer,
    ttf: *const sphtext.ttf.Ttf,
    distance_field_generator: *const sphrender.DistanceFieldGenerator,
};

pub const LayoutBounds = struct {
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,

    fn width(self: LayoutBounds) u31 {
        return @intCast(self.max_x - self.min_x);
    }

    fn height(self: LayoutBounds) u31 {
        return @intCast(self.max_y - self.min_y);
    }
};

alloc: gui.GuiAlloc,
glyph_locations: RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc),
layout_bounds: LayoutBounds = .{},
buffer: TextRenderer.Buffer,
render_source: TextRenderer.RenderSource,
text: RuntimeSegmentedList(u8),
wrap_width: u31 = 0,
shared: *const SharedState,
color: gui.Color,
widget: gui.Widget,

const Self = @This();

pub fn init(alloc: gui.GuiAlloc, shared: *const SharedState, initial_text: []const u8, color: gui.Color) !Self {
    const text_buffer = try sphrender.xyuvt_program.makeFullScreenPlane(alloc.gl);
    var text_render_source = try sphrender.xyuvt_program.RenderSource.init(alloc.gl);
    text_render_source.bindData(shared.text_renderer.program.handle(), text_buffer);

    const typical_max_glyphs = 128;
    const max_glyph_capacity = 1 << 20;

    const text = try RuntimeSegmentedList(u8).init(
        alloc.heap.general(),
        alloc.heap.expansion(),
        typical_max_glyphs,
        max_glyph_capacity,
    );

    const glyph_locations = try RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc).init(
        alloc.heap.general(),
        alloc.heap.expansion(),
        typical_max_glyphs,
        max_glyph_capacity,
    );

    var ret = Self{
        .alloc = alloc,
        .glyph_locations = glyph_locations,
        .text = text,
        .buffer = text_buffer,
        .render_source = text_render_source,
        .shared = shared,
        .color = color,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .render = render,
                .update = update,
                .input = null,
                .reset = null,
            },
        },
    };

    try ret.setText(initial_text);
    return ret;
}

pub fn setText(self: *Self, new_text: []const u8) !void {
    if (!self.text.contentMatches(new_text)) {
        try self.text.setContents(new_text);
        try self.regenerate(self.wrap_width);
    }
}

fn update(widget: *gui.Widget, available_size: gui.PixelSize, _: f32) anyerror!void {
    const self: *Self = @fieldParentPtr("widget", widget);

    if (self.wrap_width != available_size.width) {
        try self.regenerate(available_size.width);
    }

    self.widget.size = .{
        .width = @intCast(self.layout_bounds.width()),
        .height = @intCast(self.layout_bounds.height()),
    };
}

fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);

    // FIXME: Render a baseline. We could probably adjust our size so
    // that it always reports the min/max height of a char to get
    // consistent layout, then find the baseline relative to that area
    //
    // Baseline location can use the max ascent/descent metrics
    self.shared.text_renderer.render(self.render_source, .{ self.color.r, self.color.g, self.color.b }, transform);
}

fn regenerate(self: *Self, wrap_width: u31) !void {
    if (wrap_width == 0) return;

    const text = try self.text.makeContiguous(self.shared.scratch_alloc.allocator());

    const text_layout = try self.shared.text_renderer.layoutText(
        self.shared.scratch_alloc.allocator(),
        text,
        self.shared.ttf.*,
        wrap_width,
    );

    try self.shared.text_renderer.updateTextBuffer(
        self.shared.scratch_alloc,
        self.shared.scratch_gl,
        text_layout,
        self.shared.ttf.*,
        self.shared.distance_field_generator.*,
        &self.buffer,
    );

    self.render_source.setLen(self.buffer.len);

    self.layout_bounds = .{
        .min_x = text_layout.min_x,
        .min_y = text_layout.min_y,
        .max_x = text_layout.max_x,
        .max_y = text_layout.max_y,
    };

    try self.glyph_locations.setContents(text_layout.glyphs);
    self.wrap_width = wrap_width;
}
