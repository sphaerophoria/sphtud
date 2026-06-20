const std = @import("std");

const ExpansionAlloc = @This();

pub const Info = struct {
    min_expansion_size_log2: u8,
    supports_free: bool,

    pub const linear: *const Info = &.{
        .min_expansion_size_log2 = 0,
        .supports_free = false,
    };
};

info: *const Info,
alloc: std.mem.Allocator,

pub const invalid = ExpansionAlloc{
    .info = &.{
        .min_expansion_size_log2 = 0,
        .supports_free = false,
    },
    .alloc = .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = undefined,
            .resize = undefined,
            .remap = undefined,
            .free = undefined,
        },
    },
};

pub fn linear(alloc: std.mem.Allocator) ExpansionAlloc {
    return .{
        .info = .linear,
        .alloc = alloc,
    };
}

pub fn general(alloc: std.mem.Allocator) ExpansionAlloc {
    return .{
        .info = &.{
            .min_expansion_size_log2 = 0,
            .supports_free = true,
        },
        .alloc = alloc,
    };
}

pub fn allocExternal(alloc: std.mem.Allocator, expansion: anytype) !ExpansionAlloc {
    const info = try alloc.create(Info);
    info.min_expansion_size_log2 = expansion.info.min_expansion_size_log2;
    info.supports_free = expansion.info.supports_free;
    return .{
        .info = info,
        .alloc = alloc,
    };
}

pub const system_page = ExpansionAlloc{
    .info = &.{
        .min_expansion_size_log2 = @intCast(std.math.log2(std.heap.pageSize())),
        .supports_free = true,
    },
    .alloc = std.heap.page_allocator,
};
