const std = @import("std");
const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const sphalloc = @import("sphalloc");
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

pub const Shared = struct {
    program: sphrender.shader_program.Program(Uniforms),
    guitext_shared: *const gui.gui_text.SharedState,
    scratch: *sphalloc.BufAllocator,
    default_color: gui.Color,
    active_color: gui.Color,

    pub fn init(
        gl_alloc: *sphrender.GlAlloc,
        guitext_shared: *const gui.gui_text.SharedState,
        scratch: *sphalloc.BufAllocator,
        default_color: gui.Color,
        active_color: gui.Color,
    ) !Shared {
        return .{
            .program = try sphrender.shader_program.Program(Uniforms).init(gl_alloc, vertex_shader, frag_shader),
            .guitext_shared = guitext_shared,
            .scratch = scratch,
            .default_color = default_color,
            .active_color = active_color,
        };
    }
};

pub fn histogram(comptime Action: type, alloc: sphrender.RenderAlloc, retriever: anytype, shared: *const Shared) !Widget(Action) {
    const T = Histogram(Action, @TypeOf(retriever));

    const ctx = try alloc.heap.arena().create(T);

    var render_source = try sphrender.shader_program.RenderSource.init(alloc.gl);
    const render_data = try sphrender.shader_program.Buffer(Vertex).init(alloc.gl, &.{});

    render_source.bindData(Vertex, shared.program.handle, render_data);

    const axis_text_alloc = try alloc.heap.makeSubAlloc("histogram axis text");

    ctx.* = .{
        .shared = shared,
        .retriever = retriever,
        .render_source = render_source,
        .render_data = render_data,
        .max_y = 0,
        .axis_text_alloc = axis_text_alloc,
        .x_axis_text = &.{},

        // NOTE: GuiText object that shows current text lives for lifetime of
        // widget. Note that the text itself will change and get re-allocated
        // from the curnent_hovered_text_alloc, but the widget will not
        .x_axis_gui_text = try gui.gui_text.guiText(alloc, shared.guitext_shared, &ctx.x_axis_text),
    };

    return .{
        .ctx = ctx,
        .name = "histogram",
        .vtable = &T.widget_vtable,
    };
}

pub fn Histogram(comptime Action: type, comptime Retriever: type) type {
    return struct {
        retriever: Retriever,
        shared: *const Shared,
        size: PixelSize = .{},
        last_generation: u64 = std.math.maxInt(u64),
        render_source: sphrender.shader_program.RenderSource,
        render_data: sphrender.shader_program.Buffer(Vertex),
        hovered_idx: i32 = -1,
        max_y: f32,
        num_buckets: i32 = 0,

        // NOTE: Only used for the text backing GuiText, not GuiText itself
        axis_text_alloc: *sphalloc.Sphalloc,
        axis_text_idx: i32 = -1,
        x_axis_text: []const u8,

        x_axis_gui_text: gui.gui_text.GuiText(*[]const u8),

        const Self = @This();
        const widget_vtable = Widget(Action).VTable{
            .render = render,
            .getSize = getSize,
            .update = update,
            .setInputState = setInputState,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            // Render the histogram
            const self: *Self = @ptrCast(@alignCast(ctx));

            const histogram_bounds = histogramBounds(widget_bounds);
            const transform =
                sphmath.Transform.scale(1.0, 2 / self.max_y) // [0,max_y] -> [0, 2]
                    .then(sphmath.Transform.translate(0.0, -1.0)) // [0,2] -> [-1, 1]
                    .then(gui.util.widgetToClipTransform(histogram_bounds, window_bounds)); // Put in widget area

            self.render_source.bindData(Vertex, self.shared.program.handle, self.render_data);
            const default_color_v4 = sphmath.Vec4{
                self.shared.default_color.r,
                self.shared.default_color.g,
                self.shared.default_color.b,
                self.shared.default_color.a,
            };
            const active_color_v4 = sphmath.Vec4{
                self.shared.active_color.r,
                self.shared.active_color.g,
                self.shared.active_color.b,
                self.shared.active_color.a,
            };
            self.shared.program.render(self.render_source, .{
                .default_color = default_color_v4,
                .active_color = active_color_v4,
                .transform = transform.inner,
                .hovered_idx = self.hovered_idx,
            });

            const x_text_area = PixelBBox{
                .top = histogram_bounds.bottom,
                .bottom = widget_bounds.bottom,
                .left = histogram_bounds.left,
                .right = histogram_bounds.right,
            };

            renderTextCentered(x_text_area, window_bounds, self.x_axis_gui_text);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;

            const y_vals = self.retriever.yVals();
            if (self.axis_text_idx != self.hovered_idx) {
                try self.axis_text_alloc.reset();

                self.x_axis_text = &.{};
                self.axis_text_idx = self.hovered_idx;

                if (self.hovered_idx > 0 and self.hovered_idx < y_vals.len) {
                    self.x_axis_text = try std.fmt.allocPrint(
                        self.axis_text_alloc.arena(),
                        "x: {d}, y: {d}",
                        .{ self.hovered_idx, y_vals[@intCast(self.hovered_idx)] },
                    );
                } else {}
            }

            try self.x_axis_gui_text.update(available_size.width);

            const next_generation = self.retriever.generation();
            if (self.last_generation == next_generation) {
                return;
            }

            // Data changed, so force an axis text regen
            self.hovered_idx = -1;

            const cp = self.shared.scratch.checkpoint();
            defer self.shared.scratch.restore(cp);

            self.num_buckets = std.math.cast(i32, y_vals.len) orelse return error.TooManyBuckets;
            self.max_y = 0;

            var points = try sphutil.RuntimeBoundedArray(Vertex).init(self.shared.scratch.allocator(), 6 * y_vals.len);

            for (y_vals, 0..) |val, x_idx| {
                self.max_y = @max(val, self.max_y);

                const bucket_points = try makeGlPoints(x_idx, y_vals.len, val);
                try points.appendSlice(&bucket_points);
            }

            self.render_data.updateBuffer(points.items);
            self.last_generation = next_generation;
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (!input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.hovered_idx = -1;
                return .{};
            }

            const histogram_bounds = histogramBounds(widget_bounds);

            const mouse_x: i32 = @intFromFloat(input_state.mouse_pos.x);
            self.hovered_idx = @divTrunc(
                (mouse_x - histogram_bounds.left) * self.num_buckets,
                histogram_bounds.calcWidth(),
            );

            return .{};
        }
    };
}

const Vertex = struct {
    vPos: sphmath.Vec2,
    vIdx: i32,
};
const Uniforms = struct {
    default_color: sphmath.Vec4,
    active_color: sphmath.Vec4,
    transform: sphmath.Mat3x3,
    hovered_idx: i32,
};

pub const vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\in int vIdx;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\flat out int idx;
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\    idx = vIdx;
    \\}
;

const frag_shader =
    \\#version 330
    \\uniform vec4 default_color = vec4(1.0, 1.0, 1.0, 1.0);
    \\uniform vec4 active_color = vec4(1.0, 1.0, 1.0, 1.0);
    \\uniform int hovered_idx = -1;
    \\flat in int idx;
    \\out vec4 fragment;
    \\void main() {
    \\  if (idx == hovered_idx) {
    \\     fragment = active_color;
    \\  } else {
    \\     fragment = default_color;
    \\  }
    \\}
;

fn histogramBounds(widget_bounds: PixelBBox) PixelBBox {
    const adjustment = @max(widget_bounds.calcWidth(), widget_bounds.calcHeight()) / 20;
    return .{
        .left = widget_bounds.left,
        .bottom = widget_bounds.bottom - adjustment,
        .top = widget_bounds.top,
        .right = widget_bounds.right,
    };
}

fn renderTextCentered(area_bounds: PixelBBox, window_bounds: PixelBBox, text: gui.gui_text.GuiText(*[]const u8)) void {
    const text_size = text.size();
    const area_cx: i32 = @intFromFloat(area_bounds.cx());
    const area_cy: i32 = @intFromFloat(area_bounds.cy());

    const text_bounds = PixelBBox{
        .left = area_cx - text_size.width / 2,
        .right = area_cx + text_size.width / 2 + text_size.width % 2,
        .top = area_cy - text_size.height / 2,
        .bottom = area_cy + text_size.height / 2 + text_size.height % 2,
    };

    const text_transform = gui.util.widgetToClipTransform(text_bounds, window_bounds);
    text.render(text_transform);
}

fn makeGlPoints(x_idx: usize, num_items: usize, y: f32) ![6]Vertex {
    var bar_width: f32 = @floatFromInt(num_items);
    bar_width = 2.0 / bar_width;

    const x_idx_c: i32 = std.math.cast(i32, x_idx) orelse return error.TooManyBuckets;

    // x_idx / num_items is left edge
    var left: f32 = @floatFromInt(x_idx);
    left /= @floatFromInt(num_items);
    left = left * 2.0 - 1.0;

    const right = left + bar_width;

    // Note y positions are in [0,max_y], will be normalized to [-1, 1] in
    // transform later. This allows us to generate points before we have
    // figured out the max
    const tl = Vertex{ .vPos = .{ left, y }, .vIdx = x_idx_c };
    const tr = Vertex{ .vPos = .{ right, y }, .vIdx = x_idx_c };
    const bl = Vertex{ .vPos = .{ left, 0 }, .vIdx = x_idx_c };
    const br = Vertex{ .vPos = .{ right, 0 }, .vIdx = x_idx_c };

    return .{
        bl, tl, tr,
        bl, tr, br,
    };
}
