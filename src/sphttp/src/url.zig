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
