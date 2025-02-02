const std = @import("std");
const Allocator = std.mem.Allocator;
const sphutil = @import("sphutil");
const RuntimeSegmentedList = sphutil.RuntimeSegmentedList;
const memory_limits = @import("memory_limits.zig");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;

const sphtext = @import("sphtext");
const ttf_mod = sphtext.ttf;

pub const FontId = struct { value: usize };
const FontStorage = @This();

// FIXME: Fonts can be fairly large, we should only keep the ones we are
// actively using loaded
const FontData = struct {
    ttf_content: []const u8,
    path: [:0]const u8, // relative
    ttf: ttf_mod.Ttf,
};

pub const Save = []const u8;

alloc: *Sphalloc,
inner: RuntimeSegmentedList(FontData),

pub fn init(alloc: *Sphalloc) !FontStorage {
    return .{
        .alloc = alloc,
        .inner = try RuntimeSegmentedList(FontData).init(
            alloc.arena(),
            alloc.block_alloc.allocator(),
            memory_limits.initial_fonts,
            memory_limits.max_fonts,
        ),
    };
}

// On success, takes ownership of font_data and name
pub fn append(self: *FontStorage, font_data: []const u8, path: [:0]const u8, ttf: ttf_mod.Ttf) !FontId {
    const next_id = self.inner.len;
    try self.inner.append(.{ .ttf_content = font_data, .path = path, .ttf = ttf });
    return .{ .value = next_id };
}

pub fn get(self: FontStorage, id: FontId) FontData {
    return self.inner.get(id.value);
}

pub fn numItems(self: FontStorage) usize {
    return self.inner.len;
}

pub const IdIter = struct {
    idx: usize = 0,
    max: usize,

    pub fn next(self: *IdIter) ?FontId {
        if (self.idx >= self.max) {
            return null;
        }

        defer self.idx += 1;
        return .{ .value = self.idx };
    }
};

pub fn idIter(self: FontStorage) IdIter {
    return .{ .max = self.inner.len };
}

pub fn saveLeaky(self: FontStorage, alloc: Allocator) ![]Save {
    var ret = try alloc.alloc([]const u8, self.inner.len);
    var it = self.inner.sliceIter();
    var out_idx: usize = 0;
    while (it.next()) |slice| {
        for (slice) |elem| {
            ret[out_idx] = try std.fs.cwd().realpathAlloc(alloc, elem.path);
            out_idx += 1;
        }
    }

    return ret;
}
