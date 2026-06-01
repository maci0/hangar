// SPDX-License-Identifier: MIT
//! Serial console reader and connection management.
//!
//! Spawns a background reader thread for the VM's Unix-domain serial socket,
//! appending bytes into a shared ring buffer (polled by consoleTimerCB).

const std = @import("std");
const usock = @import("usock.zig");
const ringbuf = @import("ringbuf.zig");
const sync = @import("sync.zig");
const app = @import("appstate.zig");

fn serialReader() void {
    const fd = app.serial_fd orelse return;
    var buf: [4096]u8 = undefined;
    while (@atomicLoad(bool, &app.serial_running, .seq_cst)) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        app.serial_mutex.lock();
        app.serial_len = ringbuf.append(&app.serial_buf, app.serial_len, buf[0..@intCast(n)]);
        app.serial_mutex.unlock();
    }
    // Clean up after unexpected exit (VM died, socket error, etc.).
    // If serialDisconnect already set running=false, skip — it handles cleanup.
    if (@atomicRmw(bool, &app.serial_running, .Xchg, false, .seq_cst)) {
        _ = std.c.close(fd);
        app.serial_fd = null;
    }
}

/// Connect to the VM's serial Unix socket and start the reader thread.
pub fn serialConnect(vm_name: []const u8) void {
    if (app.serial_fd != null) return;
    var path_buf: [320]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/kvmgui-serial-{s}.sock", .{vm_name}) catch return;
    const stream = usock.UnixStream.connect(path) catch return;
    app.serial_fd = stream.fd;
    @atomicStore(bool, &app.serial_running, true, .seq_cst);
    app.serial_thread = std.Thread.spawn(std.Thread.SpawnConfig{}, serialReader, .{}) catch {
        app.serial_fd = null;
        return;
    };
}

/// Stop the serial reader thread and close the socket.
pub fn serialDisconnect() void {
    @atomicStore(bool, &app.serial_running, false, .seq_cst);
    if (app.serial_fd) |fd| { _ = std.c.close(fd); app.serial_fd = null; }
    if (app.serial_thread) |t| { t.join(); app.serial_thread = null; }
}
