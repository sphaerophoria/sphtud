const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("../ui.zig");
const util = @import("util.zig");
const gui_text = @import("gui_text.zig");
const GuiText = gui_text.GuiText;
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Color = gui.Color;
const sphtext = @import("../text.zig");
const TextRenderer = sphtext.TextRenderer;
const SquircleRenderer = @import("SquircleRenderer.zig");
const sphutil = @import("sphutil");

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

const TextboxActionKind = enum {
    insert,
    delete,
    backspace,
};

const TextboxAction = union(enum) {
    insert_char: usize,
    delete_char: usize,

    fn fromKind(kind: TextboxActionKind, idx: usize) ?TextboxAction {
        switch (kind) {
            .insert => return .{ .insert_char = idx },
            .delete => return .{ .delete_char = idx },
            .backspace => {
                if (idx == 0) return null;
                return .{ .delete_char = idx - 1 };
            },
        }
    }
};

pub const TextboxNotifier = struct {
    priv: struct {
        insert_idx: usize,
        channel: *std.ArrayList(TextboxAction),
    },
    events: []const gui.KeyEvent,

    pub fn insertIdx(self: TextboxNotifier, string_len: usize) usize {
        return @max(string_len, self.priv.insert_idx);
    }

    pub fn deleteIdx(self: TextboxNotifier, string_len: usize) ?usize {
        if (self.priv.insert_idx >= string_len) return null;
        return self.priv.insert_idx;
    }

    pub fn backspaceIdx(self: TextboxNotifier) ?usize {
        if (self.priv.insert_idx == 0) return null;
        return self.priv.insert_idx - 1;
    }

    pub fn notify(self: *TextboxNotifier, kind: TextboxActionKind) !void {
        const action = TextboxAction.fromKind(kind, self.priv.insert_idx) orelse return;
        switch (kind) {
            .insert => self.priv.insert_idx += 1,
            .backspace => self.priv.insert_idx -|= 1,
            .delete => {},
        }
        try self.priv.channel.appendBounded(action);
    }
};

fn Textbox(comptime Action: type, comptime TextRetriever: type, comptime TextAction: type) type {
    return struct {
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
        executed_actions: std.ArrayList(TextboxAction),
        focused: bool = false,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

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
            const cursor_label_offs = getCursorOffsetFromText(
                self.gui_text.glyph_locations,
                self.gui_text.layout_bounds,
                self.cursor_pos_text_idx,
            );

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

        fn update(ctx: ?*anyopaque, _: PixelSize, _: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            try self.gui_text.update(std.math.maxInt(u31));

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
            self.executed_actions.shrinkRetainingCapacity(0);
        }

        fn updateTextPosition(self: *Self) void {
            const cursor_label_offs = getCursorOffsetFromText(
                self.gui_text.glyph_locations,
                self.gui_text.layout_bounds,
                self.cursor_pos_text_idx,
            );
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

        fn setInputState(ctx: ?*anyopaque, _: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) gui.InputResponse(Action) {
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
                const frame_keys = input_state.key_tracker.pressed_this_frame.items;

                if (frame_keys.len == 0) break :blk;

                for (frame_keys) |key| {
                    switch (key.key) {
                        .left_arrow => self.cursor_pos_text_idx = self.cursor_pos_text_idx -| 1,
                        .right_arrow => {
                            const text = self.gui_text.text;
                            self.cursor_pos_text_idx = @min(self.cursor_pos_text_idx + 1, text.len);
                        },
                        else => {},
                    }
                }
                action = generateAction(Action, &self.text_action, self.makeNotifier(frame_keys));
            }

            return .{
                .wants_focus = wants_focus,
                .action = action,
            };
        }

        fn makeNotifier(self: *Self, events: []const gui.KeyEvent) TextboxNotifier {
            return .{
                .priv = .{
                    .insert_idx = self.cursor_pos_text_idx,
                    .channel = &self.executed_actions,
                },
                .events = events,
            };
        }
    };
}

pub fn makeTextbox(comptime Action: type, alloc: gui.GuiAlloc, text_retreiver: anytype, text_action: anytype, shared: *const SharedTextboxState) !Widget(Action) {
    const TB = Textbox(Action, @TypeOf(text_retreiver), @TypeOf(text_action));
    const box = try alloc.heap.arena().create(TB);

    const new_buffer = try gui_text.guiText(alloc, shared.guitext_shared, .white, text_retreiver);

    box.* = .{
        .gui_text = new_buffer,
        .text_action = text_action,
        .cursor_pos_text_idx = new_buffer.text.len,
        .shared = shared,
        .executed_actions = .initBuffer(try alloc.heap.arena().alloc(TextboxAction, 100)),
    };

    return .{
        .vtable = &TB.widget_vtable,
        .name = "textbox",
        .ctx = box,
    };
}

// Helper function to automatically notify when applying edits on a text
// element backed by an array list
pub fn executeTextEditOnArrayList(
    alloc: Allocator,
    text_input: *std.ArrayListUnmanaged(u8),
    notifier: *gui.textbox.TextboxNotifier,
) !void {
    for (notifier.events) |ev| {
        switch (ev.key) {
            .ascii => |char| {
                try text_input.insert(alloc, notifier.priv.insert_idx, char);
                try notifier.notify(.insert);
            },
            .backspace => {
                _ = text_input.orderedRemove(notifier.backspaceIdx() orelse continue);
                try notifier.notify(.backspace);
            },
            .delete => {
                _ = text_input.orderedRemove(notifier.deleteIdx(text_input.items.len) orelse continue);
                try notifier.notify(.delete);
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

fn getCursorOffsetFromText(
    glyph_locations: sphutil.RuntimeSegmentedList(TextRenderer.TextLayout.GlyphLoc),
    layout_bounds: gui.gui_text.LayoutBounds,
    cursor_pos: usize,
) i32 {
    var cursor_offs: i32 = layout_bounds.max_x;

    if (cursor_pos < glyph_locations.len) {
        const cursor_right_glyph = glyph_locations.get(cursor_pos);
        cursor_offs = cursor_right_glyph.pixel_x1 - layout_bounds.min_x;
    }
    return cursor_offs;
}

fn generateAction(comptime Action: type, action_generator: anytype, notifier: TextboxNotifier) Action {
    const Ptr = @TypeOf(action_generator);
    const T = @typeInfo(Ptr).pointer.child;

    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "generate")) {
                return action_generator.generate(notifier);
            }
        },
        .pointer => |p| {
            switch (@typeInfo(p.child)) {
                .@"fn" => {
                    return action_generator.*(notifier);
                },
                else => {},
            }
        },
        else => {},
    }
}
