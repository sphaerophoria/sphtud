const std = @import("std");

pub const DateTime = struct {
    year: u16,
    month: Month,
    day: u8, // 1-31

    hours: u8,
    minutes: u8,
    seconds: u8,

    pub fn init(epoch: i64) DateTime {
        const date = Date.fromCeDay(epochToCeDay(epoch));

        const second = @mod(epoch, 60);
        const minute = @divTrunc(@mod(epoch, 60 * 60), 60);
        const hour = @divTrunc(@mod(epoch, 60 * 60 * 24), 60 * 60);

        return .{
            .year = @intCast(date.year),
            .month = date.month,
            .day = date.day,
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
        try print2Digit(w, dt.day);

        try w.writeByte(' ');

        try print2Digit(w, dt.hours);
        try w.writeByte(':');
        try print2Digit(w, dt.minutes);
        try w.writeByte(':');
        try print2Digit(w, dt.seconds);
    }
};

pub const Date = struct {
    year: i64,
    month: Month,
    day: u8, // 1-31

    pub fn toCeDay(date: Date) i64 {
        const year: u32 = @intCast(date.year);
        const month = @intFromEnum(date.month) + 1;
        var days = daysBeforeYear(year) + @as(u32, date.day);
        for (1..month) |m| days += daysInMonthRaw(year, @intCast(m));
        return days;
    }

    pub fn fromCeDay(days: i64) Date {
        // Find the year: estimate from the exact 146097-days-per-400-years cadence
        // (an over- or under-shoot of at most one), then correct.
        const day_of_ce: u32 = @intCast(days - 1); // 0-based days since 0001-01-01
        var year: u32 = @intCast(@as(u64, day_of_ce) * 400 / 146097 + 1);
        while (daysBeforeYear(year) > day_of_ce) year -= 1;
        while (daysBeforeYear(year + 1) <= day_of_ce) year += 1;

        var year_day = day_of_ce - daysBeforeYear(year); // 0-based day within year
        for (1..13) |m| {
            const in_month = daysInMonthRaw(year, @intCast(m));
            if (year_day < in_month) {
                return .{
                    .year = year,
                    .month = @enumFromInt(m - 1),
                    .day = @intCast(year_day + 1),
                };
            }
            year_day -= in_month;
        }

        unreachable;
    }

    pub fn parse(s: []const u8) !Date {
        var it = std.mem.splitScalar(u8, s, '-');
        const year_s = it.next() orelse return error.InvalidDate;
        const month_s = it.next() orelse return error.InvalidDate;
        const day_s = it.next() orelse return error.InvalidDate;
        if (it.next() != null) return error.InvalidDate;

        const month = try std.fmt.parseInt(u8, month_s, 10);
        if (month < 1 or month > 12) return error.InvalidDate;

        return .{
            .year = try std.fmt.parseInt(i64, year_s, 10),
            .month = @enumFromInt(month - 1),
            .day = try std.fmt.parseInt(u8, day_s, 10),
        };
    }

    pub fn format(self: Date, w: *std.Io.Writer) !void {
        if (self.year < 0) try w.writeByte('-');
        try w.printInt(@abs(self.year), 10, .lower, .{ .fill = '0', .width = 4, .alignment = .right });
        try w.writeByte('-');
        try w.printInt(@as(u32, @intFromEnum(self.month)) + 1, 10, .lower, .{ .fill = '0', .width = 2, .alignment = .right });
        try w.writeByte('-');
        try w.printInt(self.day, 10, .lower, .{ .fill = '0', .width = 2, .alignment = .right });
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

// Number of days from 0001-01-01 (day 1) to the unix epoch (1970-01-01) in the
// proleptic Gregorian calendar. Matches chrono's NaiveDate::num_days_from_ce.
pub const epoch_days_from_ce = 719163;

// Days elapsed since 0001-01-01 (which is day 1) for the given unix timestamp,
// in the proleptic Gregorian calendar.
pub fn epochToCeDay(epoch_seconds: i64) i64 {
    return @divFloor(epoch_seconds, std.time.s_per_day) + epoch_days_from_ce;
}

// 30 days have september, april, june, and november; all the rest have 31,
// except for february, which has 28 (or sometimes 29 or something).
const days_per_month = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysBeforeYear(year: u32) u32 {
    const y = year - 1;
    return 365 * y + y / 4 - y / 100 + y / 400;
}

pub fn daysInMonth(year: u32, month: Month) u8 {
    return daysInMonthRaw(year, @intFromEnum(month) + 1);
}

fn daysInMonthRaw(year: u32, month: u8) u8 {
    return days_per_month[month - 1] + @as(u8, @intFromBool(month == 2 and isLeapYear(year)));
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

test "num days from ce" {
    // 0001-01-01 is day 1
    try std.testing.expectEqual(1, epochToCeDay(-62135596800));
    // Unix epoch
    try std.testing.expectEqual(719163, epochToCeDay(0));
    // 2000-01-01
    try std.testing.expectEqual(730120, epochToCeDay(946684800));
    // Partial day floors down, and negatives floor toward -inf
    try std.testing.expectEqual(719163, epochToCeDay(std.time.s_per_day - 1));
    try std.testing.expectEqual(719162, epochToCeDay(-1));
}

test "date num days from ce" {
    // 0001-01-01 is day 1
    try std.testing.expectEqual(1, (Date{ .year = 1, .month = .jan, .day = 1 }).toCeDay());
    // Unix epoch
    try std.testing.expectEqual(719163, (Date{ .year = 1970, .month = .jan, .day = 1 }).toCeDay());
    // 2000-01-01
    try std.testing.expectEqual(730120, (Date{ .year = 2000, .month = .jan, .day = 1 }).toCeDay());
}

test "date round trip" {
    const cases = [_]Date{
        .{ .year = 1, .month = .jan, .day = 1 },
        .{ .year = 1970, .month = .jan, .day = 1 },
        .{ .year = 2000, .month = .feb, .day = 29 },
        .{ .year = 2023, .month = .dec, .day = 31 },
        .{ .year = 2024, .month = .jul, .day = 18 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case, Date.fromCeDay(case.toCeDay()));
    }
}

test "date parse and format" {
    const parsed = try Date.parse("2024-07-18");
    try std.testing.expectEqual(Date{ .year = 2024, .month = .jul, .day = 18 }, parsed);

    var buf: [32]u8 = undefined;
    const res = try std.fmt.bufPrint(&buf, "{f}", .{parsed});
    try std.testing.expectEqualStrings("2024-07-18", res);
}

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
