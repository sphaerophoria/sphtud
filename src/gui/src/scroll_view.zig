const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const Scrollbar = gui.scrollbar.Scrollbar;
const SquircleRenderer = @import("SquircleRenderer.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub fn ScrollView(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        size: PixelSize,

        scrollbar_present: bool = false,
        scroll_offs: i32 = 0,
        scrollbar: Scrollbar,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        pub fn init(
            alloc: Allocator,
            inner: Widget(Action),
            scrollbar_style: *const gui.scrollbar.Style,
            squircle_renderer: *const SquircleRenderer,
        ) !Widget(Action) {
            const view = try alloc.create(Self);

            view.* = .{
                .inner = inner,
                .scrollbar = .{
                    .renderer = squircle_renderer,
                    .style = scrollbar_style,
                },
                .size = inner.getSize(),
            };
            return .{
                .ctx = view,
                .vtable = &widget_vtable,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.inner.deinit(alloc);
            alloc.destroy(self);
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // We cannot know if the layout requires a scrollbar without
            // actually executing a layout. Try layout with the current scroll
            // state, and re-layout if the state is wrong
            const scrollbar_options = [2]bool{
                self.scrollbar_present,
                !self.scrollbar_present,
            };

            for (scrollbar_options) |scrollbar_present| {
                self.scrollbar_present = scrollbar_present;

                const adjusted_window_size = .{
                    .width = available_size.width - self.scrollbarWidth(),
                    .height = available_size.height,
                };
                try self.inner.update(adjusted_window_size);

                // If we update and the scrollbar is in the wrong state, flip it
                if (scrollbarInWrongState(
                    available_size.height,
                    self.contentHeight(),
                    self.scrollbar_present,
                )) {
                    continue;
                }

                break;
            }

            self.size = available_size;
            self.clampScrollOffs();

            self.scrollbar.handle_ratio =
                @as(f32, @floatFromInt(available_size.height)) /
                @as(f32, @floatFromInt(self.contentHeight()));

            self.scrollbar.top_offs_ratio =
                @as(f32, @floatFromInt(self.scroll_offs)) /
                @as(f32, @floatFromInt(self.contentHeight()));
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const new_scroll_ratio = self.scrollbar.handleInput(
                input_state,
                scrollAreaBounds(self.scrollbar, bounds),
            );

            if (new_scroll_ratio) |scroll_loc| {
                const content_height: f32 = @floatFromInt(self.contentHeight());
                self.scroll_offs = @intFromFloat(content_height * scroll_loc);
            }

            if (input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.scroll_offs -= @intFromFloat(input_state.frame_scroll * 15);
            }

            self.clampScrollOffs();

            const widget_bounds = self.innerBounds(bounds);
            return self.inner.setInputState(
                widget_bounds,
                widget_bounds.calcIntersection(input_bounds),
                input_state,
            );
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            {
                // Child widgets do not attempt to keep themselves in their
                // bounds. For most cases this is fine, however if we have a
                // scrollview as part of a layout, we need to ensure that our
                // child does not poke out the top or bottom of our scroll
                const scissor = sphrender.TemporaryScissor.init();
                defer scissor.reset();

                const child_bounds = self.innerBounds(bounds);
                const scissor_bounds = child_bounds.calcIntersection(bounds);
                scissor.set(
                    scissor_bounds.left,
                    window_bounds.bottom - scissor_bounds.bottom,
                    scissor_bounds.calcWidth(),
                    scissor_bounds.calcHeight(),
                );
                self.inner.render(child_bounds, window_bounds);
            }

            if (self.scrollbar_present) {
                self.scrollbar.render(
                    scrollAreaBounds(self.scrollbar, bounds),
                    window_bounds,
                );
            }
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.scroll_offs = 0;
            self.inner.reset();
        }

        fn innerBounds(self: Self, bounds: PixelBBox) PixelBBox {
            const top = bounds.top - self.scroll_offs;
            const left = bounds.left;
            const layout_size = self.inner.getSize();
            return .{
                .top = top,
                .left = left,
                .right = left + layout_size.width,
                .bottom = top + layout_size.height,
            };
        }

        fn contentHeight(self: Self) u31 {
            return self.inner.getSize().height;
        }

        fn scrollbarWidth(self: Self) u31 {
            if (self.scrollbar_present) {
                return self.scrollbar.style.width;
            } else {
                return 0;
            }
        }

        fn clampScrollOffs(self: *Self) void {
            self.scroll_offs = std.math.clamp(
                self.scroll_offs,
                0,
                self.contentHeight() -| self.size.height,
            );
        }
    };
}

fn scrollAreaBounds(scrollbar: Scrollbar, bounds: PixelBBox) PixelBBox {
    return .{
        .left = bounds.right - scrollbar.style.width,
        .right = bounds.right,
        .top = bounds.top,
        .bottom = bounds.bottom,
    };
}

fn scrollbarMissing(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) and !scrollbar_present;
}

fn scrollbarInWrongState(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) != scrollbar_present;
}
