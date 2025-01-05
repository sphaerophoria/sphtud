const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const util = @import("util.zig");
const Color = gui.Color;
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputResponse = gui.InputResponse;
const InputState = gui.InputState;
const PopupLayer = gui.popup_layer.PopupLayer;
const GuiText = gui.gui_text.GuiText;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const Style = struct {
    background: Color,
    hover_background: Color,
    click_background: Color,
    popup_background: Color,
    corner_radius: f32,
    box_width: u31,
    box_height: u31,
    triangle_width: u31,
    triangle_height: u31,
    triangle_color: Color,
    popup_width: u31,
    popup_height: u31,
    layout_pad: u31,
};

pub const Shared = struct {
    style: Style,
    triangle_program: sphrender.PlaneRenderProgram,
    triangle_buf: sphrender.PlaneRenderProgram.Buffer,
    guitext_state: *const gui.gui_text.SharedState,
    squircle_renderer: *const SquircleRenderer,
    selectable: *const gui.selectable_list.SharedState,
    scroll_style: *const gui.scrollbar.Style,
    frame: *const gui.frame.Shared,

    const Options = struct {
        style: Style,
        guitext_state: *const gui.gui_text.SharedState,
        squircle_renderer: *const SquircleRenderer,
        selectable: *const gui.selectable_list.SharedState,
        scroll_style: *const gui.scrollbar.Style,
        frame: *const gui.frame.Shared,
    };

    pub fn init(alloc: Allocator, options: Options) !Shared {
        const triangle_program = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, solid_color_fragment_shader, SolidColorIdx);
        errdefer triangle_program.deinit(alloc);

        var triangle_buf = triangle_program.makeDefaultBuffer();
        errdefer triangle_buf.deinit();
        triangle_buf.updateBuffer(&.{
            // Make a triangle that is pointing down and taking up the full
            // clip space
            //
            // UV coords aren't used, we could just use a different vertex
            // shader, but whatever
            .{ .uv_x = 0.0, .uv_y = 0.0, .clip_x = -1.0, .clip_y = 1.0 },
            .{ .uv_x = 0.0, .uv_y = 0.0, .clip_x = 1.0, .clip_y = 1.0 },
            .{ .uv_x = 0.0, .uv_y = 0.0, .clip_x = 0.0, .clip_y = -1.0 },
        });

        return .{
            .triangle_program = triangle_program,
            .triangle_buf = triangle_buf,
            .style = options.style,
            .guitext_state = options.guitext_state,
            .squircle_renderer = options.squircle_renderer,
            .selectable = options.selectable,
            .scroll_style = options.scroll_style,
            .frame = options.frame,
        };
    }

    pub fn deinit(self: *Shared, alloc: Allocator) void {
        self.triangle_buf.deinit();
        self.triangle_program.deinit(alloc);
    }
};

pub fn makeComboBox(comptime Action: type, alloc: Allocator, retriever: anytype, on_select: anytype, popup_layer: *PopupLayer(Action), shared: *const Shared) !Widget(Action) {
    const T = ComboBox(Action, @TypeOf(retriever), @TypeOf(on_select));
    const ctx = try alloc.create(T);
    errdefer alloc.destroy(ctx);

    const gui_text = try gui.gui_text.guiText(alloc, shared.guitext_state, selectedTextRetriever(retriever));
    errdefer gui_text.deinit(alloc);

    ctx.* = .{
        .alloc = alloc,
        .shared = shared,
        .popup_layer = popup_layer,
        .retriever = retriever,
        .gui_text = gui_text,
        .on_select = on_select,
    };

    return .{
        .ctx = ctx,
        .vtable = &T.widget_vtable,
    };
}

pub fn ComboBox(comptime Action: type, comptime ListRetriever: type, comptime ListActionGenerator: type) type {
    return struct {
        alloc: Allocator,
        shared: *const Shared,
        popup_layer: *gui.popup_layer.PopupLayer(Action),
        retriever: ListRetriever,
        on_select: ListActionGenerator,
        gui_text: GuiText(SelectedTextRetriever(ListRetriever)),
        state: enum {
            default,
            hover,
            click,
        } = .default,

        const Self = @This();
        const widget_vtable = gui.Widget(Action).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .reset = null,
            .setFocused = null,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.gui_text.deinit(alloc);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            {
                const color = switch (self.state) {
                    .default => self.shared.style.background,
                    .hover => self.shared.style.hover_background,
                    .click => self.shared.style.click_background,
                };

                const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
                self.shared.squircle_renderer.render(
                    color,
                    self.shared.style.corner_radius,
                    widget_bounds,
                    transform,
                );
            }

            const sub_sizes = SubSizes.calc(self.shared.style);

            {
                const triangle_bounds = sub_sizes.triangleBounds(widget_bounds);
                const transform = util.widgetToClipTransform(triangle_bounds, window_bounds);
                self.shared.triangle_program.render(self.shared.triangle_buf, &.{}, &.{
                    .{
                        .idx = @intFromEnum(SolidColorIdx.color),
                        .val = .{
                            .float3 = .{
                                self.shared.style.triangle_color.r,
                                self.shared.style.triangle_color.g,
                                self.shared.style.triangle_color.b,
                            },
                        },
                    },
                    .{
                        .idx = @intFromEnum(SolidColorIdx.transform),
                        .val = .{ .mat3x3 = transform.inner },
                    },
                });
            }

            {
                const text_bounds = sub_sizes.textBounds(self.gui_text.size(), widget_bounds);
                const transform = util.widgetToClipTransform(text_bounds, window_bounds);
                self.gui_text.render(transform);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const text_size = self.gui_text.size();
            const height = @max(
                self.shared.style.box_height,
                text_size.height + self.shared.style.layout_pad,
            );

            return .{
                .width = self.shared.style.box_width,
                .height = height,
            };
        }

        fn update(ctx: ?*anyopaque, _: PixelSize) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const sub_bounds = SubSizes.calc(self.shared.style);
            try self.gui_text.update(self.alloc, sub_bounds.text_wrap);
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                self.state = .click;
                self.spawnOverlay(input_state.mouse_down_location.?) catch |e| {
                    std.log.err("Failed to spawn overlay: {s}", .{@errorName(e)});
                };
            } else if (input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.state = .hover;
            } else {
                self.state = .default;
            }

            return .{
                .wants_focus = false,
                .action = null,
            };
        }

        fn spawnOverlay(self: *Self, loc: gui.MousePos) !void {
            const stack = try gui.stack.Stack(Action).init(self.alloc);
            errdefer stack.deinit(self.alloc);

            const rect = try gui.rect.Rect(Action).init(
                self.alloc,
                self.shared.style.corner_radius,
                self.shared.style.popup_background,
                self.shared.squircle_renderer,
            );
            try stack.pushWidgetOrDeinit(self.alloc, rect, .fill);

            const frame = blk: {
                const list = try gui.selectable_list.selectableList(
                    Action,
                    self.alloc,
                    self.retriever,
                    self.on_select,
                    self.shared.selectable,
                );
                errdefer list.deinit(self.alloc);

                const frame = try gui.frame.makeFrame(
                    Action,
                    self.alloc,
                    .{
                        .inner = list,
                        .shared = self.shared.frame,
                    },
                );

                break :blk frame;
            };

            const scroll = blk: {
                errdefer frame.deinit(self.alloc);

                break :blk try gui.scroll_view.ScrollView(Action).init(
                    self.alloc,
                    frame,
                    self.shared.scroll_style,
                    self.shared.squircle_renderer,
                );
            };

            const box = blk: {
                errdefer scroll.deinit(self.alloc);

                const height = @min(
                    self.shared.style.popup_height - self.shared.style.layout_pad,
                    frame.getSize().height,
                );

                break :blk try gui.box.box(
                    Action,
                    self.alloc,
                    scroll,
                    .{
                        .width = self.shared.style.popup_width - self.shared.style.layout_pad,
                        .height = height,
                    },
                    .fill_none,
                );
            };

            try stack.pushWidgetOrDeinit(self.alloc, box, .centered);

            self.popup_layer.set(self.alloc, stack.asWidget(), @intFromFloat(loc.x), @intFromFloat(loc.y));
        }
    };
}

const SubSizes = struct {
    text_wrap: u31,
    text_offs: i32,
    triangle: PixelSize,
    triangle_offs_x: i32,
    triangle_offs_y: i32,

    fn calc(style: Style) SubSizes {
        const triangle_right = style.box_width -| style.layout_pad;
        const triangle_left = triangle_right -| style.triangle_width;
        const text_right = triangle_left -| style.layout_pad;
        const text_left = style.layout_pad;

        return .{
            .text_wrap = text_right -| text_left,
            .text_offs = text_left,
            .triangle = .{
                .width = triangle_right - triangle_left,
                .height = style.triangle_height,
            },
            .triangle_offs_x = triangle_left,
            .triangle_offs_y = style.layout_pad,
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
            .bottom = top + self.triangle.height,
            .left = left,
            .right = left + self.triangle.width,
        };
    }
};

fn SelectedTextRetriever(comptime ListRetriever: type) type {
    return struct {
        inner: ListRetriever,

        pub fn getText(self: @This()) []const u8 {
            const selected = self.inner.selectedId();
            if (selected >= self.inner.numItems()) {
                return "none";
            }

            return self.inner.getText(selected);
        }
    };
}

fn selectedTextRetriever(list_retriever: anytype) SelectedTextRetriever(@TypeOf(list_retriever)) {
    return .{
        .inner = list_retriever,
    };
}

const SolidColorIdx = enum {
    color,
    transform,
};

const solid_color_fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;
