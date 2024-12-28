const std = @import("std");
const Allocator = std.mem.Allocator;

const sphtext = @import("sphtext");
const ttf_mod = sphtext.ttf;

pub const FontId = struct { value: usize };
const FontStorage = @This();

const FontData = struct {
    ttf_content: []const u8,
    path: [:0]const u8, // relative
    ttf: ttf_mod.Ttf,
};

pub const Save = []const u8;

inner: std.ArrayListUnmanaged(FontData) = .{},

pub fn deinit(self: *FontStorage, alloc: Allocator) void {
    for (self.inner.items) |*font_data| {
        font_data.ttf.deinit(alloc);
        alloc.free(font_data.ttf_content);
        alloc.free(font_data.path);
    }
    self.inner.deinit(alloc);
}

// On success, takes ownership of font_data and name
pub fn append(self: *FontStorage, alloc: Allocator, font_data: []const u8, path: [:0]const u8, ttf: ttf_mod.Ttf) !FontId {
    const next_id = self.inner.items.len;
    try self.inner.append(alloc, .{ .ttf_content = font_data, .path = path, .ttf = ttf });
    return .{ .value = next_id };
}

pub fn get(self: FontStorage, id: FontId) FontData {
    return self.inner.items[id.value];
}

pub fn numItems(self: FontStorage) usize {
    return self.inner.items.len;
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
    return .{ .max = self.inner.items.len };
}

pub fn saveLeaky(self: FontStorage, alloc: Allocator) ![]Save {
    var ret = try alloc.alloc([]const u8, self.inner.items.len);
    for (self.inner.items, 0..) |v, i| {
        ret[i] = try std.fs.cwd().realpathAlloc(alloc, v.path);
    }

    return ret;
}
