// SPDX-License-Identifier: MIT
//! Minimal blocking Unix-domain stream socket.
//!
//! Zig 0.16 gutted `std.posix` socket helpers and moved networking behind the
//! new `std.Io` interface (which threads an `Io` instance through every call).
//! QMP and the serial console only need a plain blocking AF_UNIX stream, so we
//! wrap the raw libc bindings directly. `link_libc` is already required by the
//! C dependencies, so the `std.c.*` symbols are always available.

const std = @import("std");
const c = std.c;

/// Linux AF_UNIX connect() waits for accept(). Bound so a listening but
/// never-accepted peer (wedged QEMU, a lost test server thread) cannot hang
/// the caller for the kernel's default (~127s).
const CONNECT_TIMEOUT_MS: u31 = 3_000;

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0o4000;

pub const UnixStream = struct {
    fd: c.fd_t,

    /// Connect to an AF_UNIX stream socket at `path`.
    pub fn connect(path: []const u8) !UnixStream {
        var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        const addrlen: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
        const flags = c.fcntl(fd, F_GETFL, @as(c_int, 0));
        if (flags < 0) return error.SocketFailed;
        _ = c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        const connected = blk: {
            if (c.connect(fd, @ptrCast(&addr), addrlen) == 0) break :blk true;
            if (c._errno().* != @intFromEnum(c.E.INPROGRESS) and
                c._errno().* != @intFromEnum(c.E.AGAIN)) break :blk false;
            var pfd = c.pollfd{ .fd = fd, .events = c.POLL.OUT, .revents = 0 };
            const pr = c.poll(@ptrCast(&pfd), 1, CONNECT_TIMEOUT_MS);
            if (pr <= 0) break :blk false;
            if (pfd.revents & c.POLL.OUT == 0) break :blk false;
            var so_err: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&so_err), &len) != 0) break :blk false;
            break :blk so_err == 0;
        };
        _ = c.fcntl(fd, F_SETFL, flags);
        if (!connected) return error.ConnectionFailed;
        // Linux may complete AF_UNIX connect from the listen backlog before
        // accept(); bound I/O so a peer that never reads/writes cannot hang.
        const stream: UnixStream = .{ .fd = fd };
        stream.setTimeout(CONNECT_TIMEOUT_MS);
        return stream;
    }

    /// Read up to `buf.len` bytes. Returns 0 on EOF.
    pub fn read(self: UnixStream, buf: []u8) !usize {
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    /// Write up to `buf.len` bytes. Returns the number written.
    pub fn write(self: UnixStream, buf: []const u8) !usize {
        const n = c.write(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.WriteFailed;
        return @intCast(n);
    }

    /// Apply a receive + send timeout (milliseconds) so blocking reads/writes
    /// cannot hang forever when the peer (e.g. a frozen QEMU) stops responding.
    /// A timed-out `read`/`write` surfaces as `error.ReadFailed`/`error.WriteFailed`.
    /// Best-effort: failure to set the option is ignored (the socket simply
    /// stays in its default blocking mode).
    pub fn setTimeout(self: UnixStream, ms: u32) void {
        const tv: c.timeval = .{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        _ = c.setsockopt(self.fd, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
        _ = c.setsockopt(self.fd, c.SOL.SOCKET, c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    }

    pub fn close(self: UnixStream) void {
        _ = c.close(self.fd);
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// Exercise connect/read/write/close against a REAL AF_UNIX listener bound in
// the test (echo server on a background thread). No display/hardware needed.

const testing = std.testing;

test "usock: connect/write/read/close round-trip over a real listener" {
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-usock-test-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);

    const srv = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (srv < 0) return error.SkipZigTest;
    defer _ = c.close(srv);
    defer _ = c.unlink(path.ptr);

    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    if (c.bind(srv, @ptrCast(&addr), addrlen) != 0) return error.SkipZigTest;
    if (c.listen(srv, 1) != 0) return error.SkipZigTest;

    const Echo = struct {
        fn run(listen_fd: c.fd_t) void {
            const conn = c.accept(listen_fd, null, null);
            if (conn < 0) return;
            defer _ = c.close(conn);
            var b: [64]u8 = undefined;
            const n = c.read(conn, &b, b.len);
            if (n > 0) _ = c.write(conn, &b, @intCast(n));
        }
    };
    var th = try std.Thread.spawn(std.Thread.SpawnConfig{}, Echo.run, .{srv});
    defer {
        _ = c.shutdown(srv, 2);
        th.join();
    }

    const stream = try UnixStream.connect(path);
    defer stream.close();
    try testing.expectEqual(@as(usize, 5), try stream.write("hello"));
    var rb: [16]u8 = undefined;
    const got = try stream.read(rb[0..]);
    try testing.expectEqualStrings("hello", rb[0..got]);
}

test "usock: connect to a listener that never accepts times out" {
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-usock-noaccept-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);

    const srv = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (srv < 0) return error.SkipZigTest;
    defer {
        _ = c.close(srv);
        _ = c.unlink(path.ptr);
    }

    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    if (c.bind(srv, @ptrCast(&addr), addrlen) != 0) return error.SkipZigTest;
    if (c.listen(srv, 1) != 0) return error.SkipZigTest;

    // Linux can complete connect() from the listen backlog before accept().
    // The hang is then a blocking read, not connect.
    const stream = try UnixStream.connect(path);
    defer stream.close();
    var t0: c.timespec = undefined;
    var t1: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &t0);
    var buf: [8]u8 = undefined;
    try testing.expectError(error.ReadFailed, stream.read(&buf));
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &t1);
    const elapsed_ms = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < CONNECT_TIMEOUT_MS + 1000);
}

test "usock: connect to nonexistent path fails" {
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-usock-nope-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    if (UnixStream.connect(path)) |stream| {
        stream.close();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.SocketFailed => return error.SkipZigTest,
        error.ConnectionFailed => {},
        else => return err,
    }
}

test "usock: overly long path is rejected before any syscall" {
    const long = "/tmp/" ++ ("x" ** 200);
    try testing.expectError(error.NameTooLong, UnixStream.connect(long));
}

test "fuzz: connect never panics with random paths" {
    var prng = std.Random.DefaultPrng.init(0xAF01_F00);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, 150);
        var path: [150]u8 = undefined;
        for (path[0..len]) |*ch| ch.* = rnd.intRangeAtMost(u8, 32, 126);
        if (UnixStream.connect(path[0..len])) |stream| {
            stream.close();
        } else |_| {}
    }
}
