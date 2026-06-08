//! Connection-streaming HTTP handlers — responses written directly to the socket
//! fd rather than returned as a token. Currently: screenshot (QMP screendump →
//! PNG). disk2 download/upload and OVF export are candidates to move here too.

const std = @import("std");
const c = std.c;
const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
const appstate = @import("appstate.zig");
const httpreq = @import("httpreq.zig");
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const writeAll = httpresp.writeAll;
const writeHttpResponse = httpresp.writeHttpResponse;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;
const HTTP_BAD_REQUEST = httpresp.HTTP_BAD_REQUEST;
const HTTP_CONFLICT = httpresp.HTTP_CONFLICT;
const HTTP_INTERNAL_ERROR = httpresp.HTTP_INTERNAL_ERROR;

/// Capture the running guest's display and stream it back as PNG (QMP
/// screendump). Only meaningful for a running VM; a stopped VM gets 409.
pub fn screenshot(conn: c.fd_t, req: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid idx\"}");
            return;
        }
        const v = &appstate.vms[idx];
        if (!v.isAlive()) {
            writeHttpResponse(conn, HTTP_CONFLICT, "application/json; charset=utf-8", "{\"error\":\"vm not running\"}");
            return;
        }
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len or !qmp.isPathSafeName(nm)) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        }
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    var path_buf: [96]u8 = undefined;
    const png_path = std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-shot-{d}-{d}.png", .{ std.c.getpid(), ts.nsec }) catch {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
        return;
    };

    {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        };
        client.connect(sock) catch |e| {
            logOpErr("screenshot", e, name_buf[0..name_len]);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        };
        defer client.disconnect();
        // Drop any pre-planted entry (e.g. an attacker symlink at this path)
        // before QEMU's screendump writes it, so it can't be redirected (CWE-59).
        _ = c.unlink(png_path);
        client.screenshotPng(png_path) catch |e| {
            logOpErr("screenshot", e, name_buf[0..name_len]);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot failed\"}");
            return;
        };
    }
    defer _ = c.unlink(png_path);

    const fd = c.open(png_path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot read failed\"}");
        return;
    }
    defer _ = c.close(fd);
    const seek_end = c.lseek(fd, 0, 2);
    if (seek_end <= 0) {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot empty\"}");
        return;
    }
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(fd, 0, 0) < 0) return;

    var hdr_buf: [256]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{file_size}) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return;
    var sbuf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &sbuf, sbuf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &sbuf, @intCast(n))) return;
    }
    logAudit("screenshot", name_buf[0..name_len]);
}

// ── Tests ───────────────────────────────────────────────────────────

test "streams: screenshot rejects a non-matching request (writes to a pipe)" {
    // Drive a real fd: a pipe whose read end we drain. parseIdx fails → 400.
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return; // skip if pipe unavailable
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    screenshot(fds[1], "GET /api/other HTTP/1.1");
    var buf: [256]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(n)], "400") != null);
}
