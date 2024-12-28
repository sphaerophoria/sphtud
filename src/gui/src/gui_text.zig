const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const gui = @import("gui.zig");
const sphtext = @import("sphtext");
const sphrender = @import("sphrender");
const PixelSize = gui.PixelSize;
const TextRenderer = sphtext.TextRenderer;

pub const SharedState = struct {
    text_renderer: *TextRenderer,
    ttf: *const sphtext.ttf.Ttf,
    distance_field_generator: *const sphrender.DistanceFieldGenerator,
};

pub fn guiText(alloc: Allocator, shared: *const SharedState, text_retriever_const: anytype) !GuiText(@TypeOf(text_retriever_const)) {
    // Ideally we don't layout now, because the layout is likely going to
    // change when we put whatever widget we are rendering in into whatever
    // container it belongs to.
    //
    // Its convenient for users of us to have a valid layout though, so we just
    // layout nothing for now
    const text_layout = TextRenderer.TextLayout.empty;
    errdefer text_layout.deinit(alloc);

    const text_buffer = shared.text_renderer.program.makeDefaultBuffer();
    errdefer text_buffer.deinit();

    // Callers still may want to look at the text
    var text_retriever = text_retriever_const;
    const text = getText(&text_retriever);

    const duped_text = try alloc.dupe(u8, text);
    errdefer alloc.free(duped_text);

    return .{
        .layout = text_layout,
        .text = duped_text,
        .buffer = text_buffer,
        .shared = shared,
        .text_retriever = text_retriever,
    };
}

pub fn GuiText(comptime TextRetriever: type) type {
    return struct {
        layout: TextRenderer.TextLayout,
        buffer: TextRenderer.Buffer,
        text: []const u8,
        wrap_width: u31 = 0,
        shared: *const SharedState,

        text_retriever: TextRetriever,

        const Self = @This();

        pub fn deinit(self: Self, alloc: Allocator) void {
            self.layout.deinit(alloc);
            alloc.free(self.text);
            self.buffer.deinit();
        }

        pub fn update(self: *Self, alloc: Allocator, wrap_width: u31) !void {
            if (self.wrap_width != wrap_width) {
                try self.regenerate(alloc, wrap_width);
                return;
            }

            const new_text = getText(&self.text_retriever);
            if (!std.mem.eql(u8, new_text, self.text)) {
                try self.regenerate(alloc, wrap_width);
                return;
            }
        }

        pub fn size(self: Self) PixelSize {
            return .{
                .width = @intCast(self.layout.width()),
                .height = @intCast(self.layout.height()),
            };
        }

        pub fn render(self: Self, transform: sphmath.Transform) void {
            // FIXME: Render a baseline. We could probably adjust our size so
            // that it always reports the min/max height of a char to get
            // consistent layout, then find the baseline relative to that area
            //
            // Baseline location can use the max ascent/descent metrics
            self.shared.text_renderer.render(self.buffer, transform);
        }

        pub fn getNextText(self: *Self) []const u8 {
            return getText(&self.text_retriever);
        }

        fn regenerate(self: *Self, alloc: Allocator, wrap_width: u31) !void {
            const text = getText(&self.text_retriever);
            const text_layout = try self.shared.text_renderer.layoutText(
                alloc,
                text,
                self.shared.ttf.*,
                wrap_width,
            );
            errdefer text_layout.deinit(alloc);

            const text_buffer = try self.shared.text_renderer.makeTextBuffer(
                alloc,
                text_layout,
                self.shared.ttf.*,
                self.shared.distance_field_generator.*,
            );
            errdefer text_buffer.deinit();

            const duped_text = try alloc.dupe(u8, text);
            errdefer alloc.free(duped_text);

            self.layout.deinit(alloc);
            self.buffer.deinit();
            alloc.free(self.text);

            self.layout = text_layout;
            self.buffer = text_buffer;
            self.text = duped_text;
            self.wrap_width = wrap_width;
        }
    };
}

fn getText(text_retriever: anytype) []const u8 {
    const Ptr = @TypeOf(text_retriever);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "getText")) {
                return text_retriever.getText();
            }
        },
        .Pointer => |p| {
            if (p.child == u8 and p.size == .Slice) {
                return text_retriever.*;
            }

            const child_info = @typeInfo(p.child);
            if (child_info == .Array and child_info.Array.child == u8) {
                return text_retriever.*;
            }

            if (child_info == .Pointer and child_info.Pointer.child == u8 and child_info.Pointer.size == .Slice) {
                return text_retriever.*.*;
            }
        },
        else => {},
    }

    @compileError("text_retriever must be a string or have a getText() function, type is " ++ @typeName(T));
}
