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

test "netutil: constants have their documented POSIX/Linux values" {
    try std.testing.expectEqual(@as(c_uint, 2), AF_INET);
    try std.testing.expectEqual(@as(c_int, 1), SOCK_STREAM);
    try std.testing.expectEqual(@as(c_int, 2), SHUT_RDWR);
    try std.testing.expectEqual(@as(c_int, 1), TCP_NODELAY);
}
