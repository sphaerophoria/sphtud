const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const gui = @import("gui.zig");
const sphtext = @import("sphtext");
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const RuntimeSegmentedList = sphutil.RuntimeSegmentedList;
const PixelSize = gui.PixelSize;
const TextRenderer = sphtext.TextRenderer;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphrender.GlAlloc;

pub const SharedState = struct {
    scratch_alloc: *ScratchAlloc,
    scratch_gl: *GlAlloc,
    text_renderer: *TextRenderer,
    ttf: *const sphtext.ttf.Ttf,
    distance_field_generator: *const sphrender.DistanceFieldGenerator,
};

pub fn guiText(alloc: gui.GuiAlloc, shared: *const SharedState, text_retriever_const: anytype) !GuiText(@TypeOf(text_retriever_const)) {
    const text_buffer = try sphrender.xyuvt_program.makeFullScreenPlane(alloc.gl);
    var text_render_source = try sphrender.xyuvt_program.RenderSource.init(alloc.gl);
    text_render_source.bindData(shared.text_renderer.program.handle(), text_buffer);

    const typical_max_glyphs = 128;
    const max_glyph_capacity = 1 << 20;

    const text = try RuntimeSegmentedList(u8).init(
        alloc.heap.general(),
        alloc.heap.block_alloc.allocator(),
        typical_max_glyphs,
        max_glyph_capacity,
    );

    const glyph_locations = try RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc).init(
        alloc.heap.general(),
        alloc.heap.block_alloc.allocator(),
        typical_max_glyphs,
        max_glyph_capacity,
    );

    return .{
        .alloc = alloc,
        .glyph_locations = glyph_locations,
        .text = text,
        .buffer = text_buffer,
        .render_source = text_render_source,
        .shared = shared,
        .text_retriever = text_retriever_const,
    };
}

pub const LayoutBounds = struct {
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,

    pub fn width(self: LayoutBounds) u31 {
        return @intCast(self.max_x - self.min_x);
    }

    pub fn height(self: LayoutBounds) u31 {
        return @intCast(self.max_y - self.min_y);
    }
};

pub fn GuiText(comptime TextRetriever: type) type {
    return struct {
        alloc: gui.GuiAlloc,
        glyph_locations: RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc),
        layout_bounds: LayoutBounds = .{},
        buffer: TextRenderer.Buffer,
        render_source: TextRenderer.RenderSource,
        text: RuntimeSegmentedList(u8),
        wrap_width: u31 = 0,
        shared: *const SharedState,

        text_retriever: TextRetriever,

        const Self = @This();

        pub fn update(self: *Self, wrap_width: u31) !void {
            if (self.wrap_width != wrap_width) {
                try self.regenerate(wrap_width);
                return;
            }

            const new_text = getText(&self.text_retriever);
            if (!self.text.contentMatches(new_text)) {
                try self.regenerate(wrap_width);
                return;
            }
        }

        pub fn size(self: Self) PixelSize {
            return .{
                .width = @intCast(self.layout_bounds.width()),
                .height = @intCast(self.layout_bounds.height()),
            };
        }

        pub fn render(self: Self, transform: sphmath.Transform) void {
            // FIXME: Render a baseline. We could probably adjust our size so
            // that it always reports the min/max height of a char to get
            // consistent layout, then find the baseline relative to that area
            //
            // Baseline location can use the max ascent/descent metrics
            self.shared.text_renderer.render(self.render_source, transform);
        }

        pub fn getNextText(self: *Self) []const u8 {
            return getText(&self.text_retriever);
        }

        fn regenerate(self: *Self, wrap_width: u31) !void {
            const text = getText(&self.text_retriever);
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
            try self.text.setContents(text);
            self.wrap_width = wrap_width;
        }
    };
}

fn getText(text_retriever: anytype) []const u8 {
    const Ptr = @TypeOf(text_retriever);
    const T = @typeInfo(Ptr).pointer.child;

    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "getText")) {
                return text_retriever.getText();
            }
        },
        .pointer => |p| {
            if (p.child == u8 and p.size == .slice) {
                return text_retriever.*;
            }

            const child_info = @typeInfo(p.child);
            if (child_info == .array and child_info.array.child == u8) {
                return text_retriever.*;
            }

            if (child_info == .pointer and child_info.pointer.child == u8 and child_info.pointer.size == .slice) {
                return text_retriever.*.*;
            }
        },
        else => {},
    }

    @compileError("text_retriever must be a string or have a getText() function, type is " ++ @typeName(T));
}
