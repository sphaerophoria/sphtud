const std = @import("std");
const stdout = std.io.getStdOut();

pub const IncludeIter = struct {
    second_buf: []const u8,
    state: enum {
        first,
        second,
    },
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !IncludeIter {
        var p = try std.process.spawn(io, .{
            .argv = &.{ "cc", "-E", "-Wp,-v", "-xc", "/dev/null" },
            .stdout = .ignore,
            .stdin = .ignore,
            .stderr = .pipe,
        });

        var stderr_reader = p.stderr.?.reader(io, &.{});
        const content = try stderr_reader.interface.allocRemaining(alloc, .limited(1 << 20));

        _ = try p.wait(io);

        const first_segment_string = "#include \"...\" search starts here:\n";
        const second_segment_string = "#include <...> search starts here:\n";
        const second_segment_end = "End of search list";

        const first_start =
            (std.mem.indexOf(u8, content, first_segment_string) orelse return error.UnexpectedFormat) + first_segment_string.len;
        const first_end = std.mem.indexOf(u8, content, second_segment_string) orelse return error.UnexpectedFormat;
        const second_start = first_end + second_segment_string.len;
        const second_end = std.mem.indexOf(u8, content, second_segment_end) orelse return error.UnexpectedFormat;

        return .{
            .inner = std.mem.splitScalar(u8, content[first_start..first_end], '\n'),
            .second_buf = content[second_start..second_end],
            .state = .first,
        };
    }

    pub fn next(self: *IncludeIter) ?[]const u8 {
        while (true) {
            if (self.inner.next()) |elem| {
                const trimmed = std.mem.trim(u8, elem, &std.ascii.whitespace);
                if (trimmed.len != 0) {
                    return trimmed;
                }
            }

            switch (self.state) {
                .first => {
                    self.inner = std.mem.splitScalar(u8, self.second_buf, '\n');
                    self.state = .second;
                },
                .second => return null,
            }
        }
    }
};
