const sphalloc = @import("sphalloc");
const HeapScratch = sphalloc.ScratchAlloc;
const GlAlloc = @import("GlAlloc.zig");

const Scratch = @This();

heap: *HeapScratch,
gl: *GlAlloc,

const Checkpoint = struct {
    heap: HeapScratch.Checkpoint,
    gl: GlAlloc.Checkpoint,
};

pub fn checkpoint(self: Scratch) Checkpoint {
    return .{
        .heap = self.heap.checkpoint(),
        .gl = self.gl.checkpoint(),
    };
}

pub fn restore(self: *Scratch, from: Checkpoint) void {
    self.heap.restore(from.heap);
    self.gl.restore(from.gl);
}
