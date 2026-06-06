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
        if (c.connect(fd, @ptrCast(&addr), addrlen) != 0) return error.ConnectionFailed;

        return .{ .fd = fd };
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
    defer th.join();

    const stream = try UnixStream.connect(path);
    defer stream.close();
    try testing.expectEqual(@as(usize, 5), try stream.write("hello"));
    var rb: [16]u8 = undefined;
    const got = try stream.read(rb[0..]);
    try testing.expectEqualStrings("hello", rb[0..got]);
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
