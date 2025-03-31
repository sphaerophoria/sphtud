const gui = @import("sphui");
const UiAction = @import("ui_action.zig").UiAction;
const ImageDrawer = @import("ImageDrawer.zig");
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const SquircleRenderer = gui.SquircleRenderer;
const RenderAlloc = sphrender.RenderAlloc;
const xyt = sphrender.xyt_program;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

const ImageDrawerTab = @This();

drawer: *ImageDrawer,
squircle_renderer: *const SquircleRenderer,
chevron_program: ChevronProgram,
chevron_render_source: ChevronRenderSource,
tab_size: PixelSize,
tab_hover_color: gui.Color,
tab_state: enum {
    default,
    hovered,
} = .default,

pub fn init(
    alloc: RenderAlloc,
    drawer: *ImageDrawer,
    squircle_renderer: *const SquircleRenderer,
    tab_size: PixelSize,
    tab_hover_color: gui.Color,
) !*ImageDrawerTab {
    const chevron_program = try ChevronProgram.init(alloc.gl, constant_color_shader);
    const width_clip = 0.7;
    const left_pos = -0.7;
    const chevron_buffer = try sphrender.xyt_program.Buffer.init(alloc.gl, &.{
        .{ .vPos = .{ left_pos, 1.0 } },
        .{ .vPos = .{ left_pos + width_clip, 1.0 } },
        .{ .vPos = .{ 1.0, 0.0 } },

        .{ .vPos = .{ left_pos, 1.0 } },
        .{ .vPos = .{ 1.0, 0.0 } },
        .{ .vPos = .{ 1.0 - width_clip, 0.0 } },

        .{ .vPos = .{ left_pos, -1.0 } },
        .{ .vPos = .{ 1.0 - width_clip, 0.0 } },
        .{ .vPos = .{ 1.0, 0.0 } },

        .{ .vPos = .{ left_pos, -1.0 } },
        .{ .vPos = .{ 1.0, 0.0 } },
        .{ .vPos = .{ left_pos + width_clip, -1.0 } },
    });

    var chevron_render_source = try ChevronRenderSource.init(alloc.gl);
    chevron_render_source.bindData(chevron_program.handle(), chevron_buffer);

    const ret = try alloc.heap.arena().create(ImageDrawerTab);
    ret.* = .{
        .drawer = drawer,
        .squircle_renderer = squircle_renderer,
        .tab_size = tab_size,
        .tab_hover_color = tab_hover_color,
        .chevron_program = chevron_program,
        .chevron_render_source = chevron_render_source,
    };
    return ret;
}

pub fn asWidget(self: *ImageDrawerTab) gui.Widget(UiAction) {
    return .{
        .ctx = self,
        .name = "drawer tab",
        .vtable = &widget_vtable,
    };
}

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = ImageDrawerTab.render,
    .getSize = ImageDrawerTab.getSize,
    .setInputState = ImageDrawerTab.setInputState,
    .update = null,
    .setFocused = null,
    .reset = null,
};

fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *ImageDrawerTab = @ptrCast(@alignCast(ctx));
    const tab_color = switch (self.tab_state) {
        .default => self.drawer.style.background_color,
        .hovered => self.tab_hover_color,
    };

    self.squircle_renderer.render(
        tab_color,
        0,
        widget_bounds,
        gui.util.widgetToClipTransform(widget_bounds, window_bounds),
    );

    const widget_width = widget_bounds.calcWidth();
    const widget_height = widget_bounds.calcHeight();
    const x_inset = widget_width / 3;
    const y_inset = widget_height / 3;
    const chevron_bounds = PixelBBox{
        .left = widget_bounds.left + x_inset,
        .right = widget_bounds.right - x_inset,
        .top = widget_bounds.top + y_inset,
        .bottom = widget_bounds.bottom - y_inset,
    };

    const initial_txfm = if (self.drawer.drawer_state.actionIsOpen())
        sphmath.Transform.scale(-1.0, 1.0)
    else
        sphmath.Transform.identity;

    self.chevron_program.render(
        self.chevron_render_source,
        .{
            .color = .{ 1.0, 1.0, 1.0 },
            .transform = initial_txfm.then(gui.util.widgetToClipTransform(chevron_bounds, window_bounds)).inner,
        },
    );
}

fn getSize(ctx: ?*anyopaque) PixelSize {
    const self: *ImageDrawerTab = @ptrCast(@alignCast(ctx));
    return self.tab_size;
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(UiAction) {
    const self: *ImageDrawerTab = @ptrCast(@alignCast(ctx));
    _ = widget_bounds;

    if (input_bounds.containsMousePos(input_state.mouse_pos)) {
        self.tab_state = .hovered;
    } else {
        self.tab_state = .default;
    }

    if (input_state.mouse_pressed and input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
        self.drawer.toggleOpenState();
    }

    return .{
        .wants_focus = false,
        .action = null,
    };
}

const constant_color_shader =
    \\#version 330
    \\
    \\out vec4 fragment;
    \\uniform vec3 color = vec3(1.0, 1.0, 1.0);
    \\
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;

const ChevronUniform = struct {
    color: sphmath.Vec3,
    transform: sphmath.Mat3x3,
};

const ChevronProgram = xyt.Program(ChevronUniform);
const ChevronRenderSource = xyt.RenderSource;
