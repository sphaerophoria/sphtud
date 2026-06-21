const std = @import("std");

pub const DateTime = struct {
    year: u16,
    month: Month,
    day: u8,

    hours: u8,
    minutes: u8,
    seconds: u8,

    pub fn init(epoch: i64) DateTime {
        const year = yearFromEpoch(@intCast(epoch));
        const year_day = yearDayFromEpoch(@intCast(epoch));
        const month = monthFromYearDay(year, year_day);

        const second = @mod(epoch, 60);
        const minute = @divTrunc(@mod(epoch, 60 * 60), 60);
        const hour = @divTrunc(@mod(epoch, 60 * 60 * 24), 60 * 60);

        return .{
            .year = @intCast(year),
            .month = month.month,
            .day = @intCast(month.day),
            .hours = @intCast(hour),
            .minutes = @intCast(minute),
            .seconds = @intCast(second),
        };
    }

    fn print2Digit(w: *std.Io.Writer, val: anytype) !void {
        try w.printInt(
            val,
            10,
            .lower,
            .{
                .fill = '0',
                .width = 2,
                .alignment = .right,
            },
        );
    }

    pub fn format(dt: DateTime, w: *std.Io.Writer) !void {
        try print2Digit(w, dt.year);
        try w.writeByte('-');
        try print2Digit(w, @as(u32, @intFromEnum(dt.month)) + 1);
        try w.writeByte('-');
        try print2Digit(w, dt.day + 1);

        try w.writeByte(' ');

        try print2Digit(w, dt.hours);
        try w.writeByte(':');
        try print2Digit(w, dt.minutes);
        try w.writeByte(':');
        try print2Digit(w, dt.seconds);
    }
};

pub const Month = enum {
    jan,
    feb,
    mar,
    apr,
    may,
    jun,
    jul,
    aug,
    sep,
    oct,
    nov,
    dec,
};

pub const TimeZone = struct {
    times: []Time,
    options: []Option,
    tz_strs: []const u8,

    const Time = struct {
        time: i64,
        option: u16 = std.math.maxInt(u16),
    };

    const Option = struct {
        ut_offs: i32,
        is_dst: bool,
        tz_str_offs: usize,
    };

    const Builder = struct {
        alloc: std.mem.Allocator,
        scratch: std.mem.Allocator,

        // All array lists are on scratch allocators
        // Content of array lists are on the output alloc
        times: std.ArrayList(Time),
        options: std.ArrayList(Option),
        char_buf: []const u8,

        pub fn parseTzFile(self: *Builder, r: *std.Io.Reader) !void {
            const tz = try TzHeader.parse(r);

            if (tz.version > '1') {
                try r.discardAll(tz.dataLen(4));

                const tz2 = try TzHeader.parse(r);
                try self.parseV1V2Data(i64, tz2, r);
            } else {
                try self.parseV1V2Data(i32, tz, r);
            }
        }

        // Re-used for V1/V2. V2 has a second segment that's identical to V1,
        // but with a larger type for the time steps
        pub fn parseV1V2Data(self: *Builder, comptime T: type, tz: TzHeader, r: *std.Io.Reader) !void {
            try self.times.ensureUnusedCapacity(self.scratch, tz.time_count);
            try self.options.ensureUnusedCapacity(self.scratch, tz.type_count);

            for (0..tz.time_count) |_| {
                const val = try r.takeInt(T, .big);
                self.times.appendBounded(.{ .time = val }) catch unreachable;
            }

            for (self.times.items) |*time| {
                const val = try r.takeByte();
                time.option = val;
            }

            for (0..tz.type_count) |_| {
                const tt_info = try TtInfo.parse(r);
                self.options.appendBounded(.{
                    .ut_offs = tt_info.tt_utoff,
                    .is_dst = tt_info.tt_isdst != 0,
                    .tz_str_offs = tt_info.tt_desigidx,
                }) catch unreachable;
            }

            if (tz.leap_count != 0) return error.Unimplemented;

            const tmp_dsg_chars = try r.take(tz.char_count);
            self.char_buf = try self.alloc.dupe(u8, tmp_dsg_chars);

            // I'm still a bit confused by these fields, but AFAICT these are
            // only used for applying posix TZ strings (which we don't do yet).
            // man tzfile
            //
            // The standard/wall and UT/local indicators were designed for
            // transforming a TZif file's transition times into transitions
            // appropriate for another time zone specified via a proleptic TZ
            // string that lacks rules
            //
            // Since we are not doing this, just discard the data
            try r.discardAll(tz.is_std_count);
            try r.discardAll(tz.is_ut_count);
        }
    };

    pub fn init(out_alloc: std.mem.Allocator, scratch: std.mem.Allocator, r: *std.Io.Reader) !TimeZone {
        var builder = Builder{
            .alloc = out_alloc,
            .scratch = scratch,
            .times = .empty,
            .options = .empty,
            .char_buf = &.{},
        };

        try builder.parseTzFile(r);

        return .{
            .times = try out_alloc.dupe(Time, builder.times.items),
            .options = try out_alloc.dupe(Option, builder.options.items),
            .tz_strs = builder.char_buf,
        };
    }

    pub fn fromUTC(self: TimeZone, time: i64) !i64 {
        const transition_idx = std.sort.lowerBound(Time, self.times, time, struct {
            fn f(val: i64, item: Time) std.math.Order {
                return std.math.order(val, item.time);
            }
        }.f);

        if (transition_idx == self.times.len) {
            return error.Unimplemented;
        }

        // FIXME: Minorly confident about == behavior. We could be wrong at the
        // boundarys for 1 second, whatever man :)

        const transition = self.times[transition_idx -| 1];
        const zone = self.options[transition.option];
        return time + zone.ut_offs;
    }
};

const epoch_year = 1970;
const first_leap_year = 1968;

fn additionalLeapDays(years_since_epoch: u32) u32 {
    return (years_since_epoch + 1) / 4 - (years_since_epoch + 69) / 100 + (years_since_epoch + 369) / 400;
}

fn yearFromEpoch(epoch: u32) u32 {
    const days_since_epoch = epoch / 60 / 60 / 24;

    // Initial overestimate
    const years_since_epoch = days_since_epoch / 365;
    const days_adjusted = days_since_epoch - additionalLeapDays(years_since_epoch);

    return days_adjusted / 365 + epoch_year;
}

// How many days into the current year are we
fn yearDayFromEpoch(epoch: u32) u32 {
    const days = epoch / 60 / 60 / 24;
    const year = yearFromEpoch(epoch);
    return days - yearDayStart(year);
}

// This year starts how many days after jan 1 1970
fn yearDayStart(year: u32) u32 {
    const years_since_epoch = year - 1970;
    const day = years_since_epoch * 365;
    return day + additionalLeapDays(years_since_epoch);
}

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

const MonthDay = struct {
    month: Month,
    day: u32,
};

fn monthFromYearDay(year: u32, year_day: u32) MonthDay {
    var count = year_day;
    var month: u32 = 0;

    // 30 days have september,
    // april, june, and november
    // all the rest have 31,
    // except for february, which has 28
    // or sometimes 29 or something
    var days_per_month: [12]u32 = .{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    if (isLeapYear(year)) days_per_month[1] += 1;

    for (days_per_month) |days_in_month| {
        if (days_in_month > count) {
            return .{
                .month = @enumFromInt(month),
                .day = count,
            };
        }
        month += 1;
        count -= days_in_month;
    }

    unreachable;
}

const TzHeader = struct {
    version: u8,
    // 15 bytes of padding
    is_ut_count: u32,
    is_std_count: u32,

    leap_count: u32,
    time_count: u32,
    type_count: u32,
    char_count: u32,

    fn parse(r: *std.Io.Reader) !TzHeader {
        if (!std.mem.eql(u8, "TZif", try r.take(4))) return error.InvalidMagic;

        const version = try r.takeByte();
        try r.discardAll(15);

        return .{
            .version = version,
            .is_ut_count = try r.takeInt(u32, .big),
            .is_std_count = try r.takeInt(u32, .big),
            .leap_count = try r.takeInt(u32, .big),
            .time_count = try r.takeInt(u32, .big),
            .type_count = try r.takeInt(u32, .big),
            .char_count = try r.takeInt(u32, .big),
        };
    }

    fn dataLen(self: TzHeader, time_size: usize) usize {
        return self.time_count * (time_size + 1) +
            self.char_count +
            self.type_count * 6 +
            self.leap_count * (time_size + 4) +
            self.is_ut_count +
            self.is_std_count;
    }

    pub fn format(self: TzHeader, w: *std.Io.Writer) !void {
        try w.print("version: {c}, ", .{self.version});

        try w.print("is_ut_count: {d}, ", .{self.is_ut_count});
        try w.print("is_std_count: {d}, ", .{self.is_std_count});

        try w.print("leap_count: {d}, ", .{self.leap_count});
        try w.print("time_count: {d}, ", .{self.time_count});
        try w.print("type_count: {d}, ", .{self.type_count});
        try w.print("char_count: {d}, ", .{self.char_count});
    }
};

const TtInfo = struct {
    tt_utoff: i32,
    tt_isdst: u8,
    tt_desigidx: u8,

    fn parse(r: *std.Io.Reader) !TtInfo {
        return .{
            .tt_utoff = try r.takeInt(i32, .big),
            .tt_isdst = try r.takeByte(),
            .tt_desigidx = try r.takeByte(),
        };
    }
};

const TestCase = struct {
    input: i64,
    output: []const u8,

    pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]TestCase {
        return try std.json.parseFromSliceLeaky([]TestCase, alloc, data, .{});
    }
};

test "utc times" {
    const test_cases_blob = @embedFile("datetime/utc_tests.json");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const test_cases = try TestCase.parse(arena.allocator(), test_cases_blob);

    for (test_cases) |case| {
        const dt = DateTime.init(case.input);
        var buf: [100]u8 = undefined;
        const res = try std.fmt.bufPrint(&buf, "{f}", .{dt});
        try std.testing.expectEqualStrings(case.output, res);
    }
}

test "local times" {
    const test_cases_blob = @embedFile("datetime/vancouver_tests.json");
    const tz_blob = @embedFile("datetime/Vancouver_TZ_sample");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var scratch = std.heap.FixedBufferAllocator.init(try std.heap.page_allocator.alloc(u8, 1 * 1024 * 1024));
    defer std.heap.page_allocator.free(scratch.buffer);

    var tz_reader = std.Io.Reader.fixed(tz_blob);
    const zone_info = try TimeZone.init(arena.allocator(), scratch.allocator(), &tz_reader);

    const test_cases = try TestCase.parse(arena.allocator(), test_cases_blob);

    for (test_cases) |case| {
        const adjusted = zone_info.fromUTC(case.input) catch |e| switch (e) {
            error.Unimplemented => continue,
        };

        const dt = DateTime.init(adjusted);
        var buf: [100]u8 = undefined;
        const res = try std.fmt.bufPrint(&buf, "{f}", .{dt});
        try std.testing.expectEqualStrings(case.output, res);
    }
}
