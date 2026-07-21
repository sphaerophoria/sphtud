const std = @import("std");

//https://en.wikipedia.org/wiki/Levenshtein_distance#Iterative_with_two_matrix_rows
pub fn levenshteinDistance(scratch: std.mem.Allocator, s: []const u8, t: []const u8) !usize {
    const n = @max(s.len, t.len);

    var v0 = try scratch.alloc(usize, n + 1);
    var v1 = try scratch.alloc(usize, n + 1);

    for (0..n + 1) |i| {
        v0[i] = i;
    }

    for (0..s.len) |i| {
        v1[0] = i + 1;
        for (0..t.len) |j| {
            const deletion_cost = v0[j + 1] + 1;
            const insertion_cost = v1[j] + 1;

            const substitution_cost = if (s[i] == t[j]) v0[j] else v0[j] + 1;

            v1[j + 1] = std.mem.min(usize, &.{ deletion_cost, insertion_cost, substitution_cost });
        }
        std.mem.swap([]usize, &v0, &v1);
    }

    return v0[t.len];
}

test "levenshteinDistance" {
    var alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer alloc.deinit();

    try std.testing.expectEqual(1, try levenshteinDistance(alloc.allocator(), "hello", "hell"));
    try std.testing.expectEqual(1, try levenshteinDistance(alloc.allocator(), "helo", "hell"));
    try std.testing.expectEqual(1, try levenshteinDistance(alloc.allocator(), "helo", "hello"));
}
