const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const label_mod = @import("label.zig");
const Label = label_mod.Label;
const gui = @import("gui.zig");
const SquircleRenderer = @import("SquircleRenderer.zig");
const util = @import("util.zig");
const gui_text = @import("gui_text.zig");
const InputState = gui.InputState;
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub const SharedButtonState = struct {
    squircle_renderer: *const SquircleRenderer,
    text_shared: *const gui_text.SharedState,
    style: ButtonStyle,

    pub fn render(self: SharedButtonState, color: Color, widget_bounds: PixelBBox, transform: sphmath.Transform) void {
        self.squircle_renderer.render(color, self.style.corner_radius, widget_bounds, transform);
    }
};

pub const ButtonStyle = struct {
    default_color: Color,
    hover_color: Color,
    click_color: Color,
    corner_radius: f32 = 20.0,
    width: u31,
    height: u31,
};

pub fn makeButton(
    comptime Action: type,
    alloc: gui.GuiAlloc,
    text_retriever: anytype,
    shared: *const SharedButtonState,
    click_action: anytype,
) !Widget(Action) {
    const label = try label_mod.makeLabel(Action, alloc, text_retriever, shared.text_shared);

    const T = Button(Action, @TypeOf(click_action));
    const button = try alloc.heap.arena().create(T);
    button.* = .{
        .label = label,
        .click_action = click_action,
        .shared = shared,
    };

    return .{
        .vtable = &T.widget_vtable,
        .name = "button",
        .ctx = @ptrCast(button),
    };
}

pub fn Button(comptime Action: type, comptime ActionGenerator: type) type {
    return struct {
        label: Widget(Action),

        click_action: ActionGenerator,

        shared: *const SharedButtonState,

        state: enum {
            none,
            hovered,
            clicked,
        } = .none,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
            .setFocused = null,
            .reset = null,
        };

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.shared.style.width,
                .height = self.shared.style.height,
            };
        }

        fn update(ctx: ?*anyopaque, _: PixelSize, delta_s: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.label.update(
                .{
                    .width = self.shared.style.width,
                    .height = self.shared.style.height,
                },
                delta_s,
            );
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?Action = null;

            const mouse_down_in_box = input_bounds.containsOptMousePos(input_state.mouse_down_location);
            const cursor_in_box = input_bounds.containsMousePos(input_state.mouse_pos);

            if (mouse_down_in_box and cursor_in_box) {
                self.state = .clicked;

                if (input_state.mouse_released) {
                    ret = getAction(Action, &self.click_action);
                }
            } else if (cursor_in_box) {
                self.state = .hovered;
            } else {
                self.state = .none;
            }

            return .{
                .wants_focus = false,
                .action = ret,
            };
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const color = switch (self.state) {
                .none => self.shared.style.default_color,
                .hovered => self.shared.style.hover_color,
                .clicked => self.shared.style.click_color,
            };

            const transform = util.widgetToClipTransform(bounds, window);
            self.shared.render(color, bounds, transform);

            const label_bounds = util.centerBoxInBounds(self.label.getSize(), bounds);
            self.label.render(label_bounds, window);
        }
    };
}

fn getAction(comptime Action: type, generator: anytype) Action {
    const Ptr = @TypeOf(generator);
    const T = @typeInfo(Ptr).pointer.child;

    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "generate")) {
                return generator.generate();
            }
        },
        else => {},
    }

    return generator.*;
}
