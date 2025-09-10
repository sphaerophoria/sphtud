const sphalloc = @import("sphalloc");
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const gl = sphrender.gl;
const gui = @import("gui.zig");
const std = @import("std");

pub fn multiLineGraph(comptime Action: type, alloc: sphrender.RenderAlloc, shared: *const Shared, retrievers: anytype) !gui.Widget(Action) {
    const T = MultiLineGraph(@TypeOf(retrievers[0]), Action);

    const ret = try alloc.heap.arena().create(T);

    const graph_states = try alloc.heap.arena().alloc(SingleGraphState, retrievers.len);
    for (graph_states) |*item| {
        item.* = .{
            .generation = std.math.maxInt(usize),
            .render_source = try sphrender.xyt_program.RenderSource.init(alloc.gl),
            .render_buf = try sphrender.xyt_program.Buffer.init(alloc.gl, &.{}),
            .hover_point = null,
        };

        item.render_source.bindData(shared.solid_color_renderer.handle(), item.render_buf);
    }

    const texts = try alloc.heap.arena().alloc(
        gui.gui_text.GuiText(*SingleGraphState),
        retrievers.len,
    );

    for (texts, graph_states) |*text, *graph_state| {
        text.* = try gui.gui_text.guiText(alloc, shared.guitext_shared, graph_state);
    }

    ret.* = .{
        .zoom = 1.0,
        .retrievers = retrievers,
        .graph_states = graph_states,
        .labels = texts,
        .x_scale = 1.0,
        .y_scale = 1.0,
        .shared = shared,
    };

    return .{
        .vtable = &T.vtable,
        .name = "multi_line_graph",
        .ctx = ret,
    };
}

pub const Style = struct {
    label_color_width: u31,
    label_color_margin: u31,
    hover_ratio_size: f32,
};

pub const Shared = struct {
    scratch: sphalloc.LinearAllocator,
    style: Style,
    squircle_renderer: *const gui.SquircleRenderer,
    squircle_corner_radius_px: f32,
    solid_color_renderer: *sphrender.xyt_program.SolidColorProgram,
    solid_color_full_screen_source: sphrender.xyt_program.RenderSource,
    guitext_shared: *const gui.gui_text.SharedState,

    pub fn init(
        gl_alloc: *sphrender.GlAlloc,
        scratch: sphalloc.LinearAllocator,
        style: Style,
        squircle_renderer: *const gui.SquircleRenderer,
        squircle_corner_radius_px: f32,
        solid_color_renderer: *sphrender.xyt_program.SolidColorProgram,
        guitext_shared: *const gui.gui_text.SharedState,
    ) !Shared {
        const full_screen_buf = try sphrender.xyt_program.Buffer.init(gl_alloc, &.{
            .{ .vPos = .{ -1, -1 } },
            .{ .vPos = .{ -1, 1 } },
            .{ .vPos = .{ 1, 1 } },

            .{ .vPos = .{ -1, -1 } },
            .{ .vPos = .{ 1, 1 } },
            .{ .vPos = .{ 1, -1 } },
        });
        var full_screen_source = try sphrender.xyt_program.RenderSource.init(gl_alloc);
        full_screen_source.bindData(solid_color_renderer.handle(), full_screen_buf);

        return .{
            .scratch = scratch,
            .style = style,
            .squircle_renderer = squircle_renderer,
            .squircle_corner_radius_px = squircle_corner_radius_px,
            .solid_color_renderer = solid_color_renderer,
            .solid_color_full_screen_source = full_screen_source,
            .guitext_shared = guitext_shared,
        };
    }
};

pub const GraphPoint = struct {
    x: f32,
    y: f32,
};

const SingleGraphState = struct {
    generation: usize = std.math.maxInt(usize),
    render_source: sphrender.xyt_program.RenderSource,
    render_buf: sphrender.xyt_program.Buffer,
    hover_point: ?GraphPoint,
    label_buf: [100]u8 = undefined,

    pub fn getText(self: *@This()) []const u8 {
        const p = self.hover_point orelse return "";

        return std.fmt.bufPrint(
            &self.label_buf,
            "{d} -> {d}",
            .{ p.x, p.y },
        ) catch
            &self.label_buf;
    }
};

pub fn MultiLineGraph(comptime Retriever: type, comptime Action: type) type {
    return struct {
        size: gui.PixelSize = .{},

        // How much to blow up the graph, relative to it's default size
        zoom: f32,

        // Multipliers to put graph points in the range of [0,1]
        x_scale: f32,
        y_scale: f32,

        retrievers: []Retriever,
        graph_states: []SingleGraphState,
        labels: []gui.gui_text.GuiText(*SingleGraphState),
        shared: *const Shared,

        const Self = @This();

        const vtable = gui.Widget(Action).VTable{
            .render = render,
            .getSize = getSize,
            .update = update,
            .setInputState = setInputState,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const graph_bounds = self.graphBoundsFromWidgetBounds(widget_bounds);
            const graph_to_clip = self.graphToClipTxfm(graph_bounds, window_bounds);

            {
                var scissor = sphrender.TemporaryScissor.init();
                defer scissor.reset();

                scissor.set(
                    graph_bounds.left,
                    window_bounds.calcHeight() - graph_bounds.bottom,
                    graph_bounds.calcWidth(),
                    graph_bounds.calcHeight(),
                );

                self.renderGraphs(graph_to_clip);
                self.renderHoverIndicators(graph_bounds, graph_to_clip);
            }

            self.renderLabels(graph_bounds, widget_bounds, window_bounds);
        }

        fn renderGraphs(self: *Self, graph_to_clip: sphmath.Transform) void {
            gl.glLineWidth(3.0);

            for (self.retrievers, self.graph_states) |r, gs| {
                if (!r.getEnable()) continue;

                const color = r.getColor();
                self.shared.solid_color_renderer.renderLineStrip(gs.render_source, .{
                    .color = .{ color.r, color.g, color.b },
                    .transform = graph_to_clip.inner,
                });
            }
        }

        fn renderHoverIndicators(self: *Self, graph_bounds: gui.PixelBBox, graph_to_clip: sphmath.Transform) void {
            const graph_aspect = asf32(graph_bounds.calcWidth()) / asf32(graph_bounds.calcHeight());

            // Takes the full screen [-1, 1] square and turns it into a
            // small square in graph space. This allows us to
            // manipulate it's position in graph space easily below
            const small_square_txfm = sphmath.Transform.scale(
                self.shared.style.hover_ratio_size * 1 / self.x_scale,
                self.shared.style.hover_ratio_size * 1 / self.y_scale / self.zoom * graph_aspect,
            );

            for (self.retrievers, self.graph_states) |r, gs| {
                const color = r.getColor();
                if (gs.hover_point) |hp| {
                    const hover_txfm = small_square_txfm
                        .then(.translate(hp.x, hp.y))
                        .then(graph_to_clip);

                    self.shared.solid_color_renderer.render(
                        self.shared.solid_color_full_screen_source,
                        .{
                            .color = .{ color.r, color.g, color.b },
                            .transform = hover_txfm.inner,
                        },
                    );
                }
            }
        }

        fn renderLabels(self: *Self, graph_bounds: gui.PixelBBox, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
            const label_left = widget_bounds.left + self.shared.style.label_color_width;
            var label_top = graph_bounds.bottom + self.shared.style.label_color_margin;
            for (self.retrievers, self.graph_states, self.labels) |r, gs, l| {
                if (!r.getEnable() or gs.hover_point == null) {
                    continue;
                }

                const color = r.getColor();
                const label_size = l.size();

                const label_bbox = gui.PixelBBox{
                    .top = label_top,
                    .left = label_left,
                    .right = label_left + label_size.width,
                    .bottom = label_top + label_size.height,
                };

                label_top = label_bbox.bottom + self.shared.style.label_color_margin;

                l.render(gui.util.widgetToClipTransform(label_bbox, window_bounds));

                const color_bbox = gui.PixelBBox{
                    .left = widget_bounds.left + self.shared.style.label_color_margin,
                    .top = label_bbox.top,
                    .bottom = label_bbox.bottom,
                    .right = label_left - self.shared.style.label_color_margin,
                };

                self.shared.squircle_renderer.render(
                    color,
                    self.shared.squircle_corner_radius_px,
                    color_bbox,
                    gui.util.widgetToClipTransform(color_bbox, window_bounds),
                );
            }
        }

        fn graphToClipTxfm(self: *Self, graph_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) sphmath.Transform {
            return sphmath.Transform.scale(self.x_scale * 2, self.y_scale * 2)
                .then(.translate(-1.0, -1.0))
                .then(.scale(1.0, self.zoom))
                .then(.translate(0, self.zoom - 1))
                .then(gui.util.widgetToClipTransform(graph_bounds, window_bounds));
        }

        fn getSize(ctx: ?*anyopaque) gui.PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: gui.PixelSize, _: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;

            var acc = BoundsAccumulator{};

            for (self.retrievers, self.graph_states) |*retriever, *graph_state| {
                const data_generation = retriever.getGeneration();

                acc.pushBounds(retriever.getBounds());

                if (data_generation != graph_state.generation) {
                    try self.regenerateGlBuffers(retriever, graph_state);
                    graph_state.generation = data_generation;
                }
            }

            self.x_scale = 1.0 / acc.max_x;
            self.y_scale = 1.0 / acc.max_y;

            for (self.labels) |*label| {
                try label.update(available_size.width - self.shared.style.label_color_width);
            }
        }

        fn regenerateGlBuffers(self: *Self, retriever: *Retriever, graph_state: *SingleGraphState) !void {
            const cp = self.shared.scratch.checkpoint();
            defer self.shared.scratch.restore(cp);

            var gl_buf = try sphutil.RuntimeBoundedArray(sphrender.xyt_program.Vertex).init(
                self.shared.scratch.allocator(),
                retriever.len(),
            );

            var it = retriever.iter();
            while (it.next()) |point| {
                try gl_buf.append(.{ .vPos = .{ point.x, point.y } });
            }

            graph_state.render_buf.updateBuffer(gl_buf.items);
            graph_state.render_source.setLen(gl_buf.items.len);
        }

        fn labelAreaHeight(self: Self) u31 {
            var sum: u31 = 0;
            for (self.labels) |label| {
                sum += label.size().height;
                sum += self.shared.style.label_color_margin;
            }
            return sum;
        }

        fn graphBoundsFromWidgetBounds(self: Self, widget_bounds: gui.PixelBBox) gui.PixelBBox {
            var graph_bounds = widget_bounds;
            graph_bounds.bottom -= self.labelAreaHeight();
            // 10 pixel arbitrary right margin to allow hovering last element
            graph_bounds.right -= 10;
            return graph_bounds;
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            for (self.graph_states) |*gs| {
                gs.hover_point = null;
            }

            if (!input_bounds.containsMousePos(input_state.mouse_pos)) {
                return .{};
            }

            self.zoom *= std.math.pow(f32, 1.1, input_state.frame_scroll);
            self.zoom = @max(self.zoom, 1.0);
            input_state.consumeScroll();

            const graph_bounds = self.graphBoundsFromWidgetBounds(widget_bounds);
            const mouse_x_px = input_state.mouse_pos.x - asf32(graph_bounds.left);
            const mouse_x_norm = mouse_x_px / asf32(graph_bounds.calcWidth());
            for (self.retrievers, self.graph_states) |*r, *gs| {
                if (!r.getEnable()) continue;
                gs.hover_point = r.closestPoint(mouse_x_norm / self.x_scale);
            }

            return .{};
        }
    };
}

const BoundsAccumulator = struct {
    max_x: f32 = 0,
    max_y: f32 = 0,

    fn pushBounds(self: *BoundsAccumulator, bounds: GraphPoint) void {
        self.max_x = @max(bounds.x, self.max_x);
        self.max_y = @max(bounds.y, self.max_y);
    }
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}
