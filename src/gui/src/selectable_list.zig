const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const gui_text = @import("gui_text.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const Style = struct {
    highlight_color: gui.Color,
    hover_color: gui.Color,
    background_color: gui.Color,
    corner_radius: f32,
    item_pad: u31,
    min_item_height: u31,
};

pub const SharedState = struct {
    gui_text_state: *const gui_text.SharedState,
    squircle_renderer: *const SquircleRenderer,
    style: Style,
};

pub fn selectableList(comptime Action: type, alloc: gui.GuiAlloc, retriever: anytype, generator: anytype, shared: *const SharedState) !Widget(Action) {
    const S = SelectableList(Action, @TypeOf(retriever), @TypeOf(generator));

    const ret = try alloc.heap.arena().create(S);

    const list_alloc = try alloc.makeSubAlloc("selectable_list_content");

    ret.* = .{
        .list_alloc = list_alloc,
        .retriever = retriever,
        .parent_width = 0,
        .action_generator = generator,
        .item_labels = &.{},
        .shared = shared,
    };

    return .{
        .vtable = &S.widget_vtable,
        .name = "selectable_list",
        .ctx = ret,
    };
}

pub fn SelectableList(comptime Action: type, comptime Retriever: type, comptime GenerateSelect: type) type {
    return struct {
        list_alloc: gui.GuiAlloc,

        retriever: Retriever,
        action_generator: GenerateSelect,
        item_labels: []TextItem,
        parent_width: u31,
        shared: *const SharedState,
        hover_idx: ?usize = null,

        debounce_state: enum {
            clicked,
            released,
        } = .released,

        const TextItem = gui_text.GuiText(LabelAdaptor(Retriever));
        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const selected = self.retriever.selectedId();

            const squircle_renderer = ListSquircleRenderer{ .shared = self.shared, .window_bounds = window_bounds };
            squircle_renderer.render(widget_bounds, self.shared.style.background_color);

            var label_bounds_it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels);
            while (label_bounds_it.next()) |item| {
                if (self.getItemColor(item.idx, selected)) |item_color| {
                    squircle_renderer.render(item.full_bounds, item_color);
                }

                const transform = util.widgetToClipTransform(item.label_bounds, window_bounds);
                item.item.render(transform);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const widget_bounds = PixelBBox{
                .left = 0,
                .top = 0,
                .bottom = std.math.maxInt(i32),
                .right = self.parent_width,
            };

            var it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels);

            while (it.next()) |_| {}

            return .{
                .width = self.parent_width,
                .height = @intCast(@max(it.y_offs, self.shared.style.min_item_height)),
            };
        }

        fn update(ctx: ?*anyopaque, available_space: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const num_items = self.retriever.numItems();

            self.parent_width = available_space.width;

            if (num_items != self.item_labels.len) {
                self.item_labels = &.{};
                try self.list_alloc.reset();

                self.item_labels = try makeTextLabels(TextItem, self.list_alloc, self.shared, self.retriever, num_items);
            }

            for (self.item_labels) |*item| {
                try item.update(self.parent_width);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const no_action = gui.InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            var ret = no_action;

            var hover_idx: ?usize = null;

            var label_bounds_it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels);
            while (label_bounds_it.next()) |item| {
                const item_input_bounds = item.full_bounds.calcIntersection(input_bounds);

                // Debounce to prevent potentially expensive action spam
                if (self.debounce_state == .released and item_input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                    ret = .{
                        .wants_focus = false,
                        .action = generateAction(Action, &self.action_generator, item.idx),
                    };
                    self.debounce_state = .clicked;
                }

                if (item_input_bounds.containsMousePos(input_state.mouse_pos)) {
                    hover_idx = item.idx;
                }
            }

            if (input_state.mouse_released) {
                self.debounce_state = .released;
            }

            self.hover_idx = hover_idx;

            return ret;
        }

        fn getItemColor(self: Self, item_idx: usize, selected_idx: usize) ?gui.Color {
            if (item_idx == self.hover_idx) {
                return self.shared.style.hover_color;
            } else if (item_idx == selected_idx) {
                return self.shared.style.highlight_color;
            } else {
                return null;
            }
        }

        const ListSquircleRenderer = struct {
            shared: *const SharedState,
            window_bounds: PixelBBox,

            fn render(self: ListSquircleRenderer, bounds: PixelBBox, color: gui.Color) void {
                const transform = util.widgetToClipTransform(bounds, self.window_bounds);
                self.shared.squircle_renderer.render(
                    color,
                    self.shared.style.corner_radius,
                    bounds,
                    transform,
                );
            }
        };

        // Iterate GuiText items with their bounds
        const LabelBoundsIt = struct {
            item_labels: []TextItem,
            y_offs: i32,
            widget_left: i32,
            widget_right: i32,
            style: *const Style,
            idx: usize = 0,

            fn init(widget_bounds: PixelBBox, style: *const Style, item_labels: []TextItem) LabelBoundsIt {
                return .{
                    .item_labels = item_labels,
                    .y_offs = widget_bounds.top,
                    .widget_left = widget_bounds.left,
                    .widget_right = widget_bounds.right,
                    .style = style,
                };
            }

            const Output = struct {
                idx: usize,
                item: TextItem,
                label_bounds: PixelBBox,
                full_bounds: PixelBBox,
            };

            fn next(self: *LabelBoundsIt) ?Output {
                if (self.idx >= self.item_labels.len) {
                    return null;
                }
                defer self.idx += 1;

                const item = self.item_labels[self.idx];
                const item_size = item.size();

                const effective_height = @max(item_size.height, self.style.min_item_height) + self.style.item_pad;
                const full_top = self.y_offs;
                const full_bounds = PixelBBox{
                    .top = full_top,
                    .bottom = full_top + effective_height,
                    .right = self.widget_right,
                    .left = self.widget_left,
                };

                const label_center_y: i32 = @intFromFloat(full_bounds.cy());
                const label_top = label_center_y - item_size.height / 2;
                const label_bottom = label_center_y + item_size.height / 2 + item_size.height % 2;
                const label_bounds = PixelBBox{
                    .left = self.widget_left,
                    .right = self.widget_left + item_size.width,
                    .top = label_top,
                    .bottom = label_bottom,
                };

                self.y_offs += effective_height;
                return .{
                    .idx = self.idx,
                    .item = self.item_labels[self.idx],
                    .label_bounds = label_bounds,
                    .full_bounds = full_bounds,
                };
            }
        };
    };
}

fn LabelAdaptor(comptime Retriever: type) type {
    return struct {
        retriever: Retriever,
        idx: usize,

        pub fn getText(self: @This()) []const u8 {
            return self.retriever.getText(self.idx);
        }
    };
}

fn labelAdaptor(retriever: anytype, idx: usize) LabelAdaptor(@TypeOf(retriever)) {
    return .{
        .retriever = retriever,
        .idx = idx,
    };
}

fn makeTextLabels(
    comptime TextItem: type,
    alloc: gui.GuiAlloc,
    shared: *const SharedState,
    retriever: anytype,
    num_items: usize,
) ![]TextItem {
    const ret = try alloc.heap.arena().alloc(TextItem, num_items);
    for (0..ret.len) |i| {
        const text = try gui_text.guiText(
            alloc,
            shared.gui_text_state,
            labelAdaptor(retriever, i),
        );

        ret[i] = text;
    }
    return ret;
}

fn generateAction(comptime Action: type, action_generator: anytype, idx: usize) Action {
    const Ptr = @TypeOf(action_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "generate")) {
                return action_generator.generate(idx);
            }
        },
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return action_generator.*(idx);
                },
                else => {},
            }
        },
        else => {},
    }
}
