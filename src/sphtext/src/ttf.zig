const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const OffsetTable = packed struct {
    scaler: u32,
    num_tables: u16,
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,
};

const TableDirectoryEntry = extern struct {
    tag: [4]u8,
    check_sum: u32,
    offset: u32,
    length: u32,
};

fn tableFromEntry(font_data: []const u8, entry: TableDirectoryEntry) []const u8 {
    return font_data[entry.offset .. entry.offset + entry.length];
}

const RuntimeParser = struct {
    data: []const u8,
    idx: usize = 0,

    pub fn readVal(self: *RuntimeParser, comptime T: type) T {
        const size = @bitSizeOf(T) / 8;
        defer self.idx += size;
        return fixEndianness(std.mem.bytesToValue(T, self.data[self.idx .. self.idx + size]));
    }

    pub fn readArray(self: *RuntimeParser, comptime T: type, alloc: Allocator, len: usize) ![]T {
        const size = @bitSizeOf(T) / 8 * len;
        defer self.idx += size;
        return fixSliceEndianness(T, alloc, std.mem.bytesAsSlice(T, self.data[self.idx .. self.idx + size]));
    }
};

const Fixed = packed struct(u32) {
    frac: i16,
    integer: i16,
};

const HeadTable = packed struct {
    version: Fixed,
    font_revision: Fixed,
    check_sum_adjustment: u32,
    magic_number: u32,
    flags: u16,
    units_per_em: u16,
    created: i64,
    modified: i64,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    mac_style: u16,
    lowest_rec_ppem: u16,
    font_direction_hint: i16,
    index_to_loc_format: i16,
    glyph_data_format: i16,
};

const MaxpTable = packed struct {
    version: Fixed,
    num_glyphs: u16,
    max_points: u16,
    max_contours: u16,
    max_component_points: u16,
    max_component_contours: u16,
    max_zones: u16,
    max_twilight_points: u16,
    max_storage: u16,
    max_function_defs: u16,
    max_instruction_defs: u16,
    maxStackElements: u16,
    maxSizeOfInstructions: u16,
    maxComponentElements: u16,
    maxComponentDepth: u16,
};

const HheaTable = packed struct {
    version: Fixed,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    advance_width_max: u16,
    min_left_side_bearing: i16,
    min_right_side_bearing: i16,
    x_max_extent: i16,
    caret_slope_rise: i16,
    caret_slope_run: i16,
    caret_offset: i16,
    reserved1: i16,
    reserved2: i16,
    reserved3: i16,
    reserved4: i16,
    metric_data_format: i16,
    num_of_long_hor_metrics: u16,
};

pub const HmtxTable = struct {
    hmtx_bytes: []const u8,

    pub const LongHorMetric = packed struct {
        advance_width: u16,
        left_side_bearing: i16,
    };

    pub fn getMetrics(self: HmtxTable, num_hor_metrics: usize, glyph_index: usize) LongHorMetric {
        if (glyph_index < num_hor_metrics) {
            return self.loadHorMetric(glyph_index);
        } else {
            const last = self.loadHorMetric(num_hor_metrics - 1);
            const lsb_index = glyph_index - num_hor_metrics;
            const lsb_offs = num_hor_metrics * @bitSizeOf(LongHorMetric) / 8 + lsb_index * 2;
            const lsb = fixEndianness(std.mem.bytesToValue(i16, self.hmtx_bytes[lsb_offs..]));
            return .{
                .advance_width = last.advance_width,
                .left_side_bearing = lsb,
            };
        }
    }

    fn loadHorMetric(self: HmtxTable, idx: usize) LongHorMetric {
        const offs = idx * @bitSizeOf(LongHorMetric) / 8;
        return fixEndianness(std.mem.bytesToValue(LongHorMetric, self.hmtx_bytes[offs..]));
    }
};

pub const CmapTable = struct {
    cmap_bytes: []const u8,

    const Index = packed struct {
        version: u16,
        num_subtables: u16,
    };

    const SubtableLookup = packed struct {
        platform_id: u16,
        platform_specific_id: u16,
        offset: u32,

        fn isUnicodeBmp(self: SubtableLookup) bool {
            return (self.platform_id == 0 and self.platform_specific_id == 3) or // unicode + bmp
                (self.platform_id == 3 and self.platform_specific_id == 1) // windows + unicode ucs 2
            ;
        }
    };

    const Subtable = packed struct {
        platform_id: u16,
        platform_specific_id: u16,
        offset: u32,
    };

    pub const SubtableFormat4 = struct {
        format: u16,
        length: u16,
        language: u16,
        seg_count_x2: u16,
        search_range: u16,
        entry_selector: u16,
        range_shift: u16,
        end_code: []const u16,
        reserved_pad: u16,
        start_code: []const u16,
        id_delta: []const u16,
        id_range_offset: []const u16,
        glyph_indices: []const u16,

        fn getGlyphIndex(self: SubtableFormat4, c: u16) u16 {
            // This won't make sense if you don't read the spec...
            var i: usize = 0;
            while (i < self.end_code.len) {
                if (self.end_code[i] >= c and self.start_code[i] <= c) {
                    break;
                }
                i += 1;
            }

            if (i >= self.end_code.len) return 0;

            const byte_offset_from_id_offset = self.id_range_offset[i];
            if (byte_offset_from_id_offset == 0) {
                return self.id_delta[i] +% c;
            } else {
                // We apply the pointer offset a little different than the spec
                // suggests. We made individual allocations when copying/byte
                // swapping the id_range_offset and glyph_indices out of the input
                // data. This means that we can't just do pointer addition
                //
                // Instead we look at the data as follows
                //
                // [ id range ] [glyph indices ]
                //     |--offs_bytes--|
                //     ^
                //     i
                //
                // To find the index into glyph indices, we just subtract i from
                // id_range.len, and subtract that from the offset
                const offs_from_loc = byte_offset_from_id_offset / 2 + (c - self.start_code[i]);
                const dist_to_end = self.id_range_offset.len - i;
                const glyph_index_index = offs_from_loc - dist_to_end;
                return self.glyph_indices[glyph_index_index] +% self.id_delta[i];
            }
        }
    };

    fn readIndex(self: CmapTable) Index {
        return fixEndianness(std.mem.bytesToValue(Index, self.cmap_bytes[0 .. @bitSizeOf(Index) / 8]));
    }

    fn readSubtableLookup(self: CmapTable, idx: usize) SubtableLookup {
        const subtable_size = @bitSizeOf(SubtableLookup) / 8;
        const start = @bitSizeOf(Index) / 8 + idx * subtable_size;
        const end = start + subtable_size;

        return fixEndianness(std.mem.bytesToValue(SubtableLookup, self.cmap_bytes[start..end]));
    }

    fn readSubtableFormat(self: CmapTable, offset: usize) u16 {
        return fixEndianness(std.mem.bytesToValue(u16, self.cmap_bytes[offset .. offset + 2]));
    }

    fn readSubtableFormat4(self: CmapTable, alloc: Allocator, offset: usize) !SubtableFormat4 {
        var runtime_parser = RuntimeParser{ .data = self.cmap_bytes[offset..] };
        const format = runtime_parser.readVal(u16);
        const length = runtime_parser.readVal(u16);
        const language = runtime_parser.readVal(u16);
        const seg_count_x2 = runtime_parser.readVal(u16);
        const search_range = runtime_parser.readVal(u16);
        const entry_selector = runtime_parser.readVal(u16);
        const range_shift = runtime_parser.readVal(u16);

        const end_code: []const u16 = try runtime_parser.readArray(u16, alloc, seg_count_x2 / 2);
        const reserved_pad = runtime_parser.readVal(u16);
        const start_code: []const u16 = try runtime_parser.readArray(u16, alloc, seg_count_x2 / 2);
        const id_delta: []const u16 = try runtime_parser.readArray(u16, alloc, seg_count_x2 / 2);
        const id_range_offset: []const u16 = try runtime_parser.readArray(u16, alloc, seg_count_x2 / 2);
        const glyph_indices: []const u16 = try runtime_parser.readArray(u16, alloc, (runtime_parser.data.len - runtime_parser.idx) / 2);

        return .{
            .format = format,
            .length = length,
            .language = language,
            .seg_count_x2 = seg_count_x2,
            .search_range = search_range,
            .entry_selector = entry_selector,
            .range_shift = range_shift,
            .end_code = end_code,
            .reserved_pad = reserved_pad,
            .start_code = start_code,
            .id_delta = id_delta,
            .id_range_offset = id_range_offset,
            .glyph_indices = glyph_indices,
        };
    }
};

fn fixEndianness(val: anytype) @TypeOf(val) {
    if (builtin.cpu.arch.endian() == .big) {
        return val;
    }

    switch (@typeInfo(@TypeOf(val))) {
        .Struct => {
            var ret = val;
            std.mem.byteSwapAllFields(@TypeOf(val), &ret);
            return ret;
        },
        .Int => {
            return std.mem.bigToNative(@TypeOf(val), val);
        },
        inline else => @compileError("Cannot fix endianness for " ++ @typeName(@TypeOf(val))),
    }
}

fn fixSliceEndianness(comptime T: type, alloc: Allocator, slice: []align(1) const T) ![]T {
    const duped = try alloc.alloc(T, slice.len);
    for (0..slice.len) |i| {
        duped[i] = fixEndianness(slice[i]);
    }
    return duped;
}

pub const GlyphTable = struct {
    data: []const u8,

    pub const GlyphCommon = packed struct {
        number_of_contours: i16,
        x_min: i16,
        y_min: i16,
        x_max: i16,
        y_max: i16,
    };

    const SimpleGlyphFlag = packed struct(u8) {
        on_curve_point: bool,
        x_short_vector: bool,
        y_short_vector: bool,
        repeat_flag: bool,
        x_is_same_or_positive_x_short_vector: bool,
        y_is_same_or_positive_y_short_vector: bool,
        overlap_simple: bool,
        reserved: bool,
    };

    const GlyphParseVariant = enum {
        short_pos,
        short_neg,
        long,
        repeat,

        fn fromBools(short: bool, is_same_or_positive_short: bool) GlyphParseVariant {
            if (short) {
                if (is_same_or_positive_short) {
                    return .short_pos;
                } else {
                    return .short_neg;
                }
            } else {
                if (is_same_or_positive_short) {
                    return .repeat;
                } else {
                    return .long;
                }
            }
        }
    };

    const SimpleGlyph = struct {
        common: GlyphCommon,
        end_pts_of_contours: []u16,
        instruction_length: u16,
        instructions: []u8,
        flags: []SimpleGlyphFlag,
        x_coordinates: []i16,
        y_coordinates: []i16,
    };

    fn getGlyphCommon(self: GlyphTable, start: usize) GlyphCommon {
        return fixEndianness(std.mem.bytesToValue(GlyphCommon, self.data[start .. start + @bitSizeOf(GlyphCommon) / 8]));
    }

    fn getGlyphSimple(self: GlyphTable, alloc: Allocator, start: usize, end: usize) !SimpleGlyph {
        var runtime_parser = RuntimeParser{ .data = self.data[start..end] };
        const common = runtime_parser.readVal(GlyphCommon);

        const end_pts_of_contours = try runtime_parser.readArray(u16, alloc, @intCast(common.number_of_contours));
        const instruction_length = runtime_parser.readVal(u16);
        const instructions = try runtime_parser.readArray(u8, alloc, instruction_length);
        const num_contours = end_pts_of_contours[end_pts_of_contours.len - 1] + 1;
        const flags = try alloc.alloc(SimpleGlyphFlag, num_contours);

        var i: usize = 0;
        while (i < num_contours) {
            defer i += 1;
            const flag_u8 = runtime_parser.readVal(u8);
            const flag: SimpleGlyphFlag = @bitCast(flag_u8);
            std.debug.assert(flag.reserved == false);

            flags[i] = flag;

            if (flag.repeat_flag) {
                const num_repetitions = runtime_parser.readVal(u8);
                @memset(flags[i + 1 .. i + 1 + num_repetitions], flag);
                i += num_repetitions;
            }
        }

        const x_coords = try alloc.alloc(i16, num_contours);
        for (flags, 0..) |flag, idx| {
            const parse_variant = GlyphParseVariant.fromBools(flag.x_short_vector, flag.x_is_same_or_positive_x_short_vector);
            switch (parse_variant) {
                .short_pos => x_coords[idx] = runtime_parser.readVal(u8),
                .short_neg => x_coords[idx] = -@as(i16, runtime_parser.readVal(u8)),
                .long => x_coords[idx] = runtime_parser.readVal(i16),
                .repeat => x_coords[idx] = 0,
            }
        }

        const y_coords = try alloc.alloc(i16, num_contours);
        for (flags, 0..) |flag, idx| {
            const parse_variant = GlyphParseVariant.fromBools(flag.y_short_vector, flag.y_is_same_or_positive_y_short_vector);
            switch (parse_variant) {
                .short_pos => y_coords[idx] = runtime_parser.readVal(u8),
                .short_neg => y_coords[idx] = -@as(i16, runtime_parser.readVal(u8)),
                .long => y_coords[idx] = runtime_parser.readVal(i16),
                .repeat => y_coords[idx] = 0,
            }
        }

        return .{
            .common = common,
            .end_pts_of_contours = end_pts_of_contours,
            .instruction_length = instruction_length,
            .instructions = instructions,
            .flags = flags,
            .x_coordinates = x_coords,
            .y_coordinates = y_coords,
        };
    }
};

pub const Ttf = struct {
    const HeaderTag = enum {
        cmap,
        head,
        maxp,
        loca,
        glyf,
        hhea,
        hmtx,
    };

    head: HeadTable,
    maxp: MaxpTable,
    cmap: CmapTable,
    loca: []const u32,
    glyf: GlyphTable,
    hhea: HheaTable,
    hmtx: HmtxTable,

    cmap_subtable: CmapTable.SubtableFormat4,

    pub fn init(alloc: Allocator, font_data: []const u8) !Ttf {
        const offset_table = fixEndianness(std.mem.bytesToValue(OffsetTable, font_data[0 .. @bitSizeOf(OffsetTable) / 8]));
        const table_directory_start = @bitSizeOf(OffsetTable) / 8;
        const table_directory_end = table_directory_start + @bitSizeOf(TableDirectoryEntry) * offset_table.num_tables / 8;
        const table_entries = std.mem.bytesAsSlice(TableDirectoryEntry, font_data[table_directory_start..table_directory_end]);
        var head: ?HeadTable = null;
        var maxp: ?MaxpTable = null;
        var cmap: ?CmapTable = null;
        var glyf: ?GlyphTable = null;
        var loca: ?[]const u32 = null;
        var hhea: ?HheaTable = null;
        var hmtx: ?HmtxTable = null;

        for (table_entries) |entry_big| {
            const entry = fixEndianness(entry_big);
            const tag = std.meta.stringToEnum(HeaderTag, &entry.tag) orelse continue;

            switch (tag) {
                .head => {
                    head = fixEndianness(std.mem.bytesToValue(HeadTable, tableFromEntry(font_data, entry)));
                },
                .hhea => {
                    hhea = fixEndianness(std.mem.bytesToValue(HheaTable, tableFromEntry(font_data, entry)));
                },
                .loca => {
                    loca = try fixSliceEndianness(u32, alloc, @alignCast(std.mem.bytesAsSlice(u32, tableFromEntry(font_data, entry))));
                },
                .maxp => {
                    maxp = fixEndianness(std.mem.bytesToValue(MaxpTable, tableFromEntry(font_data, entry)));
                },
                .cmap => {
                    cmap = CmapTable{ .cmap_bytes = tableFromEntry(font_data, entry) };
                },
                .glyf => {
                    glyf = GlyphTable{ .data = tableFromEntry(font_data, entry) };
                },
                .hmtx => {
                    hmtx = HmtxTable{ .hmtx_bytes = tableFromEntry(font_data, entry) };
                },
            }
        }

        const head_unwrapped = head orelse return error.NoHead;

        // Otherwise locs are the wrong size
        std.debug.assert(head_unwrapped.index_to_loc_format == 1);
        // Magic is easy to check
        std.debug.assert(head_unwrapped.magic_number == 0x5F0F3CF5);

        const subtable = try readSubtable(alloc, cmap orelse unreachable);

        return .{
            .maxp = maxp orelse return error.NoMaxp,
            .head = head_unwrapped,
            .loca = loca orelse return error.NoLoca,
            .cmap = cmap orelse return error.NoCmap,
            .glyf = glyf orelse return error.NoGlyf,
            .cmap_subtable = subtable,
            .hhea = hhea orelse return error.NoHhea,
            .hmtx = hmtx orelse return error.NoHmtx,
        };
    }
};

const FPoint = @Vector(2, i16);

pub const GlyphSegmentIter = struct {
    glyph: GlyphTable.SimpleGlyph,
    x_acc: i16 = 0,
    y_acc: i16 = 0,

    idx: usize = 0,
    contour_idx: usize = 0,
    last_contour_last_point: FPoint = .{ 0, 0 },

    pub const Output = union(enum) {
        line: struct {
            a: FPoint,
            b: FPoint,
            contour_id: usize,
        },
        bezier: struct {
            a: FPoint,
            b: FPoint,
            c: FPoint,
            contour_id: usize,
        },
    };

    pub fn init(glyph: GlyphTable.SimpleGlyph) GlyphSegmentIter {
        return GlyphSegmentIter{
            .glyph = glyph,
        };
    }

    pub fn next(self: *GlyphSegmentIter) ?Output {
        while (true) {
            if (self.idx >= self.glyph.x_coordinates.len) return null;
            defer self.idx += 1;

            const a = self.getPoint(self.idx);

            defer self.x_acc = a.pos[0];
            defer self.y_acc = a.pos[1];

            const b = self.getPoint(self.idx + 1);
            const c = self.getPoint(self.idx + 2);

            const ret = abcToCurve(a, b, c, self.contour_idx);
            if (self.glyph.end_pts_of_contours[self.contour_idx] == self.idx) {
                self.contour_idx += 1;
                self.last_contour_last_point = a.pos;
            }

            if (ret) |val| {
                return val;
            }
        }
    }

    const Point = struct {
        on_curve: bool,
        pos: FPoint,
    };

    fn abcToCurve(a: Point, b: Point, c: Point, contour_idx: usize) ?Output {
        if (a.on_curve and b.on_curve) {
            return .{ .line = .{
                .a = a.pos,
                .b = b.pos,
                .contour_id = contour_idx,
            } };
        } else if (b.on_curve) {
            return null;
        }

        std.debug.assert(!b.on_curve);

        const a_on = resolvePoint(a, b);
        const c_on = resolvePoint(c, b);

        return .{ .bezier = .{
            .a = a_on,
            .b = b.pos,
            .c = c_on,
            .contour_id = contour_idx,
        } };
    }

    fn contourStart(self: GlyphSegmentIter) usize {
        if (self.contour_idx == 0) {
            return 0;
        } else {
            return self.glyph.end_pts_of_contours[self.contour_idx - 1] + 1;
        }
    }

    fn wrappedContourIdx(self: GlyphSegmentIter, idx: usize) usize {
        const contour_start = self.contourStart();
        const contour_len = self.glyph.end_pts_of_contours[self.contour_idx] + 1 - contour_start;

        return (idx - contour_start) % contour_len + contour_start;
    }

    fn getPoint(self: *GlyphSegmentIter, idx: usize) Point {
        var x_acc = self.x_acc;
        var y_acc = self.y_acc;

        for (self.idx..idx + 1) |i| {
            const wrapped_i = self.wrappedContourIdx(i);
            if (wrapped_i == self.contourStart()) {
                x_acc = self.last_contour_last_point[0];
                y_acc = self.last_contour_last_point[1];
            }
            x_acc += self.glyph.x_coordinates[wrapped_i];
            y_acc += self.glyph.y_coordinates[wrapped_i];
        }

        const pos = FPoint{
            x_acc,
            y_acc,
        };

        const on_curve = self.glyph.flags[self.wrappedContourIdx(idx)].on_curve_point;
        return .{
            .on_curve = on_curve,
            .pos = pos,
        };
    }

    fn resolvePoint(maybe_off: Point, off: Point) FPoint {
        if (maybe_off.on_curve) return maybe_off.pos;
        std.debug.assert(off.on_curve == false);

        return (maybe_off.pos + off.pos) / FPoint{ 2, 2 };
    }
};

fn readSubtable(alloc: Allocator, cmap: CmapTable) !CmapTable.SubtableFormat4 {
    const index = cmap.readIndex();
    const unicode_table_offs = blk: {
        for (0..index.num_subtables) |i| {
            const subtable = cmap.readSubtableLookup(i);
            if (subtable.isUnicodeBmp()) {
                break :blk subtable.offset;
            }
        }
        return error.NoUnicodeBmpTables;
    };

    const format = cmap.readSubtableFormat(unicode_table_offs);
    if (format != 4) {
        std.log.err("Can only handle unicode format 4", .{});
        return error.Unimplemented;
    }

    return try cmap.readSubtableFormat4(alloc, unicode_table_offs);
}

pub fn glyphHeaderForChar(ttf: Ttf, char: u16) ?GlyphTable.GlyphCommon {
    const glyph_index = ttf.cmap_subtable.getGlyphIndex(char);
    const glyf_start = ttf.loca[glyph_index];
    const glyf_end = ttf.loca[glyph_index + 1];

    if (glyf_start == glyf_end) return null;

    return ttf.glyf.getGlyphCommon(glyf_start);
}

pub fn glyphForChar(alloc: Allocator, ttf: Ttf, char: u16) !?GlyphTable.SimpleGlyph {
    const glyph_index = ttf.cmap_subtable.getGlyphIndex(char);
    const glyf_start = ttf.loca[glyph_index];
    const glyf_end = ttf.loca[glyph_index + 1];

    if (glyf_start == glyf_end) return null;

    const glyph_header = ttf.glyf.getGlyphCommon(glyf_start);

    std.debug.assert(glyph_header.number_of_contours >= 0);
    return try ttf.glyf.getGlyphSimple(alloc, glyf_start, glyf_end);
}

pub fn metricsForChar(ttf: Ttf, char: u16) HmtxTable.LongHorMetric {
    const glyph_index = ttf.cmap_subtable.getGlyphIndex(char);
    return ttf.hmtx.getMetrics(ttf.hhea.num_of_long_hor_metrics, glyph_index);
}

pub fn lineHeight(ttf: Ttf) i16 {
    return ttf.hhea.ascent - ttf.hhea.descent + ttf.hhea.line_gap;
}

pub fn lineHeightPx(ttf: Ttf, point_size: f32) i32 {
    const converter = FunitToPixelConverter.init(point_size, @floatFromInt(ttf.head.units_per_em));
    return converter.pixelFromFunit(lineHeight(ttf));
}

pub const FunitToPixelConverter = struct {
    scale: f32,

    pub fn init(font_size: f32, units_per_em: f32) FunitToPixelConverter {
        const dpi = 96; // Default DPI is 96
        const base_dpi = 72; // from ttf spec
        return .{
            .scale = font_size * dpi / (base_dpi * units_per_em),
        };
    }

    pub fn pixelBoundsForGlyph(self: FunitToPixelConverter, glyph_header: GlyphTable.GlyphCommon) [2]u16 {
        const width_f: f32 = @floatFromInt(glyph_header.x_max - glyph_header.x_min);
        const height_f: f32 = @floatFromInt(glyph_header.y_max - glyph_header.y_min);

        return .{
            @intFromFloat(@round(width_f * self.scale)),
            @intFromFloat(@round(height_f * self.scale)),
        };
    }

    pub fn pixelFromFunit(self: FunitToPixelConverter, funit: i64) i32 {
        const size_f: f32 = @floatFromInt(funit);
        return @intFromFloat(@round(self.scale * size_f));
    }
};

pub const BBox = struct {
    const invalid = BBox{
        .min_x = std.math.maxInt(i16),
        .max_x = std.math.minInt(i16),
        .min_y = std.math.maxInt(i16),
        .max_y = std.math.minInt(i16),
    };

    min_x: i16,
    max_x: i16,
    min_y: i16,
    max_y: i16,

    pub fn width(self: BBox) usize {
        return @intCast(self.max_x - self.min_x);
    }

    pub fn height(self: BBox) usize {
        return @intCast(self.max_y - self.min_y);
    }
};

fn pointsBounds(points: []const FPoint) BBox {
    var ret = BBox.invalid;

    for (points) |point| {
        ret.min_x = @min(point[0], ret.min_x);
        ret.min_y = @min(point[1], ret.min_x);
        ret.max_x = @max(point[0], ret.max_x);
        ret.max_y = @max(point[1], ret.max_x);
    }

    return ret;
}

fn curveBounds(curve: GlyphSegmentIter.Output) BBox {
    switch (curve) {
        .line => |l| {
            return pointsBounds(&.{ l.a, l.b });
        },
        .bezier => |b| {
            return pointsBounds(&.{ b.a, b.b, b.c });
        },
    }
}

fn mergeBboxes(a: BBox, b: BBox) BBox {
    return .{
        .min_x = @min(a.min_x, b.min_x),
        .max_x = @max(a.max_x, b.max_x),
        .min_y = @min(a.min_y, b.min_y),
        .max_y = @max(a.max_y, b.max_y),
    };
}

const RowCurvePointInner = struct {
    x_pos: i64,
    entering: bool,
    contour_id: usize,

    pub fn format(value: RowCurvePointInner, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d} ({}, {})", .{ value.x_pos, value.entering, value.contour_id });
    }
};

const RowCurvePoint = struct {
    x_pos: i64,
    entering: bool,

    pub fn format(value: RowCurvePoint, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d} ({})", .{ value.x_pos, value.entering });
    }
};

fn sortRemoveDuplicateCurvePoints(alloc: Allocator, points: *std.ArrayList(RowCurvePointInner)) !void {
    var to_remove = std.ArrayList(usize).init(alloc);
    defer to_remove.deinit();
    for (0..points.items.len) |i| {
        const next_idx = (i + 1) % points.items.len;
        if (points.items[i].entering == points.items[next_idx].entering and points.items[i].contour_id == points.items[next_idx].contour_id) {
            if (points.items[i].entering) {
                if (points.items[i].x_pos > points.items[next_idx].x_pos) {
                    try to_remove.append(i);
                } else {
                    try to_remove.append(next_idx);
                }
            } else {
                if (points.items[i].x_pos > points.items[next_idx].x_pos) {
                    try to_remove.append(next_idx);
                } else {
                    try to_remove.append(i);
                }
            }
        }
    }

    while (to_remove.popOrNull()) |i| {
        if (points.items.len == 1) break;
        _ = points.swapRemove(i);
    }

    const lessThan = struct {
        fn f(_: void, lhs: RowCurvePointInner, rhs: RowCurvePointInner) bool {
            if (lhs.x_pos == rhs.x_pos) {
                return lhs.entering and !rhs.entering;
            }
            return lhs.x_pos < rhs.x_pos;
        }
    }.f;
    std.mem.sort(RowCurvePointInner, points.items, {}, lessThan);
}

fn findRowCurvePoints(alloc: Allocator, curves: []const GlyphSegmentIter.Output, y: i64) ![]RowCurvePoint {
    var ret = std.ArrayList(RowCurvePointInner).init(alloc);
    defer ret.deinit();

    for (curves) |curve| {
        switch (curve) {
            .line => |l| {
                const a_f: @Vector(2, f32) = @floatFromInt(l.a);
                const b_f: @Vector(2, f32) = @floatFromInt(l.b);
                const y_f: f32 = @floatFromInt(y);

                if (l.b[1] == l.a[1]) continue;
                const t = (y_f - a_f[1]) / (b_f[1] - a_f[1]);

                if (!(t >= 0.0 and t <= 1.0)) {
                    continue;
                }

                const x = std.math.lerp(a_f[0], b_f[0], t);

                const x_pos_i: i64 = @intFromFloat(@round(x));
                const entering = l.a[1] < l.b[1];

                try ret.append(.{ .entering = entering, .x_pos = x_pos_i, .contour_id = l.contour_id });
            },
            .bezier => |b| {
                const a_f: @Vector(2, f32) = @floatFromInt(b.a);
                const b_f: @Vector(2, f32) = @floatFromInt(b.b);
                const c_f: @Vector(2, f32) = @floatFromInt(b.c);

                const ts = findBezierTForY(a_f[1], b_f[1], c_f[1], @floatFromInt(y));

                for (ts, 0..) |t, i| {
                    if (!(t >= 0.0 and t <= 1.0)) {
                        continue;
                    }
                    const tangent_line = quadBezierTangentLine(a_f, b_f, c_f, t);

                    const eps = 1e-7;
                    const at_apex = @abs(tangent_line.a[1] - tangent_line.b[1]) < eps;
                    const at_end = t < eps or @abs(t - 1.0) < eps;
                    const moving_up = tangent_line.a[1] < tangent_line.b[1] or b.a[1] < b.c[1];

                    // If we are at the apex, and at the very edge of a curve,
                    // we have to be careful. In this case we can only count
                    // one of the enter/exit events as we are only half of the
                    // parabola.
                    //
                    // U -> enter/exit
                    // \_ -> enter
                    // _/ -> exit
                    //  _
                    // / -> enter
                    // _
                    //  \-> exit

                    // The only special case is that we are at the apex, and at
                    // the end of the curve. In this case we only want to
                    // consider one of the two points. Otherwise we just ignore
                    // the apex as it's an immediate enter/exit. I.e. useless
                    //
                    // This boils down to the following condition
                    if (at_apex and (!at_end or i == 1)) continue;

                    const x_f = sampleQuadBezierCurve(a_f, b_f, c_f, t)[0];
                    const x_px: i64 = @intFromFloat(@round(x_f));
                    try ret.append(.{
                        .entering = moving_up,
                        .x_pos = x_px,
                        .contour_id = b.contour_id,
                    });
                }
            },
        }
    }

    try sortRemoveDuplicateCurvePoints(alloc, &ret);

    const real_ret = try alloc.alloc(RowCurvePoint, ret.items.len);
    for (0..ret.items.len) |i| {
        real_ret[i] = .{
            .entering = ret.items[i].entering,
            .x_pos = ret.items[i].x_pos,
        };
    }

    return real_ret;
}

test "find row points V" {
    // Double counted point at the apex of a V, should immediately go in and out
    const curves = [_]GlyphSegmentIter.Output{
        .{
            .line = .{
                .a = .{ -1.0, 1.0 },
                .b = .{ 0.0, 0.0 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 0.0, 0.0 },
                .b = .{ 1.0, 1.0 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 0);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 0,
                .entering = true,
            },
            .{
                .x_pos = 0,
                .entering = false,
            },
        },
        points,
    );
}

test "find row points X" {
    // Double entry and exit on the horizontal part where there's wraparound
    const curves = [_]GlyphSegmentIter.Output{
        .{
            .line = .{
                .a = .{ 5, 0 },
                .b = .{ 10, -10 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ -10, -10 },
                .b = .{ -5, 0 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ -5, 0 },
                .b = .{ -10, 10 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 10, 10 },
                .b = .{ 5, 0 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 0);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = -5,
                .entering = true,
            },
            .{
                .x_pos = 5,
                .entering = false,
            },
        },
        points,
    );
}

test "find row points G" {
    // G has segment that goes
    //
    // |       ^
    // v____   |
    //      |  |
    //      v  |
    //
    // In this case we somehow have to avoid double counting the down arrow
    //

    const curves = [_]GlyphSegmentIter.Output{
        .{
            .line = .{
                .a = .{ 0, -5 },
                .b = .{ 0, 0 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 0, 0 },
                .b = .{ 5, 0 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 5, 0 },
                .b = .{ 5, 5 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 5, 5 },
                .b = .{ 10, 5 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 10, 5 },
                .b = .{ 10, -5 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 0);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 0,
                .entering = true,
            },
            .{
                .x_pos = 10,
                .entering = false,
            },
        },
        points,
    );
}

test "find row points horizontal line into bezier cw" {
    // Bottom inside of one of the holes in the letter B
    // shape like ___/. Here we want to ensure that after we exit the
    // quadratic, we have determined that we are outside the curve
    const curves = [_]GlyphSegmentIter.Output{
        .{
            .bezier = .{
                .a = .{ 855, 845 },
                .b = .{ 755, 713 },
                .c = .{ 608, 713 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 608, 713 },
                .b = .{ 369, 713 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 369, 713 },
                .b = .{ 369, 800 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 713);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 369,
                .entering = true,
            },
            .{
                .x_pos = 608,
                .entering = false,
            },
        },
        points,
    );
}

test "find row points bezier apex matching" {
    // Top of a C. There are two bezier curves that run into eachother at the
    // apex with a tangent of 0. This should result in an immediate in/out
    const curves = [_]GlyphSegmentIter.Output{
        .{
            .bezier = .{
                .a = .{ 350, 745 },
                .b = .{ 350, 135 },
                .c = .{ 743, 135 },
                .contour_id = 0,
            },
        },
        .{
            .bezier = .{
                .a = .{ 743, 135 },
                .b = .{ 829, 135 },
                .c = .{ 916, 167 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 135);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 743,
                .entering = true,
            },
            .{
                .x_pos = 743,
                .entering = false,
            },
        },
        points,
    );
}

test "find row points ascending line segments" {
    // Double counted point should be deduplicated as it's going in the same direction
    //
    // e.g. the o will be in two segments, but should count as one line cross
    //     /
    //    /
    //   o
    //  /
    // /

    const curves = [_]GlyphSegmentIter.Output{
        .{
            .line = .{
                .a = .{ 0, 0 },
                .b = .{ 1, 1 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 1, 1 },
                .b = .{ 2, 2 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 1);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 1,
                .entering = true,
            },
        },
        points,
    );
}

test "find row points bezier curve into line" {
    // In the following case
    //  |<-----
    //  |      \
    //  v
    //
    // If we end up on the horizontal line, we should see an exit followed by entry (counter clockwise)
    //
    const curves = [_]GlyphSegmentIter.Output{
        .{
            .bezier = .{
                .a = .{ 5, 0 },
                .b = .{ 5, 1 },
                .c = .{ 3, 1 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 3, 1 },
                .b = .{ 1, 1 },
                .contour_id = 0,
            },
        },
        .{
            .line = .{
                .a = .{ 1, 1 },
                .b = .{ 1, 0 },
                .contour_id = 0,
            },
        },
    };

    const points = try findRowCurvePoints(std.testing.allocator, &curves, 1);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqualSlices(
        RowCurvePoint,
        &.{
            .{
                .x_pos = 1,
                .entering = false,
            },
            .{
                .x_pos = 3,
                .entering = true,
            },
        },
        points,
    );
}

const Canvas = struct {
    pixels: []u8,
    width: usize,

    pub fn init(alloc: Allocator, width: usize, height: usize) !Canvas {
        const pixels = try alloc.alloc(u8, width * height);
        return .{
            .pixels = pixels,
            .width = width,
        };
    }

    pub fn iWidth(self: Canvas) i64 {
        return @intCast(self.width);
    }

    pub fn calcHeight(self: Canvas) i64 {
        return @intCast(self.pixels.len / self.width);
    }

    pub fn clampedY(self: Canvas, val: i64) i64 {
        return @intCast(std.math.clamp(val, 0, self.calcHeight()));
    }

    pub fn clampedX(self: Canvas, val: i64) i64 {
        return @intCast(std.math.clamp(val, 0, self.iWidth()));
    }

    pub fn getRow(self: Canvas, y: i64) []u8 {
        const row_start: usize = @intCast(y * self.iWidth());
        const row_end: usize = row_start + self.width;
        return self.pixels[row_start..row_end];
    }
};

pub fn renderGlyphAt1PxPerFunit(alloc: Allocator, glyph: GlyphTable.SimpleGlyph) !struct { Canvas, BBox } {
    var iter = GlyphSegmentIter.init(glyph);

    var curves = std.ArrayList(GlyphSegmentIter.Output).init(alloc);
    defer curves.deinit();

    var total_bbox = BBox{
        .min_x = glyph.common.x_min,
        .max_x = glyph.common.x_max,
        .min_y = glyph.common.y_min,
        .max_y = glyph.common.y_max,
    };

    while (iter.next()) |item| {
        try curves.append(item);
    }

    var canvas = try Canvas.init(alloc, ((total_bbox.width() + 7) / 8) * 8, total_bbox.height());

    @memset(canvas.pixels, 0);

    var y = total_bbox.min_y;
    while (y < total_bbox.max_y) {
        defer y += 1;
        const row = canvas.getRow(y - total_bbox.min_y);

        const row_curve_points = try findRowCurvePoints(alloc, curves.items, y);
        defer alloc.free(row_curve_points);

        var winding_count: i64 = 0;
        var start: i64 = 0;
        for (row_curve_points) |point| {
            if (point.entering == false) {
                winding_count -= 1;
            } else {
                winding_count += 1;
                if (winding_count == 1) {
                    start = point.x_pos;
                }
            }
            // NOTE: Always see true first due to sorting
            if (winding_count == 0) {
                @memset(row[@intCast(canvas.clampedX(start - total_bbox.min_x))..@intCast(canvas.clampedX(point.x_pos - total_bbox.min_x))], 255);
            }
        }
    }

    return .{ canvas, total_bbox };
}

pub fn findBezierTForY(p1: f32, p2: f32, p3: f32, y: f32) [2]f32 {
    // Bezier curve formula comes from lerping p1->p2 by t, p2->p3 by t, and
    // then lerping the line from those two points by t as well
    //
    // p12 = (t * (p2 - p1)) + p1
    // p23 = (t * (p3 - p2)) + p2
    // out = (t * (p23 - p12)) + p12
    //
    // expanding and simplifying...
    // p12 = t*p2 - t*p1 + p1
    // p23 = t*p3 - t*p2 + p2
    // out = t(t*p3 - t*p2 + p2) - t(t*p2 - t*p1 + p1) + t*p2 - t*p1 + p1
    // out = t^2*p3 - t^2*p2 + t*p2 - t^2*p2 + t^2*p1 - t*p1 + t*p2 - t*p1 + p1
    // out = t^2(p3 - 2*p2 + p1) + t(p2 - p1 + p2 - p1) + p1
    // out = t^2(p3 - 2*p2 + p1) + 2*t(p2 - p1) + p1
    //
    // Which now looks like a quadratic formula that we can solve for.
    // Calling t^2 coefficient a, t coefficient b, and the remainder c...
    const a = p3 - 2 * p2 + p1;
    const b = 2 * (p2 - p1);
    // Note that we are solving for out == y, so we need to adjust the c term
    // to p1 - y
    const c = p1 - y;

    const eps = 1e-7;
    const not_quadratic = @abs(a) < eps;
    const not_linear = not_quadratic and @abs(b) < eps;
    if (not_linear) {
        // I guess in this case we can return any t, as all t values will
        // result in the same y value.
        return .{ 0.5, 0.5 };
    } else if (not_quadratic) {
        // bt + c = 0 (c accounts for y)
        const ret = -c / b;
        return .{ ret, ret };
    }

    const out_1 = (-b + @sqrt(b * b - 4 * a * c)) / (2 * a);
    const out_2 = (-b - @sqrt(b * b - 4 * a * c)) / (2 * a);
    return .{ out_1, out_2 };
}

const TangentLine = struct {
    a: @Vector(2, f32),
    b: @Vector(2, f32),
};

pub fn quadBezierTangentLine(a: @Vector(2, f32), b: @Vector(2, f32), c: @Vector(2, f32), t: f32) TangentLine {
    const t_splat: @Vector(2, f32) = @splat(t);
    const ab = std.math.lerp(a, b, t_splat);
    const bc = std.math.lerp(b, c, t_splat);
    return .{
        .a = ab,
        .b = bc,
    };
}

pub fn sampleQuadBezierCurve(a: @Vector(2, f32), b: @Vector(2, f32), c: @Vector(2, f32), t: f32) @Vector(2, f32) {
    const tangent_line = quadBezierTangentLine(a, b, c, t);
    return std.math.lerp(tangent_line.a, tangent_line.b, @as(@Vector(2, f32), @splat(t)));
}

test "bezier solving" {
    const curves = [_][3]@Vector(2, f32){
        .{
            .{ -20, 20 },
            .{ 0, 0 },
            .{ 20, 20 },
        },
        .{
            .{ -15, -30 },
            .{ 5, 15 },
            .{ 10, 20 },
        },
        .{
            .{ 40, -30 },
            .{ 80, -10 },
            .{ 20, 10 },
        },
    };

    const ts = [_]f32{ 0.0, 0.1, 0.4, 0.5, 0.8, 1.0 };

    for (curves) |curve| {
        for (ts) |in_t| {
            const point1 = sampleQuadBezierCurve(
                curve[0],
                curve[1],
                curve[2],
                in_t,
            );

            var t1, var t2 = findBezierTForY(curve[0][1], curve[1][1], curve[2][1], point1[1]);
            if (@abs(t1 - in_t) > @abs(t2 - in_t)) {
                std.mem.swap(f32, &t1, &t2);
            }
            try std.testing.expectApproxEqAbs(in_t, t1, 0.001);

            if (t2 <= 1.0 and t2 >= 0.0) {
                const point2 = sampleQuadBezierCurve(
                    curve[0],
                    curve[1],
                    curve[2],
                    t2,
                );

                try std.testing.expectApproxEqAbs(point2[1], point1[1], 0.001);
            }
        }
    }
}
