// SPDX-License-Identifier: MIT
//! Serial console reader and connection management.
//!
//! Spawns a background reader thread for the VM's Unix-domain serial socket,
//! appending bytes into a shared ring buffer that the web server relays to
//! clients over the `/ws/serial/` WebSocket.

const std = @import("std");
const usock = @import("usock.zig");
const ringbuf = @import("ringbuf.zig");
const sync = @import("sync.zig");
const serialpath = @import("serialpath.zig");
const app = @import("appstate.zig");

var serial_lifecycle_mutex: sync.SpinMutex = .{};

fn serialReader() void {
    serial_lifecycle_mutex.lock();
    const fd = app.serial_fd orelse {
        serial_lifecycle_mutex.unlock();
        return;
    };
    serial_lifecycle_mutex.unlock();

    var buf: [4096]u8 = undefined;
    while (@atomicLoad(bool, &app.serial_running, .seq_cst)) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n > 0) {
            app.serial_mutex.lock();
            app.serial_len = ringbuf.append(&app.serial_buf, app.serial_len, buf[0..@intCast(n)]);
            app.serial_mutex.unlock();
        } else if (n == 0) {
            break; // EOF — VM disconnected
        } else {
            // n < 0: error — retry on transient, break on permanent
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.c.E.INTR) or e == @intFromEnum(std.c.E.AGAIN)) continue;
            break;
        }
    }
    // Clean up after unexpected exit (VM died, socket error, etc.).
    // If serialDisconnect already set running=false, skip — it handles cleanup.
    if (@atomicRmw(bool, &app.serial_running, .Xchg, false, .seq_cst)) {
        serial_lifecycle_mutex.lock();
        if (app.serial_fd != null and app.serial_fd.? == fd) {
            _ = std.c.close(fd);
            app.serial_fd = null;
        }
        serial_lifecycle_mutex.unlock();
    }
}

/// Connect to the VM's serial Unix socket and start the reader thread.
pub fn serialConnect(vm_name: []const u8) void {
    serial_lifecycle_mutex.lock();
    defer serial_lifecycle_mutex.unlock();

    // Reap a reader that exited on its own (EOF / socket error). Such a reader
    // clears serial_fd in its cleanup path but cannot null its own thread
    // handle; without this, serial_thread would stay set forever and every
    // reconnect below would bail out at the guard, permanently wedging the
    // serial console after the first disconnect (and leaking the thread).
    // We hold serial_lifecycle_mutex, which the reader releases before
    // returning, so the thread is already terminating — detach frees it.
    if (app.serial_thread != null and app.serial_fd == null and
        !@atomicLoad(bool, &app.serial_running, .seq_cst))
    {
        app.serial_thread.?.detach();
        app.serial_thread = null;
    }

    if (app.serial_fd != null or app.serial_thread != null) return;
    var path_buf: [320]u8 = undefined;
    const path = serialpath.serialSocketPath(&path_buf, vm_name) catch return;
    const stream = usock.UnixStream.connect(path) catch return;
    app.serial_fd = stream.fd;
    @atomicStore(bool, &app.serial_running, true, .seq_cst);
    app.serial_thread = std.Thread.spawn(std.Thread.SpawnConfig{}, serialReader, .{}) catch {
        @atomicStore(bool, &app.serial_running, false, .seq_cst);
        _ = std.c.close(stream.fd);
        app.serial_fd = null;
        return;
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "serial: reader loop reads data from socketpair into ringbuf" {
    // Create a socketpair: fd[0] is the "VM side" (which we write into),
    // fd[1] is the "serial reader side" (which the reader reads from).
    var fds: [2]c_int = undefined;
    _ = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    defer _ = std.c.close(fds[0]);

    // Wire up the appstate globals for the reader.
    app.serial_fd = fds[1];
    app.serial_len = 0;
    app.serial_mutex = sync.SpinMutex{};
    @memset(&app.serial_buf, 0);
    @atomicStore(bool, &app.serial_running, true, .seq_cst);

    // Spawn the reader thread.
    app.serial_thread = try std.Thread.spawn(std.Thread.SpawnConfig{}, serialReader, .{});

    // Write data on the VM side.
    const msg = "Hello from serial!";
    _ = std.c.write(fds[0], msg, msg.len);
    // Also write a second chunk to test append behavior.
    const msg2 = " second chunk";
    _ = std.c.write(fds[0], msg2, msg2.len);
    // Shutdown the write side to signal EOF, which will cause the reader to exit cleanly.
    _ = std.c.shutdown(fds[0], std.c.SHUT.WR);

    // Wait for the reader to process the data (brief spin with yield).
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        app.serial_mutex.lock();
        const len = app.serial_len;
        app.serial_mutex.unlock();
        if (len >= msg.len + msg2.len) break;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    // Verify the received data.
    app.serial_mutex.lock();
    const total = app.serial_len;
    const received = app.serial_buf[0..total];
    app.serial_mutex.unlock();

    try std.testing.expect(total >= msg.len + msg2.len);
    try std.testing.expect(std.mem.indexOf(u8, received, msg) != null);
    try std.testing.expect(std.mem.indexOf(u8, received, msg2) != null);

    // Tear down — but don't call serialDisconnect since we already shut down the writer side.
    // The reader should have exited (fd got EOF). Just join and close.
    if (app.serial_thread) |t| {
        t.join();
        app.serial_thread = null;
    }
    _ = std.c.close(fds[1]);
    app.serial_fd = null;
}

test "fuzz: serialReader handles random data bursts and disconnect racing" {
    var prng = std.Random.DefaultPrng.init(0x5E814CF0);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        // Create a fresh socketpair each iteration.
        var fds: [2]c_int = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer _ = std.c.close(fds[0]);

        app.serial_fd = fds[1];
        app.serial_len = 0;
        app.serial_mutex = sync.SpinMutex{};
        @memset(&app.serial_buf, 0);
        @atomicStore(bool, &app.serial_running, true, .seq_cst);

        app.serial_thread = std.Thread.spawn(std.Thread.SpawnConfig{}, serialReader, .{}) catch {
            _ = std.c.close(fds[1]);
            app.serial_fd = null;
            continue;
        };

        // Write random chunks.
        const reps = rnd.uintLessThan(usize, 8);
        for (0..reps) |_| {
            const chunk_len = rnd.uintLessThan(usize, @min(128, buf.len));
            for (buf[0..chunk_len]) |*b| b.* = rnd.int(u8);
            _ = std.c.write(fds[0], &buf, chunk_len);
            // Random micro-delay to encourage interleaving.
            var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(rnd.uintLessThan(u32, 1_000_000)) };
            _ = std.c.nanosleep(&ts, null);
        }

        // Disconnect by signalling stop + shutdown.
        serialDisconnect();

        // Verify invariants: serial_len never exceeds buffer capacity.
        try std.testing.expect(app.serial_len <= app.SERIAL_BUF_SIZE);

        // serialDisconnect joined the thread and reset state.
        try std.testing.expect(app.serial_fd == null);
        try std.testing.expect(app.serial_thread == null);
    }
}

test "serial: serialDisconnect when no connection active is a no-op" {
    // Ensure clean state.
    app.serial_running = false;
    app.serial_fd = null;
    app.serial_thread = null;

    // Should not crash.
    serialDisconnect();

    try std.testing.expect(app.serial_fd == null);
    try std.testing.expect(app.serial_thread == null);
}

test "serial: serialConnect returns early when already connected" {
    // Simulate an already-active connection.
    app.serial_fd = 999; // fake fd
    defer app.serial_fd = null;

    // Call connect — should return immediately via the first guard.
    serialConnect("any-vm");
    // fd should still be the fake value (unchanged).
    try std.testing.expectEqual(@as(?std.c.fd_t, 999), app.serial_fd);
}

test "serial: serialConnect with non-existent socket fails gracefully" {
    // Ensure clean state.
    app.serial_fd = null;
    app.serial_thread = null;

    // Call with a VM name that has no serial socket.
    serialConnect("no-such-vm-12345");

    // Should not have set up any connection.
    try std.testing.expect(app.serial_fd == null);
    try std.testing.expect(app.serial_thread == null);
}

test "serial: serialConnect reaps a self-exited reader so reconnect is possible" {
    // Simulate the post-EOF state: serial_fd cleared by the reader's cleanup,
    // serial_running false, but serial_thread still set (the reader cannot
    // null its own handle). A trivial thread that returns immediately stands
    // in for the exited reader.
    app.serial_fd = null;
    @atomicStore(bool, &app.serial_running, false, .seq_cst);
    app.serial_thread = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run() void {}
    }.run, .{});

    // Connect to a non-existent socket: the connect itself fails, but the stale
    // thread handle must be reaped first so the guard no longer wedges us.
    serialConnect("no-such-vm-reap-test");

    try std.testing.expect(app.serial_thread == null);
    try std.testing.expect(app.serial_fd == null);
}

/// Stop the serial reader thread and close the socket.
/// Uses shutdown() to unblock the reader's read() call without closing
/// the fd prematurely — avoids a double-close race where the OS recycles
/// the fd number before the thread exits its read() syscall.
pub fn serialDisconnect() void {
    @atomicStore(bool, &app.serial_running, false, .seq_cst);
    // Shutdown the socket to unblock any in-flight read() in the reader
    // thread, so the thread can observe running==false and exit.
    serial_lifecycle_mutex.lock();
    const fd = app.serial_fd;
    if (fd) |current| _ = std.c.shutdown(current, std.c.SHUT.RDWR);
    const thread = app.serial_thread;
    app.serial_thread = null;
    serial_lifecycle_mutex.unlock();

    if (thread) |t| {
        t.join();
    }
    // Now safe to close: the thread is joined and has either already
    // closed the fd via its cleanup path or skipped it (Rmw returned false).
    serial_lifecycle_mutex.lock();
    if (fd) |closing| {
        if (app.serial_fd != null and app.serial_fd.? == closing) {
            _ = std.c.close(closing);
            app.serial_fd = null;
        }
    }
    serial_lifecycle_mutex.unlock();
}
