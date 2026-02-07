const std = @import("std");

pub const UriIter = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn init(target: []const u8) UriIter {
        const target_preprocessed = blk: {
            if (target.len == 0) break :blk &.{};
            if (target[0] != '/') break :blk &.{};
            break :blk target[1..];
        };

        return .{
            .inner = std.mem.splitScalar(u8, target_preprocessed, '/'),
        };
    }

    pub fn Res(comptime T: type) type {
        return union(enum) {
            match: T,
            not_match: []const u8,
        };
    }

    pub fn next(self: *UriIter, comptime T: type) ?Res(T) {
        while (true) {
            const component = self.inner.next() orelse return null;
            if (component.len == 0) continue;

            const ti = @typeInfo(T);
            switch (ti) {
                .@"enum" => |ei| {
                    inline for (ei.fields) |field| {
                        if (std.mem.eql(u8, component, field.name)) {
                            return .{ .match = @enumFromInt(field.value) };
                        }
                    }
                    return .{ .not_match = component };
                },
                .int => {
                    const val = std.fmt.parseInt(T, component, 0) catch return .{ .not_match = component };
                    return .{ .match = val };
                },
                else => {},
            }
        }
    }
};

test "UriIter" {
    const SampleApi = enum {
        some_target,
        some_other_target,
    };

    {
        var it = UriIter.init("");
        try std.testing.expectEqual(null, it.next(SampleApi));
    }

    {
        var it = UriIter.init("/");
        try std.testing.expectEqual(null, it.next(SampleApi));
    }

    {
        var it = UriIter.init("/some_target");
        try std.testing.expectEqual(UriIter.Res(SampleApi){ .match = .some_target }, it.next(SampleApi));
        try std.testing.expectEqual(null, it.next(i64));
    }

    {
        var it = UriIter.init("/some_target/");
        try std.testing.expectEqual(UriIter.Res(SampleApi){ .match = .some_target }, it.next(SampleApi));
        try std.testing.expectEqual(null, it.next(i64));
    }

    {
        var it = UriIter.init("/some_target/5");
        try std.testing.expectEqual(UriIter.Res(SampleApi){ .match = .some_target }, it.next(SampleApi));
        try std.testing.expectEqual(UriIter.Res(i64){ .match = 5 }, it.next(i64));
    }

    {
        var it = UriIter.init("/some_target//5");
        try std.testing.expectEqual(UriIter.Res(SampleApi){ .match = .some_target }, it.next(SampleApi));
        try std.testing.expectEqual(UriIter.Res(i64){ .match = 5 }, it.next(i64));
    }
}

pub const QueryParamIter = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub const Item = struct {
        key: []const u8,
        val: []const u8,
    };

    pub fn init(target: []const u8) QueryParamIter {
        var empty = QueryParamIter{ .inner = std.mem.splitScalar(u8, &.{}, '&') };
        _ = empty.next();

        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return empty;
        if (query_start + 1 >= target.len) return empty;

        return .{
            .inner = std.mem.splitScalar(u8, target[query_start + 1 ..], '&'),
        };
    }

    pub fn next(self: *QueryParamIter) ?Item {
        const kv = self.inner.next() orelse return null;
        const split_idx = std.mem.indexOfScalar(u8, kv, '=');
        const key = extractKey(kv, split_idx);
        const value = extractValue(kv, split_idx);
        return .{
            .key = key,
            .val = value,
        };
    }

    fn extractKey(kv: []const u8, split_idx_opt: ?usize) []const u8 {
        const split_idx = split_idx_opt orelse return kv;
        return kv[0..split_idx];
    }

    fn extractValue(kv: []const u8, split_idx_opt: ?usize) []const u8 {
        const split_idx = split_idx_opt orelse return "";
        if (split_idx + 1 >= kv.len) return "";

        return kv[split_idx + 1 ..];
    }
};

test "QueryParamIter" {
    {
        var it = QueryParamIter.init("/hello");
        try std.testing.expectEqual(null, it.next());
    }

    {
        var it = QueryParamIter.init("/?");
        try std.testing.expectEqual(null, it.next());
    }

    {
        var it = QueryParamIter.init("/?q");
        const kv = it.next() orelse return error.NoItem;
        try std.testing.expectEqualStrings("q", kv.key);
        try std.testing.expectEqualStrings("", kv.val);
    }

    {
        var it = QueryParamIter.init("/?q=");
        const kv = it.next() orelse return error.NoItem;
        try std.testing.expectEqualStrings("q", kv.key);
        try std.testing.expectEqualStrings("", kv.val);
    }

    {
        var it = QueryParamIter.init("/?q=hello");
        const kv = it.next() orelse return error.NoItem;
        try std.testing.expectEqualStrings("q", kv.key);
        try std.testing.expectEqualStrings("hello", kv.val);
    }

    {
        var it = QueryParamIter.init("/?q=hello&r=goodbye");
        {
            const kv = it.next() orelse return error.NoItem;
            try std.testing.expectEqualStrings("q", kv.key);
            try std.testing.expectEqualStrings("hello", kv.val);
        }

        {
            const kv = it.next() orelse return error.NoItem;
            try std.testing.expectEqualStrings("r", kv.key);
            try std.testing.expectEqualStrings("goodbye", kv.val);
        }
    }
}
