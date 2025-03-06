pub const DrawingTool = enum { brush, eraser };

pub const ToolParams = struct {
    active_drawing_tool: DrawingTool = .brush,
    eraser_width: f32 = 0.02,
    composition_debug: bool = false,
};
