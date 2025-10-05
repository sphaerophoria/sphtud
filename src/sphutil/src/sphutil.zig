const std = @import("std");
const noalloc = @import("sphutil_noalloc");
const sphalloc = @import("sphalloc");

pub const CircularBuffer = noalloc.CircularBuffer;
pub const RuntimeBoundedArray = noalloc.RuntimeBoundedArray;
pub const RuntimeSegmentedListConfigurable = noalloc.RuntimeSegmentedListConfigurable;
pub const RuntimeSegmentedListLinearAlloc = noalloc.RuntimeSegmentedListLinearAlloc;
pub const hash_map = noalloc.hash_map;
pub const StringHashMapLinear = noalloc.StringHashMapLinear;

pub const sphalloc_expansion_alloc_info = noalloc.runtime_segmented_list.ExpansionAllocInfo{
    .min_expansion_size_log2 = sphalloc.tiny_page_log2,
    .supports_free = true,
};
pub fn RuntimeSegmentedListSphalloc(comptime T: type) type {
    return RuntimeSegmentedListConfigurable(T, sphalloc_expansion_alloc_info);
}

pub const AutoHashMapLinear = noalloc.AutoHashMapLinear;
pub fn AutoHashMapSphalloc(comptime K: type, comptime V: type) type {
    return noalloc.hash_map.AutoHashMapConfigurable(K, V, sphalloc_expansion_alloc_info);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
