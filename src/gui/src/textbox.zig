const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const util = @import("util.zig");
const gui_text = @import("gui_text.zig");
const GuiText = gui_text.GuiText;
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Color = gui.Color;
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const TextboxStyle = struct {
    background_color: Color,
    size: gui.PixelSize,
    left_edge_pad: u31,
    corner_radius: f32,
    cursor_width: u31,
    cursor_height: u31,
    cursor_color: Color,
};

pub const SharedTextboxState = struct {
    squircle_renderer: *const SquircleRenderer,
    guitext_shared: *const gui_text.SharedState,
    style: TextboxStyle,
};

const TextboxAction = union(enum) {
    insert_char: usize,
    delete_char: usize,
};

pub const TextboxNotifier = struct {
    alloc: Allocator,
    channel: *std.ArrayListUnmanaged(TextboxAction),

    pub fn notify(self: TextboxNotifier, action: TextboxAction) !void {
        try self.channel.append(self.alloc, action);
    }
};

fn Textbox(comptime Action: type, comptime TextRetriever: type, comptime TextAction: type) type {
    return struct {
        alloc: Allocator,
        shared: *const SharedTextboxState,
        text_action: TextAction,
        gui_text: GuiText(TextRetriever),
        // Where the label should be positioned relative to its default
        // position in the box. Implements scrolling
        label_left_offs: i32 = 0,
        // Where the cursor is, in units of characters
        cursor_pos_text_idx: usize,
        // When we request that the application edits the text we are looking
        // at, we need to know how the text was transformed from the previous
        // state to the current state. Otherwise we would not know where to put
        // the cursor
        //
        // This action list is fed through a TextboxNotifier in Action, and we
        // check actions performed on next update()
        executed_actions: std.ArrayListUnmanaged(TextboxAction) = .{},
        focused: bool = false,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        fn deinit(ctx: ?*anyopaque, _: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.gui_text.deinit(self.alloc);
            self.executed_actions.deinit(self.alloc);
            self.alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.renderBackground(widget_bounds, window_bounds);
            const label_bounds = self.renderText(widget_bounds, window_bounds);

            if (self.focused) {
                self.renderCursor(label_bounds, widget_bounds, window_bounds);
            }
        }

        fn renderBackground(self: Self, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
            self.shared.squircle_renderer.render(
                self.shared.style.background_color,
                self.shared.style.corner_radius,
                widget_bounds,
                transform,
            );
        }

        fn renderText(self: Self, widget_bounds: PixelBBox, window_bounds: PixelBBox) PixelBBox {
            const label_bounds = makeLabelBounds(
                self.shared.style,
                self.label_left_offs,
                self.gui_text.size(),
                widget_bounds,
            );

            const temp_scissor = sphrender.TemporaryScissor.init();
            defer temp_scissor.reset();

            temp_scissor.set(
                widget_bounds.left,
                window_bounds.calcHeight() - widget_bounds.bottom,
                widget_bounds.calcWidth(),
                widget_bounds.calcHeight(),
            );

            const label_transform = util.widgetToClipTransform(label_bounds, window_bounds);
            self.gui_text.render(label_transform);
            return label_bounds;
        }

        fn renderCursor(self: Self, label_bounds: PixelBBox, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const cursor_label_offs = getCursorOffsetFromText(self.gui_text.layout, self.cursor_pos_text_idx);

            const cursor_bounds = makeCursorBounds(
                self.shared.style,
                label_bounds.left + cursor_label_offs,
                widget_bounds,
            );

            const cursor_transform = util.widgetToClipTransform(cursor_bounds, window_bounds);
            self.shared.squircle_renderer.render(
                self.shared.style.cursor_color,
                0.0,
                cursor_bounds,
                cursor_transform,
            );
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.shared.style.size;
        }

        fn update(ctx: ?*anyopaque, _: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            try self.gui_text.update(self.alloc, std.math.maxInt(u31));

            self.processExternalActions();
            self.updateTextPosition();
        }

        fn processExternalActions(self: *Self) void {
            for (self.executed_actions.items) |action| {
                switch (action) {
                    .insert_char => |idx| {
                        if (idx <= self.cursor_pos_text_idx) {
                            self.cursor_pos_text_idx += 1;
                        }
                    },
                    .delete_char => |idx| {
                        if (idx < self.cursor_pos_text_idx) {
                            self.cursor_pos_text_idx -= 1;
                        }
                    },
                }
            }
            self.executed_actions.clearRetainingCapacity();
        }

        fn updateTextPosition(self: *Self) void {
            const cursor_label_offs = getCursorOffsetFromText(self.gui_text.layout, self.cursor_pos_text_idx);
            const cursor_widget_offs = cursor_label_offs + self.label_left_offs;

            // Ensure the cursor is visible by shifting the text. This means
            // that the text offset + cursor from text offset result in a
            // cursor position that is inside the widget bounds
            if (cursor_widget_offs < 0) {
                self.label_left_offs -= cursor_widget_offs;
            } else if (cursor_widget_offs > self.shared.style.size.width) {
                self.label_left_offs -= cursor_widget_offs - self.shared.style.size.width;
            }
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.focused = focused;
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.label_left_offs = 0;
            // reset() may be called before update(), which means that we
            // cannot use self.gui_text.text. We need to position ourselves at
            // the end of whatever text will be laid out on the next frame, not
            // whatever happens to be laid out now
            self.cursor_pos_text_idx = self.gui_text.getNextText().len;
        }

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var wants_focus = self.focused;

            if (input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                wants_focus = true;
            }

            if (input_state.mouse_down_location) |loc| {
                if (self.focused and !input_bounds.containsMousePos(loc)) {
                    wants_focus = false;
                }
            }

            var action: ?Action = null;
            if (self.focused) blk: {
                if (input_state.frame_keys.items.len == 0) break :blk;

                for (input_state.frame_keys.items) |key| {
                    switch (key.key) {
                        .left_arrow => self.cursor_pos_text_idx = self.cursor_pos_text_idx -| 1,
                        .right_arrow => {
                            const text = self.gui_text.text;
                            self.cursor_pos_text_idx = @min(self.cursor_pos_text_idx + 1, text.len);
                        },
                        else => {},
                    }
                }
                action = generateAction(Action, &self.text_action, self.makeNotifier(), self.cursor_pos_text_idx, input_state.frame_keys.items);
            }

            return .{
                .wants_focus = wants_focus,
                .action = action,
            };
        }

        fn makeNotifier(self: *Self) TextboxNotifier {
            return .{
                .alloc = self.alloc,
                .channel = &self.executed_actions,
            };
        }
    };
}

pub fn makeTextbox(comptime Action: type, alloc: Allocator, text_retreiver: anytype, text_action: anytype, shared: *const SharedTextboxState) !Widget(Action) {
    const TB = Textbox(Action, @TypeOf(text_retreiver), @TypeOf(text_action));
    const box = try alloc.create(TB);

    const new_buffer = try gui_text.guiText(alloc, shared.guitext_shared, text_retreiver);
    errdefer new_buffer.deinit(alloc);

    box.* = .{
        .alloc = alloc,
        .gui_text = new_buffer,
        .text_action = text_action,
        .cursor_pos_text_idx = new_buffer.text.len,
        .shared = shared,
    };

    return .{
        .vtable = &TB.widget_vtable,
        .ctx = box,
    };
}

// Helper function to automatically notify when applying edits on a text
// element backed by an array list
pub fn executeTextEditOnArrayList(
    alloc: Allocator,
    text_input: *std.ArrayListUnmanaged(u8),
    insert_idx: usize,
    notifier: gui.textbox.TextboxNotifier,
    events: []const gui.KeyEvent,
) !void {
    var num_inserted: isize = 0;

    for (events) |ev| {
        const fixed_insert_idx: usize =
            // FIXME: Cast hell
            @intCast(std.math.clamp(@as(isize, @intCast(insert_idx)) + num_inserted, 0, @as(isize, @intCast(text_input.items.len))));

        switch (ev.key) {
            .ascii => |char| {
                try text_input.insert(alloc, fixed_insert_idx, char);
                num_inserted += 1;
                try notifier.notify(.{ .insert_char = fixed_insert_idx });
            },
            .backspace => {
                if (fixed_insert_idx > 0) {
                    const delete_idx = fixed_insert_idx - 1;
                    if (delete_idx < text_input.items.len) {
                        _ = text_input.orderedRemove(delete_idx);
                        num_inserted -= 1;
                        try notifier.notify(.{ .delete_char = delete_idx });
                    }
                }
            },
            .delete => {
                const delete_idx = fixed_insert_idx;
                if (delete_idx < text_input.items.len) {
                    _ = text_input.orderedRemove(delete_idx);
                    num_inserted -= 1;
                    try notifier.notify(.{ .delete_char = delete_idx });
                }
            },
            else => {},
        }
    }
}

fn makeCursorBounds(style: TextboxStyle, cursor_left: i32, widget_bounds: PixelBBox) PixelBBox {
    const cursor_center: i32 = @intFromFloat(widget_bounds.cy());
    const cursor_top = cursor_center - style.cursor_height / 2;
    return PixelBBox{
        .left = cursor_left,
        .right = cursor_left + style.cursor_width,
        .top = cursor_top,
        .bottom = cursor_top + style.cursor_height,
    };
}

fn makeLabelBounds(style: TextboxStyle, left_offs: i32, label_size: PixelSize, widget_bounds: PixelBBox) PixelBBox {
    const y_offs = @divTrunc(style.size.height -| label_size.height, 2);
    const x_offs = style.left_edge_pad;
    var left = widget_bounds.left + x_offs;
    const top = widget_bounds.top + y_offs;

    left += left_offs;
    const right = left + label_size.width;

    return PixelBBox{
        .left = left,
        .top = top,
        .right = right,
        .bottom = top + label_size.height,
    };
}

fn getCursorOffsetFromText(layout: TextRenderer.TextLayout, cursor_pos: usize) i32 {
    var cursor_offs: i32 = layout.max_x;
    if (cursor_pos < layout.glyphs.len) {
        const cursor_right_glyph = layout.glyphs[cursor_pos];
        cursor_offs = cursor_right_glyph.pixel_x1 - layout.min_x;
    }
    return cursor_offs;
}

fn generateAction(comptime Action: type, action_generator: anytype, notifier: TextboxNotifier, pos: usize, items: []const gui.KeyEvent) Action {
    const Ptr = @TypeOf(action_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "generate")) {
                return action_generator.generate(notifier, pos, items);
            }
        },
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return action_generator.*(notifier, pos, items);
                },
                else => {},
            }
        },
        else => {},
    }
}
