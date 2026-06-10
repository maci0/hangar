//! POSIX networking constants (not exposed by std.c in Zig 0.16) + small socket
//! helpers, shared by the listener setup, accept loop, WebSocket relays, and the
//! guest-agent client.

const std = @import("std");
const c = std.c;

pub const AF_INET: c_uint = 2;
pub const AF_INET6: c_uint = 10;
pub const AF_UNIX: c_uint = 1;
pub const SOCK_STREAM: c_int = 1;
pub const SOL_SOCKET: c_int = 1;
pub const SO_REUSEADDR: c_int = 2;
pub const SO_RCVTIMEO: c_int = 20;
pub const SO_SNDTIMEO: c_int = 21;
pub const SHUT_RDWR: c_int = 2;
pub const IPPROTO_IPV6: c_int = 41;
pub const IPV6_V6ONLY: c_int = 26;
pub const IPPROTO_TCP: c_int = 6;
pub const TCP_NODELAY: c_int = 1;

/// Disable Nagle on a TCP socket. Interactive VNC/SPICE relay traffic is
/// dominated by small mouse/keyboard packets; without this, Nagle coalescing
/// adds up to ~40ms of latency per input event. Best-effort — failure is
/// non-fatal (the relay still works, just with higher latency).
pub fn setTcpNoDelay(fd: c.fd_t) void {
    const one: c_int = 1;
    _ = c.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, @sizeOf(c_int));
}

/// True if some process is already listening on `port` at the IPv4 loopback —
/// detected by attempting a connection (a refused connect means the port is
/// free). Connect-probing (not bind-probing) is used deliberately: it mirrors
/// the VNC/SPICE relay path, needs no bind permission, and correctly spots an
/// external listener on a port QEMU would otherwise fail to bind. Best-effort: a
/// socket-creation failure reports "free" so the caller doesn't loop forever.
pub fn portInUse(port: u16) bool {
    const fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    // Bound the probe (200ms) so a filtered/slow port can never block power-on,
    // which runs under vms_mutex. Loopback refuse/accept is instant anyway.
    const tv: c.timeval = .{ .sec = 0, .usec = 200_000 };
    _ = c.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = c.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = @intCast(AF_INET);
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0;
}

test "netutil: portInUse — a listening port reads as in-use, a refused one free" {
    // Stand up a listener, confirm portInUse sees it; an un-listened port is free.
    const fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = @intCast(AF_INET);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));
    addr.port = 0; // OS-assigned ephemeral
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0 or c.listen(fd, 1) != 0) {
        _ = c.close(fd);
        return error.SkipZigTest; // sandbox forbids bind/listen
    }
    var bound: c.sockaddr.in = undefined;
    var blen: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&bound), &blen) != 0) {
        _ = c.close(fd);
        return error.SkipZigTest;
    }
    const port = std.mem.bigToNative(u16, bound.port);
    try std.testing.expect(portInUse(port)); // listener is up
    _ = c.close(fd);
    try std.testing.expect(!portInUse(port)); // gone → connect refused
}

test "netutil: constants have their documented POSIX/Linux values" {
    try std.testing.expectEqual(@as(c_uint, 2), AF_INET);
    try std.testing.expectEqual(@as(c_int, 1), SOCK_STREAM);
    try std.testing.expectEqual(@as(c_int, 2), SHUT_RDWR);
    try std.testing.expectEqual(@as(c_int, 1), TCP_NODELAY);
}
