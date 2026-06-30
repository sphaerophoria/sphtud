const std = @import("std");
const sphmath = @import("../math.zig");
const sphrender = @import("../render.zig");
const gui = @import("../ui.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const util = @import("../ui/util.zig");
const Rect = @import("Rect.zig");
const Frame = @import("Frame.zig");
const Stack = @import("Stack.zig");
const Drag = @import("Drag.zig");
const Label = @import("Label.zig");
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;
const GlAlloc = sphrender.GlAlloc;

const HexagonProgram = sphrender.xyuvt_program.Program(HexagonUniform);
const LightnessProgram = sphrender.xyuvt_program.Program(LightnessUniform);

pub const Style = struct {
    preview_width: u31,
    preview_height: u31,
    popup_width: u31,
    popup_background: Color,
    corner_radius: f32,
    item_pad: u31,
    hex_preview_height: u31,
    slider_height: u31,
};

pub const Shared = struct {
    squircle_renderer: *const SquircleRenderer,
    hexagon_renderer: HexagonProgram,
    hexagon_render_source: sphrender.xyuvt_program.RenderSource,
    lightness_renderer: LightnessProgram,
    lightness_render_source: sphrender.xyuvt_program.RenderSource,
    popup_layer: *gui.PopupLayer,
    event_queue: *gui.EventQueue,
    drag_shared: *const Drag.Shared,
    label_shared: *const Label.SharedState,
    style: Style,

    pub fn init(
        gl_alloc: *GlAlloc,
        squircle_renderer: *const SquircleRenderer,
        popup_layer: *gui.PopupLayer,
        event_queue: *gui.EventQueue,
        drag_shared: *const Drag.Shared,
        label_shared: *const Label.SharedState,
        style: Style,
    ) !Shared {
        const hexagon_program = try HexagonProgram.init(gl_alloc, hexagon_color_frag);
        const lightness_program = try LightnessProgram.init(gl_alloc, lightness_slider_frag);
        const full_screen_plane = try sphrender.xyuvt_program.makeFullScreenPlane(gl_alloc);

        var hexagon_render_source = try sphrender.xyuvt_program.RenderSource.init(gl_alloc);
        hexagon_render_source.bindData(hexagon_program.handle(), full_screen_plane);

        var lightness_render_source = try sphrender.xyuvt_program.RenderSource.init(gl_alloc);
        lightness_render_source.bindData(lightness_program.handle(), full_screen_plane);

        return .{
            .squircle_renderer = squircle_renderer,
            .popup_layer = popup_layer,
            .event_queue = event_queue,
            .hexagon_renderer = hexagon_program,
            .hexagon_render_source = hexagon_render_source,
            .lightness_renderer = lightness_program,
            .lightness_render_source = lightness_render_source,
            .drag_shared = drag_shared,
            .label_shared = label_shared,
            .style = style,
        };
    }
};

color: Color,
on_change: usize,
shared: *const Shared,

popup_hexagon: ColorHexagon,
popup_bg: Rect,
popup_frame: Frame,
popup_stack_items: [2]Stack.StackItem,
popup_stack: Stack,

widget: Widget,

const Self = @This();

pub fn initPinned(self: *Self, alloc: gui.GuiAlloc, initial_color: Color, on_change: usize, shared: *const Shared) !void {
    self.color = initial_color;
    self.on_change = on_change;
    self.shared = shared;
    try self.popup_hexagon.initPinned(alloc, &self.color, shared.event_queue, on_change, shared);
    self.popup_bg = Rect.init(shared.style.popup_background, shared.style.corner_radius, shared.squircle_renderer);
    self.popup_frame = Frame.init(&self.popup_hexagon.widget, shared.style.item_pad);
    self.popup_stack_items = .{
        .{ .widget = &self.popup_bg.widget, .match_siblings = true },
        .{ .widget = &self.popup_frame.widget },
    };
    self.popup_stack = Stack.init(self.popup_stack_items[0..]);
    self.widget = .{
        .focused = false,
        .size = .{
            .width = shared.style.preview_width,
            .height = shared.style.preview_height,
        },
        .vtable = &.{
            .update = null,
            .input = input,
            .render = render,
            .reset = null,
        },
    };
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const is_held = input_bounds.containsOptMousePos(input_state.mouse_down_location);
    if (is_held and input_state.mouse_pressed) {
        const popup = &self.popup_stack.widget;
        popup.reset();
        try popup.update(
            .{ .width = self.shared.style.popup_width + self.shared.style.item_pad * 2, .height = 0 },
            0,
        );
        self.shared.popup_layer.set(popup, widget_bounds.left, widget_bounds.bottom);
    }
}

fn render(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const transform = util.widgetToClipTransform(bounds, window);
    self.shared.squircle_renderer.render(
        self.color,
        self.shared.style.corner_radius,
        bounds,
        transform,
    );
}

fn calcLightness(color: Color) f32 {
    // You might be tempted to use an average here, but then you can never have
    // maximum lightness that isn't white
    var current_lightness = @max(color.r, color.g);
    current_lightness = @max(current_lightness, color.b);
    return current_lightness;
}

const ColorAxis = struct {
    r: sphmath.Vec3,
    g: sphmath.Vec3,
    b: sphmath.Vec3,

    fn calcHsvFacing() ColorAxis {
        const Vec3 = sphmath.Vec3;

        // Rotate the RGB cube such that we are looking at it along the x=y=z
        // axis. In this scenario we want the white vector to point straight
        // towards the camera (z), and the blue axis to point straight up
        // (towards y). Since the green and red vectors need to be evenly
        // rotated, we rotate these by 2pi/3 around the camera axis

        const rgb_white = Vec3{ 1, 1, 1 };
        const rgb_blue = Vec3{ 0, 0, 1 };

        const white_length = sphmath.length(rgb_white);

        // If we want to place the cube on it's corner, we need the angle
        // between the axis and the ground. You may expect this to be 45
        // degrees, but it's not.
        //
        // We know that the white line points straight up, so we can find the
        // angle between white and an axis, and then do 90 degrees - that angle
        // to find angle to the ground
        //
        // We don't actually care about the angle though, just the distance
        // from the axis to the ground, and the new xy length. We have distance
        // from the ground because
        //
        //    1.0  .-^
        //     .-^   | (sin(t))
        // .-^       |
        // ^^^^^^^^^^^
        //    cos(t)

        // And since sin(t) and cos(t) are 90 degrees rotated from eachother,
        // we can just calculate the  cross and dot product between the blue
        // and white vectors and use those for our xy length and z heights,
        // scaled to make the axis lengths 1

        const z_height = sphmath.dot(rgb_white, rgb_blue) / white_length;
        const xy_len = sphmath.length(sphmath.cross(rgb_white, rgb_blue)) / white_length;

        const blue_axis = Vec3{ 0, xy_len, z_height };

        // Now we just need to rotate by 1/3 and 2/3 turns
        const rg_x = xy_len * @cos(std.math.pi / 6.0);
        const rg_y = -xy_len * @sin(std.math.pi / 6.0);

        const red_axis = Vec3{ rg_x, rg_y, z_height };
        const green_axis = Vec3{ -rg_x, rg_y, z_height };
        return .{
            .r = red_axis,
            .b = blue_axis,
            .g = green_axis,
        };
    }
};

const hsv_rgb_axis = ColorAxis.calcHsvFacing();

// Mirror of glsl code below
fn bestAxis(center_offs: sphmath.Vec2) sphmath.Vec3 {
    const b2 = sphmath.Vec2{ hsv_rgb_axis.b[0], hsv_rgb_axis.b[1] };
    const g2 = sphmath.Vec2{ hsv_rgb_axis.g[0], hsv_rgb_axis.g[1] };
    const r2 = sphmath.Vec2{ hsv_rgb_axis.r[0], hsv_rgb_axis.r[1] };

    const db = sphmath.dot(center_offs, b2);
    const dr = sphmath.dot(center_offs, r2);
    const dg = sphmath.dot(center_offs, g2);

    if (db > dg and db > dr) return hsv_rgb_axis.b else if (dg > dr) return hsv_rgb_axis.g else return hsv_rgb_axis.r;
}

// Mirror of glsl code below
fn pixelToRgb(lightness: f32, pixel_pos: gui.MousePos, bounds: PixelBBox) Color {
    const uv = sphmath.Vec2{
        (pixel_pos.x - @as(f32, @floatFromInt(bounds.left))) / @as(f32, @floatFromInt(bounds.calcWidth())),
        -(pixel_pos.y - @as(f32, @floatFromInt(bounds.bottom))) / @as(f32, @floatFromInt(bounds.calcWidth())),
    };

    const center_offs = uv * sphmath.Vec2{ 2.0, 2.0 } - sphmath.Vec2{ 1.0, 1.0 };

    const best_axis = bestAxis(center_offs);

    const white_point = hsv_rgb_axis.r + hsv_rgb_axis.g + hsv_rgb_axis.b;
    const white_to_axis = best_axis - white_point;
    const white_to_axis_xy = sphmath.Vec2{ white_to_axis[0], white_to_axis[1] };
    const best_axis_xy = sphmath.Vec2{ best_axis[0], best_axis[1] };
    const best_axis_xy_len = sphmath.length(best_axis_xy);
    const surface_scalar = sphmath.dot(center_offs, sphmath.normalize(white_to_axis_xy) / sphmath.Vec2{ best_axis_xy_len, best_axis_xy_len });
    const surface_z = white_point[2] + surface_scalar * white_to_axis[2];
    const surface_point = sphmath.Vec3{ center_offs[0], center_offs[1], surface_z };

    // Here we diverge from the GLSL code a little bit. In GLSL we want to
    // discard out of bounds items, however we want to snap to the closest edge
    var r = std.math.clamp(sphmath.dot(surface_point, hsv_rgb_axis.r), 0.0, 1.0);
    var g = std.math.clamp(sphmath.dot(surface_point, hsv_rgb_axis.g), 0.0, 1.0);
    var b = std.math.clamp(sphmath.dot(surface_point, hsv_rgb_axis.b), 0.0, 1.0);

    r *= lightness;
    g *= lightness;
    b *= lightness;
    return Color{ .r = r, .g = g, .b = b, .a = 1.0 };
}

const SplitHexagonBounds = struct {
    hexagon: PixelBBox,
    pointer: PixelBBox,
    lightness: PixelBBox,
    preview: PixelBBox,
};

fn splitHexagonBounds(style: Style, bounds: PixelBBox, lightness: f32) SplitHexagonBounds {
    // Bounds should be allocated
    //
    //             lightness
    //               v
    // -------------------
    // |    ___    |   | |
    // |   /   \   |   | |
    // |   \   /   |   |o|< pointer
    // |    ^^^    |   | |
    // |-----------------|
    // | Preview segment |
    // -------------------

    const preview_bounds = PixelBBox{
        .top = bounds.bottom - style.hex_preview_height,
        .bottom = bounds.bottom,
        .left = bounds.left,
        .right = bounds.right,
    };

    var remaining_bounds = bounds;
    remaining_bounds.bottom = preview_bounds.top - style.item_pad;

    const width = remaining_bounds.calcWidth();
    const hexagon_bounds = PixelBBox{
        .left = remaining_bounds.left,
        .right = remaining_bounds.left + remaining_bounds.calcHeight(),
        .top = remaining_bounds.top,
        .bottom = remaining_bounds.bottom,
    };
    std.debug.assert(hexagon_bounds.right < bounds.right);

    remaining_bounds.left = hexagon_bounds.right + style.item_pad;

    const triangle_width = @divTrunc(width, 20);

    const lightness_bounds = PixelBBox{
        .left = remaining_bounds.left,
        .right = bounds.right - style.item_pad - triangle_width,
        .top = remaining_bounds.top + @divTrunc(triangle_width, 2),
        .bottom = remaining_bounds.bottom - @divTrunc(triangle_width, 2),
    };

    var triangle_bounds = PixelBBox{
        .top = remaining_bounds.top,
        .bottom = remaining_bounds.bottom,
        .left = bounds.right - triangle_width,
        .right = bounds.right,
    };

    const total_lightness_range_px: f32 = @floatFromInt(remaining_bounds.calcHeight() - triangle_width);
    const triangle_bottom_offs: i32 = @intFromFloat(total_lightness_range_px * lightness);

    triangle_bounds.bottom = std.math.clamp(
        remaining_bounds.bottom - triangle_bottom_offs,
        remaining_bounds.top + triangle_width,
        remaining_bounds.bottom,
    );
    triangle_bounds.top = triangle_bounds.bottom - triangle_width;

    return .{
        .hexagon = hexagon_bounds,
        .pointer = triangle_bounds,
        .lightness = lightness_bounds,
        .preview = preview_bounds,
    };
}

const HexagonUniform = struct {
    lightness: f32,
    selected_color: sphmath.Vec3,
    transform: sphmath.Mat3x3,
};

const LightnessUniform = struct {
    color: sphmath.Vec3,
    total_size: sphmath.Vec2,
    corner_radius: f32,
    transform: sphmath.Mat3x3,
};

// Why not just use HSV? I don't like the idea of it. Geometrically it doesn't
// make sense to me. We have RGB pixels in our monitor. These are 3 independent
// axis which cap out at a value of 1. How can we possibly display the range of
// colors in a circle? We can because as we rotate through the hues, the
// overall brightness actually goes up. red/green -> yellow is more total
// brightness than either individually
//
// Use a geometrically consistent view of RGB. The way the color picker is
// shown in HSV is nice, however it is deceiving. We will instead use a
// projection of the RGB cube where we are looking down towards the brightest
// corner. All math below is just to project our view onto the 3 surfaces of
// the cube that we can see.
//
// This is probably worse than HSV, but conceptually I like it more :)
pub const hexagon_color_frag = std.fmt.comptimePrint(
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform float lightness;
    \\uniform vec3 selected_color;
    \\
    \\vec3 blue_axis = vec3({d}, {d}, {d});
    \\vec3 red_axis = vec3({d}, {d}, {d});
    \\vec3 green_axis = vec3({d}, {d}, {d});
    \\vec3 white_point = blue_axis + red_axis + green_axis;
    \\
    \\// Mirrored in zig code
    \\vec3 bestAxis(vec2 center_offs) {{
    \\    // Which of the RGB axis are we most aligned with? We'll sample from
    \\    // the quad on that side
    \\    float db = dot(center_offs, blue_axis.xy);
    \\    float dr = dot(center_offs, red_axis.xy);
    \\    float dg = dot(center_offs, green_axis.xy);
    \\
    \\    if (db > dg && db > dr) return blue_axis;
    \\    else if (dg > dr) return green_axis;
    \\    else return red_axis;
    \\}}
    \\
    \\// Mirrored in zig code
    \\void main()
    \\{{
    \\    vec2 center_offs = vec2(uv * 2.0 - 1.0);
    \\
    \\    vec3 best_axis = bestAxis(center_offs);
    \\
    \\    // Imagine we are raycasting from a plane that touches the brightest
    \\    // corner of the cube downwards, where do we hit the surface of the
    \\    // cube?
    \\
    \\    // ______w__v_______
    \\    //      .^. |
    \\    //    .^   ^.
    \\    //   ^.     .^ a
    \\    //     ^. .^
    \\    //       ^
    \\    //
    \\    // We know that point w is at center_offs 0, 0
    \\    // We know that point a is where the axis tip is
    \\    // We have the vector wa and the vector wv
    \\    // Our depth is how much along the surface of our plane
    \\    // we've moved towards a, multiplied by the total depth at a
    \\
    \\    vec3 white_to_axis = best_axis - white_point;
    \\    float surface_scalar = dot(center_offs, normalize(white_to_axis.xy) / length(best_axis.xy));
    \\    float surface_z = white_point.z + surface_scalar * white_to_axis.z;
    \\    vec3 surface_point = vec3(center_offs, surface_z);
    \\
    \\    // We have a point on the surface of the cube, just find it's rgb components
    \\    float r = dot(surface_point, red_axis);
    \\    float g = dot(surface_point, green_axis);
    \\    float b = dot(surface_point, blue_axis);
    \\    // Actually we lied, the point isn't on the surface of the cube, it's
    \\    // on the surface of a pyramid that matches the top of the cube. We
    \\    // just have to bounds check to see if we've left where the pyramid
    \\    // and the cube are the same
    \\    if (b < 0.0 || g < 0.0 || r < 0.0) {{
    \\        discard;
    \\    }} else {{
    \\        fragment = vec4(r * lightness, g * lightness, b * lightness, 1.0);
    \\    }}
    \\
    \\    vec3 scaled_selected_color = selected_color / lightness;
    \\
    \\    // RGB -> UV coordinate
    \\    float white_inner_radius = 0.07;
    \\    float white_outer_radius = 0.085;
    \\    float outer_radius = 0.10;
    \\    vec2 selected_screen_coord = (red_axis * scaled_selected_color.r + green_axis * scaled_selected_color.g + blue_axis * scaled_selected_color.b).xy;
    \\    float selected_color_offs = length(center_offs - selected_screen_coord);
    \\    if (selected_color_offs > white_inner_radius && selected_color_offs < white_outer_radius) {{
    \\        fragment = vec4(1.0, 1.0, 1.0, 1.0);
    \\    }} else if (selected_color_offs >= white_outer_radius && selected_color_offs < outer_radius) {{
    \\        fragment = vec4(0.0, 0.0, 0.0, 1.0);
    \\    }}
    \\}}
, .{
    hsv_rgb_axis.b[0],
    hsv_rgb_axis.b[1],
    hsv_rgb_axis.b[2],
    hsv_rgb_axis.r[0],
    hsv_rgb_axis.r[1],
    hsv_rgb_axis.r[2],
    hsv_rgb_axis.g[0],
    hsv_rgb_axis.g[1],
    hsv_rgb_axis.g[2],
});

const lightness_slider_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\uniform vec2 total_size;
    \\uniform float corner_radius;
    \\
    \\bool inCorner(vec2 corner_coord) {
    \\    bool x_out = corner_coord.x >= total_size.x - corner_radius;
    \\    bool y_out = corner_coord.y >= total_size.y - corner_radius;
    \\    return x_out && y_out;
    \\}
    \\
    \\void main()
    \\{
    \\    vec2 pixel_coord = uv * total_size;
    \\    vec2 corner_coord = (abs(uv - 0.5) + 0.5) * total_size;
    \\    if (inCorner(corner_coord)) {
    \\        vec2 rel_0 = corner_coord - total_size + corner_radius;
    \\        if (rel_0.x * rel_0.x + rel_0.y * rel_0.y > corner_radius * corner_radius) discard;
    \\    }
    \\
    \\    fragment = vec4(color * uv.y, 1.0);
    \\}
;

fn hexagonHeight(style: Style) u31 {
    return @intCast(@divTrunc(
        @as(i32, @intCast(style.popup_width)) * 17,
        20,
    ));
}

fn hexAreaBounds(style: Style, bounds: PixelBBox) PixelBBox {
    return .{
        .top = bounds.top,
        .bottom = bounds.top + hexagonHeight(style) + style.item_pad + style.hex_preview_height,
        .left = bounds.left,
        .right = bounds.right,
    };
}

fn sliderRowBounds(style: Style, bounds: PixelBBox) [3]PixelBBox {
    const pad: i32 = style.item_pad;
    const slider_h: i32 = style.slider_height;
    const hex_h: i32 = hexagonHeight(style);
    var result: [3]PixelBBox = undefined;
    for (0..3) |i| {
        const top = bounds.top + hex_h + pad + style.hex_preview_height + pad + @as(i32, @intCast(i)) * (slider_h + pad);
        result[i] = .{
            .top = top,
            .bottom = top + slider_h,
            .left = bounds.left,
            .right = bounds.right,
        };
    }
    return result;
}

/// The graphical part of the color picker overlay. Note that this includes the
/// lightness slider, which may be confusing. A more natural name to me is
/// ColorPicker, but that's already used to refer to the widget as a whole
const ColorHexagon = struct {
    color: *Color,
    event_queue: *gui.EventQueue,
    on_change: usize,
    shared: *const Shared,
    r_label: *Label,
    g_label: *Label,
    b_label: *Label,
    r_drag: Drag,
    g_drag: Drag,
    b_drag: Drag,
    widget: Widget,

    fn initPinned(self: *ColorHexagon, alloc: gui.GuiAlloc, color: *Color, event_queue: *gui.EventQueue, on_change: usize, shared: *const Shared) !void {
        self.color = color;
        self.event_queue = event_queue;
        self.on_change = on_change;
        self.shared = shared;

        self.r_label = try alloc.heap.arena().create(Label);
        self.r_label.* = try Label.init(alloc, shared.label_shared, "R: 1.00", .white);
        self.g_label = try alloc.heap.arena().create(Label);
        self.g_label.* = try Label.init(alloc, shared.label_shared, "G: 1.00", .white);
        self.b_label = try alloc.heap.arena().create(Label);
        self.b_label.* = try Label.init(alloc, shared.label_shared, "B: 1.00", .white);

        self.r_drag = Drag.init(&self.r_label.widget, on_change, shared.drag_shared);
        self.g_drag = Drag.init(&self.g_label.widget, on_change, shared.drag_shared);
        self.b_drag = Drag.init(&self.b_label.widget, on_change, shared.drag_shared);

        self.widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = hexUpdate,
                .input = hexInput,
                .render = hexRender,
                .reset = null,
            },
        };
    }

    fn hexUpdate(widget: *Widget, _: PixelSize, delta_s: f32) !void {
        const self: *ColorHexagon = @fieldParentPtr("widget", widget);
        const style = self.shared.style;
        const hex_h = hexagonHeight(style);
        const pad = style.item_pad;
        const slider_h = style.slider_height;
        widget.size = .{
            .width = style.popup_width,
            .height = hex_h + pad + style.hex_preview_height + 3 * (pad + slider_h),
        };

        var buf: [16]u8 = undefined;
        const color = self.color.*;
        try self.r_label.setText(std.fmt.bufPrint(&buf, "R: {d:.2}", .{color.r}) catch "R: ?");
        try self.g_label.setText(std.fmt.bufPrint(&buf, "G: {d:.2}", .{color.g}) catch "G: ?");
        try self.b_label.setText(std.fmt.bufPrint(&buf, "B: {d:.2}", .{color.b}) catch "B: ?");

        const drag_size = PixelSize{ .width = style.popup_width, .height = slider_h };
        try self.r_drag.widget.update(drag_size, delta_s);
        try self.g_drag.widget.update(drag_size, delta_s);
        try self.b_drag.widget.update(drag_size, delta_s);
    }

    fn hexInput(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
        const self: *ColorHexagon = @fieldParentPtr("widget", widget);
        const current_lightness = calcLightness(self.color.*);
        const split = splitHexagonBounds(self.shared.style, hexAreaBounds(self.shared.style, widget_bounds), current_lightness);

        const hex_input = input_bounds.calcIntersection(split.hexagon);
        if (hex_input.containsOptMousePos(input_state.mouse_down_location)) {
            self.color.* = pixelToRgb(current_lightness, input_state.mouse_pos, split.hexagon);
            try self.event_queue.appendBounded(self.on_change);
        }

        const lightness_input = split.lightness.calcUnion(split.pointer).calcIntersection(input_bounds);
        if (lightness_input.containsOptMousePos(input_state.mouse_down_location)) {
            const height_f: f32 = @floatFromInt(lightness_input.calcHeight());
            const bottom_f: f32 = @floatFromInt(lightness_input.bottom);
            const new_lightness = std.math.clamp(
                (bottom_f - input_state.mouse_pos.y) / height_f,
                0.0,
                1.0,
            );

            const eps = 1e-7;
            var color = self.color.*;

            if (current_lightness < eps) {
                color.r = new_lightness;
                color.g = new_lightness;
                color.b = new_lightness;
            } else {
                const ratio = new_lightness / current_lightness;
                color.r *= ratio;
                color.g *= ratio;
                color.b *= ratio;
            }

            self.color.* = color;
            try self.event_queue.appendBounded(self.on_change);
        }

        // RGB sliders
        const drag_scale = 1.0 / @as(f32, @floatFromInt(self.shared.style.popup_width));
        const slider_rows = sliderRowBounds(self.shared.style, widget_bounds);

        try self.r_drag.widget.input(slider_rows[0], slider_rows[0].calcIntersection(input_bounds), input_state);
        self.color.r = std.math.clamp(self.color.r + self.r_drag.takeDrag() * drag_scale, 0, 1);

        try self.g_drag.widget.input(slider_rows[1], slider_rows[1].calcIntersection(input_bounds), input_state);
        self.color.g = std.math.clamp(self.color.g + self.g_drag.takeDrag() * drag_scale, 0, 1);

        try self.b_drag.widget.input(slider_rows[2], slider_rows[2].calcIntersection(input_bounds), input_state);
        self.color.b = std.math.clamp(self.color.b + self.b_drag.takeDrag() * drag_scale, 0, 1);
    }

    fn hexRender(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
        const self: *ColorHexagon = @fieldParentPtr("widget", widget);
        const color = self.color.*;
        const lightness = calcLightness(color);

        const eps = 1e-7;
        const max_brightness_color: Color = if (lightness < eps)
            .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
        else
            .{
                .r = color.r / lightness,
                .g = color.g / lightness,
                .b = color.b / lightness,
                .a = 1.0,
            };

        const split = splitHexagonBounds(self.shared.style, hexAreaBounds(self.shared.style, bounds), lightness);

        {
            const transform = util.widgetToClipTransform(split.hexagon, window);
            self.shared.hexagon_renderer.render(self.shared.hexagon_render_source, .{
                .lightness = lightness,
                .selected_color = .{ color.r, color.g, color.b },
                .transform = transform.inner,
            });
        }

        {
            const transform = util.widgetToClipTransform(split.lightness, window);
            self.shared.lightness_renderer.render(self.shared.lightness_render_source, .{
                .color = .{ max_brightness_color.r, max_brightness_color.g, max_brightness_color.b },
                .total_size = .{
                    @floatFromInt(split.lightness.calcWidth()),
                    @floatFromInt(split.lightness.calcHeight()),
                },
                .corner_radius = self.shared.style.corner_radius,
                .transform = transform.inner,
            });
        }

        {
            const transform = util.widgetToClipTransform(split.pointer, window);
            self.shared.squircle_renderer.render(
                .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                @floatFromInt(split.pointer.calcWidth() / 2),
                split.pointer,
                transform,
            );
        }

        {
            const transform = util.widgetToClipTransform(split.preview, window);
            self.shared.squircle_renderer.render(
                color,
                self.shared.style.corner_radius,
                split.preview,
                transform,
            );
        }

        const slider_rows = sliderRowBounds(self.shared.style, bounds);
        self.r_drag.widget.render(slider_rows[0], window);
        self.g_drag.widget.render(slider_rows[1], window);
        self.b_drag.widget.render(slider_rows[2], window);
    }
};
