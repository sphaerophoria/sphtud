/// DNS implementation, io implementation agnostic, unit testable
const std = @import("std");
const sphtud = @import("../sphtud.zig");
const system = std.posix.system;

request_buf: [dns_query_max]u8,
dns_alloc: *sphtud.alloc.Sphalloc,
resolv_conf: ResolvConf,
hosts: Hosts,
pool: Pool,
dns_packet_id: u16,

const dns_query_max = 512; // rfc 1035 2.3.4
const max_retries = 3;
const retry_timeout = 3;

const Pool = sphtud.util.ObjectPool(QueryStorage, QueryHandle);
const DnsImpl = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, resolv_conf: ResolvConf, hosts: Hosts, max_connections: usize) !DnsImpl {
    return .{
        .request_buf = undefined,
        .hosts = hosts,
        .dns_alloc = alloc,
        .resolv_conf = resolv_conf,
        .dns_packet_id = 0,
        .pool = try .init(
            alloc.arena(),
            alloc.expansion(),
            8,
            max_connections,
        ),
    };
}

const Self = @This();

pub const QueryHandle = struct {
    id: usize,

    pub fn toIdx(self: QueryHandle) usize {
        return self.id;
    }

    pub fn fromIdx(idx: usize) QueryHandle {
        return .{ .id = idx };
    }
};

// When you get this you should
// * call next() and dispatch datagrams
// * schedule a timeout if we want one
// * store the handle and release it when you're done with it
// * Immediately check if the query has returned any answers
pub const QueryResult = struct {
    handle: QueryHandle,
    timeout: ?std.Io.Duration,
    priv: struct {
        buf: []u8,
        idx: u16,
        parent: *DnsImpl,
    },

    const SendTo = struct {
        ip: std.Io.net.IpAddress,
        data: []u8,
    };

    pub fn next(self: *QueryResult) ?SendTo {
        const priv = &self.priv;
        const rc = &priv.parent.resolv_conf;

        if (priv.idx >= rc.num_nameservers) {
            return null;
        }

        defer priv.idx += 1;

        // Between requests for the same host, the only thing that changes is
        // the ID. Just re-use the existing buffer and update the ID manually
        const query = priv.parent.get(self.handle);
        std.mem.writeInt(u16, priv.buf[0..2], query.start_id +% priv.idx, .big);

        return .{
            .ip = rc.nameservers[priv.idx],
            .data = priv.buf,
        };
    }
};

pub fn makeQuery(self: *Self, host: []const u8) !QueryResult {
    if (parseIp(host)) |ip| {
        return self.makeImmediate(ip);
    }

    if (self.hosts.get(host)) |ip| switch (ip) {
        .ip4 => |v| {
            return self.makeImmediate(v.bytes);
        },
        .ip6 => {},
    };

    return self.makeDnsQuery(host);
}

fn parseIp(host: []const u8) ?[4]u8 {
    const ip = std.Io.net.IpAddress.parse(host, 0) catch return null;
    switch (ip) {
        .ip4 => |val| return val.bytes,
        .ip6 => return null,
    }
}

// QueryResult references a buffer owned by DnsImpl, multiple cannot be in
// flight at once
fn makeDnsQuery(self: *Self, host: []const u8) !QueryResult {
    const query = try self.pool.acquire(self.dns_alloc.expansion());
    errdefer self.pool.release(self.dns_alloc.expansion(), query.handle);

    const alloc = try self.dns_alloc.makeSubAlloc("dns query");
    errdefer alloc.deinit();

    query.val.* = .{
        .alloc = alloc,
        .retry_count = 1,
        .err = null,
        .host = try alloc.arena().dupe(u8, host),
        .query_results = @splat(null),
        .idx = 0,
        .sub_idx = 0,
        .parent = self,
        .start_id = self.dns_packet_id,
    };

    var w = std.Io.Writer.fixed(&self.request_buf);
    try writeDnsQuery(&w, host, self.dns_packet_id);

    self.dns_packet_id +%= self.resolv_conf.num_nameservers;

    while (self.dns_packet_id +% self.resolv_conf.num_nameservers < self.dns_packet_id) {
        self.dns_packet_id +%= self.resolv_conf.num_nameservers;
    }

    return .{
        .handle = query.handle,
        .timeout = .fromSeconds(retry_timeout),
        .priv = .{
            .buf = w.buffered(),
            .idx = 0,
            .parent = self,
        },
    };
}

fn makeImmediate(self: *Self, ip: [4]u8) !QueryResult {
    const query = try self.pool.acquire(self.dns_alloc.expansion());
    errdefer self.pool.release(self.dns_alloc.expansion(), query.handle);

    // Query acts like we're on the last nameserver, and the last nameserver
    // has already responded with a single IP

    query.val.* = .{
        .alloc = try self.dns_alloc.makeSubAlloc("immediate query"),
        .retry_count = max_retries,
        .err = null,
        .host = &.{},
        .query_results = @splat(&.{}),
        .idx = self.resolv_conf.num_nameservers - 1,
        .sub_idx = 0,
        .parent = self,
        .start_id = 0,
    };

    const res = try query.val.alloc.arena().alloc([4]u8, 1);
    res[0] = ip;
    query.val.query_results[self.resolv_conf.num_nameservers - 1] = res;

    // Response we act like we already sent all our requests
    return .{
        .handle = query.handle,
        .timeout = null,
        .priv = .{
            .buf = &.{},
            .idx = self.resolv_conf.num_nameservers,
            .parent = self,
        },
    };
}

pub fn get(self: *Self, handle: QueryHandle) *QueryStorage {
    return self.pool.get(handle);
}

pub fn release(self: *Self, handle: QueryHandle) void {
    const query = self.pool.get(handle);
    query.deinit();
    self.pool.release(self.dns_alloc.expansion(), handle);
}

pub fn onRecv(self: *Self, received: []const u8) !?QueryHandle {
    var r = std.Io.Reader.fixed(received);

    const header = try DnsHeader.read(&r);
    try discardQuestions(&r, header.qdcount);

    const matched = self.matchQuery(header.id) orelse {
        // FIXME: Diagnostics maybe?
        std.log.warn("Got dns response for non-existing query ({d})\n", .{header.id});
        return null;
    };

    if (header.tc != 0) {
        // FIXME: Diagnostics maybe?
        std.log.err("DNS resolution failed, try again with tcp :)\n", .{});
        matched.query.val.query_results[matched.sub_idx] = &.{};

        // No need to notify when we know there's nothing to do, unless
        // it's the last one, then the caller needs to realize that
        // they're screwed
        if (matched.sub_idx == self.resolv_conf.num_nameservers - 1) {
            return matched.query.handle;
        }
    }

    if (readAnswers(matched.query.val.alloc.arena(), header, &r)) |ips| {
        matched.query.val.query_results[matched.sub_idx] = ips;
    } else |e| {
        matched.query.val.err = e;
    }

    return matched.query.handle;
}

const MatchedQuery = struct {
    query: Pool.WithHandle,
    sub_idx: usize,
};

fn matchQuery(self: *Self, id: u16) ?MatchedQuery {
    var it = self.pool.iter();

    while (it.next()) |q| {
        const end_id = q.val.start_id +% self.resolv_conf.num_nameservers;

        // This should be ensured when we increment the packet id
        std.debug.assert(end_id >= q.val.start_id);

        if (id >= q.val.start_id and id < end_id) {
            return .{
                .query = q,
                .sub_idx = id - q.val.start_id,
            };
        }
    }

    return null;
}

fn readAnswers(alloc: std.mem.Allocator, header: DnsHeader, r: *std.Io.Reader) ![][4]u8 {
    const ips_buf = try alloc.alloc([4]u8, header.ancount);
    var ips = std.ArrayList([4]u8).initBuffer(ips_buf);

    for (0..header.ancount) |_| {
        const answer = try DnsRR.read(r);
        const typ = std.enums.fromInt(QType, answer.typ);
        const class = std.enums.fromInt(QClass, answer.class);

        if (typ == .a and class == .in) {
            if (answer.rdata.len < 4) {
                return error.InvalidAnswer;
            }

            ips.appendBounded(.{
                answer.rdata[0],
                answer.rdata[1],
                answer.rdata[2],
                answer.rdata[3],
            }) catch unreachable;
        }
    }

    return ips.items;
}

const TimeoutAction = union(enum) {
    retry: QueryResult,
    finish,
};

pub fn onTimeout(self: *Self, handle: QueryHandle) !TimeoutAction {
    const query = self.pool.get(handle);

    if (query.retry_count >= max_retries) {
        query.err = error.Timedout;
        return .finish;
    }

    query.retry_count += 1;

    var w = std.Io.Writer.fixed(&self.request_buf);
    try writeDnsQuery(&w, query.host, query.start_id);

    return .{
        .retry = .{
            .handle = handle,
            .timeout = .fromSeconds(retry_timeout),
            .priv = .{
                .buf = w.buffered(),
                .idx = 0,
                .parent = self,
            },
        },
    };
}

pub const QueryStorage = struct {
    alloc: *sphtud.alloc.Sphalloc,

    retry_count: u8,
    err: ?anyerror,

    host: []const u8,
    query_results: [ResolvConf.max_ns]?[][4]u8,
    idx: usize,
    sub_idx: usize,
    parent: *DnsImpl,
    start_id: u16,

    const IterRes = union(enum) {
        item: [4]u8,
        wait,
        finished,
    };

    pub fn next(self: *QueryStorage) !IterRes {
        if (self.err) |e| return e;

        while (true) {
            if (self.idx >= self.parent.resolv_conf.num_nameservers) {
                return .finished;
            }

            const ips = self.query_results[self.idx] orelse return .wait;

            if (self.sub_idx >= ips.len) {
                self.idx += 1;
                self.sub_idx = 0;
                continue;
            }

            const ip = ips[self.sub_idx];
            self.sub_idx += 1;
            return .{
                .item = ip,
            };
        }
    }

    fn deinit(self: QueryStorage) void {
        self.alloc.deinit();
    }
};

const dns_port = 53;

pub const ResolvConf = struct {
    nameservers: [max_ns]std.Io.net.IpAddress,
    num_nameservers: u8,

    pub fn parse(reader: *std.Io.Reader) !ResolvConf {
        var nameservers: [max_ns]std.Io.net.IpAddress = undefined;
        var num_nameservers: u8 = 0;

        while (true) {
            const line = try reader.takeDelimiter('\n') orelse break;
            const nameserver_key = "nameserver ";
            if (line.len > nameserver_key.len and std.mem.startsWith(u8, line, nameserver_key)) {
                nameservers[num_nameservers] = try .parse(line[nameserver_key.len..], dns_port);
                // Our DNS impl only sends/receives on an IPv4 socket
                if (nameservers[num_nameservers] == .ip6) continue;
                num_nameservers += 1;
            }
        }

        return .{
            .nameservers = nameservers,
            .num_nameservers = num_nameservers,
        };
    }

    const max_ns = 3;
};

test "resolv conf ignores ipv6" {
    const example =
        \\# Generated by NetworkManager
        \\search lan
        \\nameserver 192.168.1.1
        \\nameserver 2001:db8:95cb::1
        \\nameserver 192.168.254.1
    ;

    var r = std.Io.Reader.fixed(example);
    const resolv_conf = try ResolvConf.parse(&r);
    try std.testing.expectEqual(2, resolv_conf.num_nameservers);
    try std.testing.expectEqual(std.Io.net.IpAddress{
        .ip4 = .{ .bytes = .{ 192, 168, 1, 1 }, .port = 53 },
    }, resolv_conf.nameservers[0]);
    try std.testing.expectEqual(std.Io.net.IpAddress{
        .ip4 = .{ .bytes = .{ 192, 168, 254, 1 }, .port = 53 },
    }, resolv_conf.nameservers[1]);
}

pub const Hosts = struct {
    lookup: sphtud.util.hash_map.StringHashMap(std.Io.net.IpAddress),

    pub fn parse(arena: std.mem.Allocator, reader: *std.Io.Reader) !Hosts {
        var lookup = try sphtud.util.hash_map.StringHashMap(std.Io.net.IpAddress).init(
            arena,
            .linear(arena),
            8,
            // Surely no one has 2000 hosts entries, I have like 4
            2048,
        );

        while (true) {
            const line = try reader.takeDelimiter('\n') orelse break;

            var it = std.mem.splitAny(u8, line, &std.ascii.whitespace);
            const ip_s = it.next() orelse continue;
            const ip = std.Io.net.IpAddress.parse(ip_s, 0) catch continue;

            while (it.next()) |host| {
                try lookup.put(try arena.dupe(u8, host), ip);
            }
        }

        return .{
            .lookup = lookup,
        };
    }

    pub fn get(self: *Hosts, host: []const u8) ?std.Io.net.IpAddress {
        return self.lookup.get(host);
    }
};

const DnsHeader = struct {
    id: u16,
    qr: u1,
    opcode: u4,
    aa: u1,
    tc: u1,
    rd: u1,
    ra: u1,
    z: u3,
    rcode: u4,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    pub fn read(r: *std.Io.Reader) !DnsHeader {
        const id = try r.takeInt(u16, .big);

        const b2 = try r.takeByte();
        const qr: u1 = @truncate(b2 >> 7);
        const opcode: u4 = @truncate(b2 >> 3);
        const aa: u1 = @truncate(b2 >> 2);
        const tc: u1 = @truncate(b2 >> 1);
        const rd: u1 = @truncate(b2);

        const b3 = try r.takeByte();
        const ra: u1 = @truncate(b3 >> 7);
        const z: u3 = @truncate(b3 >> 4);
        const rcode: u1 = @truncate(b3);

        const qdcount = try r.takeInt(u16, .big);
        const ancount = try r.takeInt(u16, .big);
        const nscount = try r.takeInt(u16, .big);
        const arcount = try r.takeInt(u16, .big);

        return .{
            .id = id,
            .qr = qr,
            .opcode = opcode,
            .aa = aa,
            .tc = tc,
            .rd = rd,
            .ra = ra,
            .z = z,
            .rcode = rcode,
            .qdcount = qdcount,
            .ancount = ancount,
            .nscount = nscount,
            .arcount = arcount,
        };
    }
};

fn writeHeader(w: *std.Io.Writer, self: DnsHeader) !void {
    try w.writeInt(u16, self.id, .big);
    try w.writeByte(
        asu8(self.qr) << 7 | asu8(self.opcode) << 3 | asu8(self.aa) << 2 | asu8(self.tc) << 1 | self.rd,
    );
    try w.writeByte(
        asu8(self.ra) << 7 | asu8(self.z) << 4 | self.rcode,
    );
    try w.writeInt(u16, self.qdcount, .big);
    try w.writeInt(u16, self.ancount, .big);
    try w.writeInt(u16, self.nscount, .big);
    try w.writeInt(u16, self.arcount, .big);
}

fn asu8(in: anytype) u8 {
    return @intCast(in);
}

const QType = enum(u16) {
    a = 1,
};

const QClass = enum(u16) {
    in = 1,
};

fn writeQuestion(w: *std.Io.Writer, name: []const u8) !void {
    {
        var it = std.mem.splitScalar(u8, name, '.');
        while (it.next()) |section| {
            const len8 = std.math.cast(u8, section.len) orelse return error.InvalidHost;

            try w.writeByte(len8);
            try w.writeAll(section);
        }
        try w.writeByte(0);
    }

    try w.writeInt(u16, @intFromEnum(QType.a), .big);
    try w.writeInt(u16, @intFromEnum(QClass.in), .big);
}

fn writeDnsQuery(w: *std.Io.Writer, host: []const u8, id: u16) !void {
    const header = DnsHeader{
        .id = id,
        .qr = 0,
        .opcode = 0,
        .aa = 0,
        .tc = 0,
        .rd = 1,
        .ra = 0,
        .z = 0,
        .rcode = 0,
        .qdcount = 1,
        .ancount = 0,
        .arcount = 0,
        .nscount = 0,
    };

    try writeHeader(w, header);
    try writeQuestion(w, host);
}

fn discardQname(r: *std.Io.Reader) !void {
    while (true) {
        const len = try r.takeByte();
        if (len == 0) break;
        try r.discardAll(len);
    }
}

fn discardQuestions(r: *std.Io.Reader, qdcount: u16) !void {
    for (0..qdcount) |_| {
        try discardQname(r);
        try r.discardAll(4);
    }
}

fn parseName(full: []const u8, r: *std.Io.Reader, out: *std.ArrayList(u8)) !void {
    while (true) {
        const len = try r.takeByte();
        if (len == 0) break;

        if (len >> 6 == 0b11) {
            var offset: u16 = len & 0x3f;
            offset <<= 8;
            offset |= try r.takeByte();

            if (offset >= full.len) return error.InvalidOffset;

            var offs_r = std.Io.Reader.fixed(full[offset..]);
            try parseName(full, &offs_r, out);
            break;
        }

        try out.appendSliceBounded(try r.take(len));
        try out.appendBounded('.');
    }
}

const DnsRR = struct {
    name_buf: [256]u8,
    name_len: usize,
    typ: u16,
    class: u16,
    ttl: u32,
    rdlength: u16,
    rdata: []const u8,

    pub fn read(r: *std.Io.Reader) !DnsRR {
        std.debug.assert(r.vtable == std.Io.Reader.fixed(&.{}).vtable);

        var name_buf: [256]u8 = undefined;
        var name = std.ArrayList(u8).initBuffer(&name_buf);
        try parseName(r.buffer, r, &name);

        const typ = try r.takeInt(u16, .big);
        const class = try r.takeInt(u16, .big);
        const ttl = try r.takeInt(u32, .big);
        const rdlength = try r.takeInt(u16, .big);
        const rdata = try r.take(rdlength);

        return .{
            .name_buf = name_buf,
            .name_len = @intCast(name.items.len),
            .typ = typ,
            .class = class,
            .ttl = ttl,
            .rdlength = rdlength,
            .rdata = rdata,
        };
    }
};

const TestFixture = struct {
    tpa: sphtud.alloc.TinyPageAllocator,
    root: sphtud.alloc.Sphalloc,
    impl: DnsImpl,

    pub fn initPinned(self: *TestFixture) !void {
        try self.tpa.initPinned();
        try self.root.initPinned(self.tpa.allocator(), "test root");

        // Yoinked from my machine
        const resolv_conf_data =
            \\# Generated by resolvconf
            \\search lan
            \\nameserver 192.168.1.1
            \\nameserver 192.168.1.2
            \\options edns0
        ;

        var rc_reader = std.Io.Reader.fixed(resolv_conf_data);
        const resolv_conf = try ResolvConf.parse(&rc_reader);

        const hosts_data =
            \\192.168.1.1 something.lan something
            \\192.168.1.2 other.lan
        ;

        var hosts_reader = std.Io.Reader.fixed(hosts_data);
        const hosts = try Hosts.parse(self.root.arena(), &hosts_reader);

        self.impl = try .init(&self.root, resolv_conf, hosts, 100);
    }
};

fn makeFakeResponse(id: u16, buf: []u8) []const u8 {
    // Real response for www.google.com
    const data: []const u8 = &.{ 0, 0, 129, 128, 0, 1, 0, 8, 0, 0, 0, 0, 3, 119, 119, 119, 6, 103, 111, 111, 103, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 157, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 150, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 151, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 152, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 153, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 154, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 155, 119, 192, 12, 0, 1, 0, 1, 0, 0, 0, 118, 0, 4, 142, 251, 156, 119 };
    @memcpy(buf[0..data.len], data);
    std.mem.writeInt(u16, buf[0..2], id, .big);
    return buf[0..data.len];
}

test "query sanity" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    var query_action = try fixture.impl.makeQuery("www.google.com");

    var fake_response_buf: [4096]u8 = undefined;

    {
        const to_send = query_action.next() orelse return error.MissingAction;
        // Manually tested that this is a valid dns request
        const expected = &.{
            0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x03, 0x77, 0x77, 0x77,
            0x06, 0x67, 0x6F, 0x6F, 0x67, 0x6C, 0x65, 0x03,
            0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01,
        };
        try std.testing.expectEqualSlices(u8, expected, to_send.data);
    }

    {
        const to_send = query_action.next() orelse return error.MissingAction;
        // Same as above but with the ID changed
        const expected = &.{
            0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x03, 0x77, 0x77, 0x77,
            0x06, 0x67, 0x6F, 0x6F, 0x67, 0x6C, 0x65, 0x03,
            0x63, 0x6F, 0x6D, 0x00, 0x00, 0x01, 0x00, 0x01,
        };
        try std.testing.expectEqualSlices(u8, expected, to_send.data);
    }

    {
        const to_send = query_action.next();
        try std.testing.expect(to_send == null);
    }

    {
        const query = fixture.impl.get(query_action.handle);
        const response = makeFakeResponse(query.start_id, &fake_response_buf);
        const handle = try fixture.impl.onRecv(response) orelse return error.MissingHandle;

        try std.testing.expectEqual(handle, query_action.handle);

        const expected: []const [4]u8 = &.{
            .{ 142, 251, 157, 119 },
            .{ 142, 251, 150, 119 },
            .{ 142, 251, 151, 119 },
            .{ 142, 251, 152, 119 },
            .{ 142, 251, 153, 119 },
            .{ 142, 251, 154, 119 },
            .{ 142, 251, 155, 119 },
            .{ 142, 251, 156, 119 },
        };

        for (expected) |eip| {
            const next = try query.next();
            try std.testing.expect(next == .item);
            try std.testing.expectEqualSlices(u8, &eip, &next.item);
        }

        const next = try query.next();
        try std.testing.expect(next == .wait);
    }
}

test "pointer in pointer example" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    var query_action = try fixture.impl.makeQuery("api.tvmaze.com");

    // Drain events
    while (query_action.next()) |_| {}

    const handle = try fixture.impl.onRecv(&.{
        0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x03, 0x61, 0x70, 0x69,
        0x06, 0x74, 0x76, 0x6d, 0x61, 0x7a, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00, 0x00, 0x01, 0x00, 0x01,
        0xc0, 0x0c, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2c, 0x00, 0x08, 0x05, 0x65, 0x64, 0x67,
        0x65, 0x73, 0xc0, 0x10, 0xc0, 0x2c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2c, 0x00, 0x04,
        0x5e, 0x10, 0x6e, 0xc2,
    }) orelse unreachable;

    const query = fixture.impl.get(handle);
    _ = try query.next();
}

test "dns timeout failure" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    const action = try fixture.impl.makeQuery("www.google.com");
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), action.timeout);

    {
        const timeout_action = try fixture.impl.onTimeout(action.handle);
        try std.testing.expect(timeout_action == .retry);

        try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), timeout_action.retry.timeout);
    }

    {
        const timeout_action = try fixture.impl.onTimeout(action.handle);
        try std.testing.expect(timeout_action == .retry);

        try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), timeout_action.retry.timeout);
    }

    {
        const timeout_action = try fixture.impl.onTimeout(action.handle);
        try std.testing.expect(timeout_action == .finish);

        try std.testing.expectEqual(error.Timedout, fixture.impl.get(action.handle).err.?);
    }
}

test "dns timeout once" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    const action = try fixture.impl.makeQuery("www.google.com");
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), action.timeout);

    {
        const timeout_action = try fixture.impl.onTimeout(action.handle);
        try std.testing.expect(timeout_action == .retry);

        try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), timeout_action.retry.timeout);
    }

    {
        var fake_response_buf: [4096]u8 = undefined;
        const query = fixture.impl.get(action.handle);
        const response = makeFakeResponse(query.start_id, &fake_response_buf);
        const handle = try fixture.impl.onRecv(response) orelse return error.MissingHandle;
        try std.testing.expectEqual(handle, action.handle);
    }
}

fn testImmediate(fixture: *TestFixture, host: []const u8, expected: [4]u8) !void {
    var action = try fixture.impl.makeQuery(host);

    try std.testing.expectEqual(null, action.timeout);
    try std.testing.expectEqual(null, action.next());

    const query = fixture.impl.get(action.handle);
    try std.testing.expectEqual(QueryStorage.IterRes{ .item = expected }, try query.next());
    try std.testing.expectEqual(.finished, try query.next());
}

test "immediate" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    try testImmediate(&fixture, "192.168.1.1", .{ 192, 168, 1, 1 });
    try testImmediate(&fixture, "something", .{ 192, 168, 1, 1 });
    try testImmediate(&fixture, "something.lan", .{ 192, 168, 1, 1 });
    try testImmediate(&fixture, "other.lan", .{ 192, 168, 1, 2 });
}
