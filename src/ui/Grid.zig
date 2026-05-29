const std = @import("std");
const sphtud = @import("../sphtud.zig");
const gui = sphtud.ui;

pub const Grid = @This();

pub const ColumnConfig = struct {
    // Width ratios are preprocessed such that they add to 1.0
    width: Width,
    horizontal_justify: HJustification,
    vertical_justify: VJustification,
};

pub const Width = union(enum) {
    // Ratio of space after all fixed elements as a fraction of sum of all
    // ratios.
    // e.g. ratio: 1.0, ratio: 1.0, fixed: 200 will result in the first two
    // columns splitting the available space after the 200 pixels are used by
    // the right most element
    ratio: f32,
    fixed: u31,
};

pub const HJustification = enum {
    left,
    center,
    right,
};

pub const VJustification = enum {
    top,
    center,
    bottom,
};

const GridItem = struct {
    widget: *gui.Widget,
    bounds: gui.PixelBBox = .{ .top = 0, .left = 0, .right = 0, .bottom = 0 },
};

columns: []const ColumnConfig,
items: sphtud.util.RuntimeSegmentedList(GridItem),
item_pad: u31,
widget: gui.Widget,

pub fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, columns: []const ColumnConfig, item_pad: u31) !Grid {
    const normalized = try arena.dupe(ColumnConfig, columns);
    normalize(normalized);

    return .{
        .columns = normalized,
        .items = try .init(arena, expansion, 32, 1024),
        .item_pad = item_pad,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
    };
}

pub fn append(self: *Grid, widget: *gui.Widget) !void {
    try self.items.append(.{ .widget = widget });
}

pub fn clear(self: *Grid) void {
    self.items.clear();
}

fn update(widget: *gui.Widget, available_size: gui.PixelSize, delta_s: f32) !void {
    const self: *Grid = @fieldParentPtr("widget", widget);

    var layout_calc = LayoutCalc.init(available_size, self.columns, self.item_pad);
    var content_height: u31 = 0;

    var it = self.items.iter();
    outer: while (true) {
        const iter_checkpoint = it;

        // First pass: update widgets to get their sizes and compute row height.
        for (0..self.columns.len) |column_idx| {
            const item = it.next() orelse break;
            const widget_available = layout_calc.widgetAvailable(column_idx);
            try item.widget.update(widget_available, delta_s);
            layout_calc.updateMaxHeight(item.widget.size);
        }

        // Second pass: assign bounds using the computed row height.
        it = iter_checkpoint;
        for (0..self.columns.len) |column_idx| {
            const item = it.next() orelse break :outer;
            const widget_available = layout_calc.widgetAvailable(column_idx);
            item.bounds = layout_calc.widgetBounds(item.widget.size, widget_available, column_idx);
            content_height = @max(content_height, @as(u31, @intCast(item.bounds.bottom)));
            layout_calc.advanceX(widget_available);
        }

        layout_calc.advanceY();
    }

    self.widget.size = .{
        .width = available_size.width,
        .height = content_height,
    };
}

fn render(widget: *gui.Widget, grid_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *Grid = @fieldParentPtr("widget", widget);
    var it = self.items.iter();
    while (it.next()) |item| {
        const child_bounds = childBounds(item.bounds, grid_bounds);
        item.widget.render(child_bounds, window_bounds);
    }
}

fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
    const self: *Grid = @fieldParentPtr("widget", widget);
    var it = self.items.iter();
    while (it.next()) |item| {
        const child_bounds = childBounds(item.bounds, widget_bounds);
        try item.widget.input(child_bounds, child_bounds.calcIntersection(input_bounds), input_state);
    }
}

fn reset(widget: *gui.Widget) void {
    const self: *Grid = @fieldParentPtr("widget", widget);
    var it = self.items.iter();
    while (it.next()) |item| {
        item.widget.reset();
    }
}

fn childBounds(bounds_rel_grid: gui.PixelBBox, grid_bounds: gui.PixelBBox) gui.PixelBBox {
    return .{
        .top = grid_bounds.top + bounds_rel_grid.top,
        .bottom = grid_bounds.top + bounds_rel_grid.bottom,
        .left = grid_bounds.left + bounds_rel_grid.left,
        .right = grid_bounds.left + bounds_rel_grid.right,
    };
}

fn normalize(cols: []ColumnConfig) void {
    var ratio_sum: f32 = 0;
    for (cols) |c| {
        if (c.width == .ratio) ratio_sum += c.width.ratio;
    }
    if (ratio_sum == 0) return;
    for (cols) |*c| {
        if (c.width == .ratio) c.width.ratio /= ratio_sum;
    }
}

const LayoutCalc = struct {
    columns: []const ColumnConfig,
    row_usable_width: u31,
    item_pad: u31,
    row_height: u31 = 0,
    x_offs: u31 = 0,
    y_offs: u31 = 0,

    fn init(available_size: gui.PixelSize, columns: []const ColumnConfig, item_pad: u31) LayoutCalc {
        const num_cols: u31 = @intCast(columns.len);
        var fixed_total: u31 = 0;
        for (columns) |c| {
            if (c.width == .fixed) fixed_total += c.width.fixed;
        }
        const padding_total = (num_cols -| 1) * item_pad;
        const row_usable_width = available_size.width -| fixed_total -| padding_total;
        return .{
            .columns = columns,
            .row_usable_width = row_usable_width,
            .item_pad = item_pad,
        };
    }

    fn widgetWidth(self: LayoutCalc, column_idx: usize) u31 {
        return switch (self.columns[column_idx].width) {
            .ratio => |r| @intFromFloat(@as(f32, @floatFromInt(self.row_usable_width)) * r),
            .fixed => |w| w,
        };
    }

    fn widgetAvailable(self: LayoutCalc, column_idx: usize) gui.PixelSize {
        return .{
            .width = self.widgetWidth(column_idx),
            .height = 0, // grid rows have no fixed height constraint
        };
    }

    fn updateMaxHeight(self: *LayoutCalc, size: gui.PixelSize) void {
        self.row_height = @max(self.row_height, size.height);
    }

    fn widgetBounds(self: LayoutCalc, widget_size: gui.PixelSize, widget_available: gui.PixelSize, column_idx: usize) gui.PixelBBox {
        const left: i32 = switch (self.columns[column_idx].horizontal_justify) {
            .left => self.x_offs,
            .right => self.x_offs + widget_available.width -| widget_size.width,
            .center => self.x_offs + widget_available.width / 2 -| widget_size.width / 2,
        };
        const top: i32 = switch (self.columns[column_idx].vertical_justify) {
            .top => self.y_offs,
            .bottom => self.y_offs + self.row_height -| widget_size.height,
            .center => self.y_offs + self.row_height / 2 -| widget_size.height / 2,
        };
        return .{
            .top = top,
            .left = left,
            .right = left + widget_size.width,
            .bottom = top + widget_size.height,
        };
    }

    fn advanceX(self: *LayoutCalc, widget_available: gui.PixelSize) void {
        self.x_offs += widget_available.width + self.item_pad;
    }

    fn advanceY(self: *LayoutCalc) void {
        self.y_offs += self.row_height + self.item_pad;
        self.x_offs = 0;
        self.row_height = 0;
    }
};
