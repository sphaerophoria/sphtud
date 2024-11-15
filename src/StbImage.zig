const stbi = @cImport({
    @cInclude("stb_image.h");
});

const StbImage = @This();

data: []u8,
width: usize,

pub fn init(path: [:0]const u8) !StbImage {
    var width: c_int = 0;
    var height: c_int = 0;
    stbi.stbi_set_flip_vertically_on_load(1);
    const data = stbi.stbi_load(path, &width, &height, null, 4);

    if (data == null) {
        return error.NoData;
    }

    errdefer stbi.stbi_image_free(data);

    if (width < 0) {
        return error.InvalidWidth;
    }

    return .{
        .data = data[0..@intCast(width * height * 4)],
        .width = @intCast(width),
    };
}

pub fn deinit(self: StbImage) void {
    stbi.stbi_image_free(@ptrCast(self.data.ptr));
}

pub fn calcHeight(self: StbImage) usize {
    return self.data.len / self.width / 4;
}
