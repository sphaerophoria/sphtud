const std = @import("std");

pub fn load(dl: *std.DynLib, out: anytype) !void {
    inline for (std.meta.fields(@TypeOf(out.*))) |field| {
        @field(out.*, field.name) = dl.lookup(field.type, field.name) orelse {
            return error.Missing;
        };
    }
}
