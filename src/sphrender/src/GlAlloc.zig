const std = @import("std");
const gl = @import("gl");
const sphalloc = @import("sphalloc");
const sphutil = @import("sphutil");
const RuntimeSegmentedList = sphutil.RuntimeSegmentedList;
const Sphalloc = sphalloc.Sphalloc;

// I'm not going to bother with implementing unmanaged versions of these right
// now
alloc: *Sphalloc,
vbos: RuntimeSegmentedList(gl.GLuint),
vaos: RuntimeSegmentedList(gl.GLuint),
programs: RuntimeSegmentedList(gl.GLuint),
textures: RuntimeSegmentedList(gl.GLuint),
children: RuntimeSegmentedList(*GlAlloc),
parent: ?*GlAlloc = null,

const GlAlloc = @This();

pub fn init(alloc: *Sphalloc) !GlAlloc {
    const typical_size = 5;
    const max_size = 1000;
    return .{
        .alloc = alloc,
        .vbos = try RuntimeSegmentedList(gl.GLuint).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            typical_size,
            max_size,
        ),
        .vaos = try RuntimeSegmentedList(gl.GLuint).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            typical_size,
            max_size,
        ),
        .programs = try RuntimeSegmentedList(gl.GLuint).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            typical_size,
            max_size,
        ),
        .textures = try RuntimeSegmentedList(gl.GLuint).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            typical_size,
            max_size,
        ),
        .children = try RuntimeSegmentedList(*GlAlloc).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            typical_size,
            max_size,
        ),
    };
}

pub fn deinit(self: *GlAlloc) void {
    self.reset();
    if (self.parent) |p| {
        p.removeChild(self) catch {
            std.log.warn("GlAlloc leaked", .{});
        };
    }
}

pub fn removeChild(self: *GlAlloc, child: *GlAlloc) !void {
    var it = self.children.iter();
    var idx: usize = 0;
    while (it.next()) |v| {
        defer idx += 1;
        if (v.* == child) {
            self.children.swapRemove(idx);
            break;
        }
    }
    self.alloc.general().destroy(child);
}

pub fn reset(self: *GlAlloc) void {
    self.restore(.{
        .program_idx = 0,
        .vbo_idx = 0,
        .vao_idx = 0,
        .texture_idx = 0,
    });

    var child_it = self.children.iter();
    while (child_it.next()) |child| {
        child.*.reset();
    }

    self.vaos.clear();
    self.vbos.clear();
    self.programs.clear();
    self.textures.clear();
    self.children.clear();
}

pub fn createBuffer(self: *GlAlloc) !gl.GLuint {
    var vertex_buffer: gl.GLuint = 0;
    gl.glCreateBuffers(1, &vertex_buffer);
    try self.registerVbo(vertex_buffer);
    return vertex_buffer;
}

pub fn createArray(self: *GlAlloc) !gl.GLuint {
    var vao: gl.GLuint = 0;
    gl.glCreateVertexArrays(1, &vao);
    try self.registerVao(vao);
    return vao;
}

pub fn createProgram(self: *GlAlloc) !gl.GLuint {
    const program = gl.glCreateProgram();
    try self.programs.append(program);
    return program;
}

pub fn genTexture(self: *GlAlloc) !gl.GLuint {
    var texture: gl.GLuint = undefined;
    gl.glGenTextures(1, &texture);
    try self.textures.append(texture);
    return texture;
}

pub const Checkpoint = struct {
    vbo_idx: usize,
    vao_idx: usize,
    program_idx: usize,
    texture_idx: usize,
};

pub fn checkpoint(self: *GlAlloc) Checkpoint {
    return .{
        .vbo_idx = self.vbos.len,
        .vao_idx = self.vaos.len,
        .program_idx = self.programs.len,
        .texture_idx = self.textures.len,
    };
}

pub fn restore(self: *GlAlloc, restore_point: Checkpoint) void {
    var vbo_it = self.vbos.iter();
    vbo_it.skip(restore_point.vbo_idx);
    // FIXME: Could definitely free in chunks
    while (vbo_it.next()) |elem| {
        gl.glDeleteBuffers(1, elem);
    }

    var vao_it = self.vaos.iter();
    vao_it.skip(restore_point.vao_idx);
    // FIXME: Could definitely free in chunks
    while (vao_it.next()) |elem| {
        gl.glDeleteVertexArrays(1, elem);
    }

    var program_it = self.programs.iter();
    program_it.skip(restore_point.program_idx);
    // FIXME: Could definitely free in chunks
    while (program_it.next()) |elem| {
        gl.glDeleteProgram(elem.*);
    }

    var texture_it = self.textures.iter();
    texture_it.skip(restore_point.texture_idx);
    // FIXME: Could definitely free in chunks
    while (texture_it.next()) |elem| {
        gl.glDeleteTextures(1, elem);
    }

    self.vbos.shrink(restore_point.vbo_idx);
    self.vaos.shrink(restore_point.vao_idx);
    self.textures.shrink(restore_point.texture_idx);
    self.programs.shrink(restore_point.program_idx);
}

pub fn registerVbo(self: *GlAlloc, vbo: gl.GLuint) !void {
    try self.vbos.append(vbo);
}

pub fn registerVao(self: *GlAlloc, vao: gl.GLuint) !void {
    try self.vaos.append(vao);
}

pub fn makeSubAlloc(self: *GlAlloc, alloc: *Sphalloc) !*GlAlloc {
    const child = try self.alloc.general().create(GlAlloc);
    child.* = try GlAlloc.init(alloc);
    child.parent = self;
    try self.children.append(child);
    return child;
}
