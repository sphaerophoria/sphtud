const std = @import("std");
const sphalloc = @import("../alloc.zig");
const sphutil = @import("sphutil");
const gui = @import("../ui.zig");

pub const Shared = struct {
    layout_pad: u31,
    scroll_shared: *const gui.scrollbar.Shared,
};

pub fn scrollList(comptime Action: type, alloc: gui.GuiAlloc, scratch: sphalloc.LinearAllocator, factory: anytype, shared: *const Shared) !gui.Widget(Action) {
    var arena = alloc.heap.arena();

    const Factory = @TypeOf(factory);
    const T = ScrollList(Action, Factory);

    const widget = try arena.create(T);
    widget.* = .{
        .factory = factory,
        .scratch = scratch,
        .first_widget_idx = 0,
        .scroll_anchor = .{
            .screen_ratio = 0.0,
            .item_idx = 0,
            .item_offs = 0,
        },
        .active_widgets = try .init(
            arena,
            alloc.heap.expansion(),
            typical_active_widgets,
            max_active_widgets,
        ),
        .size = .{},
        .scrollbar = .{
            .shared = shared.scroll_shared,
        },
        .shared = shared,
    };

    return .{
        .ctx = widget,
        .name = "scrollable list",
        .vtable = &T.widget_vtable,
    };
}

// 8 seems like a nice typical amount
const typical_active_widgets = 8;
// 10000 widgets on the screen is way more than there are
// pixels, so surely that shouldn't happen very often
const max_active_widgets = 10000;

pub fn ScrollList(comptime Action: type, comptime Factory: type) type {
    return struct {
        scratch: sphalloc.LinearAllocator,
        factory: Factory,

        scrollbar: gui.scrollbar.Scrollbar,
        size: gui.PixelSize,

        active_widgets: ActiveWidgets(Action),
        first_widget_idx: usize,

        // This gets updated in setInputState(), but doesn't apply until the
        // next frame's update()
        scroll_anchor: ScrollAnchor,
        shared: *const Shared,

        const ScrollListSelf = @This();

        const widget_vtable = gui.Widget(Action).VTable{
            .render = render,
            .getSize = getSize,
            .update = update,
            .setInputState = setInputState,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
            const self: *ScrollListSelf = @ptrCast(@alignCast(ctx));

            var it = self.active_widgets.iter();
            while (it.next()) |active_widget| {
                const render_bounds = active_widget.bounds.offset(
                    widget_bounds.left + self.shared.layout_pad,
                    widget_bounds.top + self.shared.layout_pad,
                );
                active_widget.widget.render(render_bounds, window_bounds);
            }

            self.scrollbar.render(scrollAreaBounds(self.scrollbar, widget_bounds), window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) gui.PixelSize {
            const self: *ScrollListSelf = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn getContentSize(self: *ScrollListSelf) gui.PixelSize {
            return .{
                .height = self.size.height - self.shared.layout_pad * 2,
                .width = self.size.width - self.shared.layout_pad * 2 - self.shared.scroll_shared.style.width,
            };
        }

        fn update(ctx: ?*anyopaque, container_size: gui.PixelSize, delta_s: f32) anyerror!void {
            const self: *ScrollListSelf = @ptrCast(@alignCast(ctx));

            self.size = container_size;

            var layout_helper = try LayoutHelper.init(
                self.scratch.allocator(),
                delta_s,
                self,
            );
            try layout_helper.layout();

            self.selectNewAnchor(layout_helper.num_items);

            self.scrollbar.scroll_ratio = calcScrollbarPosition(
                Action,
                self.active_widgets,
                self.first_widget_idx,
                layout_helper.num_items,
                layout_helper.content_size.height,
            );

            // If we change the handle size when the bar is moving, that
            // results in a slight change in position, which can result in a
            // bar size change again. This can cause nasty flickering. Just
            // heal it when we let go
            if (self.scrollbar.scroll_input_state != .dragging) {
                self.scrollbar.handle_ratio = calcHandleRatio(
                    layout_helper.totalHeight(),
                    container_size.height,
                    self.active_widgets.len,
                    layout_helper.num_items,
                );
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) gui.InputResponse(Action) {
            const self: *ScrollListSelf = @ptrCast(@alignCast(ctx));

            if (self.scrollbar.handleInput(
                input_state,
                input_bounds.calcIntersection(scrollAreaBounds(self.scrollbar, widget_bounds)),
            )) |pos| {
                var item_offs: f64 = pos;
                item_offs *= @floatFromInt(self.factory.numItems());

                const item_idx: usize = @intFromFloat(item_offs);
                item_offs = @mod(item_offs, 1.0);

                self.scroll_anchor = .{
                    .item_idx = item_idx,
                    .screen_ratio = pos,
                    .item_offs = @floatCast(item_offs),
                };
            }

            if (input_bounds.containsMousePos(input_state.mouse_pos)) blk: {
                if (self.size.height == 0) break :blk;
                self.scroll_anchor.screen_ratio += input_state.frame_scroll * 15 / @as(f32, @floatFromInt(self.size.height));
                input_state.consumeScroll();
            }

            return .{};
        }

        fn scrollAreaBounds(scrollbar: gui.scrollbar.Scrollbar, bounds: gui.PixelBBox) gui.PixelBBox {
            return .{
                .left = bounds.right - scrollbar.shared.style.width,
                .right = bounds.right,
                .top = bounds.top,
                .bottom = bounds.bottom,
            };
        }

        fn selectNewAnchor(self: *ScrollListSelf, num_items: usize) void {
            const content_size = self.getContentSize();

            if (self.isAtBottom(content_size.height, num_items)) {
                self.scroll_anchor = .{
                    .screen_ratio = 1.0,
                    .item_idx = std.math.maxInt(usize),
                    .item_offs = 1.0,
                };
                return;
            }

            var it = self.active_widgets.iter();
            var i: usize = 0;
            while (it.next()) |elem| {
                defer i += 1;

                if (elem.bounds.top < 0) continue;

                var screen_ratio: f32 = @floatFromInt(elem.bounds.top);
                screen_ratio /= @floatFromInt(content_size.height);

                self.scroll_anchor = .{
                    .item_idx = self.first_widget_idx + i,
                    .item_offs = 0,
                    .screen_ratio = screen_ratio,
                };

                break;
            }
        }

        fn isAtBottom(self: *ScrollListSelf, content_height: u31, num_items: usize) bool {
            if (self.active_widgets.len == 0) return false;
            if (self.first_widget_idx + self.active_widgets.len != num_items) return false;

            const last_elem = self.active_widgets.get(self.active_widgets.len - 1);
            return last_elem.bounds.bottom == content_height;
        }

        const LayoutHelper = struct {
            top_cursor: i32,
            top_idx: usize,

            bottom_cursor: i32,
            bottom_idx: usize,

            expansion: sphutil.ExpansionAlloc,
            anchor_to_top: ActiveWidgetsUnmanaged(Action),
            anchor_to_bottom: ActiveWidgetsUnmanaged(Action),

            num_items: usize,
            delta_s: f32,

            parent: *ScrollListSelf,
            content_size: gui.PixelSize,

            pub fn init(
                alloc: std.mem.Allocator,
                delta_s: f32,
                parent: *ScrollListSelf,
            ) !LayoutHelper {
                const num_items = parent.factory.numItems();
                const content_size = parent.getContentSize();
                const container_height_f: f32 = @floatFromInt(content_size.height);

                var anchor_item_point: f64 = @floatFromInt(parent.scroll_anchor.item_idx);
                anchor_item_point += @floatCast(parent.scroll_anchor.item_offs);

                var anchor_item_id = parent.scroll_anchor.item_idx;
                var anchor_item_offs = @mod(anchor_item_point, 1.0);

                // If we are trying to snap the bottom of the last item to the
                // bottom of the screen, we need to use a valid index and
                // offset it such that we're acting relative to it's bottom,
                // not it's top like for literally every other case
                if (anchor_item_id >= num_items) {
                    anchor_item_id = num_items - 1;
                    anchor_item_offs = 1.0;
                }

                const anchor_px: i32 = @intFromFloat(container_height_f * parent.scroll_anchor.screen_ratio);

                const expansion = sphutil.ExpansionAlloc.linear(alloc);
                var anchor_to_top = try ActiveWidgetsUnmanaged(Action).init(
                    alloc,
                    expansion,
                    @max(parent.active_widgets.len, 8),
                    max_active_widgets,
                );

                const anchor_to_bottom = try ActiveWidgetsUnmanaged(Action).init(
                    alloc,
                    expansion,
                    @max(parent.active_widgets.len, 8),
                    max_active_widgets,
                );

                var top_cursor: i32 = anchor_px;
                var bottom_cursor: i32 = anchor_px;

                var top_idx: usize = 0;
                var bottom_idx: usize = 0;

                if (num_items > 0) {
                    const first_widget = try getWidget(&parent.active_widgets, parent.first_widget_idx, parent.factory, anchor_item_id);

                    const available_above = gui.PixelSize{
                        .height = @max(0, anchor_px),
                        .width = content_size.width,
                    };
                    try first_widget.update(available_above, delta_s);

                    const widget_size = first_widget.getSize();

                    // 100 px tall widget anchored at item_point 0.4 means that we
                    // need the 40th pixel of the widget to line up with the anchor
                    // pixel
                    const top_offs: i32 = @intFromFloat(
                        anchor_item_offs * @as(f64, @floatFromInt(widget_size.height)),
                    );
                    const top = anchor_px - top_offs;

                    const widget_bounds = gui.PixelBBox{
                        .top = top,
                        .bottom = top + widget_size.height,
                        .left = 0,
                        .right = widget_size.width,
                    };

                    try anchor_to_top.append(.linear(alloc), .{
                        .widget = first_widget,
                        .bounds = widget_bounds,
                    });

                    top_cursor = top;
                    bottom_cursor = widget_bounds.bottom;

                    top_idx = anchor_item_id;
                    bottom_idx = anchor_item_id + 1;
                }

                return .{
                    .top_cursor = top_cursor,
                    .top_idx = top_idx,

                    .bottom_cursor = bottom_cursor,
                    .bottom_idx = bottom_idx,

                    .parent = parent,

                    .expansion = expansion,
                    .anchor_to_top = anchor_to_top,
                    .anchor_to_bottom = anchor_to_bottom,

                    .num_items = num_items,
                    .delta_s = delta_s,
                    .content_size = content_size,
                };
            }

            fn layout(self: *LayoutHelper) !void {

                // Down, up, then down again. We want to make sure that if
                // we're scrolled past the bottom or top, we clamp our layout
                // such that we aren't layout out useless stuff.
                //
                // We layout down, then up, so that in cases where we're out of
                // bounds on both sides, sticking to the top takes precedence
                try self.layoutDown();
                try self.snapDown();

                try self.layoutUp();
                try self.snapUp();

                // After snapping up, there may be a little bit more room, so
                // layout down again
                try self.layoutDown();

                try self.releaseUnused();
                try self.commitTempLists();
            }

            fn layoutDown(self: *LayoutHelper) !void {
                while (!self.atBottom()) {
                    try self.layoutNextBelow();
                }
            }

            fn layoutUp(self: *LayoutHelper) !void {
                while (!self.atTop()) {
                    try self.layoutNextAbove();
                }
            }

            fn snapUp(self: *LayoutHelper) !void {
                if (self.top_cursor > 0) {
                    try self.adjustUncommittedYs(-self.top_cursor);
                }
            }

            fn snapDown(self: *LayoutHelper) !void {
                if (self.bottom_cursor < self.content_size.height and self.top_idx != 0) {
                    const dist_from_bottom = self.content_size.height - self.bottom_cursor;
                    try self.adjustUncommittedYs(dist_from_bottom);
                }
            }

            fn atTop(self: *LayoutHelper) bool {
                return self.top_cursor <= 0 or self.top_idx <= 0;
            }

            fn layoutNextAbove(self: *LayoutHelper) !void {
                self.top_idx -= 1;

                const widget = try getWidget(
                    &self.parent.active_widgets,
                    self.parent.first_widget_idx,
                    self.parent.factory,
                    self.top_idx,
                );
                try widget.update(self.availableTop(), self.delta_s);
                const size = widget.getSize();

                // FIXME: On failure we probably have to release the widget back
                try self.anchor_to_top.append(
                    self.expansion,
                    .{
                        .widget = widget,
                        .bounds = .{
                            .top = self.top_cursor - size.height,
                            .bottom = self.top_cursor,
                            .left = 0,
                            .right = size.width,
                        },
                    },
                );

                self.top_cursor -= size.height;
            }

            fn atBottom(self: *LayoutHelper) bool {
                return self.bottom_cursor >= self.content_size.height or self.bottom_idx >= self.num_items;
            }

            fn layoutNextBelow(self: *LayoutHelper) !void {
                const widget = try getWidget(&self.parent.active_widgets, self.parent.first_widget_idx, self.parent.factory, self.bottom_idx);
                try widget.update(self.availableBottom(), self.delta_s);
                const size = widget.getSize();

                try self.anchor_to_bottom.append(
                    self.expansion,
                    .{
                        .widget = widget,
                        .bounds = .{
                            .top = self.bottom_cursor,
                            .bottom = self.bottom_cursor + size.height,
                            .left = 0,
                            .right = size.width,
                        },
                    },
                );

                self.bottom_cursor += size.height;
                self.bottom_idx += 1;
            }

            fn availableTop(self: *LayoutHelper) gui.PixelSize {
                return .{
                    .height = @max(0, self.top_cursor),
                    .width = self.content_size.width,
                };
            }

            fn availableBottom(self: *LayoutHelper) gui.PixelSize {
                return .{
                    .height = @max(0, @as(i32, self.content_size.height) - self.bottom_cursor),
                    .width = self.content_size.width,
                };
            }

            fn releaseUnused(self: *LayoutHelper) !void {
                // First widget idx looks like it's 0, but there technically
                // isn't one. This caused problems at some point, but there's a
                // good chance this check is no longer needed after some other
                // rearranging
                if (self.parent.active_widgets.len == 0) return;

                for (self.parent.first_widget_idx..@max(self.top_idx, self.parent.first_widget_idx)) |widget_idx| {
                    const active_idx = self.widgetToActiveIdx(widget_idx) orelse break;
                    self.parent.factory.destroyWidget(widget_idx, self.parent.active_widgets.get(active_idx).widget);
                }

                const previous_last = self.parent.first_widget_idx + self.parent.active_widgets.len;
                for (self.bottom_idx..@max(previous_last, self.bottom_idx)) |widget_idx| {
                    const active_idx = self.widgetToActiveIdx(widget_idx) orelse break;
                    self.parent.factory.destroyWidget(widget_idx, self.parent.active_widgets.get(active_idx).widget);
                }
            }

            fn widgetToActiveIdx(self: *LayoutHelper, widget_idx: usize) ?usize {
                if (widget_idx >= self.parent.first_widget_idx + self.parent.active_widgets.len) return null;
                if (widget_idx < self.parent.first_widget_idx) return null;

                return widget_idx - self.parent.first_widget_idx;
            }

            fn getWidget(active: *ActiveWidgets(Action), first: usize, factory: Factory, id: usize) !gui.Widget(Action) {
                if (id >= first and id < first + active.len) {
                    return active.get(id - first).widget;
                }
                return try factory.createWidget(id);
            }

            fn totalHeight(self: *LayoutHelper) u31 {
                return @intCast(self.bottom_cursor - self.top_cursor);
            }

            fn commitTempLists(self: *LayoutHelper) !void {
                self.parent.active_widgets.clear();
                self.parent.first_widget_idx = self.top_idx;

                var i: usize = self.anchor_to_top.len;
                while (i > 0) {
                    i -= 1;
                    try self.parent.active_widgets.append(self.anchor_to_top.get(i));
                }

                var it = self.anchor_to_bottom.iter();
                while (it.next()) |elem| {
                    try self.parent.active_widgets.append(elem.*);
                }

                self.anchor_to_bottom.clear(self.expansion);
                self.anchor_to_top.clear(self.expansion);
            }

            fn adjustUncommittedYs(self: *LayoutHelper, offset: i32) !void {
                self.top_cursor += offset;
                self.bottom_cursor += offset;

                var it = self.anchor_to_top.iter();
                while (it.next()) |elem| {
                    elem.bounds.top += offset;
                    elem.bounds.bottom += offset;
                }

                it = self.anchor_to_bottom.iter();
                while (it.next()) |elem| {
                    elem.bounds.top += offset;
                    elem.bounds.bottom += offset;
                }
            }
        };
    };
}

pub fn ActiveWidget(comptime Action: type) type {
    return struct {
        widget: gui.Widget(Action),
        bounds: gui.PixelBBox = .{
            .top = 0,
            .bottom = 0,
            .left = 0,
            .right = 0,
        },
    };
}

fn ActiveWidgets(comptime Action: type) type {
    return sphutil.RuntimeSegmentedList(ActiveWidget(Action));
}

fn ActiveWidgetsUnmanaged(comptime Action: type) type {
    return sphutil.RuntimeSegmentedListUnmanaged(ActiveWidget(Action));
}

const ScrollAnchor = struct {
    // Where on the screen we want to anchor to
    screen_ratio: f32,
    // Which item we are anchoring
    item_idx: usize,
    // Where in the item we are anchoring (in item space)
    item_offs: f32,
};

fn asf32(v: anytype) f32 {
    return @floatFromInt(v);
}

fn calcScrollbarPosition(comptime Action: type, active_widgets: ActiveWidgets(Action), first_widget_idx: usize, num_items: usize, container_height: u31) f32 {
    const num_items_f = asf32(num_items);
    const container_height_f = asf32(container_height);

    var it = active_widgets.iter();
    var idx: usize = first_widget_idx;
    while (it.next()) |elem| {
        defer idx += 1;

        const idx_f: f32 = @floatFromInt(idx);

        const item_top_norm = idx_f / num_items_f;
        const item_bottom_norm = (idx_f + 1) / num_items_f;

        const screen_top_norm = asf32(elem.bounds.top) / container_height_f;
        const screen_bottom_norm = asf32(elem.bounds.bottom) / container_height_f;

        const item_height = item_bottom_norm - item_top_norm;
        const screen_height = screen_bottom_norm - screen_top_norm;

        // lerp for item space
        // t * item_height + item_top_norm
        //
        // lerp for screen space
        // t * screen_height + screen_top_norm
        //
        // We want to find the point where the item height is the
        // same as it's position in the window to match the scroll
        // anchor generation from scrollbar pos, so we just set
        // them to be equal and solve for t
        //
        // t * item_height + item_top_norm = t * screen_height + screen_top_norm
        const t = (screen_top_norm - item_top_norm) / (item_height - screen_height);
        if (t >= 0.0 and t <= 1.0) {
            return t * item_height + item_top_norm;
        }
    }

    return 0.0;
}

fn calcHandleRatio(layout_height: i32, container_height: u31, active_items: usize, total_items: usize) f32 {
    if (container_height == 0 or total_items == 0) return 1.0;

    const candidate = asf32(layout_height) / asf32(container_height) *
        asf32(active_items) / asf32(total_items);

    // We don't want an infinitely small handle
    return @max(candidate, 0.05);
}
