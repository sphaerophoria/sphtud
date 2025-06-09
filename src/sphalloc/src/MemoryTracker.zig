const std = @import("std");
const Allocator = std.mem.Allocator;
const sphalloc = @import("sphalloc.zig");
const Sphalloc = sphalloc.Sphalloc;
const sphutil = @import("sphutil_noalloc");
const CircularBuffer = sphutil.CircularBuffer;

root: *Sphalloc,
sample_storage: CircularBuffer(Sample),
sample_period_ms: u32,
num_samples: usize = 0,
last_sample: std.time.Instant,

const MemoryTracker = @This();

pub fn init(alloc: Allocator, now: std.time.Instant, sample_period_ms: u32, root: *Sphalloc) !MemoryTracker {
    return .{
        .root = root,
        .sample_storage = CircularBuffer(Sample){ .items = try alloc.alloc(Sample, 10000) },
        .sample_period_ms = sample_period_ms,
        .last_sample = now,
    };
}

pub fn snapshot(leaky: Allocator, root: *Sphalloc, max_elems: usize) ![]Sample {
    var it = SphallocDfs.init(root);

    var name_indexes = std.StringHashMap(usize).init(leaky);
    var ret = try sphutil.RuntimeBoundedArray(Sample).init(leaky, max_elems);

    while (try it.next()) |elem| {
        const gop = try name_indexes.getOrPut(elem.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = ret.items.len;
            try ret.append(.{
                .name = elem.name,
                .memory_used = 0,
            });
        }

        ret.items[gop.value_ptr.*].memory_used += elem.totalMemoryAllocated();
    }

    return ret.items;
}

pub fn step(self: *MemoryTracker, now: std.time.Instant) !void {
    if (now.since(self.last_sample) / std.time.ns_per_ms < self.sample_period_ms) {
        return;
    }

    self.last_sample = now;

    var it = SphallocDfs.init(self.root);

    self.num_samples += 1;

    {
        const popped = self.sample_storage.push(.{
            .name = &.{},
            .memory_used = 0,
        });
        self.handlePoppedSample(popped);
    }

    while (try it.next()) |elem| {
        const popped = self.sample_storage.push(.{
            .name = elem.name,
            .memory_used = elem.totalMemoryAllocated(),
        });
        self.handlePoppedSample(popped);
    }
}

fn handlePoppedSample(self: *MemoryTracker, item_opt: ?Sample) void {
    const item = item_opt orelse return;
    if (item.name.len == 0) {
        self.num_samples -= 1;
    }
}

pub const AllocSamples = struct {
    name: []const u8,
    samples: []usize,
    max: usize,

    pub fn clone(self: *AllocSamples, alloc: Allocator) !AllocSamples {
        return .{
            .name = self.name,
            .samples = try alloc.dupe(usize, self.samples),
            .max = self.max,
        };
    }
};

pub fn collect(self: MemoryTracker, ret_alloc: std.mem.Allocator, scratch: sphalloc.LinearAllocator) ![]AllocSamples {
    const scratch_alloc = scratch.allocator();

    // Surely we don't have more than 50 allocators
    // There's probably a better estimate from sample_storage len +
    // num_samples, but whatever
    var ret_buckets = try sphutil.RuntimeBoundedArray(AllocSamples).init(ret_alloc, 50);
    var ret_samples = try sphutil.RuntimeBoundedArray(usize).init(ret_alloc, self.sample_storage.items.len);

    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    var storage_it = self.sample_storage.iter();
    while (storage_it.next()) |sample| {
        if (sample.name.len == 0) {
            break;
        }
    }

    const AllocSamplesBuilder = struct {
        samples: std.ArrayListUnmanaged(usize) = .{},
        max: usize = 0,
    };
    var sample_map = std.StringHashMap(AllocSamplesBuilder).init(scratch_alloc);
    var sample_idx: usize = 0;
    while (storage_it.next()) |sample| {
        if (sample.name.len == 0) {
            sample_idx += 1;
            continue;
        }
        const gop = try sample_map.getOrPut(sample.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        // Fill samples if any were missed (due to allocator removal and
        // addition, or late addition)
        const old_len = gop.value_ptr.samples.items.len;
        if (sample_idx >= old_len) {
            try gop.value_ptr.samples.resize(ret_alloc, sample_idx);
            @memset(gop.value_ptr.samples.items[old_len..], 0);
            try gop.value_ptr.samples.append(ret_alloc, sample.memory_used);
        } else {
            gop.value_ptr.samples.items[sample_idx] += sample.memory_used;
        }

        gop.value_ptr.max = @max(gop.value_ptr.max, gop.value_ptr.samples.items[sample_idx]);
    }

    var sample_map_it = sample_map.iterator();
    while (sample_map_it.next()) |kv| {
        const old_samples_len = ret_samples.items.len;
        try ret_samples.appendSlice(kv.value_ptr.samples.items);
        if (kv.value_ptr.samples.items.len < self.num_samples) {
            const zero_start = ret_samples.items.len;
            try ret_samples.resize(zero_start + self.num_samples - kv.value_ptr.samples.items.len);
            @memset(ret_samples.items[zero_start..], 0);
        }

        try ret_buckets.append(.{
            .name = kv.key_ptr.*,
            .samples = ret_samples.items[old_samples_len..],
            .max = kv.value_ptr.max,
        });
    }

    return ret_buckets.items;
}

const SphallocDfs = struct {
    const max_depth = 10;

    stack: std.BoundedArray(StackElem, max_depth),
    const StackElem = struct {
        alloc: *Sphalloc,
        child_idx: usize = 0,
    };

    pub fn init(root: *Sphalloc) SphallocDfs {
        var stack = std.BoundedArray(StackElem, max_depth){};
        stack.append(.{
            .alloc = root,
        }) catch unreachable;

        return .{
            .stack = stack,
        };
    }

    pub fn next(self: *SphallocDfs) !?*Sphalloc {
        const stack = self.stack.slice();
        if (stack.len == 0) {
            return null;
        }

        const ret = self.last().alloc;
        try self.advance();
        return ret;
    }

    fn last(self: *SphallocDfs) *StackElem {
        const stack = self.stack.slice();
        return &stack[stack.len - 1];
    }

    pub fn advance(self: *SphallocDfs) !void {
        var last_elem = self.last();
        while (true) {
            if (last_elem.child_idx < last_elem.alloc.children.len()) {
                var child_it = last_elem.alloc.children.first;
                for (0..last_elem.child_idx) |_| {
                    child_it = child_it.?.next;
                }
                try self.stack.append(.{
                    .alloc = &child_it.?.data,
                });
                last_elem.child_idx += 1;
                return;
            }

            _ = self.stack.pop();
            if (self.stack.len == 0) {
                break;
            }
            last_elem = self.last();
        }
    }
};

pub const Sample = struct {
    const null_sample_name = &.{};

    name: []const u8,
    memory_used: usize,
};
