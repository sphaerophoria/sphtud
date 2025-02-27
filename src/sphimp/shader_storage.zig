const std = @import("std");
const Allocator = std.mem.Allocator;
const Renderer = @import("Renderer.zig");
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const memory_limits = @import("memory_limits.zig");
const GlAlloc = sphrender.GlAlloc;
const RenderAlloc = sphrender.RenderAlloc;
const RuntimeSegmentedList = @import("sphutil").RuntimeSegmentedList;
const ScratchAlloc = @import("sphalloc").ScratchAlloc;

pub const Save = struct {
    name: []const u8,
    fs_source: [:0]const u8,
};

pub const ShaderId = struct { value: usize };
pub const BrushId = struct { value: usize };

pub fn ShaderStorage(comptime IdType: type) type {
    return struct {
        alloc: RenderAlloc,
        storage: RuntimeSegmentedList(Item),
        const Self = @This();

        pub const Id = IdType;

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

        pub fn init(alloc: RenderAlloc) !Self {
            return .{
                .alloc = alloc,
                .storage = try RuntimeSegmentedList(Item).init(
                    alloc.heap.arena(),
                    alloc.heap.block_alloc.allocator(),
                    memory_limits.initial_shader_storage,
                    memory_limits.shader_storage_max,
                ),
            };
        }

        pub const Item = struct {
            name: []const u8,
            program: Program,
            uniforms: sphrender.shader_program.UnknownUniforms,
            buffer: sphrender.xyuvt_program.Buffer,
            fs_source: [:0]const u8,

            fn save(self: Item) Save {
                return .{
                    .name = self.name,
                    .fs_source = self.fs_source,
                };
            }
        };

        pub fn idIter(self: Self) ShaderIdIterator {
            return .{ .max = self.storage.len };
        }

        pub fn addShader(self: *Self, name: []const u8, fs_source: [:0]const u8, scratch: *ScratchAlloc) !Id {
            const id = Id{ .value = self.storage.len };

            const shader_alloc = try self.alloc.makeSubAlloc("shader");
            errdefer shader_alloc.deinit();

            const arena = shader_alloc.heap.arena();

            const name_duped = try arena.dupe(u8, name);
            const program = try Program.init(self.alloc.gl, fs_source);

            const scratch_uniforms = try program.unknownUniforms(scratch);
            const unknown_uniforms = try scratch_uniforms.clone(shader_alloc.heap.arena());
            const buffer = try program.makeFullScreenPlane(self.alloc.gl);

            try self.storage.append(.{
                .name = name_duped,
                .program = program,
                .buffer = buffer,
                .uniforms = unknown_uniforms,
                .fs_source = try arena.dupeZ(u8, fs_source),
            });
            return id;
        }

        pub fn numItems(self: Self) usize {
            return self.storage.len;
        }

        pub fn get(self: Self, id: Id) Item {
            return self.storage.get(id.value);
        }

        pub fn save(self: Self, alloc: Allocator) ![]Save {
            const saves = try alloc.alloc(Save, self.storage.len);

            var it = self.storage.sliceIter();
            var output_save: usize = 0;
            while (it.next()) |slice| {
                for (slice) |elem| {
                    saves[output_save] = elem.save();
                    output_save += 1;
                }
            }

            return saves;
        }
    };
}
