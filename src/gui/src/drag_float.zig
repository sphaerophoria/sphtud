const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const label_mod = @import("label.zig");
const button = @import("button.zig");
const SquircleRenderer = @import("SquircleRenderer.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Color = gui.Color;
const Widget = gui.Widget;
const InputState = gui.InputState;

pub const Shared = struct {
    style: Style,
    guitext_state: *const gui.gui_text.SharedState,
    squircle_renderer: *const SquircleRenderer,
};

pub const Style = struct {
    size: PixelSize,
    default_color: Color,
    hover_color: Color,
    active_color: Color,
    corner_radius: f32,
};

pub fn dragFloat(comptime Action: type, alloc: gui.GuiAlloc, val_retriever: anytype, on_drag: anytype, drag_speed: f32, shared: *const Shared) !Widget(Action) {
    const T = DragFloat(Action, @TypeOf(val_retriever), @TypeOf(on_drag));

    const ctx = try alloc.heap.arena().create(T);

    const gui_text = try gui.gui_text.guiText(
        alloc,
        shared.guitext_state,
        LabelAdaptor(@TypeOf(val_retriever)){ .val_retriever = val_retriever },
    );

    ctx.* = .{
        .val_retriever = val_retriever,
        .gui_text = gui_text,
        .on_drag = on_drag,
        .shared = shared,
        .drag_speed = drag_speed,
    };

    return .{
        .vtable = &T.widget_vtable,
        .ctx = ctx,
    };
}

pub fn DragFloat(comptime Action: type, comptime ValRetriever: type, comptime ActionGenerator: type) type {
    return struct {
        val_retriever: ValRetriever,
        gui_text: gui.gui_text.GuiText(LabelAdaptor(ValRetriever)),
        drag_speed: f32,
        on_drag: ActionGenerator,
        shared: *const Shared,
        state: union(enum) {
            default,
            hovered,
            dragging: f32,
        } = .default,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const color = switch (self.state) {
                .dragging => self.shared.style.active_color,
                .hovered => self.shared.style.hover_color,
                .default => self.shared.style.default_color,
            };

            const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
            self.shared.squircle_renderer.render(color, self.shared.style.corner_radius, widget_bounds, transform);

            const label_bounds = util.centerBoxInBounds(self.gui_text.size(), widget_bounds);
            const label_transform = util.widgetToClipTransform(label_bounds, window_bounds);
            self.gui_text.render(label_transform);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.shared.style.size;
        }

        pub fn update(ctx: ?*anyopaque, _: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Float label content should be sized so that it doesn't exceed
            // the bounds of the widget. Wrapping the text would just go out of
            // bounds anyways... Pretend we have infinite space
            try self.gui_text.update(std.math.maxInt(u31));
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?Action = null;

            if (input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                if (self.state != .dragging) {
                    self.state = .{ .dragging = getVal(&self.val_retriever) };
                }

                const offs = input_state.mouse_pos.x - input_state.mouse_down_location.?.x;

                const start_val = self.state.dragging;
                ret = generateAction(Action, &self.on_drag, start_val + offs * self.drag_speed);
            } else if (input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.state = .hovered;
            } else {
                self.state = .default;
            }

            return .{
                .wants_focus = false,
                .action = ret,
            };
        }
    };
}

pub fn LabelAdaptor(comptime Retriever: type) type {
    return struct {
        val_retriever: Retriever,
        buf: [10]u8 = undefined,

        pub fn getText(self: *@This()) []const u8 {
            const text = std.fmt.bufPrint(&self.buf, "{d:.03}", .{getVal(&self.val_retriever)}) catch return "";
            return text;
        }
    };
}

fn generateAction(comptime Action: type, action_generator: anytype, val: f32) Action {
    const Ptr = @TypeOf(action_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "generate")) {
                return action_generator.generate(val);
            }
        },
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return action_generator.*(val);
                },
                else => {},
            }
        },
        else => {},
    }
}

fn getVal(val_retreiver: anytype) f32 {
    const Ptr = @TypeOf(val_retreiver);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "getVal")) {
                return val_retreiver.getVal();
            }
        },
        .Pointer => |p| {
            if (p.child == f32) {
                return val_retreiver.*.*;
            }
        },
        .Float => |f| {
            if (f.bits == 32) {
                return val_retreiver.*;
            }
        },
        else => {},
    }

    @compileError("val_retreiver must be a f32 or a struct with a getVal() method that returns an f32. Instead it is " ++ @typeName(T));
}
