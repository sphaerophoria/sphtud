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
const key_mapper = gui.key_mapper;

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
// Where the label should be positioned relative to its default
// position in the box. Implements scrolling
label_left_offs: i32,
selection: Selection,
shared: *const Shared,
on_change: usize,
state: union(enum) {
    none,
    dragging: struct {
        speed: i32,
        // Movement can accumulate slowly enough that movement doesn't happen
        // every frame.
        acc: f32,
    },
},
widget: Widget,

const Self = @This();

const Side = enum {
    left,
    right,
};

const Selection = struct {
    start: Item,
    end: Item,

    const init = Selection{
        .start = .{ .inner = 0 },
        .end = .{ .inner = 0 },
    };

    const Item = struct {
        inner: usize,

        fn init(idx: usize, side: Side) Item {
            const offs: usize = switch (side) {
                .left => 0,
                .right => 1,
            };
            return .{ .inner = idx * 2 + offs };
        }
    };

    fn charRange(self: Selection) ?[2]usize {
        var left = self.start;
        var right = self.end;

        if (left.inner > right.inner) {
            std.mem.swap(Item, &left, &right);
        }

        // One full character needs to be selected
        if (right.inner - left.inner < 1) {
            return null;
        }

        // Returned range is inclusive. Take the left side of the left index,
        // and the right side of the right index. If we clicked the right side
        // of a character on the left, we really want to start at the next
        // character, and end at the previous if we clicked on the left side
        // of the right character
        //
        // Since we've encoded as 2 indexes per char index, we can just offset
        // inwards by one and everything works out
        const left_idx = (left.inner + 1) / 2;
        const right_idx = (right.inner - 1) / 2;

        if (left_idx > right_idx) return null;

        return .{
            left_idx, right_idx,
        };
    }

    fn clear(self: *Selection) void {
        self.start = self.end;
    }
};

pub fn init(alloc: gui.GuiAlloc, gpa: std.mem.Allocator, on_change: usize, shared: *const Shared) !Self {
    const label = try gui.Label.init(alloc, shared.label_shared, "", shared.style.text_color);

    return .{
        .gpa = gpa,
        .text = .empty,
        .label = label,
        .label_left_offs = 0,
        .selection = .init,
        .shared = shared,
        .on_change = on_change,
        .state = .none,
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

    self.applyLabelSpeed(delta_s);
    self.updateTextPosition();
}

const EdgeCursorAdjuster = struct {
    ref_pos: i32,
    char_side: Side,
    existing_sel: Selection.Item,
    locs: *const GlyphLocs,

    fn adjust(adj: EdgeCursorAdjuster) Selection.Item {
        const idx = calcGlyphIntersection(adj.locs, adj.ref_pos) orelse return adj.existing_sel;

        const new_pos = Selection.Item.init(idx, adj.char_side);
        return adj.keepOutsideSelection(new_pos);
    }

    fn keepOutsideSelection(adj: EdgeCursorAdjuster, new_pos: Selection.Item) Selection.Item {
        // Sometimes the drag selection can start with a selection bound that
        // is outside where it would typically choose. In this case we should
        // keep the existing selection instead of applying our own

        const existing_inner = adj.existing_sel.inner;
        const new_inner = new_pos.inner;
        const unclamped_inner = switch (adj.char_side) {
            .left => @max(existing_inner, new_inner),
            .right => @min(existing_inner, new_inner),
        };
        return .{ .inner = unclamped_inner };
    }
};

fn applyLabelSpeed(self: *Self, delta_s: f32) void {
    const params = switch (self.state) {
        .dragging => |*p| p,
        .none => return,
    };

    if (params.speed == 0) {
        return;
    }

    params.acc += @as(f32, @floatFromInt(params.speed)) * delta_s / 256;
    const movement: i32 = @intFromFloat(params.acc);
    params.acc -= @floatFromInt(movement);

    self.label_left_offs -= movement;

    const widget_edge_rel_text = -self.label_left_offs;

    const adj: EdgeCursorAdjuster = if (params.speed < 0) .{
        .ref_pos = widget_edge_rel_text + self.shared.style.left_pad,
        .char_side = .right,
        .existing_sel = self.selection.end,
        .locs = &self.label.glyph_locations,
    } else .{
        .ref_pos = widget_edge_rel_text + self.shared.style.width - self.shared.style.left_pad * 2,
        .char_side = .left,
        .existing_sel = self.selection.end,
        .locs = &self.label.glyph_locations,
    };

    self.selection.end = adj.adjust();
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

    if (self.label.layout_bounds.max_x + self.label_left_offs < width) {
        self.label_left_offs = width - self.label.layout_bounds.max_x;
    }

    if (self.label.layout_bounds.min_x + self.label_left_offs > 0) {
        self.label_left_offs = 0;
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

    blk: {
        const left_idx, const right_idx = self.selection.charRange() orelse break :blk;
        if (left_idx >= self.label.glyph_locations.len) break :blk;

        const left_glyph = self.label.glyph_locations.get(left_idx);
        const right_glyph = self.label.glyph_locations.get(right_idx);

        var selection_bounds = text_bounds;
        selection_bounds.left = left_glyph.pixel_x1 + text_left;
        selection_bounds.right = right_glyph.pixel_x2 + text_left;
        const txfm = util.widgetToClipTransform(selection_bounds, window_bounds);
        self.shared.squircle_renderer.render(.{ .r = 0, .g = 0, .b = 255, .a = 0 }, 0.0, selection_bounds, txfm);
    }

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

    if (input_state.mouse_released) {
        self.state = .none;
    }

    const padded_widget: PixelBBox = .{
        .left = widget_bounds.left + self.shared.style.left_pad,
        .right = widget_bounds.right - self.shared.style.left_pad,
        .top = widget_bounds.top,
        .bottom = widget_bounds.bottom,
    };

    const mouse_in_input = input_bounds.containsMousePos(input_state.mouse_pos);
    // Discard Y position to prevent odd behavior when dragging above or below the widget
    const mouse_in_padded_widget = mouse_x_pos >= padded_widget.left and mouse_x_pos <= padded_widget.right;
    const dragging_in_padded_widget = mouse_in_padded_widget and self.state == .dragging;
    const mouse_pressed_in_input = input_state.mouse_pressed and mouse_in_input;

    const SelectionUpdate = enum {
        // Jump to specific position
        jump,
        // Move some amount per frame
        drift,
        none,
    };

    const selection_update: SelectionUpdate =
        if (dragging_in_padded_widget or mouse_pressed_in_input)
            .jump
        else if (self.state == .dragging and !widget_bounds.containsMousePos(input_state.mouse_pos))
            .drift
        else
            .none;

    switch (selection_update) {
        .jump => {
            switch (self.state) {
                .dragging => |*d| d.speed = 0,
                else => {},
            }
            self.selection.end = self.calcMouseSelection(widget_bounds, mouse_x_pos);
        },
        .drift => {
            const widget_cx = widget_bounds.cx();
            const ref_pos = if (input_state.mouse_pos.x >= widget_cx)
                widget_bounds.right
            else
                widget_bounds.left;

            self.state.dragging.speed = mouse_x_pos - ref_pos;
        },
        .none => {},
    }

    if (input_state.mouse_pressed) blk: {
        self.selection.clear();

        if (!input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
            break :blk;
        }

        widget.focused = true;
        if (self.state != .dragging) {
            self.state = .{
                .dragging = .{
                    .acc = 0,
                    .speed = 0,
                },
            };
        }
    }

    if (!widget.focused) return;

    const frame_items = input_state.key_tracker.pressed_this_frame.items;
    var changed = false;

    for (frame_items) |item| {
        switch (item) {
            .codepoint => |c| {
                _ = self.removeSelectedText();
                const codepoint_u21: u21 = std.math.cast(u21, c) orelse {
                    std.log.err("Invalid codepoint 0x{x}\n", .{c});
                    continue;
                };

                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint_u21, &encoded) catch {
                    std.log.err("Invalid codepoint 0x{x}\n", .{c});
                    continue;
                };

                try self.text.insertSlice(self.gpa, self.cursorPos(), encoded[0..encoded_len]);
                self.setCursorPos(self.cursorPos() + 1);
                changed = true;
            },
            .key => |ev| switch (key_mapper.lookup(ev)) {
                .move_left => {
                    self.setCursorPos(self.cursorPos() -| 1);
                },
                .move_right => {
                    self.setCursorPos(@min(self.cursorPos() + 1, self.text.items.len));
                },
                .select_all => {
                    self.selection.start = .init(0, .left);
                    self.selection.end = .init(self.text.items.len, .left);
                },
                .backspace => {
                    const removed = self.removeSelectedText();
                    changed |= removed;
                    if (!removed and self.cursorPos() > 0) {
                        _ = self.text.orderedRemove(self.cursorPos() - 1);
                        self.setCursorPos(self.cursorPos() - 1);
                        changed = true;
                    }
                },
                .delete => {
                    const removed = self.removeSelectedText();
                    changed |= removed;
                    if (!removed and self.cursorPos() < self.text.items.len) {
                        _ = self.text.orderedRemove(self.cursorPos());
                        changed = true;
                    }
                },
                .none => {},
            },
        }
    }

    if (changed) {
        try self.shared.event_queue.appendBounded(self.on_change);
    }
}

fn removeSelectedText(self: *Self) bool {
    if (self.selection.charRange()) |r| {
        self.text.replaceRangeBounded(r[0], r[1] - r[0] + 1, "") catch unreachable;
        self.selection.clear();
        self.setCursorPos(r[0]);
        return true;
    }

    return false;
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.label_left_offs = 0;
    self.selection.start = .init(0, .left);
    self.selection.end = .init(0, .left);
    self.state = .none;
}

fn cursorPos(self: *Self) usize {
    return (self.selection.end.inner + 1) / 2;
}

fn setCursorPos(self: *Self, idx: usize) void {
    self.selection.end.inner = idx * 2;
    if (self.state != .dragging) self.selection.clear();
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
    const cursor_pos = self.cursorPos();
    const left = currGlpyhLeft(&self.label, cursor_pos);
    const right = prevGlyphRight(&self.label, cursor_pos);

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

const GlyphCollision = enum { outside_left, inside_left, inside_right, outside_right };

fn checkGlyphHit(locs: *const GlyphLocs, idx: usize, x_pos: i32) GlyphCollision {
    const glyph_bounds = locs.get(idx);

    const cx = @divTrunc(glyph_bounds.pixel_x1 + glyph_bounds.pixel_x2, 2);

    if (x_pos < glyph_bounds.pixel_x1) {
        return .outside_left;
    } else if (x_pos < cx) {
        return .inside_left;
    } else if (x_pos < glyph_bounds.pixel_x2) {
        return .inside_right;
    } else {
        return .outside_right;
    }
}

fn calcGlyphIntersection(locs: *const GlyphLocs, x_pos: i32) ?usize {
    var bs = sphtud.util.BinarySearch.init(locs.len);

    while (bs.step()) |idx| {
        const hit = checkGlyphHit(locs, idx, x_pos);
        switch (hit) {
            .outside_left => bs.moveLeft(idx),
            .outside_right => bs.moveRight(idx),
            .inside_left, .inside_right => return idx,
        }
    }

    return null;
}

fn calcClosestSelectionItem(locs: *const GlyphLocs, x_pos: i32) Selection.Item {
    var bs = sphtud.util.BinarySearch.init(locs.len);

    var last: Selection.Item = .init(0, .left);

    while (bs.step()) |idx| {
        const hit = checkGlyphHit(locs, idx, x_pos);
        switch (hit) {
            .outside_left => {
                bs.moveLeft(idx);
                last = .init(idx, .left);
            },
            .outside_right => {
                bs.moveRight(idx);
                last = .init(idx, .right);
            },
            .inside_left => return .init(idx, .left),
            .inside_right => return .init(idx, .right),
        }
    }

    return last;
}

fn calcMouseSelection(self: *Self, widget_bounds: gui.PixelBBox, mouse_x: i32) Selection.Item {
    if (self.label.glyph_locations.len == 0) return .init(0, .left);

    const left_pos_px = textLeft(self.shared.style, self.label_left_offs, widget_bounds);
    const mouse_rel_text = mouse_x - left_pos_px;

    return calcClosestSelectionItem(&self.label.glyph_locations, mouse_rel_text);
}
