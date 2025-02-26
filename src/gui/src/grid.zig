const std = @import("std");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const Allocator = std.mem.Allocator;
const sphutil = @import("sphutil");
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

pub fn Grid(comptime Action: type) type {
    return struct {
        // sum(columns) == 1.0
        columns: []f32,
        items: sphutil.RuntimeSegmentedList(LayoutItem),
        item_pad: u31,
        grid_width: u31 = 0,
        focused_idx: ?usize = null,

        const LayoutItem = struct {
            widget: Widget(Action),
            // Relative to top left of grid
            bounds: PixelBBox = .{ .top = 0, .left = 0, .right = 0, .bottom = 0 },
        };

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        pub fn init(alloc: *Sphalloc, column_ratios: []const f32, item_pad: u31, typical_elems: usize, max_elems: usize) !*Self {
            const self = try alloc.arena().create(Self);
            const normalized = try alloc.arena().dupe(f32, column_ratios);
            normalize(normalized);

            self.* = .{
                .columns = normalized,
                .items = try sphutil.RuntimeSegmentedList(LayoutItem).init(
                    alloc.arena(),
                    alloc.block_alloc.page_alloc,
                    typical_elems,
                    max_elems,
                ),
                .item_pad = item_pad,
            };
            return self;
        }

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .name = "grid",
                .vtable = &widget_vtable,
            };
        }

        pub fn clear(self: *Self) void {
            self.items.clear();
        }

        pub fn pushWidget(self: *Self, widget: Widget(Action)) !void {
            try self.items.append(.{
                .widget = widget,
            });
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.grid_width = available_size.width;

            var layout_calc = LayoutCalc.init(available_size, self.columns, self.item_pad);

            var item_it = self.items.iter();
            outer: while (true) {
                const iter_checkpoint = item_it;

                for (0..self.columns.len) |column_idx| {
                    const item = item_it.next() orelse break;

                    const widget_available = layout_calc.widgetAvailable(column_idx);
                    try item.widget.update(widget_available, delta_s);

                    const widget_size = item.widget.getSize();

                    layout_calc.updateMaxHeight(widget_size);
                }

                item_it = iter_checkpoint;
                for (0..self.columns.len) |column_idx| {
                    const item = item_it.next() orelse break :outer;
                    const widget_size = item.widget.getSize();
                    const widget_available = layout_calc.widgetAvailable(column_idx);

                    item.bounds = layout_calc.widgetBounds(widget_size, widget_available);
                    layout_calc.advanceX(widget_available);
                }

                layout_calc.advanceY();
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));

            return .{
                .width = self.grid_width,
                .height = self.contentHeight(),
            };
        }

        fn render(ctx: ?*anyopaque, grid_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var it = self.items.iter();
            while (it.next()) |item| {
                const widget_bounds = item.bounds.offset(grid_bounds.left, grid_bounds.top);
                item.widget.render(widget_bounds, window_bounds);
            }
        }

        fn setInputState(ctx: ?*anyopaque, grid_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            var it = self.items.iter();
            var idx: usize = 0;
            while (it.next()) |item| {
                defer idx += 1;

                const widget_bounds = item.bounds.offset(grid_bounds.left, grid_bounds.top);
                const widget_input_bounds = input_bounds.calcIntersection(widget_bounds);

                const item_response = item.widget.setInputState(widget_bounds, widget_input_bounds, input_state);
                if (item_response.wants_focus) {
                    if (self.focused_idx) |focus_idx| {
                        self.items.getPtr(focus_idx).widget.setFocused(false);
                        self.focused_idx = null;
                    }

                    self.focused_idx = idx;
                    ret.wants_focus = true;
                }

                if (item_response.action != null) {
                    ret.action = item_response.action;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (self.focused_idx) |idx| {
                self.items.getPtr(idx).widget.setFocused(focused);
            }

            if (focused == false) {
                self.focused_idx = null;
            }
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var it = self.items.iter();
            while (it.next()) |item| {
                item.widget.reset();
            }
        }

        fn contentHeight(self: *Self) u31 {
            const start_idx = self.items.len -| self.columns.len;
            var it = self.items.iterFrom(start_idx);
            var ret: u31 = 0;
            while (it.next()) |item| {
                ret = @max(item.bounds.bottom, ret);
            }
            return ret;
        }
    };
}

fn rowUsableWidth(available_width: u31, num_columns: usize, item_pad: u31) u31 {
    const num_columns_u: u31 = @intCast(num_columns);
    return available_width - (num_columns_u - 1) * item_pad;
}

fn normalize(vals: []f32) void {
    var sum: f32 = 0;
    for (vals) |v| {
        sum += v;
    }

    for (vals) |*v| {
        v.* /= sum;
    }
}

const LayoutCalc = struct {
    columns: []const f32,
    row_usable_width: u31,
    available_height: u31,
    item_pad: u31,
    row_height: u31 = 0,
    x_offs: u31 = 0,
    y_offs: u31 = 0,

    fn init(available_size: PixelSize, columns: []const f32, item_pad: u31) LayoutCalc {
        const row_usable_width = rowUsableWidth(
            available_size.width,
            columns.len,
            item_pad,
        );

        return .{
            .row_usable_width = row_usable_width,
            .available_height = available_size.height,
            .columns = columns,
            .item_pad = item_pad,
        };
    }

    fn widgetAvailable(self: LayoutCalc, column_idx: usize) PixelSize {
        return PixelSize{
            .width = self.widgetWidth(column_idx),
            .height = self.available_height -| self.y_offs,
        };
    }

    fn widgetWidth(self: LayoutCalc, column_idx: usize) u31 {
        const usable_width_f: f32 = @floatFromInt(self.row_usable_width);
        return @intFromFloat(usable_width_f * self.columns[column_idx]);
    }

    fn updateMaxHeight(self: *LayoutCalc, size: PixelSize) void {
        self.row_height = @max(size.height, self.row_height);
    }

    fn widgetBounds(self: LayoutCalc, widget_size: PixelSize, widget_available: PixelSize) PixelBBox {
        const acx = widget_available.width / 2 + self.x_offs;
        const acy = self.row_height / 2 + self.y_offs;

        return .{
            .top = acy -| (widget_size.height / 2 + widget_size.width % 2),
            .left = acx -| (widget_size.width / 2 + widget_size.height % 2),
            .right = acx + widget_size.width / 2,
            .bottom = acy + widget_size.height / 2,
        };
    }

    fn advanceX(self: *LayoutCalc, widget_available: PixelSize) void {
        self.x_offs += widget_available.width + self.item_pad;
    }

    fn advanceY(self: *LayoutCalc) void {
        self.y_offs += self.row_height + self.item_pad;
        self.x_offs = 0;
        self.row_height = 0;
    }
};
