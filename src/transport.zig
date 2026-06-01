// SPDX-License-Identifier: MIT
//! KVMGUI — Transport Abstraction Layer
//! Supports Unix sockets, TCP/HTTP, and shared memory for client↔daemon communication.
const std = @import("std");
const c = std.c;

/// Transport protocol variants.
pub const Proto = enum {
    unix,   // unix:///path/to/socket — AF_UNIX same-machine
    tcp,    // http://host:port — HTTP over TCP (local or remote)
    shm,    // shm:///name — POSIX shared memory (fastest same-machine)
};

/// Parsed connection URL.
pub const Url = struct {
    proto: Proto,
    host: [128]u8 = [_]u8{0} ** 128,
    host_len: usize = 0,
    port: u16 = 9080,
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,

    pub fn parse(s: []const u8) ?Url {
        var u = Url{ .proto = .tcp, .port = 9080 };
        var rest: []const u8 = s;

        if (std.mem.startsWith(u8, s, "unix://")) { u.proto = .unix; rest = s["unix://".len..]; }
        else if (std.mem.startsWith(u8, s, "shm://")) { u.proto = .shm; rest = s["shm://".len..]; }
        else if (std.mem.startsWith(u8, s, "http://")) { u.proto = .tcp; rest = s["http://".len..]; }
        else { u.proto = .tcp; }

        if (u.proto == .unix or u.proto == .shm) {
            u.path_len = @min(rest.len, u.path.len);
            std.mem.copyForwards(u8, &u.path, rest[0..u.path_len]);
            return u;
        }
        // TCP: parse host:port.  IPv6 addresses are wrapped in brackets: [::1]:9080.
        if (rest.len > 0 and rest[0] == '[') {
            if (std.mem.indexOfScalar(u8, rest, ']')) |rbracket| {
                const host_slice = rest[1..rbracket];
                u.host_len = @min(host_slice.len, u.host.len);
                std.mem.copyForwards(u8, &u.host, host_slice[0..u.host_len]);
                const after = rest[rbracket + 1 ..];
                if (after.len > 0 and after[0] == ':') {
                    const port_str = after[1..];
                    if (std.mem.indexOfScalar(u8, port_str, '/')) |slash| {
                        u.port = std.fmt.parseInt(u16, port_str[0..slash], 10) catch 9080;
                    } else {
                        u.port = std.fmt.parseInt(u16, port_str, 10) catch 9080;
                    }
                }
                return u;
            }
        }
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            u.host_len = @min(colon, u.host.len);
            std.mem.copyForwards(u8, &u.host, rest[0..u.host_len]);
            const port_str = rest[colon + 1 ..];
            if (std.mem.indexOfScalar(u8, port_str, '/')) |slash| {
                u.port = std.fmt.parseInt(u16, port_str[0..slash], 10) catch 9080;
            } else {
                u.port = std.fmt.parseInt(u16, port_str, 10) catch 9080;
            }
        } else {
            u.host_len = @min(rest.len, u.host.len);
            std.mem.copyForwards(u8, &u.host, rest[0..u.host_len]);
        }
        return u;
    }
};

/// Shared-memory channel layout (mmap'd region).
/// Single-producer single-consumer request/response protocol.
const ShmChannel = extern struct {
    /// Request: client writes data, sets len (release).
    req_len: u32 align(4) = 0,
    _pad1: [60]u8 = [_]u8{0} ** 60, // pad to cache line
    req_data: [4096]u8 = [_]u8{0} ** 4096,

    /// Response: server writes data, sets len (release).
    resp_len: u32 align(4) = 0,
    _pad2: [60]u8 = [_]u8{0} ** 60,
    resp_data: [4096]u8 = [_]u8{0} ** 4096,
};

/// A bidirectional transport connection to the daemon.
pub const Connection = struct {
    proto: Proto,
    fd: c.fd_t = -1,
    host: [128]u8 = [_]u8{0} ** 128,
    host_len: usize = 0,
    /// For SHM: pointer to the mapped shared memory channel.
    shm: ?*volatile ShmChannel = null,

    /// Connect to a daemon at the given URL.
    pub fn connect(url: *const Url) ?Connection {
        var conn = Connection{ .proto = url.proto };
        conn.host_len = url.host_len;
        std.mem.copyForwards(u8, &conn.host, url.host[0..url.host_len]);
        if (url.proto == .shm) {
            conn.shm = connectShm(url);
            if (conn.shm == null) return null;
            conn.fd = -1;
        } else {
            conn.fd = switch (url.proto) {
                .unix => connectUnixFd(url),
                .tcp => connectTcpFd(url),
                .shm => unreachable,
            };
            if (conn.fd < 0) return null;
        }
        return conn;
    }

    /// Send a request and read the response body.
    pub fn request(self: *Connection, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
        return switch (self.proto) {
            .tcp => httpRequest(self.fd, self.host[0..self.host_len], method, path, body, out),
            .unix => rawRequest(self.fd, method, path, body, out),
            .shm => shmRequest(self, method, path, body, out),
        };
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        if (self.shm) |shm| {
            _ = c.munmap(@ptrCast(@volatileCast(@alignCast(@constCast(shm)))), @sizeOf(ShmChannel));
            self.shm = null;
        }
        if (self.fd >= 0) { _ = c.close(self.fd); self.fd = -1; }
    }
};

fn connectUnixFd(url: *const Url) c.fd_t {
    const sock = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (sock < 0) return -1;
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    const path_bytes = url.path[0..url.path_len];
    @memcpy(addr.path[0..path_bytes.len], path_bytes);
    addr.path[path_bytes.len] = 0;
    const addrlen = @offsetOf(c.sockaddr.un, "path") + path_bytes.len + 1;
    if (c.connect(sock, @ptrCast(&addr), @intCast(addrlen)) != 0) { _ = c.close(sock); return -1; }
    return sock;
}

fn connectTcpFd(url: *const Url) c.fd_t {
    const sock = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (sock < 0) return -1;
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.INET;
    hints.socktype = c.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    var host_buf: [128]u8 = [_]u8{0} ** 128;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{url.host[0..url.host_len]}) catch { _ = c.close(sock); return -1; };
    if (@intFromEnum(c.getaddrinfo(host_z, null, &hints, &res)) != 0) { _ = c.close(sock); return -1; }
    defer if (res) |r| c.freeaddrinfo(r);
    const ai = res orelse { _ = c.close(sock); return -1; };
    const addr = ai.addr orelse { _ = c.close(sock); return -1; };
    const in_addr: *c.sockaddr.in = @ptrCast(@alignCast(addr));
    in_addr.port = std.mem.nativeToBig(u16, url.port);
    if (c.connect(sock, addr, ai.addrlen) != 0) { _ = c.close(sock); return -1; }
    return sock;
}

fn connectShm(url: *const Url) ?*volatile ShmChannel {
    // Open a named POSIX shared memory region.
    var shm_name_buf: [260]u8 = undefined;
    const name = std.fmt.bufPrintZ(&shm_name_buf, "/{s}", .{url.path[0..url.path_len]}) catch return null;
    const fd = c.shm_open(name, 2, 0o600);
    if (fd < 0) return null;
    // PROT_READ|PROT_WRITE = 3, MAP_SHARED = 1
    const prot: c.PROT = @bitCast(@as(u32, 3));
    const flags: c.MAP = @bitCast(@as(u32, 1));
    const ptr = c.mmap(null, @sizeOf(ShmChannel), prot, flags, fd, 0);
    _ = c.close(fd);
    if (ptr == @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))))) return null;
    return @ptrCast(@alignCast(ptr));
}

fn shmRequest(conn: *Connection, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
    const shm = conn.shm orelse return 0;

    // Build the raw request: "METHOD /path\r\n" + optional body.
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrintZ(&req_buf, "{s} /{s}\r\n", .{ method, path }) catch return 0;
    const req_total: usize = if (body) |b| req.len + b.len + 2 else req.len;
    if (req_total > shm.req_data.len) return 0;

    @memcpy(shm.req_data[0..req.len], req[0..req.len]);
    if (body) |b| {
        @memcpy(shm.req_data[req.len..][0..b.len], b);
        @memcpy(shm.req_data[req.len + b.len ..][0..2], "\r\n");
    }
    // Publish request length (release store so server sees the data).
    @atomicStore(u32, &shm.req_len, @intCast(req_total), .release);

    // Spin-wait for response (with bounded retries to avoid infinite hang).
    var retries: u32 = 1000;
    while (retries > 0) : (retries -= 1) {
        const resp_len = @atomicLoad(u32, &shm.resp_len, .acquire);
        if (resp_len > 0) {
            const n = @min(resp_len, @as(u32, @intCast(out.len)));
            @memcpy(out[0..n], shm.resp_data[0..n]);
            // Reset for next request.
            @atomicStore(u32, &shm.resp_len, 0, .release);
            @atomicStore(u32, &shm.req_len, 0, .release);
            return n;
        }
        // Busy-wait with a brief pause (nanosleep 1ms) — simpler than
        // pulling in eventfd, and adequate for same-machine SHM IPC.
        const ts = c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    // Timeout: reset request so server doesn't process stale data.
    @atomicStore(u32, &shm.req_len, 0, .release);
    return 0;
}

/// Write all bytes, looping until complete or error.
fn writeAll(fd: c.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn httpRequest(fd: c.fd_t, host: []const u8, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
    var req_buf: [512]u8 = undefined;
    const body_len = if (body) |b| b.len else 0;
    const req = std.fmt.bufPrintZ(&req_buf, "{s} {s} HTTP/1.0\r\nHost: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, host, body_len }) catch return 0;
    writeAll(fd, req.ptr[0..req.len]);
    if (body) |b| { writeAll(fd, b); }

    var total: usize = 0;
    while (total < out.len) {
        const n = c.read(fd, out[total..].ptr, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (std.mem.indexOf(u8, out[0..total], "\r\n\r\n")) |pos| {
        const body_start = pos + 4;
        const body_bytes = out[body_start..total];
        std.mem.copyForwards(u8, out, body_bytes);
        return body_bytes.len;
    }
    return total;
}

fn rawRequest(fd: c.fd_t, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
    // Simple line-based protocol for Unix/shared memory:
    // "METHOD /path\r\n" + optional body, then read response
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrintZ(&req_buf, "{s} /{s}\r\n", .{ method, path }) catch return 0;
    writeAll(fd, req.ptr[0..req.len]);
    if (body) |b| { writeAll(fd, b); writeAll(fd, "\r\n"); }

    var total: usize = 0;
    while (total < out.len) {
        const n = c.read(fd, out[total..].ptr, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

// ── Tests ───────────────────────────────────────────────────────────
test "Url parse: tcp" {
    const u = Url.parse("http://192.168.1.1:8080").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("192.168.1.1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
}

test "Url parse: unix" {
    const u = Url.parse("unix:///var/run/kvmgui.sock").?;
    try std.testing.expectEqual(Proto.unix, u.proto);
    try std.testing.expectEqualStrings("/var/run/kvmgui.sock", u.path[0..u.path_len]);
}

test "Url parse: shm" {
    const u = Url.parse("shm:///kvmgui").?;
    try std.testing.expectEqual(Proto.shm, u.proto);
    try std.testing.expectEqualStrings("/kvmgui", u.path[0..u.path_len]);
}

test "Url parse: no scheme defaults to tcp" {
    const u = Url.parse("192.168.1.1:9080").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("192.168.1.1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 9080), u.port);
}

test "Url parse: IPv6 with brackets" {
    const u = Url.parse("http://[::1]:9080").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("::1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 9080), u.port);
}

test "Url parse: IPv6 with brackets, default port" {
    const u = Url.parse("http://[fe80::1]").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("fe80::1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 9080), u.port);
}

test "Url parse: IPv6 with brackets, default port, trailing slash" {
    const u = Url.parse("http://[::1]:8080/api/").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("::1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
}

test "fuzz: Url.parse never panics on random inputs" {
    var prng = std.Random.DefaultPrng.init(0x7A0A5A0B);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        var buf: [256]u8 = undefined;
        const n = rnd.uintLessThan(usize, 256);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        if (Url.parse(buf[0..n])) |u| {
            // Invariants: the result must always be self-consistent.
            try std.testing.expect(u.proto == .tcp or u.proto == .unix or u.proto == .shm);
            try std.testing.expect(u.host_len <= u.host.len);
            try std.testing.expect(u.path_len <= u.path.len);
        }
    }
}
