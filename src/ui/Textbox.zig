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
    const cursor_offs = cursorOffset(
        &self.label,
        self.cursor_pos,
    );
    const cursor_widget_offs = cursor_offs + self.label_left_offs;
    const width: i32 = self.shared.style.width;

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
        const cursor_offs = cursorOffset(&self.label, self.cursor_pos);
        const cursor_bounds = cursorPixelBounds(style, text_left + cursor_offs, widget_bounds);
        const cursor_transform = util.widgetToClipTransform(cursor_bounds, window_bounds);
        self.shared.squircle_renderer.render(style.cursor_color, 0.0, cursor_bounds, cursor_transform);
    }
}

fn input(widget: *Widget, _: PixelBBox, input_bounds: PixelBBox, input_state: *gui.InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    if (input_state.mouse_pressed) {
        widget.focused = input_bounds.containsOptMousePos(input_state.mouse_down_location);
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

fn cursorOffset(
    label: *gui.Label,
    cursor_pos: usize,
) i32 {
    if (cursor_pos < label.glyph_locations.len) {
        return label.glyph_locations.get(cursor_pos).pixel_x1 - label.layout_bounds.min_x;
    }
    return label.layout_bounds.max_x - label.layout_bounds.min_x;
}

fn cursorPixelBounds(style: Style, cursor_left: i32, widget_bounds: PixelBBox) PixelBBox {
    const center_y: i32 = @intFromFloat(widget_bounds.cy());
    const cursor_height: i32 = @intCast(style.height * 3 / 4);
    const top = center_y - @divTrunc(cursor_height, 2);
    return .{
        .left = cursor_left,
        .right = cursor_left + @as(i32, style.cursor_width),
        .top = top,
        .bottom = top + cursor_height,
    };
}
