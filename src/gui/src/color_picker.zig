const std = @import("std");
const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const util = @import("util.zig");
const Widget = gui.Widget;
const Layout = gui.layout.Layout;
const MousePos = gui.MousePos;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const PopupLayer = gui.popup_layer.PopupLayer;
const Color = gui.Color;
const PlaneRenderProgram = sphrender.PlaneRenderProgram;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const ColorStyle = struct {
    preview_width: u31,
    preview_height: u31,
    popup_width: u31,
    popup_background: Color,
    corner_radius: f32,
    item_pad: u31,
};

pub const SharedColorPickerState = struct {
    style: ColorStyle,
    hexagon_renderer: PlaneRenderProgram,
    vertex_buffer: PlaneRenderProgram.Buffer,
    lightness_renderer: PlaneRenderProgram,
    drag_shared: *const gui.drag_float.Shared,
    guitext_state: *const gui.gui_text.SharedState,
    squircle_renderer: *const SquircleRenderer,
    frame: *const gui.frame.Shared,
    property_list_style: *const gui.property_list.Style,

    pub fn init(
        alloc: Allocator,
        style: ColorStyle,
        drag_shared: *const gui.drag_float.Shared,
        guitext_state: *const gui.gui_text.SharedState,
        squircle_renderer: *const SquircleRenderer,
        frame_shared: *const gui.frame.Shared,
        property_list_style: *const gui.property_list.Style,
    ) !SharedColorPickerState {
        const hexagon_renderer = try PlaneRenderProgram.init(
            alloc,
            sphrender.plane_vertex_shader,
            hexagon_color_frag,
            ColorUniformIndex,
        );
        errdefer hexagon_renderer.deinit(alloc);

        const buffer = hexagon_renderer.makeDefaultBuffer();

        const lightness_renderer = try PlaneRenderProgram.init(
            alloc,
            sphrender.plane_vertex_shader,
            lightness_slider_frag,
            LightnessUniformIndex,
        );

        return .{
            .style = style,
            .hexagon_renderer = hexagon_renderer,
            .vertex_buffer = buffer,
            .drag_shared = drag_shared,
            .lightness_renderer = lightness_renderer,
            .guitext_state = guitext_state,
            .squircle_renderer = squircle_renderer,
            .frame = frame_shared,
            .property_list_style = property_list_style,
        };
    }

    pub fn deinit(self: *SharedColorPickerState, alloc: Allocator) void {
        self.hexagon_renderer.deinit(alloc);
        self.vertex_buffer.deinit();
        self.lightness_renderer.deinit(alloc);
    }
};

pub fn ColorPicker(comptime Action: type, comptime ColorRetriever: type, comptime ColorGenerator: type) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        color_retriever: ColorRetriever,
        color_generator: ColorGenerator,
        overlay: *PopupLayer(Action),
        shared: *const SharedColorPickerState,

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = null,
            .setFocused = null,
            .reset = null,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.shared.style.preview_width,
                .height = self.shared.style.preview_height,
            };
        }

        fn generateOverlayWidget(self: Self) !Widget(Action) {
            const layout = try Layout(Action).init(self.alloc, self.shared.style.item_pad);
            errdefer layout.deinit(self.alloc);

            const title = try gui.label.makeLabel(Action, self.alloc, "Color picker", self.shared.guitext_state);
            try layout.pushOrDeinitWidget(self.alloc, title);

            const picker = try makeHexagon(Action, self.alloc, self.color_retriever, self.color_generator, self.shared);
            try layout.pushOrDeinitWidget(self.alloc, picker);

            const widget_gen = WidgetGenerator(Action, ColorRetriever, ColorGenerator){
                .alloc = self.alloc,
                .guitext_state = self.shared.guitext_state,
                .squircle_renderer = self.shared.squircle_renderer,
                .shared = self.shared,
                .retriever = self.color_retriever,
                .generator = self.color_generator,
            };

            const property_list = try gui.property_list.PropertyList(Action).init(self.alloc, self.shared.property_list_style);
            const box = blk: {
                errdefer property_list.deinit(self.alloc);

                break :blk try gui.box.box(
                    Action,
                    self.alloc,
                    property_list.asWidget(),
                    .{ .width = self.shared.style.popup_width, .height = 0 },
                    gui.box.FillStyle.fill_height,
                );
            };
            try layout.pushOrDeinitWidget(self.alloc, box);

            {
                const label = try widget_gen.makeLabel("red");
                errdefer label.deinit(self.alloc);

                const drag = try widget_gen.makeRGBDrag("r");
                errdefer drag.deinit(self.alloc);

                try property_list.pushWidgets(self.alloc, label, drag);
            }

            {
                const label = try widget_gen.makeLabel("green");
                errdefer label.deinit(self.alloc);

                const drag = try widget_gen.makeRGBDrag("g");
                errdefer drag.deinit(self.alloc);

                try property_list.pushWidgets(self.alloc, label, drag);
            }

            {
                const label = try widget_gen.makeLabel("blue");
                errdefer label.deinit(self.alloc);

                const drag = try widget_gen.makeRGBDrag("b");
                errdefer drag.deinit(self.alloc);

                try property_list.pushWidgets(self.alloc, label, drag);
            }

            return try gui.frame.makeFrame(Action, self.alloc, .{
                .inner = layout.asWidget(),
                .shared = self.shared.frame,
            });
        }

        fn makeOverlayStack(self: *Self) !Widget(Action) {
            const stack = try gui.stack.Stack(Action).init(self.alloc);
            errdefer stack.deinit(self.alloc);

            const rect = try gui.rect.Rect(Action).init(
                self.alloc,
                self.shared.style.corner_radius,
                self.shared.style.popup_background,
                self.shared.squircle_renderer,
            );
            try stack.pushWidgetOrDeinit(self.alloc, rect, .fill);

            const overlay_widget = try self.generateOverlayWidget();
            try stack.pushWidgetOrDeinit(self.alloc, overlay_widget, .centered);

            return stack.asWidget();
        }

        fn spawnOverlay(self: *Self, overlay_pos: MousePos) !void {
            const stack = try self.makeOverlayStack();

            self.overlay.set(
                self.alloc,
                stack,
                @intFromFloat(overlay_pos.x),
                @intFromFloat(overlay_pos.y),
            );
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const ret = gui.InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            if (input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                self.spawnOverlay(input_state.mouse_down_location.?) catch return ret;
            }

            return ret;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window_bounds);
            const color = getColor(&self.color_retriever);

            self.shared.squircle_renderer.render(
                color,
                self.shared.style.corner_radius,
                bounds,
                transform,
            );
        }
    };
}

pub fn makeColorPicker(
    comptime Action: type,
    alloc: Allocator,
    color_retriever: anytype,
    color_generator: anytype,
    shared: *const SharedColorPickerState,
    overlay: *PopupLayer(Action),
) !Widget(Action) {
    const T = ColorPicker(Action, @TypeOf(color_retriever), @TypeOf(color_generator));
    const preview = try alloc.create(T);
    errdefer alloc.destroy(preview);

    preview.* = .{
        .alloc = alloc,
        .color_retriever = color_retriever,
        .color_generator = color_generator,
        .shared = shared,
        .overlay = overlay,
    };

    return .{
        .vtable = &T.widget_vtable,
        .ctx = preview,
    };
}

fn WidgetGenerator(comptime Action: type, comptime ColorRetriever: type, comptime ColorGenerator: type) type {
    return struct {
        alloc: Allocator,
        guitext_state: *const gui.gui_text.SharedState,
        squircle_renderer: *const SquircleRenderer,
        shared: *const SharedColorPickerState,
        retriever: ColorRetriever,
        generator: ColorGenerator,

        const Self = @This();

        fn makeLabel(self: Self, name: []const u8) !Widget(Action) {
            return gui.label.makeLabel(
                Action,
                self.alloc,
                name,
                self.guitext_state,
            );
        }

        fn makeRGBDrag(self: Self, comptime color_field: []const u8) !Widget(Action) {
            const Retriever = struct {
                color_retriever: ColorRetriever,

                pub fn getVal(rself: @This()) f32 {
                    const color = getColor(&rself.color_retriever);
                    return @field(color, color_field);
                }
            };

            const Generator = struct {
                color_retriever: ColorRetriever,
                color_generator: ColorGenerator,

                const Self = @This();

                pub fn generate(gself: @This(), val: f32) Action {
                    var color = getColor(&gself.color_retriever);
                    @field(color, color_field) = val;
                    return generateAction(Action, &gself.color_generator, color);
                }
            };

            return gui.drag_float.dragFloat(
                Action,
                self.alloc,
                Retriever{ .color_retriever = self.retriever },
                Generator{ .color_retriever = self.retriever, .color_generator = self.generator },
                0.01,
                self.shared.drag_shared,
            );
        }
    };
}

fn generateAction(comptime Action: type, color_generator: anytype, color: Color) Action {
    const Ptr = @TypeOf(color_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "generate")) {
                return color_generator.generate(color);
            }
        },
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return color_generator.*(color);
                },
                else => {},
            }
        },
        else => {},
    }
    @compileError("Failed to generate action" ++ @typeName(T));
}

fn calcLightness(color: Color) f32 {
    // You might be tempted to use an average here, but then you can never have
    // maximum lightness that isn't white
    var current_lightness = @max(color.r, color.g);
    current_lightness = @max(current_lightness, color.b);
    return current_lightness;
}

fn getColor(color_retriever: anytype) Color {
    const Ptr = @TypeOf(color_retriever);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "getColor")) {
                return color_retriever.*.getColor();
            }
        },
        .Pointer => {
            return color_retriever.*.*;
        },
        else => {},
    }

    @compileError("Cannot get color from type " ++ @typeName(T));
}

/// The graphical part of the color picker overlay. Note that this includes the
/// lightness slider, which may be confusing. A more natural name to me is
/// ColorPicker, but that's already used to refer to the widget as a whole
fn ColorHexagon(comptime Action: type, comptime ColorRetriever: type, comptime ColorGenerator: type) type {
    return struct {
        const Self = @This();
        color_retriever: ColorRetriever,
        color_generator: ColorGenerator,
        shared: *const SharedColorPickerState,

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = null,
            .setFocused = null,
            .reset = null,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // * Height should be enough for the hexagon plus the preview segment
            // * Hexagon wants to be presented in a square area
            // * Hexagon needs to reserve some room to its right for the lightness/pointer

            const hexagon_width_ratio: [2]i32 = .{ 17, 20 };
            const hexagon_height = @divTrunc(
                self.shared.style.popup_width * hexagon_width_ratio[0],
                hexagon_width_ratio[1],
            );

            // Not ideal, but good enough
            const preview_height = self.shared.drag_shared.style.size.height;

            const widget_height = hexagon_height +
                self.shared.style.item_pad +
                preview_height;

            return .{
                .width = self.shared.style.popup_width,
                .height = @intCast(widget_height),
            };
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *@This() = @ptrCast(@alignCast(ctx));

            const prev_color = getColor(&self.color_retriever);
            const current_lightness = calcLightness(prev_color);

            const split_bounds = splitHexagonBounds(self.shared, widget_bounds, current_lightness);

            const hexagon_input_bounds = input_bounds.calcIntersection(split_bounds.hexagon);
            if (hexagon_input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                const new_color = pixelToRgb(current_lightness, input_state.mouse_pos, split_bounds.hexagon);
                return .{
                    .wants_focus = false,
                    .action = generateAction(Action, &self.color_generator, new_color),
                };
            }

            const lightness_input_bounds = split_bounds.lightness.calcUnion(split_bounds.pointer).calcIntersection(input_bounds);

            if (lightness_input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                const lightness_bounds_height_f: f32 = @floatFromInt(lightness_input_bounds.calcHeight());
                const lightness_bounds_bottom_f: f32 = @floatFromInt(lightness_input_bounds.bottom);
                const mouse_bottom_offs = lightness_bounds_bottom_f - input_state.mouse_pos.y;
                const new_lightness = mouse_bottom_offs / lightness_bounds_height_f;
                var color = getColor(&self.color_retriever);

                const eps = 1e-7;
                const ratio = if (current_lightness < eps)
                    0.0
                else
                    new_lightness / current_lightness;

                color.r *= ratio;
                color.g *= ratio;
                color.b *= ratio;

                if (current_lightness < eps) {
                    color.r = new_lightness;
                    color.g = new_lightness;
                    color.b = new_lightness;
                }

                return .{
                    .wants_focus = false,
                    .action = generateAction(Action, &self.color_generator, color),
                };
            }

            return .{
                .wants_focus = false,
                .action = null,
            };
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const color = getColor(&self.color_retriever);
            const lightness = calcLightness(color);

            const eps = 1e-7;
            const max_brightness_color = if (lightness < eps)
                Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
            else blk: {
                var max_color = color;
                max_color.r /= lightness;
                max_color.g /= lightness;
                max_color.b /= lightness;
                break :blk max_color;
            };

            const split_bounds = splitHexagonBounds(self.shared, bounds, lightness);

            const transform = util.widgetToClipTransform(split_bounds.hexagon, window_bounds);
            self.shared.hexagon_renderer.render(self.shared.vertex_buffer, &.{}, &.{
                .{
                    .idx = ColorUniformIndex.lightness.asIndex(),
                    .val = .{ .float = lightness },
                },
                .{
                    .idx = ColorUniformIndex.selected_color.asIndex(),
                    .val = .{ .float3 = .{ color.r, color.g, color.b } },
                },
                .{
                    .idx = ColorUniformIndex.transform.asIndex(),
                    .val = .{ .mat3x3 = transform.inner },
                },
            });

            const lightness_transform = util.widgetToClipTransform(split_bounds.lightness, window_bounds);
            self.shared.lightness_renderer.render(
                self.shared.vertex_buffer,
                &.{},
                &.{
                    .{
                        .idx = @intFromEnum(LightnessUniformIndex.color),
                        .val = .{ .float3 = .{ max_brightness_color.r, max_brightness_color.g, max_brightness_color.b } },
                    },
                    .{
                        .idx = @intFromEnum(LightnessUniformIndex.total_size),
                        .val = .{
                            .float2 = .{
                                @floatFromInt(split_bounds.lightness.calcWidth()),
                                @floatFromInt(split_bounds.lightness.calcHeight()),
                            },
                        },
                    },
                    .{
                        .idx = @intFromEnum(LightnessUniformIndex.corner_radius),
                        .val = .{ .float = self.shared.style.corner_radius },
                    },
                    .{
                        .idx = @intFromEnum(LightnessUniformIndex.transform),
                        .val = .{ .mat3x3 = lightness_transform.inner },
                    },
                },
            );

            const triangle_transform = util.widgetToClipTransform(split_bounds.pointer, window_bounds);

            self.shared.squircle_renderer.render(
                .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                @floatFromInt(split_bounds.pointer.calcWidth() / 2),
                split_bounds.pointer,
                triangle_transform,
            );

            const preview_transform = util.widgetToClipTransform(split_bounds.preview, window_bounds);
            self.shared.squircle_renderer.render(
                color,
                self.shared.style.corner_radius,
                split_bounds.preview,
                preview_transform,
            );
        }
    };
}

fn makeHexagon(comptime Action: type, alloc: Allocator, color_retriever: anytype, color_generator: anytype, shared: *const SharedColorPickerState) !Widget(Action) {
    const T = ColorHexagon(Action, @TypeOf(color_retriever), @TypeOf(color_generator));
    const ctx = try alloc.create(T);
    errdefer alloc.destroy(ctx);

    ctx.* = .{
        .color_retriever = color_retriever,
        .color_generator = color_generator,
        .shared = shared,
    };

    return .{
        .vtable = &T.widget_vtable,
        .ctx = ctx,
    };
}

const SplitHexagonBounds = struct {
    hexagon: PixelBBox,
    pointer: PixelBBox,
    lightness: PixelBBox,
    preview: PixelBBox,
};

fn splitHexagonBounds(shared: *const SharedColorPickerState, bounds: PixelBBox, lightness: f32) SplitHexagonBounds {
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
        .top = bounds.bottom - shared.drag_shared.style.size.height,
        .bottom = bounds.bottom,
        .left = bounds.left,
        .right = bounds.right,
    };

    var remaining_bounds = bounds;
    remaining_bounds.bottom = preview_bounds.top - shared.style.item_pad;

    const width = remaining_bounds.calcWidth();
    const hexagon_bounds = PixelBBox{
        .left = remaining_bounds.left,
        .right = remaining_bounds.left + remaining_bounds.calcHeight(),
        .top = remaining_bounds.top,
        .bottom = remaining_bounds.bottom,
    };
    std.debug.assert(hexagon_bounds.right < bounds.right);

    remaining_bounds.left = hexagon_bounds.right + shared.style.item_pad;

    const triangle_width = @divTrunc(width, 20);

    const lightness_bounds = PixelBBox{
        .left = remaining_bounds.left,
        .right = bounds.right - shared.style.item_pad - triangle_width,
        .top = remaining_bounds.top + @divTrunc(triangle_width, 2),
        .bottom = remaining_bounds.bottom - @divTrunc(triangle_width, 2),
    };

    var triangle_bounds = PixelBBox{
        .top = remaining_bounds.top,
        .bottom = remaining_bounds.bottom,
        .left = remaining_bounds.right - triangle_width,
        .right = remaining_bounds.right,
    };
    triangle_bounds.left = bounds.right - triangle_width;

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
fn pixelToRgb(lightness: f32, pixel_pos: MousePos, bounds: PixelBBox) Color {
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

    var r = sphmath.dot(surface_point, hsv_rgb_axis.r);
    var g = sphmath.dot(surface_point, hsv_rgb_axis.g);
    var b = sphmath.dot(surface_point, hsv_rgb_axis.b);

    // Here we diverge from the GLSL code a little bit. In GLSL we want to
    // discard out of bounds items, however we want to snap to the closest edge
    r = std.math.clamp(r, 0.0, 1.0);
    g = std.math.clamp(g, 0.0, 1.0);
    b = std.math.clamp(b, 0.0, 1.0);

    r *= lightness;
    g *= lightness;
    b *= lightness;
    return Color{ .r = r, .g = g, .b = b, .a = 1.0 };
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

const ColorUniformIndex = enum {
    lightness,
    selected_color,
    transform,

    pub fn asIndex(self: ColorUniformIndex) usize {
        return @intFromEnum(self);
    }
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
    \\
    \\
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

const LightnessUniformIndex = enum {
    color,
    total_size,
    corner_radius,
    transform,
};
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
