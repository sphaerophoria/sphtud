const lin = @import("lin.zig");

const Transform = lin.Transform;

pub fn calcAspect(width: usize, height: usize) f32 {
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);

    return width_f / height_f;
}

pub fn aspectRatioCorrectedFill(inner_w: usize, inner_h: usize, outer_w: usize, outer_h: usize) Transform {
    return aspectsToCorrectedTransform(
        calcAspect(inner_w, inner_h),
        calcAspect(outer_w, outer_h),
    );
}

fn aspectsToCorrectedTransform(inner_aspect: f32, outer_aspect: f32) Transform {
    if (outer_aspect > inner_aspect) {
        return Transform.scale(inner_aspect / outer_aspect, 1.0);
    } else {
        return Transform.scale(1.0, outer_aspect / inner_aspect);
    }
}
