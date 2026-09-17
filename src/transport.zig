// SPDX-License-Identifier: MIT
//! Hangar: Transport Abstraction Layer
//! Supports Unix sockets and TCP/HTTP for client↔daemon communication.
const std = @import("std");
const c = std.c;

/// Client socket I/O timeout (ms). Prevents a CLI command (vmrun/remote) from
/// hanging forever against a dead or wedged daemon that accepts the connection
/// but never replies.
const CLIENT_IO_TIMEOUT_MS = 15_000;

/// TCP/Unix connect() timeout (ms). SO_SNDTIMEO does not bound a blocking
/// connect(), so a dead host (dropped SYNs) would otherwise wedge the caller
/// for the OS default (~127s on Linux). Keep it well under CLIENT_IO_TIMEOUT_MS
/// so the connect phase fails fast.
const CONNECT_TIMEOUT_MS = 10_000;

// fcntl/O_NONBLOCK numeric constants (Linux). std.c.O is a packed struct in
// 0.16, so we use the raw values for the fcntl flag dance.
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0o4000;

/// Default TCP port, used when a URL omits or has an unparseable port.
/// Canonical value; `web_server` and `webui_app` reference it to stay in sync.
pub const DEFAULT_PORT: u16 = 9080;

pub fn configPort(value: ?[]const u8) error{InvalidPort}!u16 {
    const text = value orelse return DEFAULT_PORT;
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

/// Parse a port from a host:port tail, stopping at an optional trailing path.
/// Falls back to DEFAULT_PORT on a missing or invalid value.
fn parsePort(s: []const u8) u16 {
    const end = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
    return std.fmt.parseInt(u16, s[0..end], 10) catch DEFAULT_PORT;
}

/// Best-effort recv/send timeout on a client socket fd.
fn setFdTimeout(fd: c.fd_t, ms: u32) void {
    const tv: c.timeval = .{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
}

/// Connect `fd` to `addr` with a bounded wait. A blocking connect() ignores
/// SO_SNDTIMEO, so this switches the socket to non-blocking, issues the
/// connect, and waits with poll() up to `ms`, then restores blocking mode for
/// the subsequent read/write (which are bounded by setFdTimeout). Returns true
/// only on a fully established connection.
fn connectWithTimeout(fd: c.fd_t, addr: *const c.sockaddr, addrlen: c.socklen_t, ms: u31) bool {
    const flags = c.fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    _ = c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    defer _ = c.fcntl(fd, F_SETFL, flags); // restore original (blocking) mode

    if (c.connect(fd, addr, addrlen) == 0) return true;
    if (c._errno().* != @intFromEnum(c.E.INPROGRESS)) return false;

    var pfd = c.pollfd{ .fd = fd, .events = c.POLL.OUT, .revents = 0 };
    const pr = c.poll(@ptrCast(&pfd), 1, @intCast(ms));
    if (pr <= 0) return false; // 0 = timeout, <0 = poll error
    if (pfd.revents & c.POLL.OUT == 0) return false;

    // Writable can mean "connected" or "failed", SO_ERROR disambiguates.
    var so_err: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&so_err), &len) != 0) return false;
    return so_err == 0;
}

/// Transport protocol variants.
pub const Proto = enum {
    unix, // unix:///path/to/socket, AF_UNIX same-machine
    tcp, // http://host:port, HTTP over TCP (local or remote)
};

/// Parsed connection URL.
pub const Url = struct {
    proto: Proto,
    host: [128]u8 = [_]u8{0} ** 128,
    host_len: usize = 0,
    port: u16 = DEFAULT_PORT,
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,

    pub fn parse(s: []const u8) ?Url {
        var u = Url{ .proto = .tcp, .port = DEFAULT_PORT };
        var rest: []const u8 = s;

        if (std.mem.startsWith(u8, s, "unix://")) {
            u.proto = .unix;
            rest = s["unix://".len..];
        } else if (std.mem.startsWith(u8, s, "http://")) {
            u.proto = .tcp;
            rest = s["http://".len..];
        } else if (std.mem.indexOf(u8, s, "://") != null) {
            // A scheme separator is present but matched none of the supported
            // schemes (e.g. https://, ftp://, a typo). Reject so the caller can
            // surface a clear "invalid server URL" diagnostic instead of silently
            // treating the whole string as a TCP hostname and failing to connect.
            return null;
        } else {
            // No scheme at all: treat as a bare host[:port] over TCP.
            u.proto = .tcp;
        }

        if (u.proto == .unix) {
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
                    u.port = parsePort(after[1..]);
                }
                return u;
            }
        }
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            u.host_len = @min(colon, u.host.len);
            std.mem.copyForwards(u8, &u.host, rest[0..u.host_len]);
            u.port = parsePort(rest[colon + 1 ..]);
        } else {
            u.host_len = @min(rest.len, u.host.len);
            std.mem.copyForwards(u8, &u.host, rest[0..u.host_len]);
        }
        return u;
    }
};

/// Parse the Content-Length header value from an HTTP header block (bytes
/// before the body). Case-insensitive header name. Null if absent/unparseable.
fn parseContentLength(headers: []const u8) ?usize {
    var line_start: usize = 0;
    while (line_start < headers.len) {
        const nl = std.mem.indexOfScalar(u8, headers[line_start..], '\n') orelse break;
        const line = std.mem.trim(u8, headers[line_start .. line_start + nl], " \r\t");
        line_start += nl + 1;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
        }
    }
    return null;
}

pub const Connection = struct {
    proto: Proto,
    fd: c.fd_t = -1,
    host: [128]u8 = [_]u8{0} ** 128,
    host_len: usize = 0,
    /// The parsed URL, retained so each request can redial: the daemon answers
    /// with `Connection: close`, so a socket is single-use. A CLI command that
    /// issues more than one request (e.g. resolve-name then act) must open a
    /// fresh socket per request or the second one writes to a closed peer.
    url: Url = .{ .proto = .tcp },

    /// Connect to a daemon at the given URL. The returned connection holds a
    /// live socket for the first request; subsequent requests redial.
    pub fn connect(url: *const Url) ?Connection {
        var conn = Connection{ .proto = url.proto, .url = url.* };
        conn.host_len = url.host_len;
        std.mem.copyForwards(u8, &conn.host, url.host[0..url.host_len]);
        conn.fd = dial(&conn.url);
        if (conn.fd < 0) return null;
        return conn;
    }

    fn dial(url: *const Url) c.fd_t {
        return switch (url.proto) {
            .unix => connectUnixFd(url),
            .tcp => connectTcpFd(url),
        };
    }

    /// Send a request and read the response body. Uses the socket from connect()
    /// for the first call, then redials a fresh socket for each subsequent call
    /// (the daemon closes the connection after every response). The socket is
    /// closed after the exchange so the next call always starts clean.
    pub fn request(self: *Connection, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
        if (self.fd < 0) {
            self.fd = dial(&self.url);
            if (self.fd < 0) return 0;
        }
        defer {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        return switch (self.proto) {
            .tcp => httpRequest(self.fd, self.host[0..self.host_len], method, path, body, out),
            // The daemon accepts Unix-socket connections through the same HTTP
            // accept loop as TCP, so a Unix client must speak real HTTP (Host +
            // X-API-Key + CRLFCRLF). Reuse httpRequest with a loopback Host that
            // hostHeaderOk accepts; the previous bespoke "METHOD /path" framing
            // produced "//api/..." with no headers and the server rejected it.
            .unix => httpRequest(self.fd, "localhost", method, path, body, out),
        };
    }

    /// Send a request and stream the response BODY straight to `out_fd` (for
    /// binary downloads like OVA export, where the body far exceeds any
    /// reasonable in-memory buffer). Parses the status line and Content-Length
    /// from the header block; reads exactly that many body bytes from the
    /// socket and writes them to out_fd. Returns the number of body bytes
    /// written, or an error. The whole-body-in-RAM `request()` path silently
    /// truncated large downloads at its caller's buffer size.
    pub fn requestToFd(self: *Connection, method: []const u8, path: []const u8, body: ?[]const u8, out_fd: c.fd_t) !usize {
        if (self.fd < 0) {
            self.fd = dial(&self.url);
            if (self.fd < 0) return error.ConnectFailed;
        }
        defer {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        var req_buf: [512]u8 = undefined;
        const body_len = if (body) |b| b.len else 0;
        const host = if (self.proto == .unix) "localhost" else self.host[0..self.host_len];
        const req = buildHttpRequest(&req_buf, method, path, host, try apiKey(), body_len) orelse return error.BuildFailed;
        try writeAll(self.fd, req.ptr[0..req.len]);
        if (body) |b| try writeAll(self.fd, b);

        // Read until we have the full header block (ends with CRLFCRLF).
        var hbuf: [8192]u8 = undefined;
        var hlen: usize = 0;
        var hdr_end: ?usize = null;
        while (hlen < hbuf.len) {
            const n = c.read(self.fd, hbuf[hlen..].ptr, hbuf.len - hlen);
            if (n <= 0) break;
            hlen += @intCast(n);
            if (std.mem.indexOf(u8, hbuf[0..hlen], "\r\n\r\n")) |pos| {
                hdr_end = pos + 4;
                break;
            }
        }
        const he = hdr_end orelse return error.NoHeaders;
        const headers = hbuf[0..he];
        // Status line: "HTTP/1.x NNN ..."
        const sp = std.mem.indexOfScalar(u8, headers, ' ') orelse return error.BadStatus;
        const code = std.fmt.parseInt(u16, headers[sp + 1 .. sp + 4], 10) catch return error.BadStatus;
        if (code >= 400) return error.HttpError;
        const clen = parseContentLength(headers) orelse return error.NoContentLength;

        // The bytes already read past the header are the start of the body.
        var written: usize = 0;
        const first = hbuf[he..hlen];
        if (first.len > 0) {
            try writeAll(out_fd, first);
            written += first.len;
        }
        var rbuf: [64 * 1024]u8 = undefined;
        while (written < clen) {
            const want = @min(rbuf.len, clen - written);
            const n = c.read(self.fd, &rbuf, want);
            if (n <= 0) break;
            try writeAll(out_fd, rbuf[0..@intCast(n)]);
            written += @intCast(n);
        }
        if (written < clen) return error.Truncated;
        return written;
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

fn connectUnixFd(url: *const Url) c.fd_t {
    const sock = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (sock < 0) return -1;
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    const path_bytes = url.path[0..url.path_len];
    // sun_path is 108 bytes; url.path can be longer. Reject rather than overflow
    // the fixed sockaddr field (the usock wrapper has this guard; this path
    // drifted from it). +1 for the NUL terminator.
    if (path_bytes.len + 1 > addr.path.len) return -1;
    @memcpy(addr.path[0..path_bytes.len], path_bytes);
    addr.path[path_bytes.len] = 0;
    const addrlen = @offsetOf(c.sockaddr.un, "path") + path_bytes.len + 1;
    setFdTimeout(sock, CLIENT_IO_TIMEOUT_MS);
    if (!connectWithTimeout(sock, @ptrCast(&addr), @intCast(addrlen), CONNECT_TIMEOUT_MS)) {
        _ = c.close(sock);
        return -1;
    }
    return sock;
}

fn connectTcpFd(url: *const Url) c.fd_t {
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.UNSPEC;
    hints.socktype = c.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    var host_buf: [128]u8 = [_]u8{0} ** 128;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{url.host[0..url.host_len]}) catch return -1;
    if (@intFromEnum(c.getaddrinfo(host_z, null, &hints, &res)) != 0) return -1;
    defer if (res) |r| c.freeaddrinfo(r);

    return connectChain(res, url.port);
}

/// Walk a getaddrinfo result chain and return the first address that connects.
/// Every address is tried, not just the first: a dual-stack name (e.g.
/// "localhost") commonly resolves to ::1 ahead of 127.0.0.1, and a daemon bound
/// to only one of them refuses the other. Returns -1 if none connect.
fn connectChain(first: ?*c.addrinfo, port: u16) c.fd_t {
    var next = first;
    while (next) |ai| : (next = ai.next) {
        const fd = connectResolved(ai, port);
        if (fd >= 0) return fd;
    }
    return -1;
}

/// Connect to one resolved address, overriding its port with `port`.
/// Returns the connected fd, or -1 if this address is unusable.
fn connectResolved(ai: *c.addrinfo, port: u16) c.fd_t {
    const ai_addr = ai.addr orelse return -1;

    // Copy the resolved sockaddr into a local union so we can set the port.
    // sockaddr_storage is large enough for any address family (>=128 bytes).
    const SockAddrUnion = extern union {
        in: c.sockaddr.in,
        in6: c.sockaddr.in6,
        raw: [128]u8,
    };
    var addr: SockAddrUnion = .{ .raw = [_]u8{0} ** 128 };
    if (ai.addrlen > 128) return -1;
    // Copy through a byte pointer, not asBytes(ai_addr): `c.sockaddr` is the
    // 16-byte generic struct, while ai.addrlen is the real length of what
    // getaddrinfo allocated (28 for sockaddr_in6), so slicing asBytes would
    // read past the end.
    const src: [*]const u8 = @ptrCast(ai_addr);
    @memcpy(addr.raw[0..ai.addrlen], src[0..ai.addrlen]);

    // Set port on the copy.  Both sockaddr_in and sockaddr_in6 store the
    // port as a big-endian u16 at the same offset (2).
    if (ai.family == c.AF.INET) {
        addr.in.port = std.mem.nativeToBig(u16, port);
    } else if (ai.family == c.AF.INET6) {
        addr.in6.port = std.mem.nativeToBig(u16, port);
    } else return -1;

    const sock = c.socket(@intCast(ai.family), c.SOCK.STREAM, 0);
    if (sock < 0) return -1;

    setFdTimeout(sock, CLIENT_IO_TIMEOUT_MS);
    if (!connectWithTimeout(sock, @ptrCast(&addr), ai.addrlen, CONNECT_TIMEOUT_MS)) {
        _ = c.close(sock);
        return -1;
    }
    return sock;
}

/// Write all bytes, looping until complete or error.
fn writeAll(fd: c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// The built-in API key the daemon accepts when no custom `KV_API_KEY` is set.
/// Canonical value; `web_server.API_KEY` references it so the client default and
/// the daemon default cannot silently drift apart (a divergence would 401 every
/// authenticated request in loopback mode with no test catching it).
pub const DEFAULT_API_KEY = "hangar";

/// Validate a `KV_API_KEY` value: 1-64 bytes of printable ASCII (no control
/// chars, no spaces). Canonical home for the rule; `auth` re-exports it so the
/// HTTP client (`apiKey` below) and the daemon (`auth`/`web_server`) share one
/// definition and cannot silently drift apart. Rejecting whitespace/control
/// bytes fails fast on the common `export KV_API_KEY=$(cat keyfile)` newline.
pub fn validApiKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |ch| {
        if (ch <= 0x20 or ch >= 0x7f) return false;
    }
    return true;
}

pub fn apiKey() error{InvalidApiKey}![]const u8 {
    const span = @import("appio.zig").getenv("KV_API_KEY") orelse return DEFAULT_API_KEY;
    if (!validApiKey(span)) return error.InvalidApiKey;
    return span;
}

/// Build the HTTP/1.0 request line and headers (no body) into `buf`. Split out
/// of `httpRequest` so the exact header set, crucially the `X-API-Key` the
/// daemon requires on every state-changing endpoint, is unit-testable without
/// a live socket. Returns null if `buf` is too small.
fn buildHttpRequest(buf: []u8, method: []const u8, path: []const u8, host: []const u8, key: []const u8, body_len: usize) ?[:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s} {s} HTTP/1.0\r\nHost: {s}\r\nX-API-Key: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, host, key, body_len }) catch null;
}

fn httpRequest(fd: c.fd_t, host: []const u8, method: []const u8, path: []const u8, body: ?[]const u8, out: []u8) usize {
    var req_buf: [512]u8 = undefined;
    const body_len = if (body) |b| b.len else 0;
    // Send the X-API-Key on every request. The daemon enforces auth on all
    // state-changing endpoints (start/stop/delete/snapshot/...), so without
    // this header every write command from vmrun/remote got a 401 over TCP.
    const key = apiKey() catch return 0;
    const req = buildHttpRequest(&req_buf, method, path, host, key, body_len) orelse return 0;
    writeAll(fd, req.ptr[0..req.len]) catch return 0;
    if (body) |b| {
        writeAll(fd, b) catch return 0;
    }

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

// ── Tests ───────────────────────────────────────────────────────────
test "configPort: only an absent value uses the default" {
    try std.testing.expectEqual(DEFAULT_PORT, try configPort(null));
    try std.testing.expectEqual(@as(u16, 1), try configPort("1"));
    try std.testing.expectEqual(@as(u16, 65535), try configPort("65535"));
    for ([_][]const u8{ "", "0", "65536", "-1", "garbage", " 9080", "9080\n" }) |value| {
        try std.testing.expectError(error.InvalidPort, configPort(value));
    }
}

test "fuzz: configPort accepts only nonzero u16 values" {
    var prng = std.Random.DefaultPrng.init(0xC0F19047);
    const rnd = prng.random();
    var buf: [32]u8 = undefined;
    for (0..4000) |_| {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        const port = configPort(buf[0..len]) catch |err| {
            try std.testing.expectEqual(error.InvalidPort, err);
            continue;
        };
        try std.testing.expect(port != 0);
        try std.testing.expectEqual(port, try std.fmt.parseInt(u16, buf[0..len], 10));
    }
}

test "Connection.requestToFd propagates output write failure and closes connection" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var conn = Connection{ .proto = .unix, .fd = fds[0] };
    defer conn.close();
    setFdTimeout(conn.fd, CLIENT_IO_TIMEOUT_MS);
    const response = "HTTP/1.0 200 OK\r\nContent-Length: 7\r\n\r\narchive";
    try std.testing.expectEqual(@as(isize, response.len), c.write(fds[1], response.ptr, response.len));
    const out_fd = c.open("/dev/full", .{ .ACCMODE = .WRONLY });
    try std.testing.expect(out_fd >= 0);
    defer _ = c.close(out_fd);

    try std.testing.expectError(error.WriteFailed, conn.requestToFd("POST", "/api/vms/0/export", null, out_fd));
    try std.testing.expectEqual(@as(c.fd_t, -1), conn.fd);
}

test "transport: parseContentLength is case-insensitive and bounded" {
    try std.testing.expectEqual(@as(?usize, 1234), parseContentLength("HTTP/1.0 200 OK\r\nContent-Length: 1234\r\n\r\n"));
    try std.testing.expectEqual(@as(?usize, 1234), parseContentLength("HTTP/1.0 200 OK\r\ncontent-length:1234\r\n\r\n")); // no space, lowercase
    try std.testing.expectEqual(@as(?usize, 0), parseContentLength("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n")); // absent
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("HTTP/1.0 200 OK\r\nContent-Length: notanumber\r\n\r\n"));
    // A header NAME containing the token must not false-match.
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("HTTP/1.0 200 OK\r\nX-Content-Length-Hint: 9\r\n\r\n"));
}

test "fuzz: parseContentLength never panics on random header bytes" {
    var prng = std.Random.DefaultPrng.init(0xC0_1E_0001);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = parseContentLength(buf[0..len]);
    }
}

test "Url parse: tcp" {
    const u = Url.parse("http://192.168.1.1:8080").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("192.168.1.1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
}

test "Url parse: unix" {
    const u = Url.parse("unix:///var/run/hangar.sock").?;
    try std.testing.expectEqual(Proto.unix, u.proto);
    try std.testing.expectEqualStrings("/var/run/hangar.sock", u.path[0..u.path_len]);
}

test "Url parse: unsupported scheme rejected" {
    // shm:// was removed (it was never served); a leftover shm:// URL must be
    // rejected like any other unknown scheme, not silently treated as TCP.
    try std.testing.expect(Url.parse("shm:///hangar") == null);
}

test "Url parse: no scheme defaults to tcp" {
    const u = Url.parse("192.168.1.1:9080").?;
    try std.testing.expectEqual(Proto.tcp, u.proto);
    try std.testing.expectEqualStrings("192.168.1.1", u.host[0..u.host_len]);
    try std.testing.expectEqual(@as(u16, 9080), u.port);
}

test "Url parse: unknown scheme is rejected" {
    // A scheme separator with an unsupported scheme must fail rather than being
    // silently reinterpreted as a TCP hostname.
    try std.testing.expect(Url.parse("https://host:9080") == null);
    try std.testing.expect(Url.parse("ftp://host") == null);
    try std.testing.expect(Url.parse("tcp://host:1") == null);
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

test "Connection.close: clears fd and sets to -1" {
    const sock = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    try std.testing.expect(sock >= 0);

    var conn = Connection{ .proto = .unix, .fd = sock };
    try std.testing.expect(conn.fd >= 0);

    conn.close();
    try std.testing.expectEqual(@as(c.fd_t, -1), conn.fd);
}

test "Connection.close: no-op when fd already -1" {
    var conn = Connection{ .proto = .unix, .fd = -1 };
    conn.close();
    try std.testing.expectEqual(@as(c.fd_t, -1), conn.fd);
}

test "Connection.close: no-op when fd is -1" {
    var conn = Connection{ .proto = .unix, .fd = -1 };
    conn.close();
    try std.testing.expectEqual(@as(c.fd_t, -1), conn.fd);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

test "buildHttpRequest: includes X-API-Key and core headers" {
    var buf: [512]u8 = undefined;
    const req = buildHttpRequest(&buf, "POST", "/api/vms/0/power", "127.0.0.1:9080", "secret", 0).?;
    try std.testing.expect(std.mem.startsWith(u8, req, "POST /api/vms/0/power HTTP/1.0\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, req, "\r\nX-API-Key: secret\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\r\nHost: 127.0.0.1:9080\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\r\nContent-Length: 0\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "buildHttpRequest: returns null when buffer too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(buildHttpRequest(&buf, "POST", "/api/vms/0/power", "host", "key", 0) == null);
}

test "apiKey: default when unset, honors custom, rejects invalid" {
    const saved = std.c.getenv("KV_API_KEY");
    defer {
        if (saved) |v| _ = setenv("KV_API_KEY", v, 1) else _ = unsetenv("KV_API_KEY");
    }

    _ = unsetenv("KV_API_KEY");
    try std.testing.expectEqualStrings(DEFAULT_API_KEY, try apiKey());

    _ = setenv("KV_API_KEY", "custom-secret", 1);
    try std.testing.expectEqualStrings("custom-secret", try apiKey());

    _ = setenv("KV_API_KEY", "", 1);
    try std.testing.expectError(error.InvalidApiKey, apiKey());

    var long: [80]u8 = undefined;
    @memset(&long, 'x');
    long[79] = 0;
    _ = setenv("KV_API_KEY", @ptrCast(&long), 1);
    try std.testing.expectError(error.InvalidApiKey, apiKey());

    for ([_][*:0]const u8{ "secret\n", "two words", "sécret" }) |value| {
        _ = setenv("KV_API_KEY", value, 1);
        try std.testing.expectError(error.InvalidApiKey, apiKey());
    }
    _ = unsetenv("KV_API_KEY");
}

test "invalid API key sends no request through either response path" {
    const saved = std.c.getenv("KV_API_KEY");
    defer {
        if (saved) |v| _ = setenv("KV_API_KEY", v, 1) else _ = unsetenv("KV_API_KEY");
    }
    try std.testing.expectEqual(@as(c_int, 0), setenv("KV_API_KEY", "", 1));

    for ([_]bool{ false, true }) |streaming| {
        var fds: [2]c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var conn = Connection{ .proto = .unix, .fd = fds[0] };
        defer conn.close();
        setFdTimeout(conn.fd, CLIENT_IO_TIMEOUT_MS);
        setFdTimeout(fds[1], CLIENT_IO_TIMEOUT_MS);
        const response = "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n";
        try writeAll(fds[1], response);
        var buf: [128]u8 = undefined;
        if (streaming) {
            try std.testing.expectError(error.InvalidApiKey, conn.requestToFd("POST", "/api/vms/0/export", null, -1));
        } else {
            try std.testing.expectEqual(@as(usize, 0), conn.request("POST", "/api/vms/0/start", null, &buf));
        }
        try std.testing.expectEqual(@as(c.fd_t, -1), conn.fd);
        try std.testing.expect(c.read(fds[1], &buf, buf.len) <= 0);
    }
}

test "fuzz: apiKey never substitutes the default for invalid values" {
    const saved = std.c.getenv("KV_API_KEY");
    defer {
        if (saved) |v| _ = setenv("KV_API_KEY", v, 1) else _ = unsetenv("KV_API_KEY");
    }
    var prng = std.Random.DefaultPrng.init(0xA91CE7);
    const rnd = prng.random();
    var buf: [81]u8 = undefined;
    for (0..1000) |_| {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*byte| byte.* = rnd.intRangeAtMost(u8, 1, 255);
        buf[len] = 0;
        try std.testing.expectEqual(@as(c_int, 0), setenv("KV_API_KEY", buf[0..len :0].ptr, 1));
        if (validApiKey(buf[0..len])) {
            try std.testing.expectEqualStrings(buf[0..len], try apiKey());
        } else {
            try std.testing.expectError(error.InvalidApiKey, apiKey());
        }
    }
}

test "fuzz: buildHttpRequest never panics on random inputs" {
    var prng = std.Random.DefaultPrng.init(0x7A11_5C0DE);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var src: [256]u8 = undefined;
    const methods = [_][]const u8{ "GET", "POST" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const plen = rnd.uintLessThan(usize, 80);
        const hlen = rnd.uintLessThan(usize, 80);
        const klen = rnd.uintLessThan(usize, 64);
        rnd.bytes(src[0 .. plen + hlen + klen]);
        const path = src[0..plen];
        const host = src[plen .. plen + hlen];
        const key = src[plen + hlen .. plen + hlen + klen];
        const m = methods[rnd.uintLessThan(usize, methods.len)];
        if (buildHttpRequest(&buf, m, path, host, key, rnd.int(u16))) |req| {
            try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
        }
    }
}

test "Connection.connect + request: TCP round-trip via localhost" {
    // Create a listening TCP socket on an OS-assigned port.
    const lfd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (lfd < 0) return error.SkipZigTest;
    defer _ = c.close(lfd);

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = c.AF.INET;
    addr.addr = std.mem.nativeToBig(u32, 0x7F_00_00_01); // 127.0.0.1
    addr.port = 0; // OS-assigned port
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.SkipZigTest;
    if (c.listen(lfd, 1) != 0) return error.SkipZigTest;

    // Get the assigned port.
    var addrlen: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(lfd, @ptrCast(&addr), &addrlen);
    const port = std.mem.bigToNative(u16, addr.port);
    try std.testing.expect(port > 0);

    // Background thread: accept one connection, serve an HTTP response.
    const ServerCtx = struct {
        lfd: c.fd_t,
        fn run(ctx: @This()) void {
            const cfd = c.accept(ctx.lfd, null, null);
            if (cfd < 0) return;
            defer _ = c.close(cfd);
            const resp = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}";
            _ = c.write(cfd, resp, resp.len);
        }
    };
    const server = ServerCtx{ .lfd = lfd };
    const th = try std.Thread.spawn(std.Thread.SpawnConfig{}, ServerCtx.run, .{server});

    // Connect and send a request.
    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "http://127.0.0.1:{d}", .{port});
    const url = Url.parse(host) orelse return error.ParseFailed;
    var conn = Connection.connect(&url) orelse return error.ConnectFailed;
    defer conn.close();

    var resp: [256]u8 = undefined;
    const n = conn.request("GET", "/api/status", null, &resp);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "{\"ok\":true}") != null);

    th.join();
}

test "Connection.request redials for a second request (Connection: close)" {
    // The daemon answers with Connection: close, so each request needs a fresh
    // socket. A resolve-then-act CLI command issues 2+ requests on one
    // Connection; this guards that the second one redials instead of writing to
    // the closed first socket. The mock server therefore accepts TWICE.
    const lfd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (lfd < 0) return error.SkipZigTest;
    defer _ = c.close(lfd);
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = c.AF.INET;
    addr.addr = std.mem.nativeToBig(u32, 0x7F_00_00_01);
    addr.port = 0;
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return error.SkipZigTest;
    if (c.listen(lfd, 4) != 0) return error.SkipZigTest;
    setFdTimeout(lfd, CLIENT_IO_TIMEOUT_MS);
    var addrlen: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(lfd, @ptrCast(&addr), &addrlen);
    const port = std.mem.bigToNative(u16, addr.port);

    const ServerCtx = struct {
        lfd: c.fd_t,
        fn run(ctx: @This()) void {
            // Serve exactly two one-shot HTTP responses, then stop.
            const bodies = [_][]const u8{ "{\"first\":1}", "{\"second\":2}" };
            const request_lines = [_][]const u8{ "GET /api/vms HTTP/1.0\r\n", "GET /api/vms/0 HTTP/1.0\r\n" };
            var i: usize = 0;
            while (i < 2) : (i += 1) {
                const cfd = c.accept(ctx.lfd, null, null);
                if (cfd < 0) return;
                defer _ = c.close(cfd);
                setFdTimeout(cfd, CLIENT_IO_TIMEOUT_MS);
                var dump: [512]u8 = undefined;
                var used: usize = 0;
                while (std.mem.indexOf(u8, dump[0..used], "\r\n\r\n") == null) {
                    if (used == dump.len) return;
                    const n = c.read(cfd, dump[used..].ptr, dump.len - used);
                    if (n <= 0) return;
                    used += @intCast(n);
                }
                if (!std.mem.startsWith(u8, dump[0..used], request_lines[i])) return;
                const resp = std.fmt.bufPrint(&dump, "HTTP/1.0 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ bodies[i].len, bodies[i] }) catch return;
                writeAll(cfd, resp) catch return;
            }
        }
    };
    const th = try std.Thread.spawn(std.Thread.SpawnConfig{}, ServerCtx.run, .{ServerCtx{ .lfd = lfd }});
    defer {
        _ = c.shutdown(lfd, 2);
        th.join();
    }

    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "http://127.0.0.1:{d}", .{port});
    const url = Url.parse(host) orelse return error.ParseFailed;
    var conn = Connection.connect(&url) orelse return error.ConnectFailed;
    defer conn.close();

    var resp: [256]u8 = undefined;
    const n1 = conn.request("GET", "/api/vms", null, &resp);
    try std.testing.expectEqualStrings("{\"first\":1}", resp[0..n1]);
    // Second request on the same Connection must succeed by redialing.
    const n2 = conn.request("GET", "/api/vms/0", null, &resp);
    try std.testing.expectEqualStrings("{\"second\":2}", resp[0..n2]);
}

test "Connection.request over Unix sends valid HTTP (regression: no //api framing)" {
    // The daemon serves Unix-socket clients through the same HTTP accept loop as
    // TCP, so a Unix request must be real HTTP with Host + X-API-Key. A prior
    // bug emitted "METHOD /<path>" (yielding "//api/...", no headers), which the
    // server rejected, this guards the request the client actually sends.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-transport-utest-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    const lfd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (lfd < 0) return error.SkipZigTest;
    defer {
        _ = c.close(lfd);
        _ = c.unlink(path.ptr);
    }
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen = @offsetOf(c.sockaddr.un, "path") + path.len + 1;
    if (c.bind(lfd, @ptrCast(&addr), @intCast(addrlen)) != 0) return error.SkipZigTest;
    if (c.listen(lfd, 1) != 0) return error.SkipZigTest;

    const ServerCtx = struct {
        lfd: c.fd_t,
        req: *[512]u8,
        req_len: *usize,
        fn run(ctx: @This()) void {
            const cfd = c.accept(ctx.lfd, null, null);
            if (cfd < 0) return;
            defer _ = c.close(cfd);
            setFdTimeout(cfd, CLIENT_IO_TIMEOUT_MS);
            while (ctx.req_len.* < ctx.req.len) {
                const m = c.read(cfd, ctx.req[ctx.req_len.*..].ptr, ctx.req.len - ctx.req_len.*);
                if (m <= 0) return;
                ctx.req_len.* += @intCast(m);
                const request = ctx.req[0..ctx.req_len.*];
                if (std.mem.indexOf(u8, request, "\r\n\r\n")) |end| {
                    const body_len = parseContentLength(request[0 .. end + 4]) orelse return;
                    if (request.len - end - 4 >= body_len) break;
                }
            }
            const resp = "HTTP/1.0 200 OK\r\n\r\n{\"ok\":true}";
            _ = c.write(cfd, resp, resp.len);
        }
    };
    var reqbuf: [512]u8 = undefined;
    var reqlen: usize = 0;
    const server = ServerCtx{ .lfd = lfd, .req = &reqbuf, .req_len = &reqlen };
    const th = try std.Thread.spawn(std.Thread.SpawnConfig{}, ServerCtx.run, .{server});

    var url_buf: [64]u8 = undefined;
    const urlstr = try std.fmt.bufPrint(&url_buf, "unix://{s}", .{path});
    const url = Url.parse(urlstr) orelse return error.ParseFailed;
    var conn = Connection.connect(&url) orelse return error.ConnectFailed;
    defer conn.close();

    var resp: [256]u8 = undefined;
    const n = conn.request("POST", "/api/vms/0/power", "x=1", &resp);
    th.join();

    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "{\"ok\":true}") != null);

    const sent = reqbuf[0..reqlen];
    try std.testing.expect(std.mem.startsWith(u8, sent, "POST /api/vms/0/power HTTP/1.0\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, sent, "\r\nHost: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\r\nX-API-Key: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "//api/") == null);
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
            try std.testing.expect(u.proto == .tcp or u.proto == .unix);
            try std.testing.expect(u.host_len <= u.host.len);
            try std.testing.expect(u.path_len <= u.path.len);
        }
    }
}

test "transport: connectTcpFd dials an IPv6 listener (sockaddr_in6 is 28 bytes)" {
    // Regression: the resolved sockaddr was copied through asBytes() on the
    // 16-byte generic `c.sockaddr`, so any AF_INET6 result (addrlen 28) read
    // out of bounds and panicked before a connection was ever attempted.
    const fd = c.socket(c.AF.INET6, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    defer _ = c.close(fd);
    var addr: c.sockaddr.in6 = std.mem.zeroes(c.sockaddr.in6);
    addr.family = c.AF.INET6;
    addr.addr = [_]u8{0} ** 15 ++ [_]u8{1}; // ::1
    addr.port = 0; // OS-assigned ephemeral
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in6)) != 0 or c.listen(fd, 1) != 0) {
        return error.SkipZigTest; // no IPv6 loopback here
    }
    var bound: c.sockaddr.in6 = undefined;
    var blen: c.socklen_t = @sizeOf(c.sockaddr.in6);
    if (c.getsockname(fd, @ptrCast(&bound), &blen) != 0) return error.SkipZigTest;

    var url = Url{ .proto = .tcp, .port = std.mem.bigToNative(u16, bound.port) };
    @memcpy(url.host[0..3], "::1");
    url.host_len = 3;

    const client = connectTcpFd(&url);
    try std.testing.expect(client >= 0);
    _ = c.close(client);
}

test "transport: connectChain skips an unusable address and connects to the next" {
    // Regression: only the first getaddrinfo result was tried, so a name whose
    // first address is unreachable (::1 ahead of 127.0.0.1 for "localhost")
    // never reached the daemon.
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SkipZigTest;
    defer _ = c.close(fd);
    var listen_addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    listen_addr.family = c.AF.INET;
    listen_addr.addr = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1
    listen_addr.port = 0; // OS-assigned ephemeral
    if (c.bind(fd, @ptrCast(&listen_addr), @sizeOf(c.sockaddr.in)) != 0 or c.listen(fd, 1) != 0) {
        return error.SkipZigTest; // sandbox forbids bind/listen
    }
    var bound: c.sockaddr.in = undefined;
    var blen: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&bound), &blen) != 0) return error.SkipZigTest;

    // A two-entry chain whose head has an address family connectResolved cannot
    // use, so only the second entry can produce a connection.
    var good: c.addrinfo = std.mem.zeroes(c.addrinfo);
    good.family = c.AF.INET;
    good.socktype = c.SOCK.STREAM;
    good.addrlen = @sizeOf(c.sockaddr.in);
    good.addr = @ptrCast(&listen_addr);
    var bad: c.addrinfo = std.mem.zeroes(c.addrinfo);
    bad.family = c.AF.UNSPEC;
    bad.socktype = c.SOCK.STREAM;
    bad.addrlen = @sizeOf(c.sockaddr.in);
    bad.addr = @ptrCast(&listen_addr);

    const port = std.mem.bigToNative(u16, bound.port);
    try std.testing.expectEqual(@as(c.fd_t, -1), connectChain(&bad, port)); // head alone fails
    bad.next = &good;
    const client = connectChain(&bad, port);
    try std.testing.expect(client >= 0);
    _ = c.close(client);
}
