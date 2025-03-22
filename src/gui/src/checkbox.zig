const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;
const InputResponse = gui.InputResponse;
const SquircleRenderer = @import("SquircleRenderer.zig");
const Color = gui.Color;

pub const Style = struct {
    outer_size: u31,
    inner_size: u31,
    outer_color: Color,
    inner_color: Color,
    outer_hover_color: Color,
    inner_hover_color: Color,
    corner_radius: f32,
};

pub const Shared = struct {
    squircle_renderer: *const SquircleRenderer,
    style: Style,
};

pub fn makeCheckbox(comptime Action: type, alloc: Allocator, checked: anytype, on_change: Action, shared: *const Shared) !Widget(Action) {
    const T = Checkbox(Action, @TypeOf(checked));

    const ctx = try alloc.create(T);

    ctx.* = .{
        .checked = checked,
        .on_change = on_change,
        .shared = shared,
    };

    return .{
        .ctx = ctx,
        .name = "checkbox",
        .vtable = &T.vtable,
    };
}

pub fn Checkbox(comptime Action: type, comptime Checked: type) type {
    return struct {
        checked: Checked,
        on_change: Action,
        shared: *const Shared,
        hovered: bool = false,

        const Self = @This();
        const vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = null,
            .setInputState = Self.setInputState,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const outer_color = if (self.hovered)
                self.shared.style.outer_hover_color
            else
                self.shared.style.outer_color;

            const outer_bounds = checkboxBounds(widget_bounds, self.shared.style.outer_size);
            const outer_transform = util.widgetToClipTransform(outer_bounds, window_bounds);
            self.shared.squircle_renderer.render(
                outer_color,
                self.shared.style.corner_radius,
                outer_bounds,
                outer_transform,
            );

            if (getChecked(&self.checked)) {
                const inner_color = if (self.hovered)
                    self.shared.style.inner_hover_color
                else
                    self.shared.style.inner_color;

                const inner_bounds = innerBounds(
                    widget_bounds,
                    self.shared.style.outer_size,
                    self.shared.style.inner_size,
                );
                const inner_transform = util.widgetToClipTransform(inner_bounds, window_bounds);
                self.shared.squircle_renderer.render(
                    inner_color,
                    self.shared.style.corner_radius,
                    inner_bounds,
                    inner_transform,
                );
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .width = self.shared.style.outer_size,
                .height = self.shared.style.outer_size,
            };
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var ret = InputResponse(Action){};
            if (input_bounds.containsOptMousePos(input_state.mouse_down_location) and input_state.mouse_pressed) {
                ret.action = self.on_change;
            }

            if (input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.hovered = true;
            } else {
                self.hovered = false;
            }

            return ret;
        }
    };
}

fn checkboxBounds(widget_bounds: PixelBBox, size: u31) PixelBBox {
    return .{
        .top = widget_bounds.top,
        .left = widget_bounds.left,
        .right = widget_bounds.left + size,
        .bottom = widget_bounds.top + size,
    };
}

fn innerBounds(widget_bounds: PixelBBox, outer_size: u31, inner_size: u31) PixelBBox {
    const offs = (outer_size - inner_size) / 2;
    return .{
        .top = widget_bounds.top + offs,
        .left = widget_bounds.left + offs,
        .right = widget_bounds.right - offs,
        .bottom = widget_bounds.bottom - offs,
    };
}

fn getChecked(retriever: anytype) bool {
    const Ptr = @TypeOf(retriever);
    const T = @typeInfo(Ptr).pointer.child;

    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "checked")) {
                return retriever.checked();
            }
        },
        .pointer => |p| {
            if (p.child == bool and p.size == .one) {
                return retriever.*.*;
            }
        },
        else => {},
    }

    @compileError("Checked retriever must be a bool or have a checked() function, type is " ++ @typeName(T));
}
