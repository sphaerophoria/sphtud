const std = @import("std");
const noalloc = @import("sphutil_noalloc");
const sphalloc = @import("sphalloc");

pub const CircularBuffer = noalloc.CircularBuffer;
pub const RuntimeBoundedArray = noalloc.RuntimeBoundedArray;
pub const RuntimeSegmentedListConfigurable = noalloc.RuntimeSegmentedListConfigurable;
pub const RuntimeSegmentedListLinearAlloc = noalloc.RuntimeSegmentedListLinearAlloc;

pub fn RuntimeSegmentedListSphalloc(comptime T: type) type {
    return RuntimeSegmentedListConfigurable(T, .{
        .min_expansion_size_log2 = sphalloc.tiny_page_log2,
        .supports_free = true,
    });
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
