const std = @import("std");
const coords = @import("coords.zig");
const sphmath = @import("sphmath");
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const Transform = sphmath.Transform;
const obj_mod = @import("object.zig");
const PixelDims = obj_mod.PixelDims;

const ViewState = @This();

window_width: usize = 0,
window_height: usize = 0,
viewport_center: Vec2 = .{ 0.0, 0.0 },
zoom_level: f32 = 1.0,

pub fn reset(self: *ViewState) void {
    self.viewport_center = .{ 0.0, 0.0 };
    self.zoom_level = 1.0;
}

pub fn pan(self: *ViewState, movement_obj: Vec2) void {
    self.viewport_center -= movement_obj;
}

pub fn zoom(self: *ViewState, amount: f32) void {
    // Note that amount is in range [-N,N]
    // If we want the zoom adjustment to feel consistent, we need the
    // change from 4-8x to feel the same as the change from 1-2x
    // This means that a multiplicative level feels better than an additive one
    // So we need a function that goes from [-N,N] -> [lower than 1, greater than 1]
    // If we take this to the extreme, we want -inf -> 0, inf -> inf, 1 ->
    // 0. x^y provides this.
    // x^y also has the nice property that x^y*x^z == x^(y+z), which
    // results in merged scroll events acting the same as multiple split
    // events
    // Constant tuned until whatever scroll value we were getting felt ok
    //
    //
    // 1.1^(x+y) == 1.1^x * 1.1^y
    self.zoom_level *= std.math.pow(f32, 1.1, amount);
}

pub fn windowToClipX(self: ViewState, xpos: f32) f32 {
    const window_width_f: f32 = @floatFromInt(self.window_width);
    return ((xpos / window_width_f) - 0.5) * 2;
}

pub fn windowToClipY(self: ViewState, ypos: f32) f32 {
    const window_height_f: f32 = @floatFromInt(self.window_height);
    return (1.0 - (ypos / window_height_f) - 0.5) * 2;
}

pub fn clipToObject(self: ViewState, val: Vec2, object_dims: PixelDims) Vec2 {
    const transform = self.objectToClipTransform(object_dims).invert();
    return sphmath.applyHomogenous(transform.apply(Vec3{ val[0], val[1], 1.0 }));
}

pub fn objectToClipTransform(self: ViewState, object_dims: PixelDims) Transform {
    const aspect_transform = coords.aspectRatioCorrectedFill(
        object_dims[0],
        object_dims[1],
        self.window_width,
        self.window_height,
    );

    return Transform.translate(-self.viewport_center[0], -self.viewport_center[1])
        .then(Transform.scale(self.zoom_level, self.zoom_level))
        .then(aspect_transform);
}

test "test aspect no zoom/pan" {
    const view_state = ViewState{
        .window_width = 100,
        .window_height = 50,
        .viewport_center = .{ 0.0, 0.0 },
        .zoom_level = 1.0,
    };

    const transform = view_state.objectToClipTransform(.{ 50, 100 });
    // Given an object that's 50x100, in a window 100x50
    //
    //  ______________________
    // |       |      |       |
    // |       | o  o |       |
    // |       | ____ |       |
    // |       |      |       |
    // |       |      |       |
    // |_______|______|_______|
    //
    // The object has coordinates of [-1, 1] in both dimensions, as does
    // the window
    //
    // This means that in window space, the object coordinates have be
    // squished, such that the aspect ratio of the object is preserved, and
    // the height stays the same

    const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
    const br_obj = Vec3{ 1.0, -1.0, 1.0 };

    const tl_obj_win = sphmath.applyHomogenous(transform.apply(tl_obj));
    const br_obj_win = sphmath.applyHomogenous(transform.apply(br_obj));

    // Height is essentially preserved
    try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
    try std.testing.expectApproxEqAbs(-1.0, br_obj_win[1], 0.01);

    // Width needs to be scaled in such a way that the aspect ratio 50/100
    // is preserved in _pixel_ space. The window is stretched so that the
    // aspect is 2:1. In a non stretched window, we would expect that
    // 50/100 maps to N/2, so the width of 1/2 needs to be halfed _again_
    // to stay correct in the stretched window
    //
    // New width is then 0.5
    try std.testing.expectApproxEqAbs(-0.25, tl_obj_win[0], 0.01);
    try std.testing.expectApproxEqAbs(0.25, br_obj_win[0], 0.01);
}

test "test aspect with zoom/pan" {
    // Similar to the above test case, but with the viewport moved
    const view_state = ViewState{
        .window_width = 100,
        .window_height = 50,
        .viewport_center = .{ 0.5, 0.5 },
        .zoom_level = 2.0,
    };

    const transform = view_state.objectToClipTransform(.{ 50, 100 });

    const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
    const br_obj = Vec3{ 1.0, -1.0, 1.0 };

    const tl_obj_win = sphmath.applyHomogenous(transform.apply(tl_obj));
    const br_obj_win = sphmath.applyHomogenous(transform.apply(br_obj));

    // Height should essentially be doubled in window space, because the
    // zoom is doubled. We are centered 0.5,0.5 up to the right, so a 2.0
    // height object should be 1.0 above us, and 3.0 below us
    try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
    try std.testing.expectApproxEqAbs(-3.0, br_obj_win[1], 0.01);

    // In unzoomed space, the answer was [-0.25, 0.25]. We are centered at
    // 0.5 in object space, with a 2x zoom. The 2x zoom gives moves the
    // total range to 1.0. We are centered 1/4 to the right, which means we
    // have 0.25 to the right, and 0.75 to the left
    try std.testing.expectApproxEqAbs(-0.75, tl_obj_win[0], 0.01);
    try std.testing.expectApproxEqAbs(0.25, br_obj_win[0], 0.01);
}
