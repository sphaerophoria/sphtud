const std = @import("std");
const Allocator = std.mem.Allocator;
const Renderer = @import("Renderer.zig");
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");

pub const Save = struct {
    name: []const u8,
    fs_source: [:0]const u8,
};

pub const ShaderId = struct { value: usize };
pub const BrushId = struct { value: usize };

pub fn ShaderStorage(comptime Id: type) type {
    return struct {
        storage: std.ArrayListUnmanaged(Item) = .{},
        const Self = @This();

        pub const ShaderIdIterator = struct {
            i: usize = 0,
            max: usize,

            pub fn next(self: *ShaderIdIterator) ?Id {
                if (self.i >= self.max) {
                    return null;
                }

                defer self.i += 1;
                return .{ .value = self.i };
            }
        };

        const Program = if (Id == ShaderId)
            sphrender.xyuvt_program.Program(Renderer.CustomShaderUniforms)
        else if (Id == BrushId)
            sphrender.xyuvt_program.Program(Renderer.BrushUniforms)
        else
            @compileError("Unknown shader id");

        pub const Item = struct {
            name: []const u8,
            program: Program,
            uniforms: sphrender.shader_program.UnknownUniforms,
            buffer: sphrender.xyuvt_program.Buffer,
            fs_source: [:0]const u8,

            fn deinit(self: *Item, alloc: Allocator) void {
                alloc.free(self.name);
                alloc.free(self.fs_source);
                self.buffer.deinit();
                self.uniforms.deinit(alloc);
                self.program.deinit();
            }

            fn save(self: Item) Save {
                return .{
                    .name = self.name,
                    .fs_source = self.fs_source,
                };
            }
        };

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.storage.items) |*shader| {
                shader.deinit(alloc);
            }
            self.storage.deinit(alloc);
        }

        pub fn idIter(self: Self) ShaderIdIterator {
            return .{ .max = self.storage.items.len };
        }

        pub fn addShader(self: *Self, alloc: Allocator, name: []const u8, fs_source: [:0]const u8) !Id {
            const id = Id{ .value = self.storage.items.len };

            const name_duped = try alloc.dupe(u8, name);
            errdefer alloc.free(name_duped);

            const program = try Program.init(fs_source);
            errdefer program.deinit();

            const duped_fs_source = try alloc.dupeZ(u8, fs_source);
            errdefer alloc.free(duped_fs_source);

            const unknown_uniforms = try program.unknownUniforms(alloc);
            errdefer unknown_uniforms.deinit(alloc);

            const buffer = program.makeFullScreenPlane();
            errdefer buffer.deinit();

            try self.storage.append(alloc, .{
                .name = name_duped,
                .program = program,
                .buffer = buffer,
                .uniforms = unknown_uniforms,
                .fs_source = duped_fs_source,
            });
            return id;
        }

        pub fn numItems(self: Self) usize {
            return self.storage.items.len;
        }

        pub fn get(self: Self, id: Id) Item {
            return self.storage.items[id.value];
        }

        pub fn save(self: Self, alloc: Allocator) ![]Save {
            const saves = try alloc.alloc(Save, self.storage.items.len);
            errdefer alloc.free(saves);

            for (0..self.storage.items.len) |i| {
                saves[i] = self.storage.items[i].save();
            }

            return saves;
        }
    };
}
