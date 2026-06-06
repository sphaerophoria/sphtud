const std = @import("std");
const sphtud = @import("../sphtud.zig");
const sphrender = @import("../render.zig");
const sphtext = @import("../text.zig");
const gui = @import("../ui.zig");
const util = @import("../ui/util.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const Widget = gui.Widget;
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const TextRenderer = sphtext.TextRenderer;

pub const Style = struct {
    background_color: Color,
    text_color: Color = .white,
    width: u31,
    height: u31,
    left_pad: u31,
    corner_radius: f32,
    cursor_color: Color = .white,
    cursor_width: u31 = 2,
};

pub const Shared = struct {
    label_shared: *const gui.Label.SharedState,
    squircle_renderer: *const SquircleRenderer,
    event_queue: *gui.EventQueue,
    style: Style,
};

const GlyphLocs = sphtud.util.RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc);

gpa: std.mem.Allocator,
// Renders the text
label: gui.Label,
// Actual text content
text: std.ArrayList(u8),
// Where the cursor is, in units of characters
cursor_pos: usize,
// Where the label should be positioned relative to its default
// position in the box. Implements scrolling
label_left_offs: i32,
shared: *const Shared,
on_change: usize,
widget: Widget,

const Self = @This();

pub fn init(alloc: gui.GuiAlloc, gpa: std.mem.Allocator, on_change: usize, shared: *const Shared) !Self {
    const label = try gui.Label.init(alloc, shared.label_shared, "", shared.style.text_color);

    return .{
        .gpa = gpa,
        .text = .empty,
        .label = label,
        .cursor_pos = 0,
        .label_left_offs = 0,
        .shared = shared,
        .on_change = on_change,
        .widget = .{
            .focused = false,
            .size = .{
                .width = shared.style.width,
                .height = shared.style.height,
            },
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
    };
}

pub fn setText(self: *Self, text: []const u8) !void {
    self.text.clearRetainingCapacity();
    try self.text.appendSlice(self.gpa, text);
}

fn update(widget: *Widget, _: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    try self.label.setText(self.text.items);
    try self.label.widget.update(
        .{ .width = std.math.maxInt(u31), .height = std.math.maxInt(u31) },
        delta_s,
    );

    self.updateTextPosition();
}

fn updateTextPosition(self: *Self) void {
    const cursor_offs = self.cursorOffset();
    const cursor_widget_offs = cursor_offs + self.label_left_offs;
    const width: i32 = self.shared.style.width - self.shared.style.left_pad * 2;

    if (cursor_widget_offs < 0) {
        self.label_left_offs -= cursor_widget_offs;
    } else if (cursor_widget_offs > width) {
        self.label_left_offs -= cursor_widget_offs - width;
    }
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const style = self.shared.style;

    const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
    self.shared.squircle_renderer.render(style.background_color, style.corner_radius, widget_bounds, transform);

    const text_left = textLeft(style, self.label_left_offs, widget_bounds);

    const scissor = sphrender.TemporaryScissor.init();
    defer scissor.reset();
    scissor.set(
        widget_bounds.left,
        window_bounds.bottom - widget_bounds.bottom,
        widget_bounds.calcWidth(),
        widget_bounds.calcHeight(),
    );

    const text_bounds = textPixelBounds(text_left, self.label.widget.size, widget_bounds);
    self.label.widget.render(text_bounds, window_bounds);

    if (widget.focused) {
        const cursor_offs = self.cursorOffset();
        const cursor_bounds = cursorPixelBounds(style, text_left + cursor_offs, widget_bounds);
        const cursor_transform = util.widgetToClipTransform(cursor_bounds, window_bounds);
        self.shared.squircle_renderer.render(style.cursor_color, 0.0, cursor_bounds, cursor_transform);
    }
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *gui.InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const mouse_x_pos: i32 = @intFromFloat(input_state.mouse_pos.x);

    if (input_state.mouse_pressed and input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
        const text_left = textLeft(self.shared.style, self.label_left_offs, widget_bounds);
        const mouse_x_rel_text = mouse_x_pos - text_left;
        self.cursor_pos = closestGlyph(&self.label.glyph_locations, mouse_x_rel_text);
        if (self.cursor_pos < self.label.glyph_locations.len) {
            const glpyh_loc = self.label.glyph_locations.get(self.cursor_pos);
            const glpyh_cx = @divTrunc(glpyh_loc.pixel_x1 + glpyh_loc.pixel_x2, 2);

            if (mouse_x_rel_text >= glpyh_cx)
                self.cursor_pos += 1;
        }

        widget.focused = true;
    }

    if (!widget.focused) return;

    const frame_keys = input_state.key_tracker.pressed_this_frame.items;
    var changed = false;

    for (frame_keys) |key| {
        switch (key.key) {
            .left_arrow => {
                self.cursor_pos -|= 1;
            },
            .right_arrow => {
                self.cursor_pos = @min(self.cursor_pos + 1, self.text.items.len);
            },
            .ascii => |char| {
                try self.text.insert(self.gpa, self.cursor_pos, char);
                self.cursor_pos += 1;
                changed = true;
            },
            .backspace => {
                if (self.cursor_pos > 0) {
                    _ = self.text.orderedRemove(self.cursor_pos - 1);
                    self.cursor_pos -= 1;
                    changed = true;
                }
            },
            .delete => {
                if (self.cursor_pos < self.text.items.len) {
                    _ = self.text.orderedRemove(self.cursor_pos);
                    changed = true;
                }
            },
            else => {},
        }
    }

    if (changed) {
        try self.shared.event_queue.appendBounded(self.on_change);
    }
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.label_left_offs = 0;
    self.cursor_pos = self.text.items.len;
}

fn textLeft(style: Style, left_offs: i32, widget_bounds: PixelBBox) i32 {
    return widget_bounds.left + @as(i32, style.left_pad) + left_offs;
}

fn textPixelBounds(left: i32, text_size: PixelSize, widget_bounds: PixelBBox) PixelBBox {
    const center_y: i32 = @intFromFloat(widget_bounds.cy());
    const top = center_y - @divTrunc(@as(i32, text_size.height), 2);
    return .{
        .left = left,
        .right = left + @as(i32, text_size.width),
        .top = top,
        .bottom = top + @as(i32, text_size.height),
    };
}

fn prevGlyphRight(label: *gui.Label, idx: usize) i32 {
    const prev_idx = idx -| 1;
    if (prev_idx >= label.glyph_locations.len) {
        return 0;
    } else if (idx == 0) {
        return label.layout_bounds.min_x;
    } else {
        return label.glyph_locations.get(prev_idx).pixel_x2;
    }
}

fn currGlpyhLeft(label: *gui.Label, idx: usize) i32 {
    if (idx >= label.glyph_locations.len) return label.layout_bounds.max_x;
    return label.glyph_locations.get(idx).pixel_x1;
}

fn cursorOffset(
    self: *Self,
) i32 {
    const left = currGlpyhLeft(&self.label, self.cursor_pos);
    const right = prevGlyphRight(&self.label, self.cursor_pos);

    return @divTrunc(left + right - self.shared.style.cursor_width + 1, 2);
}

fn cursorPixelBounds(style: Style, cursor_left: i32, widget_bounds: PixelBBox) PixelBBox {
    const center_y: i32 = @intFromFloat(widget_bounds.cy());
    const cursor_height: i32 = @intCast(style.height * 3 / 4);
    const top = center_y - @divTrunc(cursor_height, 2);
    const right = cursor_left + style.cursor_width;
    return .{
        .left = cursor_left,
        .right = right,
        .top = top,
        .bottom = top + cursor_height,
    };
}

fn closestGlyph(locs: *const GlyphLocs, x_pos: i32) usize {
    var bs = sphtud.util.BinarySearch.init(locs.len);

    var idx: usize = 0;

    while (bs.step()) |step_idx| {
        idx = step_idx;
        const glyph_bounds = locs.get(idx);
        const smaller_than_right = x_pos <= glyph_bounds.pixel_x2;
        const larger_than_left = x_pos >= glyph_bounds.pixel_x1;
        const is_hit = larger_than_left and smaller_than_right;

        if (is_hit)
            return idx
        else if (smaller_than_right)
            bs.moveLeft(idx)
        else if (larger_than_left)
            bs.moveRight(idx)
        else
            unreachable;
    }

    return idx;
}
