const sphimp = @import("sphimp");
const gui = @import("sphui");
const ObjectId = sphimp.object.ObjectId;

pub const ShaderUniform = struct {
    app: *sphimp.App,
    id: ObjectId,
    uniform_idx: usize,

    pub fn getColor(self: ShaderUniform) gui.Color {
        const black = gui.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
        const bindings = self.app.objects.get(self.id).shaderBindings() orelse return black;

        switch (bindings[self.uniform_idx]) {
            .float3 => |f| {
                return .{ .r = f[0], .g = f[1], .b = f[2], .a = 1.0 };
            },
            else => return black,
        }
    }
};
