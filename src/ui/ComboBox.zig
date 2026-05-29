const std = @import("std");
const sphmath = @import("../math.zig");
const sphrender = @import("../render.zig");
const gui = @import("../ui.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const scrollbar = @import("../ui/scrollbar.zig");
const util = @import("../ui/util.zig");
const ScrollView = @import("ScrollView.zig");
const Frame = @import("Frame.zig");
const Rect = @import("Rect.zig");
const Stack = @import("Stack.zig");
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;
const GlAlloc = sphrender.GlAlloc;

const TriangleProgram = sphrender.shader_program.Program(TriangleUniform);
const TriangleRenderSource = sphrender.shader_program.RenderSource;

pub const Shared = struct {
    squircle_renderer: *const SquircleRenderer,
    popup_layer: *gui.PopupLayer,
    scroll_shared: *const scrollbar.Shared,
    triangle_program: TriangleProgram,
    triangle_render_source: TriangleRenderSource,
    style: Style,

    pub fn init(
        gl_alloc: *GlAlloc,
        squircle_renderer: *const SquircleRenderer,
        popup_layer: *gui.PopupLayer,
        scroll_shared: *const scrollbar.Shared,
        style: Style,
    ) !Shared {
        const triangle_program = try TriangleProgram.init(gl_alloc, triangle_vertex_shader, triangle_fragment_shader);

        const triangle_buf = try sphrender.shader_program.Buffer(TriangleVertex).init(
            gl_alloc,
            &.{
                // Make a triangle that is pointing down and taking up the full
                // clip space
                .{ .vPos = .{ -1.0, 1.0 } },
                .{ .vPos = .{ 1.0, 1.0 } },
                .{ .vPos = .{ 0.0, -1.0 } },
            },
        );

        var triangle_render_source = try TriangleRenderSource.init(gl_alloc);
        triangle_render_source.bindData(TriangleVertex, triangle_program.handle, triangle_buf);

        return .{
            .squircle_renderer = squircle_renderer,
            .popup_layer = popup_layer,
            .scroll_shared = scroll_shared,
            .triangle_program = triangle_program,
            .triangle_render_source = triangle_render_source,
            .style = style,
        };
    }
};

pub const Style = struct {
    default_color: Color,
    hover_color: Color,
    click_color: Color,
    popup_background: Color,
    corner_radius: f32,
    width: u31,
    height: u31,
    triangle_width: u31,
    triangle_height: u31,
    triangle_color: Color,
    layout_pad: u31,
    popup_max_height: u31,
};

preview: *Widget,
shared: *const Shared,
state: enum { none, hovered, clicked },
popup_bg: Rect,
popup_scroll: ScrollView,
popup_frame: Frame,
popup_stack_items: [2]Stack.StackItem,
popup_stack: Stack,
widget: Widget,

const Self = @This();

pub fn initPinned(self: *Self, preview: *Widget, content: *Widget, shared: *const Shared) void {
    self.preview = preview;
    self.shared = shared;
    self.state = .none;
    self.popup_bg = Rect.init(shared.style.popup_background, shared.style.corner_radius, shared.squircle_renderer);
    self.popup_scroll = ScrollView.init(content, shared.scroll_shared);
    self.popup_frame = Frame.init(&self.popup_scroll.widget, shared.style.layout_pad);
    self.popup_stack_items = .{
        .{ .widget = &self.popup_bg.widget, .match_siblings = true },
        .{ .widget = &self.popup_frame.widget },
    };
    self.popup_stack = Stack.init(self.popup_stack_items[0..]);
    self.widget = .{
        .focused = false,
        .size = .{
            .width = shared.style.width,
            .height = shared.style.height,
        },
        .vtable = &.{
            .update = update,
            .input = input,
            .render = render,
            .reset = null,
        },
    };
}

const SubSizes = struct {
    text_wrap: u31,
    text_offs: i32,
    triangle_width: u31,
    triangle_height: u31,
    triangle_offs_x: i32,
    triangle_offs_y: i32,

    fn calc(style: Style) SubSizes {
        const triangle_right = style.width -| style.layout_pad;
        const triangle_left = triangle_right -| style.triangle_width;
        const text_right = triangle_left -| style.layout_pad;
        const text_left = style.layout_pad;

        return .{
            .text_wrap = text_right -| text_left,
            .text_offs = text_left,
            .triangle_width = style.triangle_width,
            .triangle_height = style.triangle_height,
            .triangle_offs_x = @intCast(triangle_left),
            .triangle_offs_y = @intCast(style.layout_pad),
        };
    }

    fn textBounds(self: SubSizes, text_size: PixelSize, widget_bounds: PixelBBox) PixelBBox {
        const left = widget_bounds.left + self.text_offs;
        const text_center: i32 = @intFromFloat(widget_bounds.cy());
        const text_top = text_center - text_size.height / 2;
        const text_bottom = text_center + text_size.height / 2 + text_size.height % 2;
        return .{
            .top = text_top,
            .bottom = text_bottom,
            .left = left,
            .right = left + text_size.width,
        };
    }

    fn triangleBounds(self: SubSizes, widget_bounds: PixelBBox) PixelBBox {
        const left = widget_bounds.left + self.triangle_offs_x;
        const top = widget_bounds.top + self.triangle_offs_y;
        return .{
            .top = top,
            .bottom = top + self.triangle_height,
            .left = left,
            .right = left + self.triangle_width,
        };
    }
};

fn update(widget: *Widget, _: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const sizes = SubSizes.calc(self.shared.style);
    try self.preview.update(
        .{ .width = sizes.text_wrap, .height = self.widget.size.height },
        delta_s,
    );
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const is_held = input_bounds.containsOptMousePos(input_state.mouse_down_location);
    const is_hovering = input_bounds.containsMousePos(input_state.mouse_pos);

    if (is_held) {
        self.state = .clicked;
        if (input_state.mouse_pressed) {
            const popup = &self.popup_stack.widget;
            popup.reset();
            try popup.update(
                .{ .width = self.shared.style.width, .height = self.shared.style.popup_max_height },
                0,
            );
            self.shared.popup_layer.set(popup, widget_bounds.left, widget_bounds.bottom);
        }
    } else if (is_hovering) {
        self.state = .hovered;
    } else {
        self.state = .none;
    }
}

fn render(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    {
        const color = switch (self.state) {
            .none => self.shared.style.default_color,
            .hovered => self.shared.style.hover_color,
            .clicked => self.shared.style.click_color,
        };

        const transform = util.widgetToClipTransform(bounds, window);
        self.shared.squircle_renderer.render(color, self.shared.style.corner_radius, bounds, transform);
    }

    const sizes = SubSizes.calc(self.shared.style);

    {
        const triangle_bounds = sizes.triangleBounds(bounds);
        const transform = util.widgetToClipTransform(triangle_bounds, window);
        self.shared.triangle_program.render(self.shared.triangle_render_source, .{
            .color = .{
                self.shared.style.triangle_color.r,
                self.shared.style.triangle_color.g,
                self.shared.style.triangle_color.b,
            },
            .transform = transform.inner,
        });
    }

    {
        const text_bounds = sizes.textBounds(self.preview.size, bounds);
        self.preview.render(text_bounds, window);
    }
}

const TriangleUniform = struct {
    color: sphmath.Vec3,
    transform: sphmath.Mat3x3,
};

const TriangleVertex = struct {
    vPos: sphmath.Vec2,
};

const triangle_vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\}
;

const triangle_fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;
