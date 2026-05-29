const std = @import("std");
const sphmath = @import("../math.zig");
const gui = @import("../ui.zig");
const sphrender = @import("../render.zig");
const sphalloc = @import("../alloc.zig");
const util = @import("../ui/util.zig");

pub const MemoryTracker = sphalloc.MemoryTracker;

const MemoryWidget = @This();

const Program = sphrender.shader_program.Program;
const GraphBuffer = sphrender.shader_program.Buffer(Vert);
const RenderSource = sphrender.shader_program.RenderSource;

const Vert = struct {
    vPos: sphmath.Vec2,
};

const Uniform = struct {
    transform: sphmath.Mat3x3,
};

pub const Shared = struct {
    scratch: *sphalloc.ScratchAlloc,
    label_shared: *const gui.Label.SharedState,
    scroll_shared: *const gui.scrollbar.Shared,
    program: Program(Uniform),
    label_width: u31,
    item_pad: u31,
    graph_height: u31,
    max_height: u31,

    pub fn init(
        gl_alloc: *sphrender.GlAlloc,
        scratch: *sphalloc.ScratchAlloc,
        label_shared: *const gui.Label.SharedState,
        scroll_shared: *const gui.scrollbar.Shared,
        label_width: u31,
        item_pad: u31,
        graph_height: u31,
        max_height: u31,
    ) !Shared {
        return .{
            .scratch = scratch,
            .label_shared = label_shared,
            .scroll_shared = scroll_shared,
            .program = try Program(Uniform).init(gl_alloc, vertex_shader, fragment_shader),
            .label_width = label_width,
            .item_pad = item_pad,
            .graph_height = graph_height,
            .max_height = max_height,
        };
    }
};

const Graph = struct {
    parent: *MemoryWidget,
    memory_tracker_idx: usize,
    buffer: GraphBuffer,
    render_source: RenderSource,
    widget: gui.Widget,

    fn graphUpdate(widget: *gui.Widget, available_size: gui.PixelSize, _: f32) anyerror!void {
        const self: *Graph = @fieldParentPtr("widget", widget);
        widget.size = .{ .width = available_size.width, .height = self.parent.shared.graph_height };

        const graph_elem = self.parent.snapshot[self.memory_tracker_idx];
        const max_sample_f: f32 = @floatFromInt(graph_elem.max);

        const scratch = self.parent.shared.scratch;
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const verts = try scratch.allocator().alloc(Vert, (graph_elem.samples.len - 1) * 6);
        @memset(verts, .{ .vPos = .{ 0, 0 } });

        var last = sampleToClip(graph_elem.samples[0], 0, max_sample_f, graph_elem.samples.len);
        for (graph_elem.samples[1..], 0..) |s, i| {
            const cur = sampleToClip(s, i + 1, max_sample_f, graph_elem.samples.len);
            setLineSegment(last, cur, verts[i * 6 ..][0..6]);
            last = cur;
        }

        self.buffer.updateBuffer(verts);
        self.render_source.len = self.buffer.len;
    }

    fn graphRender(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *Graph = @fieldParentPtr("widget", widget);
        const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
        self.parent.shared.program.render(self.render_source, .{ .transform = transform.inner });
    }
};

const Row = struct {
    label: gui.Label,
    graph: Graph,
    name_buf: [256]u8 = undefined,
};

memory_tracker: *const MemoryTracker,
snapshot_alloc: *sphalloc.Sphalloc,
snapshot: []MemoryTracker.AllocSamples,
item_alloc: gui.GuiAlloc,
rows: []Row,
grid: gui.Grid,
scroll_view: gui.ScrollView,
shared: *const Shared,
widget: gui.Widget,

pub fn init(alloc: gui.GuiAlloc, memory_tracker: *const MemoryTracker, shared: *const Shared) !*MemoryWidget {
    const ret = try alloc.heap.arena().create(MemoryWidget);

    const grid_cols = [_]gui.Grid.ColumnConfig{
        .{ .width = .{ .fixed = shared.label_width }, .horizontal_justify = .left, .vertical_justify = .center },
        .{ .width = .{ .ratio = 1 }, .horizontal_justify = .left, .vertical_justify = .center },
    };

    ret.grid = try gui.Grid.init(alloc.heap.arena(), alloc.heap.expansion(), &grid_cols, shared.item_pad);
    ret.scroll_view = gui.ScrollView.init(&ret.grid.widget, shared.scroll_shared);
    ret.item_alloc = try alloc.makeSubAlloc("memory_widget_items");
    ret.snapshot_alloc = try alloc.heap.makeSubAlloc("memory_widget_snapshot");
    ret.memory_tracker = memory_tracker;
    ret.shared = shared;
    ret.snapshot = &.{};
    ret.rows = &.{};
    ret.widget = .{
        .focused = false,
        .size = .{},
        .vtable = &.{
            .update = widgetUpdate,
            .render = widgetRender,
            .input = widgetInput,
            .reset = null,
        },
    };
    return ret;
}

fn widgetUpdate(widget: *gui.Widget, available_size: gui.PixelSize, delta_s: f32) anyerror!void {
    const self: *MemoryWidget = @fieldParentPtr("widget", widget);

    // Collect snapshot, using scratch for temporary work
    const cp = self.shared.scratch.checkpoint();
    defer self.shared.scratch.restore(cp);

    self.snapshot = &.{};
    try self.snapshot_alloc.reset();
    self.snapshot = try self.memory_tracker.collect(
        self.snapshot_alloc.arena(),
        self.shared.scratch.linear(),
    );

    // Rebuild grid rows if count changed
    if (self.rows.len != self.snapshot.len) {
        self.grid.clear();
        self.rows = &.{};
        try self.item_alloc.reset();

        const rows = try self.item_alloc.heap.arena().alloc(Row, self.snapshot.len);
        self.rows = rows;

        for (rows, 0..) |*row, i| {
            row.label = try gui.Label.init(self.item_alloc, self.shared.label_shared, "", .white);

            var render_source = try RenderSource.init(self.item_alloc.gl);
            const buffer = try GraphBuffer.init(self.item_alloc.gl, &.{});
            render_source.bindData(Vert, self.shared.program.handle, buffer);

            row.graph = .{
                .parent = self,
                .memory_tracker_idx = i,
                .buffer = buffer,
                .render_source = render_source,
                .widget = .{
                    .focused = false,
                    .size = .{},
                    .vtable = &.{
                        .update = Graph.graphUpdate,
                        .render = Graph.graphRender,
                        .input = null,
                        .reset = null,
                    },
                },
            };

            try self.grid.append(&row.label.widget);
            try self.grid.append(&row.graph.widget);
        }
    }

    // Update label text for each row
    for (self.rows, self.snapshot) |*row, elem| {
        const last_size = if (elem.samples.len > 0) elem.samples[elem.samples.len - 1] else 0;
        const text = try std.fmt.bufPrint(&row.name_buf, "{s} ({d})", .{
            elem.name,
            last_size,
        });
        try row.label.setText(text);
    }

    // Use a fixed max_height so we don't collapse when the outer layout
    // passes available.height = 0 (e.g. when scrolled off-screen).
    const scroll_available = gui.PixelSize{
        .width = available_size.width,
        .height = self.shared.max_height,
    };
    try self.scroll_view.widget.update(scroll_available, delta_s);
    self.widget.size = self.scroll_view.widget.size;
}

fn widgetRender(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *MemoryWidget = @fieldParentPtr("widget", widget);
    self.scroll_view.widget.render(widget_bounds, window_bounds);
}

fn widgetInput(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
    const self: *MemoryWidget = @fieldParentPtr("widget", widget);
    try self.scroll_view.widget.input(widget_bounds, input_bounds, input_state);
}

fn sampleToClip(sample: usize, idx: usize, max_f: f32, num_samples: usize) sphmath.Vec2 {
    const denom: f32 = @floatFromInt(num_samples -| 1);
    const x = if (denom < 1e-7) -1.0 else 2.0 * @as(f32, @floatFromInt(idx)) / denom - 1.0;
    const y: f32 = if (max_f < 1e-7) -1.0 else 2.0 * @as(f32, @floatFromInt(sample)) / max_f - 1.0;
    return .{ x, y };
}

fn setLineSegment(a: sphmath.Vec2, b: sphmath.Vec2, out: []Vert) void {
    const p1 = sphmath.Vec2{ a[0], -1.0 };
    const p2 = a;
    const p3 = b;
    const p4 = sphmath.Vec2{ b[0], -1.0 };
    out[0] = .{ .vPos = p1 };
    out[1] = .{ .vPos = p2 };
    out[2] = .{ .vPos = p3 };
    out[3] = .{ .vPos = p1 };
    out[4] = .{ .vPos = p3 };
    out[5] = .{ .vPos = p4 };
}

// FIXME: Use xyt program
// FIXME: Constant color program
pub const vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\}
;

pub const fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    fragment = vec4(1.0, 1.0, 1.0, 1.0);
    \\}
;
