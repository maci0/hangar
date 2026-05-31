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
        // TCP: parse host:port
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

/// A bidirectional transport connection to the daemon.
pub const Connection = struct {
    proto: Proto,
    fd: c.fd_t = -1,
    host: [128]u8 = [_]u8{0} ** 128,
    host_len: usize = 0,

    /// Connect to a daemon at the given URL.
    pub fn connect(url: *const Url) ?Connection {
        var conn = Connection{ .proto = url.proto };
        conn.host_len = url.host_len;
        std.mem.copyForwards(u8, &conn.host, url.host[0..url.host_len]);
        conn.fd = switch (url.proto) {
            .unix => connectUnixFd(url),
            .tcp => connectTcpFd(url),
            .shm => connectShmFd(url),
        };
        if (conn.fd < 0) return null;
        return conn;
    }

    /// Send a request and read the response body.
    pub fn request(self: *Connection, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
        return switch (self.proto) {
            .tcp => httpRequest(self.fd, self.host[0..self.host_len], method, path, body, out),
            .unix, .shm => rawRequest(self.fd, method, path, body, out),
        };
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
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
    const hints: c.addrinfo = .{ .family = c.AF.INET, .socktype = c.SOCK.STREAM, .protocol = 0, .addrlen = 0, .addr = null, .canonname = null, .next = null, .flags = 0 };
    var res: ?*c.addrinfo = null;
    const host_z = std.fmt.bufPrintZ(&([_]u8{0} ** 128), "{s}", .{url.host[0..url.host_len]}) catch { _ = c.close(sock); return -1; };
    if (c.getaddrinfo(host_z, null, &hints, &res) != 0) { _ = c.close(sock); return -1; }
    defer if (res) |r| c.freeaddrinfo(r);
    const ai = res orelse { _ = c.close(sock); return -1; };
    const in_addr: *c.sockaddr.in = @ptrCast(@alignCast(ai.addr));
    in_addr.port = std.mem.nativeToBig(u16, url.port);
    if (c.connect(sock, ai.addr, ai.addrlen) != 0) { _ = c.close(sock); return -1; }
    return sock;
}

fn connectShmFd(_: *const Url) c.fd_t {
    // Shared memory: open a named region via shm_open
    // For now return a sentinel; full SHM IPC needs ring buffer protocol
    return -1;
}

fn httpRequest(fd: c.fd_t, host: []const u8, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
    var req_buf: [512]u8 = undefined;
    const body_len = if (body) |b| b.len else 0;
    const req = std.fmt.bufPrintZ(&req_buf, "{s} {s} HTTP/1.0\r\nHost: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, host, body_len }) catch return 0;
    _ = c.write(fd, req.ptr, req.len);
    if (body) |b| { _ = c.write(fd, b.ptr, b.len); }

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
    _ = c.write(fd, req.ptr, req.len);
    if (body) |b| { _ = c.write(fd, b.ptr, b.len); _ = c.write(fd, "\r\n", 2); }

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
