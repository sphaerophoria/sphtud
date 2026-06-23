const std = @import("std");

pub const Buf = struct {
    data: []const u8,
    idx: usize,

    pub fn init(data: []const u8) Buf {
        return .{
            .data = data,
            .idx = 0,
        };
    }

    pub fn remaining(self: Buf) []const u8 {
        if (self.idx >= self.data.len) return "";
        return self.data[self.idx..];
    }

    pub fn takeOne(self: *Buf, options: []const u8) ?Idx {
        if (self.empty()) return null;

        const b = self.data[self.idx];
        for (options) |o| {
            if (b == o) {
                defer self.idx += 1;
                return .init(self.idx);
            }
        }
        return null;
    }

    pub fn takeOneNot(self: *Buf, options: []const u8) ?Idx {
        if (self.empty()) return null;

        const b = self.data[self.idx];
        for (options) |o| {
            if (b == o) {
                return null;
            }
        }

        defer self.idx += 1;
        return .init(self.idx);
    }

    pub fn takeOneBetween(self: *Buf, start: u8, end_inclusive: u8) ?Idx {
        if (self.empty()) return null;

        const b = self.data[self.idx];
        if (b >= start and b <= end_inclusive) {
            defer self.idx += 1;
            return .init(self.idx);
        }

        return null;
    }

    pub fn takeWhileAny(self: *Buf, options: []const u8) ?Range {
        var t = self.tmp();
        while (t.takeOne(options) != null) {}
        return self.commit(t);
    }

    pub fn takeUntilAny(self: *Buf, options: []const u8) ?Range {
        var t = self.tmp();
        while (t.takeOneNot(options) != null) {}
        return self.commit(t);
    }

    pub fn takeWhileBetween(self: *Buf, start: u8, end_inclusive: u8) ?Range {
        var t = self.tmp();
        while (t.takeOneBetween(start, end_inclusive) != null) {}
        return self.commit(t);
    }

    pub fn tmp(self: *Buf) Buf {
        return self.*;
    }

    pub fn emptyRange(self: *Buf) Range {
        return .{
            .start = self.idx,
            .end = self.idx,
        };
    }

    pub fn commit(self: *Buf, other: Buf) ?Range {
        if (self.idx == other.idx) return null;
        defer self.idx = other.idx;

        return .{
            .start = self.idx,
            .end = other.idx,
        };
    }

    pub fn empty(self: *Buf) bool {
        return self.idx >= self.data.len;
    }
};

pub const Idx = struct {
    val: usize,

    pub fn init(idx: usize) Idx {
        return .{
            .val = idx,
        };
    }

    pub fn data(self: Idx, buf: Buf) u8 {
        return buf.data[self.val];
    }
};

pub const Range = struct {
    // inclusive
    start: usize,
    // exclusive
    end: usize,

    pub fn data(self: Range, buf: Buf) []const u8 {
        return buf.data[self.start..self.end];
    }
};
