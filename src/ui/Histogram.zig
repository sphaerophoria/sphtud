const std = @import("std");
const sphmath = @import("../math.zig");
const gui = @import("../ui.zig");
const sphrender = @import("../render.zig");
const sphalloc = @import("../alloc.zig");
const util = @import("../ui/util.zig");
const InputState = gui.InputState;
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

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

pub const frag_shader =
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

pub const Shared = struct {
    program: sphrender.shader_program.Program(Uniforms),
    scratch: *sphalloc.ScratchAlloc,
    default_color: Color,
    active_color: Color,

    pub fn init(
        gl_alloc: *sphrender.GlAlloc,
        scratch: *sphalloc.BufAllocator,
        default_color: gui.Color,
        active_color: gui.Color,
    ) !Shared {
        return .{
            .program = try sphrender.shader_program.Program(Uniforms).init(gl_alloc, vertex_shader, frag_shader),
            .scratch = scratch,
            .default_color = default_color,
            .active_color = active_color,
        };
    }
};

num_buckets: usize = 0,
max_y: f32 = 0.0,
hovered_idx: i32 = -1,
shared: *const Shared,
render_source: sphrender.shader_program.RenderSource,
render_data: sphrender.shader_program.Buffer(Vertex),
label: *Widget,
widget: Widget,

const Self = @This();

pub fn init(
    alloc: gui.GuiAlloc,
    shared: *const Shared,
    label: *Widget,
) !Self {
    var render_source = try sphrender.shader_program.RenderSource.init(alloc.gl);
    const render_data = try sphrender.shader_program.Buffer(Vertex).init(alloc.gl, &.{});
    render_source.bindData(Vertex, shared.program.handle, render_data);

    return .{
        .shared = shared,
        .render_source = render_source,
        .render_data = render_data,
        .label = label,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = null,
            },
        },
    };
}

pub fn setData(self: *Self, data: []const f32) !void {
    self.max_y = 0;
    for (data) |y| self.max_y = @max(y, self.max_y);

    if (data.len == 0) {
        self.num_buckets = 0;
        self.render_data.updateBuffer(&.{});
        self.render_source.len = 0;
        return;
    }

    const cp = self.shared.scratch.checkpoint();
    defer self.shared.scratch.restore(cp);

    const vertices = try self.shared.scratch.allocator().alloc(Vertex, 6 * data.len);
    for (data, 0..) |y, i| {
        const pts = makeGlPoints(i, data.len, y) catch continue;
        @memcpy(vertices[i * 6 ..][0..6], &pts);
    }

    self.render_data.updateBuffer(vertices);
    self.render_source.len = vertices.len;
    self.num_buckets = data.len;
}

pub fn hoveredIdx(self: *const Self) ?usize {
    if (self.hovered_idx < 0) return null;
    const idx: usize = @intCast(self.hovered_idx);
    if (idx >= self.num_buckets) return null;
    return idx;
}

fn update(widget: *Widget, available_size: PixelSize, delta_s: f32) anyerror!void {
    const self: *Self = @fieldParentPtr("widget", widget);
    try self.label.update(available_size, delta_s);
    self.widget.size = available_size;
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const split = self.splitBounds(widget_bounds);
    const hist_input = split.histogram.calcIntersection(input_bounds);

    if (!hist_input.containsMousePos(input_state.mouse_pos)) {
        self.hovered_idx = -1;
        return;
    }

    const mouse_x: i32 = @intFromFloat(input_state.mouse_pos.x);
    const num_buckets: i32 = @intCast(self.num_buckets);
    self.hovered_idx = @divTrunc(
        (mouse_x - widget_bounds.left) * num_buckets,
        widget_bounds.calcWidth(),
    );

    try self.label.input(split.label, split.label.calcIntersection(input_bounds), input_state);
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    if (self.num_buckets == 0 or self.max_y == 0) return;

    const split_bounds = self.splitBounds(widget_bounds);

    self.label.render(split_bounds.label, window_bounds);

    const transform =
        sphmath.Transform.scale(1.0, 2.0 / self.max_y)
            .then(sphmath.Transform.translate(0.0, -1.0))
            .then(util.widgetToClipTransform(split_bounds.histogram, window_bounds));

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
}

fn makeGlPoints(x_idx: usize, num_items: usize, y: f32) ![6]Vertex {
    const x_idx_c: i32 = std.math.cast(i32, x_idx) orelse return error.TooManyBuckets;

    var bar_width: f32 = @floatFromInt(num_items);
    bar_width = 2.0 / bar_width;

    // x_idx / num_items is left edge
    var left: f32 = @floatFromInt(x_idx);
    left /= @floatFromInt(num_items);
    left = left * 2.0 - 1.0;

    const right = left + bar_width;

    const tl = Vertex{ .vPos = .{ left, y }, .vIdx = x_idx_c };
    const tr = Vertex{ .vPos = .{ right, y }, .vIdx = x_idx_c };
    const bl = Vertex{ .vPos = .{ left, 0 }, .vIdx = x_idx_c };
    const br = Vertex{ .vPos = .{ right, 0 }, .vIdx = x_idx_c };

    return .{ bl, tl, tr, bl, tr, br };
}

const SplitBounds = struct {
    histogram: gui.PixelBBox,
    label: gui.PixelBBox,
};

fn splitBounds(self: *Self, bounds: gui.PixelBBox) SplitBounds {
    var hist = bounds;
    hist.bottom -= self.label.size.height;
    var label = bounds;
    label.top = hist.bottom;
    label = gui.util.centerBoxInBounds(self.label.size, label);

    return .{
        .histogram = hist,
        .label = label,
    };
}
