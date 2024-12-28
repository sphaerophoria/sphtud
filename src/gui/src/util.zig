const std = @import("std");
const gui = @import("gui.zig");
const sphmath = @import("sphmath");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const MousePos = gui.MousePos;
const InputState = gui.InputState;

pub fn widgetToClipTransform(bounds: PixelBBox, window: PixelBBox) sphmath.Transform {
    return sphmath.Transform.scale(
        widgetToClipScale(bounds.calcWidth(), window.calcWidth()),
        widgetToClipScale(bounds.calcHeight(), window.calcHeight()),
    ).then(sphmath.Transform.translate(
        widgetToClipCenterX(bounds.cx(), window.cx()),
        widgetToClipCenterY(bounds.cy(), window.cy()),
    ));
}

pub fn widgetToClipScale(widget_size: i32, window_size: i32) f32 {
    const widget_size_f: f32 = @floatFromInt(widget_size);
    const window_size_f: f32 = @floatFromInt(window_size);
    return widget_size_f / window_size_f;
}

pub fn widgetToClipCenterX(widget_center: f32, window_center: f32) f32 {
    return (widget_center - window_center) / window_center;
}

pub fn widgetToClipCenterY(widget_center: f32, window_center: f32) f32 {
    return -(widget_center - window_center) / window_center;
}

pub fn centerBoxInBounds(box: PixelSize, bounds: PixelBBox) PixelBBox {
    const width_pad = bounds.calcWidth() -| box.width;
    const height_pad = bounds.calcHeight() -| box.height;
    const half_width_pad = @divTrunc(width_pad, 2);
    const half_height_pad = @divTrunc(height_pad, 2);

    var output = bounds;
    output.left += half_width_pad;
    output.right = output.left + box.width;
    output.top += half_height_pad;
    output.bottom = output.top + box.height;

    return output;
}

pub fn itemConsumesInput(item_bounds: PixelBBox, input_state: InputState) bool {
    // Maybe widgets should say if they consume input...
    if (input_state.mouse_down_location) |loc| {
        return item_bounds.containsMousePos(loc);
    } else {
        return item_bounds.containsMousePos(input_state.mouse_pos);
    }
}
