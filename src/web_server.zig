//! KVMGUI — Web Frontend (HTTP server + HTML/CSS UI)
//! Serves a VMware WS7-style UI via embedded HTTP server.
//! Open http://localhost:9080 in any browser.
const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const ws = @import("ws.zig");
const usock = @import("usock.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const ovf = @import("ovf.zig");
const vnet = @import("vnet.zig");
const appio = @import("appio.zig");
const autoprotect = @import("autoprotect.zig");
const sync = @import("sync.zig");

extern fn time(t: ?*c_long) c_long;

const MAX_VMS = 64;
var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var vms_mutex: sync.SpinMutex = .{};
var prefs: vm.Prefs = .{};

const PORT: u16 = 9080;
const BIND_ADDR: [4]u8 = .{ 0, 0, 0, 0 }; // 0.0.0.0 — accessible remotely
const API_KEY: []const u8 = "kvmgui"; // default API key for X-API-Key auth
var auth_token: [64]u8 = [_]u8{0} ** 64;
var auth_token_len: usize = 0;

// HV abstraction — QEMU backend dispatch table
var g_vmm: hv_iface.Vmm = undefined;
var g_vmm_handles: [MAX_VMS]?hv_iface.VmmHandle = [_]?hv_iface.VmmHandle{null} ** MAX_VMS;

/// Get or create the Vmm handle for VM at index idx.
fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        const mode: hv_backend.AccelMode = if (vms[idx].enable_kvm) .auto else .force_tcg;
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], mode, std.heap.page_allocator) catch return null;
    }
    return g_vmm_handles[idx];
}

/// Destroy the Vmm handle for VM at index idx.
fn destroyVmmHandle(idx: usize) void {
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
}

const c = std.c;

// POSIX networking constants (not in std.c in Zig 0.16)
const AF_INET: c_uint = 2;
const SOCK_STREAM: c_int = 1;
const AF_UNIX: c_uint = 1;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const SHUT_WR: c_int = 1;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 2048;

/// Simple API-key check. Reads X-API-Key header from request.
/// GET /api/vms, /api/health, /api/fb/N, /api/snapshot/list/N, WebSocket upgrade are exempt.
fn checkAuth(req: []const u8) bool {
    if (auth_token_len > 0) {
        const key_start = std.mem.indexOf(u8, req, "X-API-Key: ") orelse return false;
        const key_val_start = key_start + "X-API-Key: ".len;
        const key_end = std.mem.indexOfScalar(u8, req[key_val_start..], '\r') orelse req.len;
        const provided = req[key_val_start .. key_val_start + key_end];
        return std.mem.eql(u8, provided, auth_token[0..auth_token_len]);
    }
    // No custom token set — fall back to built-in API_KEY
    const key_start = std.mem.indexOf(u8, req, "X-API-Key: ") orelse return false;
    const key_val_start = key_start + "X-API-Key: ".len;
    const key_end = std.mem.indexOfScalar(u8, req[key_val_start..], '\r') orelse req.len;
    const provided = req[key_val_start .. key_val_start + key_end];
    return std.mem.eql(u8, provided, API_KEY);
}

/// Write an HTTP response with status code, content type, CORS headers, and body.
fn writeHttpResponse(conn: c.fd_t, status: u16, ct: []const u8, body: []const u8) void {
    const status_line: []const u8 = switch (status) {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 200 OK\r\n",
    };
    _ = c.write(conn, status_line.ptr, status_line.len);

    // CORS headers (allow cross-origin browser access)
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Origin: *\r\n"), 32);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Headers: Content-Type, X-API-Key\r\n"), 53);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"), 48);

    _ = c.write(conn, @ptrCast("Content-Type: "), 14);
    _ = c.write(conn, ct.ptr, ct.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);
    _ = c.write(conn, body.ptr, body.len);
}

/// Write HTTP headers for a streaming response (no Content-Length, uses chunked or raw stream).
fn writeStreamHeaders(conn: c.fd_t, status: u16, ct: []const u8, content_len: u64) void {
    const status_line: []const u8 = switch (status) {
        200 => "HTTP/1.1 200 OK\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 200 OK\r\n",
    };
    _ = c.write(conn, status_line.ptr, status_line.len);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Origin: *\r\n"), 32);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Headers: Content-Type, X-API-Key\r\n"), 53);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"), 48);
    _ = c.write(conn, @ptrCast("Content-Type: "), 14);
    _ = c.write(conn, ct.ptr, ct.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content_len}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);
}

fn acceptLoop(fd: c.fd_t) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) continue;
        _ = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);
    var buf: [4096]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // ── CORS preflight ──
    if (std.mem.startsWith(u8, req, "OPTIONS ")) {
        writeHttpResponse(conn, 200, "text/plain", "ok");
        return;
    }

    // ── WebSocket VNC Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/vnc/")) {
        handleWsVnc(conn, req) catch {};
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        handleWsSerial(conn, req) catch {};
        return;
    }

    // ── File download (streaming) routes — handled first ──
    if (std.mem.startsWith(u8, req, "GET /api/vm/") and std.mem.indexOf(u8, req, "/disk2/download") != null) {
        handleDisk2Download(conn, req) catch {};
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/vm/") and std.mem.indexOf(u8, req, "/upload-disk") != null) {
        const resp = handleUploadDisk(req) catch "upload err";
        const status: u16 = if (std.mem.eql(u8, resp, "ok")) @as(u16, 200) else 400;
        writeHttpResponse(conn, status, "text/plain", resp);
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/export/")) {
        handleExport(conn, req) catch {
            writeHttpResponse(conn, 500, "text/plain", "export err");
        };
        return;
    }

    // ── Standard routes ──
    var response: []const u8 = "";
    var content_type: []const u8 = "text/html";
    var status: u16 = 200;

    // Auth: check X-API-Key for mutating endpoints
    const needs_auth = !std.mem.startsWith(u8, req, "GET /api/vms") and
        !std.mem.startsWith(u8, req, "GET /api/health") and
        !std.mem.startsWith(u8, req, "GET /api/fb/") and
        !std.mem.startsWith(u8, req, "GET /api/snapshot/list/") and
        !std.mem.startsWith(u8, req, "GET /api/config") and
        !std.mem.startsWith(u8, req, "GET /api/vnets") and
        !std.mem.startsWith(u8, req, "GET /api/vm/") and
        !std.mem.startsWith(u8, req, "GET / ") and
        !std.mem.eql(u8, req[0..@min(req.len, "GET /favicon".len)], "GET /favicon");

    if (needs_auth and !checkAuth(req)) {
        writeHttpResponse(conn, 400, "text/plain", "auth required");
        return;
    }

    if (std.mem.startsWith(u8, req, "GET /api/vms")) {
        content_type = "application/json";
        response = try renderJson();
    } else if (std.mem.startsWith(u8, req, "GET /api/health")) {
        response = "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json";
    } else if (std.mem.startsWith(u8, req, "GET /api/config")) {
        content_type = "application/json";
        response = try serveConfigRaw();
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json";
        response = try renderVmDetail(req);
    } else if (std.mem.startsWith(u8, req, "POST /api/power/")) {
        response = try handlePower(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/new")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/delete/")) {
        response = try handleDelete(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/fb/")) {
        response = try renderFramebuffer(req);
        content_type = "image/bmp";
    } else if (std.mem.startsWith(u8, req, "POST /api/clone/")) {
        response = try handleClone(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/save/")) {
        response = try handleSave(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/rename/")) {
        response = try handleRename(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/save")) {
        persist.save(&vms, vm_count, prefs) catch {};
        response = "saved";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/create")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/suspend/")) {
        response = try handleSuspend(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/pause/")) {
        response = try handlePause(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/resume/")) {
        response = try handleResume(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/shutdown/")) {
        response = try handleShutdown(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/reset/")) {
        response = try handleReset(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/take/")) {
        response = try handleSnapshotTake(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/snapshot/list/")) {
        response = try handleSnapshotList(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/revert/")) {
        response = try handleSnapshotRevert(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/delete/")) {
        response = try handleSnapshotDelete(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/import")) {
        response = try handleImport(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/cad/")) {
        response = try handleCad(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/vnets")) {
        content_type = "application/json";
        response = handleVnetsJson() catch "[]";
    } else if (std.mem.startsWith(u8, req, "POST /api/vnets/save")) {
        response = handleVnetsSave(req) catch "save err";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/config")) {
        response = handleConfigSave(req) catch "save err";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET / ")) {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET /favicon")) {
        status = 404;
        response = "not found";
        content_type = "text/plain";
    } else {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    }

    // Map known error strings to HTTP status codes
    if (std.mem.eql(u8, response, "invalid") or std.mem.eql(u8, response, "invalid idx")) {
        status = 404;
    } else if (std.mem.eql(u8, response, "no disk") or std.mem.eql(u8, response, "not running")) {
        status = 400;
    } else if (std.mem.indexOf(u8, response, "err") != null) {
        status = 500;
    }

    writeHttpResponse(conn, status, content_type, response);
}

/// Return the raw vms.json content for remote clients to sync their state.
fn serveConfigRaw() ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const home = appio.getenv("HOME") orelse return "{}";
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/kvmgui/vms.json", .{home}) catch return "{}";
    return std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        path,
        std.heap.page_allocator,
        .limited(10 * 1024 * 1024),
    ) catch return "{}";
}

var fb_client: ?*vnc.VncClient = null;
var fb_mutex: sync.SpinMutex = .{};
// BMP output buffer — 54-byte header + up to 1 MB of pixel data
var fb_bmp_buf: [1024 * 1024 + 54]u8 = undefined;

/// Handle WebSocket VNC proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's VNC port,
/// and spawns bidirectional relay threads.
fn handleWsVnc(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/vnc/<idx>
    const prefix = "GET /ws/vnc/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.isAlive()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's VNC server.
    const vnc_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (vnc_fd < 0) return;
    defer _ = c.close(vnc_fd);

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, v.vnc_port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));

    if (c.connect(vnc_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        try ws.writeClose(conn);
        return;
    }

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        vnc_fd: c.fd_t,
    };
    var ctx = RelayCtx{ .ws_fd = conn, .vnc_fd = vnc_fd };

    // Thread: VNC → WebSocket
    const vnc2ws = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.vnc_fd, &buf, buf.len);
                if (n <= 0) break;
                // Send shutdown signal to peer via empty write
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch break;
            }
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    // Thread: WebSocket → VNC
    const ws2vnc = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ws.writePong(ctx_ptr.ws_fd) catch break;
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                _ = c.write(ctx_ptr.vnc_fd, buf[0..rlen].ptr, rlen);
            }
            _ = c.shutdown(ctx_ptr.vnc_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    vnc2ws.join();
    ws2vnc.join();
}

/// Handle WebSocket Serial Console proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's serial
/// Unix socket, and spawns bidirectional relay threads.
fn handleWsSerial(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/serial/<idx>
    const prefix = "GET /ws/serial/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.isAlive() or !v.enable_serial or !v.hasName()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/kvmgui-serial-{s}.sock",
        .{v.getNameSlice()},
    ) catch return;

    const serial = usock.UnixStream.connect(sock_path) catch return;
    defer serial.close();

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        serial_fd: c.fd_t,
    };
    var ctx = RelayCtx{ .ws_fd = conn, .serial_fd = serial.fd };

    // Thread: serial → WebSocket
    const ser2ws = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.serial_fd, &buf, buf.len);
                if (n <= 0) break;
                ws.writeFrame(ctx_ptr.ws_fd, .text, buf[0..@intCast(n)]) catch break;
            }
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    // Thread: WebSocket → serial
    const ws2ser = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ws.writePong(ctx_ptr.ws_fd) catch break;
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                _ = c.write(ctx_ptr.serial_fd, buf[0..rlen].ptr, rlen);
            }
            _ = c.shutdown(ctx_ptr.serial_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    ser2ws.join();
    ws2ser.join();
}

fn renderFramebuffer(req: []const u8) ![]const u8 {
    // GET /api/fb/N — return the framebuffer for VM N as a valid BMP image
    const prefix = "GET /api/fb/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid idx";
    if (idx >= vm_count) return "no vm";
    const v = &vms[idx];
    if (!v.isAlive()) return "off";

    fb_mutex.lock();
    defer fb_mutex.unlock();

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
    }
    const vc = fb_client.?;
    if (!vc.isConnected()) {
        _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0; var fh: c_int = 0;
        if (vc.getSize(&fw, &fh)) {
            const pixel_size: usize = @intCast(@as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4);
            const copy_size = @min(pixel_size, fb_bmp_buf.len - 54);
            const file_size: u32 = @intCast(54 + copy_size);

            // ── BITMAPFILEHEADER (14 bytes) ──────────────────────
            fb_bmp_buf[0] = 'B';
            fb_bmp_buf[1] = 'M';
            std.mem.writeInt(u32, fb_bmp_buf[2..6], file_size, .little); // bfSize
            std.mem.writeInt(u32, fb_bmp_buf[6..10], 0, .little);        // bfReserved
            std.mem.writeInt(u32, fb_bmp_buf[10..14], 54, .little);      // bfOffBits

            // ── BITMAPINFOHEADER (40 bytes) ──────────────────────
            @memset(fb_bmp_buf[14..54], 0); // zero-fill then set fields
            std.mem.writeInt(u32, fb_bmp_buf[14..18], 40, .little);     // biSize
            std.mem.writeInt(i32, fb_bmp_buf[18..22], fw, .little);      // biWidth
            std.mem.writeInt(i32, fb_bmp_buf[22..26], -fh, .little);     // biHeight (negative = top-down)
            std.mem.writeInt(u16, fb_bmp_buf[26..28], 1, .little);       // biPlanes
            std.mem.writeInt(u16, fb_bmp_buf[28..30], 32, .little);      // biBitCount
            // biCompression = 0 (BI_RGB), biSizeImage = 0 (OK for BI_RGB)
            // biXPelsPerMeter = biYPelsPerMeter = 2835 (~72 DPI)
            std.mem.writeInt(u32, fb_bmp_buf[38..42], 2835, .little);
            std.mem.writeInt(u32, fb_bmp_buf[42..46], 2835, .little);

            // ── Pixel data ───────────────────────────────────────
            @memcpy(fb_bmp_buf[54..][0..copy_size], @as([*]const u8, @ptrCast(pixels))[0..copy_size]);
            return fb_bmp_buf[0 .. 54 + copy_size];
        }
    }
    return "no fb";
}

fn renderVmDetail(req: []const u8) ![]const u8 {
    const prefix = "GET /api/vm/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "{}";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "{}";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "{}";
    if (idx >= vm_count) return "{}";
    const v = &vms[idx];
    var buf: [3072]u8 = undefined;
    var w: usize = 0;

    // First 32 fields
    const part1 = std.fmt.bufPrint(buf[w..],
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
    , .{
        idx, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
        v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
        std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
        if (v.hasIso()) v.getIsoPathSlice() else "",
        if (v.hasNotes()) v.getNotesSlice() else "",
        if (v.hasSharedFolder()) v.getSharedFolderSlice() else "",
        if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "",
        if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false",
        v.autoprotect_interval_min, v.autoprotect_max,
        if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
        if (v.hasDisk2()) v.getDisk2PathSlice() else "",
        v.disk2_format.toIndex(),
        if (v.hasFloppy()) "true" else "false",
        if (v.hasFloppy()) v.getFloppyPathSlice() else "",
        if (v.hasPortForwards()) v.getPortForwardsSlice() else "",
    }) catch return "{}";
    w += part1.len;

    // Remaining fields
    const part2 = std.fmt.bufPrint(buf[w..],
        \\,"mac":"{s}","mac_address":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"enable_kvm":{s},"embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s}}}
    , .{
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        std.mem.span(v.nics[1].mode.toStr()),
        if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
        std.mem.span(v.nics[2].mode.toStr()),
        if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
        v.num_displays,
        if (v.enable_serial) "true" else "false",
        if (v.enable_3d) "true" else "false",
        v.gpu_device.toIndex(),
        v.display.toIndex(),
        v.display_resolution.toIndex(),
        v.guest_os.toIndex(),
        v.audio.toIndex(),
        v.boot_order.toIndex(),
        if (v.enable_kvm) "true" else "false",
        if (v.embed_display) "true" else "false",
        v.vnc_port,
        v.spice_port,
        if (v.favorite) "true" else "false",
    }) catch return "{}";
    w += part2.len;
    return buf[0..w];
}

fn renderJson() ![]const u8 {
    var json_buf: [24576]u8 = undefined;
    var w: usize = 0;
    @memcpy(json_buf[w..][0..1], "[");
    w += 1;
    for (0..vm_count) |i| {
        if (i > 0) { json_buf[w] = ','; w += 1; }
        const v = &vms[i];

        // First block: up through port_forwards
        const part1 = std.fmt.bufPrint(json_buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
        , .{
            i, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
            v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
            std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
            if (v.hasIso()) v.getIsoPathSlice() else "",
            if (v.hasNotes()) v.getNotesSlice() else "",
            if (v.hasSharedFolder()) v.getSharedFolderSlice() else "",
            if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "",
            if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false",
            v.autoprotect_interval_min, v.autoprotect_max,
            if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
            if (v.hasDisk2()) v.getDisk2PathSlice() else "",
            v.disk2_format.toIndex(),
            if (v.hasFloppy()) "true" else "false",
            if (v.hasFloppy()) v.getFloppyPathSlice() else "",
            if (v.hasPortForwards()) v.getPortForwardsSlice() else "",
        }) catch break;
        w += part1.len;

        // Remaining fields
        const part2 = std.fmt.bufPrint(json_buf[w..],
            \\,"mac":"{s}","mac_address":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"enable_kvm":{s},"embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s}}}
        , .{
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            std.mem.span(v.nics[1].mode.toStr()),
            if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
            std.mem.span(v.nics[2].mode.toStr()),
            if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
            v.num_displays,
            if (v.enable_serial) "true" else "false",
            if (v.enable_3d) "true" else "false",
            v.gpu_device.toIndex(),
            v.display.toIndex(),
            v.display_resolution.toIndex(),
            v.guest_os.toIndex(),
            v.audio.toIndex(),
            v.boot_order.toIndex(),
            if (v.enable_kvm) "true" else "false",
            if (v.embed_display) "true" else "false",
            v.vnc_port,
            v.spice_port,
            if (v.favorite) "true" else "false",
        }) catch break;
        w += part2.len;
    }
    json_buf[w] = ']';
    w += 1;
    return json_buf[0..w];
}

fn handlePower(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    // Extract idx from /api/power/N
    const prefix = "POST /api/power/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (v.isAlive()) {
        if (getVmmHandle(idx)) |h| {
            g_vmm.forceStopFn(h);
            g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(v);
            qemu.reapVm(v);
        }
        destroyVmmHandle(idx);
    } else {
        if (getVmmHandle(idx)) |h| {
            g_vmm.startFn(h, @ptrCast(v)) catch {};
        } else {
            qemu.startVm(v, std.heap.page_allocator) catch {};
        }
    }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleNewVm(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    if (vm_count >= MAX_VMS) return "full";
    // Parse body: name=...&mem=...&cpu=...&disk=...
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var cfg = vm.VmConfig{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) cfg.setName(val);
        if (std.mem.eql(u8, key, "mem")) cfg.memory_mb = std.fmt.parseInt(u32, val, 10) catch 2048;
        if (std.mem.eql(u8, key, "cpu")) cfg.cpu_cores = std.fmt.parseInt(u32, val, 10) catch 2;
        if (std.mem.eql(u8, key, "disk")) cfg.disk_size_gb = std.fmt.parseInt(u32, val, 10) catch 20;
    }
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleClone(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    const prefix = "POST /api/clone/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count or vm_count >= MAX_VMS) return "full";
    var clone = vms[idx];
    const src = &vms[idx];
    var name_buf: [256]u8 = undefined;
    const cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{clone.getNameSlice()}) catch return "nameerr";
    clone.setName(cn);
    clone.status = .stopped;
    clone.pid = null;
    clone.vnc_port = 5900 + @as(u16, @intCast(vm_count));
    clone.spice_port = 5930 + @as(u16, @intCast(vm_count));
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    clone.setMacAddress(std.mem.span(mac));

    // Check for linked clone request
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n");
    var linked: bool = false;
    if (body_start) |bs| {
        const body = req[bs + 4 ..];
        if (std.mem.indexOf(u8, body, "linked=1") != null) linked = true;
    }

    if (linked and src.hasDisk()) {
        const home = appio.getenv("HOME") orelse "/tmp";
        var disk_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
        const disk_path = std.fmt.bufPrintZ(&disk_path_buf, "{s}/VMs/{s}.qcow2", .{ home, clone.getNameSlice() }) catch return "nameerr";
        if (getVmmHandle(idx)) |h| {
            g_vmm.createLinkedCloneFn(h, disk_path, src.getDiskPathSlice(), @intFromEnum(src.disk_format), std.heap.page_allocator) catch return "linkerr";
        } else {
            qemu.createLinkedClone(disk_path, src.getDiskPathSlice(), src.disk_format, std.heap.page_allocator) catch return "linkerr";
        }
        clone.setDiskPath(disk_path);
        clone.disk_format = .qcow2;
    }

    vms[vm_count] = clone;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleDelete(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    const prefix = "POST /api/delete/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    // Shift remaining
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) vms[i] = vms[i + 1];
    vm_count -= 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleSave(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    const prefix = "POST /api/save/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const v = &vms[idx];
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) v.setName(val);
        if (std.mem.eql(u8, key, "mem")) v.memory_mb = std.fmt.parseInt(u32, val, 10) catch v.memory_mb;
        if (std.mem.eql(u8, key, "cpu")) v.cpu_cores = std.fmt.parseInt(u32, val, 10) catch v.cpu_cores;
        if (std.mem.eql(u8, key, "cpu_sockets")) v.cpu_sockets = std.fmt.parseInt(u32, val, 10) catch v.cpu_sockets;
        if (std.mem.eql(u8, key, "disk")) v.disk_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk_size_gb;
        if (std.mem.eql(u8, key, "disk_format")) v.disk_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk_format.toIndex());
        if (std.mem.eql(u8, key, "iso_path")) v.setIsoPath(val);
        if (std.mem.eql(u8, key, "mac_address")) v.setMacAddress(val);
        if (std.mem.eql(u8, key, "network")) v.nics[0].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "firmware")) v.firmware = vm.BootFirmware.fromStr(val);
        if (std.mem.eql(u8, key, "shared_folder")) v.setSharedFolder(val);
        if (std.mem.eql(u8, key, "usb")) v.setUsbDevice(val);
        if (std.mem.eql(u8, key, "guest_tools")) v.guest_tools = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "autoprotect")) v.autoprotect = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "ap_interval")) v.autoprotect_interval_min = std.fmt.parseInt(u32, val, 10) catch v.autoprotect_interval_min;
        if (std.mem.eql(u8, key, "ap_max")) v.autoprotect_max = std.fmt.parseInt(u32, val, 10) catch v.autoprotect_max;
        if (std.mem.eql(u8, key, "disk2_path")) v.setDisk2Path(val);
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb;
        if (std.mem.eql(u8, key, "disk2_format")) v.disk2_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk2_format.toIndex());
        if (std.mem.eql(u8, key, "floppy")) v.setFloppyPath(val);
        if (std.mem.eql(u8, key, "nic2")) v.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic2_mac")) v.setNic2Mac(val);
        if (std.mem.eql(u8, key, "nic3")) v.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) v.setNic3Mac(val);
        if (std.mem.eql(u8, key, "portfw")) v.setPortForwards(val);
        if (std.mem.eql(u8, key, "notes")) v.setNotes(val);
        if (std.mem.eql(u8, key, "enable_3d")) v.enable_3d = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "gpu_device")) v.gpu_device = vm.GpuDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.gpu_device.toIndex());
        if (std.mem.eql(u8, key, "display")) v.display = vm.DisplayType.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display.toIndex());
        if (std.mem.eql(u8, key, "display_resolution")) v.display_resolution = vm.DisplayResolution.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display_resolution.toIndex());
        if (std.mem.eql(u8, key, "guest_os")) v.guest_os = vm.GuestOs.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.guest_os.toIndex());
        if (std.mem.eql(u8, key, "audio")) v.audio = vm.AudioDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.audio.toIndex());
        if (std.mem.eql(u8, key, "boot_order")) v.boot_order = vm.BootOrder.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.boot_order.toIndex());
        if (std.mem.eql(u8, key, "enable_kvm")) v.enable_kvm = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "embed_display")) v.embed_display = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "vnc_port")) v.vnc_port = std.fmt.parseInt(u16, val, 10) catch v.vnc_port;
        if (std.mem.eql(u8, key, "spice_port")) v.spice_port = std.fmt.parseInt(u16, val, 10) catch v.spice_port;
        if (std.mem.eql(u8, key, "enable_serial")) v.enable_serial = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = std.fmt.parseInt(u32, val, 10) catch v.num_displays;
        if (std.mem.eql(u8, key, "favorite")) v.favorite = std.mem.eql(u8, val, "1");
    }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn parseIdx(req: []const u8, prefix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn handleSuspend(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/suspend/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";

    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/kvmgui-state-{s}.bin", .{v.getNameSlice()}) catch return "path err";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.suspendToFile(path) catch return "migrate err";
    client.waitMigrateComplete() catch return "timeout";
    v.setSavedStatePath(path[0..]);
    if (getVmmHandle(idx)) |h| {
        g_vmm.forceStopFn(h);
        g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
    }
    destroyVmmHandle(idx);
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handlePause(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/pause/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    if (getVmmHandle(idx)) |h| {
        g_vmm.pauseFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.pause() catch return "qmp err";
    }
    return "ok";
}

fn handleResume(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/resume/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isPaused()) return "not paused";
    if (getVmmHandle(idx)) |h| {
        g_vmm.resumeFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.cont() catch return "qmp err";
    }
    return "ok";
}

fn handleRename(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/rename/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) {
            vms[idx].setName(val);
            persist.save(&vms, vm_count, prefs) catch {};
            return "ok";
        }
    }
    return "no name";
}

fn handleShutdown(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/shutdown/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    if (getVmmHandle(idx)) |h| {
        g_vmm.shutdownFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.powerdown() catch return "qmp err";
    }
    return "ok";
}

fn handleReset(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/reset/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    if (getVmmHandle(idx)) |h| {
        g_vmm.resetFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.systemReset() catch return "qmp err";
    }
    return "ok";
}

fn handleSnapshotTake(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/take/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var tag: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "tag")) {
            tag = val;
        }
    }
    if (tag.len == 0) {
        tag = std.mem.trim(u8, body, " \r\n");
    }
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    } else {
        qemu.snapshotCreate(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    }
    return "ok";
}

fn handleSnapshotList(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "GET /api/snapshot/list/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    var buf: [4096]u8 = undefined;
    const n: usize = if (getVmmHandle(idx)) |h|
        g_vmm.snapshotListFn(h, v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0
    else
        qemu.snapshotList(v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0;
    if (n > 0 and n <= buf.len) return buf[0..n];
    return "(none)";
}

fn handleSnapshotRevert(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/revert/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const tag = std.mem.trim(u8, body, " \r\n");
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotApplyFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    } else {
        qemu.snapshotApply(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    }
    return "ok";
}

fn handleSnapshotDelete(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/delete/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const tag = std.mem.trim(u8, body, " \r\n");
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "delete err";
    } else {
        qemu.snapshotDelete(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "delete err";
    }
    return "ok";
}

fn handleImport(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();

    if (vm_count >= MAX_VMS) return "full";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    // Parse key=value from body (JS sends "path=<encoded-path>")
    var path: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "path")) path = val;
    }
    if (path.len == 0) return "no path";
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const name = blk: {
        const sep = std.mem.lastIndexOfScalar(u8, path, '/');
        const basename = if (sep) |s| path[s + 1 ..] else path;
        const dot = std.mem.lastIndexOfScalar(u8, basename, '.');
        const name_slice = if (dot) |d| basename[0..d] else basename;
        if (name_slice.len >= name_buf.len) break :blk name_buf[0..];
        @memcpy(name_buf[0..name_slice.len], name_slice);
        break :blk name_buf[0..name_slice.len];
    };
    var cfg = vm.VmConfig{};
    cfg.setName(name);
    cfg.setDiskPath(path);
    cfg.disk_size_gb = 20;
    cfg.memory_mb = prefs.default_memory_mb;
    cfg.cpu_cores = prefs.default_cpu_cores;
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleCad(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/cad/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.sendCtrlAltDel() catch return "cad err";
    return "ok";
}

/// Stream the disk2 image file to the client as a download.
fn handleDisk2Download(conn: c.fd_t, req: []const u8) !void {
    const idx = parseIdx(req, "GET /api/vm/") orelse return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.hasDisk2()) return;

    const disk2_path = v.getDisk2PathSlice();
    const fd = c.open(@ptrCast(disk2_path.ptr), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return;
    defer _ = c.close(fd);

    const file_size: u64 = @intCast(c.lseek(fd, 0, 2)); // SEEK_END = 2
    _ = c.lseek(fd, 0, 0); // SEEK_SET = 0

    const basename = std.fs.path.basename(disk2_path);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{basename}) catch return;
    _ = c.write(conn, @ptrCast("HTTP/1.1 200 OK\r\n"), 17);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Origin: *\r\n"), 32);
    _ = c.write(conn, @ptrCast("Content-Type: application/octet-stream\r\n"), 40);
    _ = c.write(conn, @ptrCast("Content-Disposition: "), 21);
    _ = c.write(conn, cd.ptr, cd.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{file_size}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        _ = c.write(conn, &buf, @intCast(n));
    }
}

/// Accept a multipart/form-data file upload for disk2.
fn handleUploadDisk(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/vm/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";

    // Parse multipart boundary from Content-Type header
    const ct_start = std.mem.indexOf(u8, req, "Content-Type: multipart/form-data; boundary=") orelse return "no boundary";
    const bd_val_start = ct_start + "Content-Type: multipart/form-data; boundary=".len;
    const bd_end = std.mem.indexOfScalar(u8, req[bd_val_start..], '\r') orelse req.len;
    const boundary = req[bd_val_start .. bd_val_start + bd_end];

    // Locate body (after double CRLF)
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];

    // Find first boundary
    const first_bd = std.mem.indexOf(u8, body, boundary) orelse return "no boundary in body";
    // Skip boundary line
    var pos = first_bd + boundary.len;
    if (pos + 2 <= body.len and body[pos] == '\r' and body[pos + 1] == '\n') pos += 2;
    if (pos < body.len and body[pos] == '\n') pos += 1;

    // Skip part headers (Content-Disposition, Content-Type)
    while (pos + 1 < body.len) {
        if (body[pos] == '\r' and body[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        if (body[pos] == '\n') {
            pos += 1;
            break;
        }
        pos += 1;
    }

    // Find closing boundary (--boundary--\r\n)
    const end_bd = std.mem.indexOf(u8, body[pos..], boundary) orelse return "no end boundary";
    const file_data = body[pos .. pos + end_bd - 2]; // subtract the leading \r\n of boundary

    // Build destination path: same dir as primary disk, with _disk2 suffix + same extension
    const v = &vms[idx];
    const primary = v.getDiskPathSlice();
    const ext = std.fs.path.extension(primary);
    const dir = std.fs.path.dirname(primary) orelse primary;

    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    if (ext.len > 0 and ext.len < 16) {
        const name_no_ext = primary[dir.len + 1 .. primary.len - ext.len];
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, name_no_ext, ext }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        vms[idx].setDisk2Path(dest);
    } else {
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, primary[dir.len + 1 ..] }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        vms[idx].setDisk2Path(dest);
    }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

/// Create OVF+VMDK export, tar+gzip it, and stream the result as a download.
fn handleExport(conn: c.fd_t, req: []const u8) !void {
    const idx = parseIdx(req, "POST /api/export/") orelse return;
    if (idx >= vm_count) return;
    const v = &vms[idx];

    const dir_path = "/tmp/ovf_export";
    std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {};

    // Remove previous export if any, then recreate
    const tar_path = "/tmp/ovf_export.tar.gz";
    _ = c.unlink(tar_path);
    _ = c.unlink(dir_path); // in case it was a file (won't work on dir, but harmless)
    // Ensure directory is empty
    _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {};

    const vmdk_name = "disk1.vmdk";
    var path_buf: [vm.MAX_PATH]u8 = undefined;
    const vmdk_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, vmdk_name }) catch return;

    const disk_cap: u64 = @as(u64, v.disk_size_gb) * 1024 * 1024 * 1024;
    const spec = ovf.Spec{
        .name = v.getNameSlice(),
        .cpu_cores = v.cpu_cores,
        .memory_mb = v.memory_mb,
        .disk_capacity_bytes = disk_cap,
        .vmdk_href = vmdk_name,
        .vmdk_size_bytes = 0,
        .has_network = v.nics[0].mode != .none,
    };
    const xml = ovf.buildDescriptor(spec, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(xml);

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, v.getNameSlice() });
    defer std.heap.page_allocator.free(ovf_path);
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = ovf_path, .data = xml }) catch return;

    if (getVmmHandle(idx)) |h| {
        g_vmm.convertDiskFn(h, v.getDiskPathSlice(), vmdk_path, @intFromEnum(v.disk_format), std.heap.page_allocator) catch return;
    } else {
        qemu.convertDiskImage(v.getDiskPathSlice(), v.disk_format, vmdk_path, std.heap.page_allocator) catch return;
    }

    // Tar+gzip the export directory
    {
        const tar_argv = [_][]const u8{ "tar", "-czf", tar_path, "-C", dir_path, "." };
        qemu.runWait(&tar_argv, std.heap.page_allocator) catch return;
    }

    // Stream the tar.gz file
    const tar_fd = c.open(tar_path, .{ .ACCMODE = .RDONLY });
    if (tar_fd < 0) return;
    defer _ = c.close(tar_fd);

    const file_size: u64 = @intCast(c.lseek(tar_fd, 0, 2));
    _ = c.lseek(tar_fd, 0, 0);

    const filename = std.fmt.bufPrint(&path_buf, "{s}.ova", .{v.getNameSlice()}) catch "export.ova";
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{filename}) catch return;

    _ = c.write(conn, @ptrCast("HTTP/1.1 200 OK\r\n"), 17);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Origin: *\r\n"), 32);
    _ = c.write(conn, @ptrCast("Content-Type: application/octet-stream\r\n"), 40);
    _ = c.write(conn, @ptrCast("Content-Disposition: "), 21);
    _ = c.write(conn, cd.ptr, cd.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{file_size}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(tar_fd, &buf, buf.len);
        if (n <= 0) break;
        _ = c.write(conn, &buf, @intCast(n));
    }

    // Cleanup
    _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {};
    _ = c.unlink(tar_path);
}

fn getBody(req: []const u8) ?[]const u8 {
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    return req[body_start + 4 ..];
}

fn handleVnetsJson() ![]const u8 {
    const set = vnet.load();
    return vnet.toJson(&set, std.heap.page_allocator);
}

/// Parse key=value body data. Returns empty slice when not found.
fn bodyVal(body: []const u8, key: []const u8) []const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "{s}=", .{key}) catch return "";
    if (std.mem.indexOf(u8, body, pat)) |idx| {
        const start = idx + pat.len;
        const end = std.mem.indexOfScalar(u8, body[start..], '&') orelse body.len;
        return body[start .. start + end];
    }
    return "";
}

fn handleVnetsSave(req: []const u8) ![]const u8 {
    const body = getBody(req) orelse return "no body";
    // Body is raw JSON — parse and save
    var set = vnet.fromJson(body);
    if (set.count == 0) {
        set = vnet.NetworkSet.defaults();
    }
    try vnet.save(&set);
    return "ok";
}

fn handleConfigSave(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const body = getBody(req) orelse return "no body";

    {
        const v = bodyVal(body, "theme");
        if (v.len > 0) prefs.theme = vm.Theme.fromStr(v);
    }
    {
        const v = bodyVal(body, "default_memory_mb");
        if (v.len > 0) prefs.default_memory_mb = std.fmt.parseInt(u32, v, 10) catch prefs.default_memory_mb;
    }
    {
        const v = bodyVal(body, "default_cpu_cores");
        if (v.len > 0) prefs.default_cpu_cores = std.fmt.parseInt(u32, v, 10) catch prefs.default_cpu_cores;
    }
    {
        const v = bodyVal(body, "autoprotect_enabled");
        if (v.len > 0) prefs.autoprotect_enabled_default = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    {
        const v = bodyVal(body, "autoprotect_interval");
        if (v.len > 0) prefs.autoprotect_interval_min_default = std.fmt.parseInt(u32, v, 10) catch prefs.autoprotect_interval_min_default;
    }
    {
        const v = bodyVal(body, "autoprotect_max");
        if (v.len > 0) prefs.autoprotect_max_default = std.fmt.parseInt(u32, v, 10) catch prefs.autoprotect_max_default;
    }

    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

const index_html =
    \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>KVMGUI</title><style>
    \\*{margin:0;padding:0;box-sizing:border-box}body{font:14px system-ui;display:flex;height:100vh;background:#1e1f23;color:#e6e7ea}
    \\aside{width:220px;background:#16171a;padding:10px;overflow-y:auto;display:flex;flex-direction:column}
    \\aside h2{font-size:13px;color:#9aa1ab;margin:10px 0 5px;text-transform:uppercase;letter-spacing:1px}
    \\aside .vm-item{padding:6px 8px;cursor:pointer;border-radius:4px;display:flex;align-items:center;gap:6px;font-size:13px}
    \\aside .vm-item:hover{background:#2c2f36}.vm-item.active{background:#3b82f6;color:#fff}
    \\main{flex:1;padding:20px;overflow-y:auto}
    \\main h1{font-size:24px;margin-bottom:10px}.detail-row{display:flex;gap:10px;padding:6px 0;font-size:13px}
    \\.detail-label{color:#9aa1ab;width:100px}.btn{padding:6px 14px;border:1px solid #3a3e46;background:#2c2f36;color:#e6e7ea;border-radius:5px;cursor:pointer;font-size:13px;margin-right:6px}
    \\.btn:hover{background:#363a42}.btn.primary{background:#3b82f6;border-color:#3b82f6;color:#fff}
    \\.btn.danger{background:#c0392b;border-color:#c0392b;color:#fff}
    \\.toolbar{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
    \\#serialpanel{display:none;background:#0a0a0a;border-radius:8px;margin-bottom:16px;padding:0;overflow:hidden}
    \\#serialterm{width:100%;height:300px;background:#0a0a0a;color:#00ff66;font:13px 'Courier New',monospace;padding:8px;border:none;resize:none;outline:none;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
    \\dialog{border:none;border-radius:8px;padding:20px;background:#1e1f23;color:#e6e7ea;width:400px}
    \\dialog input,select{width:100%;padding:6px;margin:6px 0;background:#16171a;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px}
    \\dialog .btn-row{display:flex;gap:6px;margin-top:12px;justify-content:flex-end}
    \\#statusbar{position:fixed;bottom:0;left:0;right:0;padding:4px 12px;font-size:11px;background:#16171a;color:#9aa1ab}
    \\</style></head><body>
    \\<aside><h2>KVMGUI</h2><input id="search" placeholder="Filter VMs..." style="width:100%;padding:4px 8px;margin-bottom:8px;background:#2c2f36;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px;font-size:12px" oninput="filterList()"><div id="vmlist"></div>
    \\<div style="margin-top:auto"><button class="btn primary" style="width:100%" onclick="newVm()">+ New VM</button></div></aside>
    \\<main><div id="display" style="background:#000;border-radius:8px;margin-bottom:16px;display:none"><canvas id="fbcanvas" width="640" height="480" style="width:100%;max-height:400px"></canvas></div><div id="serialpanel"><textarea id="serialterm" readonly></textarea><div style="display:flex;gap:8px;padding:4px 8px"><button class="btn danger" onclick="manualDisconnectSerial()" style="font-size:11px;padding:2px 8px">Disconnect</button></div></div><div class="toolbar">
    \\<button class="btn primary" onclick="newdlg.showModal()">+ New VM</button>
    \\<button id="powerbtn" class="btn primary" onclick="powerToggle()">▶ Power On</button>
    \\<button class="btn" onclick="pauseGuest()">Pause</button>
    \\<button class="btn" onclick="resumeGuest()">Resume</button>
    \\<button class="btn" onclick="shutdownGuest()">Shut Down</button>
    \\<button class="btn" onclick="resetGuest()">Reset</button>
    \\<button class="btn" onclick="suspendGuest()">Suspend</button>
    \\<button class="btn" onclick="sendCad()">Ctrl+Alt+Del</button>
    \\<button class="btn" onclick="editVm()">Settings</button>
    \\<button class="btn" onclick="renameGuest()">Rename</button>
    \\<button class="btn" onclick="cloneGuest()">Clone</button>
    \\<button class="btn" onclick="importGuest()">Import</button>
    \\<button class="btn" onclick="takeSnapshot()">Snapshot</button>
    \\<button class="btn" onclick="exportOvf()">Export OVF</button>
    \\<button class="btn" onclick="openVnets()">VNet Editor</button>
    \\<button class="btn" onclick="openPrefs()">Preferences</button>
    \\<button class="btn" onclick="batchStart()">▶ Start All</button>
    \\<button class="btn danger" onclick="batchStop()">⏹ Stop All</button>
    \\<button class="btn danger" onclick="deleteVm()">Delete</button>
    \\</div><h1 id="vmname">Select a VM</h1>
    \\<div id="details"></div></main>
    \\<div id="statusbar">Ready</div>
    \\<dialog id="newdlg"><h3>New Virtual Machine</h3>
    \\<input id="n_name" placeholder="VM Name" value="New VM"><input id="n_mem" placeholder="Memory (MB)" type="number" value="2048">
    \\<input id="n_cpu" placeholder="CPU Cores" type="number" value="2"><input id="n_disk" placeholder="Disk (GB)" type="number" value="20">
    \\<div class="btn-row"><button class="btn" onclick="newdlg.close()">Cancel</button><button class="btn primary" onclick="createVm()">Create</button></div></dialog>
    \\<dialog id="editdlg"><h3>Virtual Machine Settings</h3><div style="max-height:70vh;overflow-y:auto">
    \\<label style="font-size:11px;color:#9aa1ab">Name</label><input id="e_name" placeholder="VM Name">
    \\<label style="font-size:11px;color:#9aa1ab">Memory (MB)</label><input id="e_mem" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">CPU Cores</label><input id="e_cpu" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">Disk Size (GB)</label><input id="e_disk" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">Network</label><select id="e_network"><option value="user">NAT (User)</option><option value="bridge">Bridged</option><option value="none">None</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Firmware</label><select id="e_firmware"><option value="bios">BIOS</option><option value="uefi">UEFI</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Shared Folder</label><input id="e_shared" placeholder="/host/path">
    \\<label style="font-size:11px;color:#9aa1ab">USB Device</label><input id="e_usb" placeholder="vendorid:prodid">
    \\<label style="font-size:11px;color:#9aa1ab">Guest Tools</label><select id="e_gt"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">AutoProtect</label><select id="e_ap"><option value="0">Off</option><option value="1">On</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">AP Interval (min)</label><input id="e_apint" type="number" value="60">
    \\<label style="font-size:11px;color:#9aa1ab">AP Max Snapshots</label><input id="e_apmax" type="number" value="10">
    \\<label style="font-size:11px;color:#9aa1ab">Disk 2 Path</label><input id="e_d2path" placeholder="/path/to/disk2.qcow2">
    \\<label style="font-size:11px;color:#9aa1ab">Disk 2 Size (GB)</label><input id="e_d2size" type="number" value="0">
    \\<label style="font-size:11px;color:#9aa1ab">Floppy Path</label><input id="e_floppy" placeholder="/path/to/floppy.img">
    \\<label style="font-size:11px;color:#9aa1ab">NIC 2</label><select id="e_nic2"><option value="none">None</option><option value="user">NAT</option><option value="bridge">Bridged</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">NIC 3</label><select id="e_nic3"><option value="none">None</option><option value="user">NAT</option><option value="bridge">Bridged</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Port Forwards</label><input id="e_pf" placeholder="tcp:2222::22,tcp:8080::80">
    \\<label style="font-size:11px;color:#9aa1ab">Notes</label><input id="e_notes" placeholder="VM notes...">
    \\<label style="font-size:11px;color:#9aa1ab">CPU Sockets</label><input id="e_cpu_sockets" type="number" value="1">
    \\<label style="font-size:11px;color:#9aa1ab">Disk Format</label><select id="e_disk_format"><option value="0">QCOW2</option><option value="1">Raw</option><option value="2">VMDK</option><option value="3">VDI</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">ISO Path</label><input id="e_iso_path" placeholder="/path/to/boot.iso">
    \\<label style="font-size:11px;color:#9aa1ab">MAC Address</label><input id="e_mac_address" placeholder="52:54:00:xx:xx:xx">
    \\<label style="font-size:11px;color:#9aa1ab">NIC 2 MAC</label><input id="e_nic2_mac" placeholder="52:54:00:xx:xx:xx">
    \\<label style="font-size:11px;color:#9aa1ab">NIC 3 MAC</label><input id="e_nic3_mac" placeholder="52:54:00:xx:xx:xx">
    \\<label style="font-size:11px;color:#9aa1ab">Disk 2 Format</label><select id="e_disk2_format"><option value="0">QCOW2</option><option value="1">Raw</option><option value="2">VMDK</option><option value="3">VDI</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">3D Acceleration</label><select id="e_enable_3d"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">GPU Device</label><select id="e_gpu_device"><option value="0">Virtio-GPU (virgl)</option><option value="1">Virtio-VGA (virgl)</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Display</label><select id="e_display"><option value="0">GTK</option><option value="1">SDL</option><option value="2">SPICE</option><option value="3">VNC</option><option value="4">None (headless)</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Display Resolution</label><select id="e_display_resolution"><option value="0">Auto</option><option value="1">800x600</option><option value="2">1024x768</option><option value="3">1280x800</option><option value="4">1920x1080</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Guest OS</label><select id="e_guest_os"><option value="0">Linux</option><option value="1">Microsoft Windows</option><option value="2">FreeBSD</option><option value="3">Apple macOS</option><option value="4">Other</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Audio</label><select id="e_audio"><option value="0">None</option><option value="1">Intel HDA</option><option value="2">AC97</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Boot Order</label><select id="e_boot_order"><option value="0">Hard Disk</option><option value="1">CD/DVD</option><option value="2">Network (PXE)</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">KVM Acceleration</label><select id="e_enable_kvm"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Embed Display</label><select id="e_embed_display"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">VNC Port</label><input id="e_vnc_port" type="number" value="5901">
    \\<label style="font-size:11px;color:#9aa1ab">SPICE Port</label><input id="e_spice_port" type="number" value="5900">
    \\<label style="font-size:11px;color:#9aa1ab">Serial Console</label><select id="e_enable_serial"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Num Displays</label><input id="e_num_displays" type="number" value="1">
    \\<label style="font-size:11px;color:#9aa1ab">Favorite</label><select id="e_favorite"><option value="0">No</option><option value="1">Yes</option></select>
    \\</div><div class="btn-row"><button class="btn" onclick="editdlg.close()">Cancel</button><button class="btn primary" onclick="saveVm()">Save</button></div></dialog>
    \\<dialog id="snapdlg"><h3>Snapshots</h3>
    \\<div style="margin-bottom:10px"><input id="s_tag" placeholder="Snapshot tag" style="width:60%"><button class="btn primary" onclick="takeSnapshotFromDlg()" style="width:35%">Take</button></div>
    \\<div id="snaplist" style="max-height:300px;overflow-y:auto;font-size:13px"><div style="color:#666">Loading...</div></div>
    \\<div class="btn-row"><button class="btn" onclick="snapdlg.close()">Close</button></div></dialog>
    \\<dialog id="clonedlg"><h3>Clone VM</h3>
    \\<p style="margin-bottom:12px;color:#9aa1ab">Choose clone type for <strong id="clone_name"></strong></p>
    \\<div class="btn-row"><button class="btn" onclick="doClone(0)">Full Clone</button><button class="btn primary" onclick="doClone(1)">Linked Clone</button><button class="btn" onclick="clonedlg.close()">Cancel</button></div></dialog>
    \\<dialog id="vnetdlg"><h3>Virtual Network Editor</h3>
    \\<div style="display:flex;gap:10px"><div style="width:40%"><select id="vnet_sel" size="8" style="width:100%;height:200px;background:#16171a;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px" onchange="onVnetSelect()"></select>
    \\<div class="btn-row"><button class="btn" onclick="vnetAdd()">Add</button><button class="btn danger" onclick="vnetRemove()">Remove</button><button class="btn" onclick="vnetDefaults()">Use Defaults</button></div></div>
    \\<div style="width:60%"><label style="font-size:11px;color:#9aa1ab">Name</label><input id="vn_name">
    \\<label style="font-size:11px;color:#9aa1ab">Type</label><select id="vn_type"><option value="bridged">Bridged</option><option value="nat">NAT</option><option value="host_only">Host-only</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Subnet</label><input id="vn_subnet" placeholder="192.168.0.0">
    \\<label style="font-size:11px;color:#9aa1ab">Mask</label><input id="vn_mask" placeholder="255.255.255.0">
    \\<label style="font-size:11px;color:#9aa1ab">DHCP</label><select id="vn_dhcp"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">DHCP Start</label><input id="vn_dstart" placeholder="192.168.0.128">
    \\<label style="font-size:11px;color:#9aa1ab">DHCP End</label><input id="vn_dend" placeholder="192.168.0.254">
    \\<label style="font-size:11px;color:#9aa1ab">Host Interface</label><input id="vn_iface" placeholder="eth0 (bridged only)">
    \\<label style="font-size:11px;color:#9aa1ab">Gateway (NAT only)</label><input id="vn_gw" placeholder="192.168.0.1">
    \\<label style="font-size:11px;color:#9aa1ab">Port Forwards</label><input id="vn_pf" placeholder="2222:192.168.0.128:22">
    \\<div class="btn-row"><button class="btn" onclick="vnetSaveCurrent()">Apply Changes</button></div></div></div>
    \\<div class="btn-row"><button class="btn primary" onclick="vnetSaveAll()">Save & Close</button><button class="btn" onclick="vnetdlg.close()">Cancel</button></div></dialog>
    \\<dialog id="prefsdlg"><h3>Preferences</h3>
    \\<label style="font-size:11px;color:#9aa1ab">Theme</label><select id="p_theme"><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Default Memory (MB)</label><input id="p_mem" type="number" value="2048">
    \\<label style="font-size:11px;color:#9aa1ab">Default CPU Cores</label><input id="p_cpu" type="number" value="2">
    \\<label style="font-size:11px;color:#9aa1ab">AutoProtect</label><select id="p_ap"><option value="0">Off</option><option value="1">On</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">AutoProtect Interval (min)</label><input id="p_apint" type="number" value="60">
    \\<label style="font-size:11px;color:#9aa1ab">AutoProtect Max Snapshots</label><input id="p_apmax" type="number" value="10">
    \\<div class="btn-row"><button class="btn" onclick="prefsdlg.close()">Cancel</button><button class="btn primary" onclick="savePrefs()">Save</button></div></dialog>
    \\<script>
    \\let vms=[]; let sel=null;
    \\function setStatus(s){document.getElementById('statusbar').textContent=s;}
    \\async function apiPost(url,body){try{const r=await fetch(url,{method:'POST',body});if(!r.ok)throw new Error(r.status);return r;}catch(e){setStatus('Error: '+e.message);return null;}}
    \\async function refresh(){try{const r=await fetch('/api/vms');if(!r.ok)return;vms=await r.json();renderList();if(sel!==null&&sel<vms.length)renderDetails();}catch(e){}}
    \\function filterList(){const f=document.getElementById('search').value.toLowerCase();renderList(f);}
    \\function renderList(filter){const e=document.getElementById('vmlist');const f=(filter||'').toLowerCase();let h='';
    \\const viz=vms.map((v,i)=>({i,show:!f||v.name.toLowerCase().includes(f),fav:v.favorite==='true',v}));
    \\let hasFavs=false,hasNon=false;for(const x of viz){if(!x.show)continue;if(x.fav)hasFavs=true;else hasNon=true;}
    \\for(const pass of[0,1]){if(pass===0){for(const x of viz){if(!x.show||!x.fav)continue;
    \\const color=x.v.status==='running'?'#22c55e':x.v.status==='paused'?'#f97316':x.v.status==='suspended'?'#eab308':'#9aa1ab';
    \\const icon=x.v.status==='running'?'▶':x.v.status==='paused'?'⏸':'  ';
    \\h+=`<div class="vm-item${sel===x.i?' active':''}" onclick="select(${x.i})"><span style="color:${color};font-weight:bold">${icon}</span> ${x.v.name}<span style="margin-left:auto;cursor:pointer;color:#fbbf24" onclick="event.stopPropagation();toggleFavorite(${x.i})">★</span></div>`;}}
    \\if(hasFavs&&hasNon)h+='<div style="color:#555;font-size:11px;padding:4px 8px;border-bottom:1px solid #333;margin:4px 0">──────────</div>';
    \\if(pass===1){for(const x of viz){if(!x.show||x.fav)continue;
    \\const color=x.v.status==='running'?'#22c55e':x.v.status==='paused'?'#f97316':x.v.status==='suspended'?'#eab308':'#9aa1ab';
    \\const icon=x.v.status==='running'?'▶':x.v.status==='paused'?'⏸':'  ';
    \\h+=`<div class="vm-item${sel===x.i?' active':''}" onclick="select(${x.i})"><span style="color:${color};font-weight:bold">${icon}</span> ${x.v.name}<span style="margin-left:auto;cursor:pointer;color:#555" onclick="event.stopPropagation();toggleFavorite(${x.i})">★</span></div>`;}}}
    \\e.innerHTML=h||'<div style="color:#666;font-size:12px">No VMs</div>';
    \\let cnt=0,running=0,paused=0,suspended=0;for(let v of vms){cnt++;if(v.status==='running')running++;else if(v.status==='paused')paused++;else if(v.status==='suspended')suspended++;}
    \\let parts=cnt+' virtual machine(s)';if(running>0)parts+=', '+running+' running';if(paused>0)parts+=', '+paused+' paused';if(suspended>0)parts+=', '+suspended+' suspended';
    \\if(sel!==null&&sel<vms.length){const v=vms[sel];document.getElementById('statusbar').textContent=v.name+' — '+v.status+'    |    '+parts;}
    \\else document.getElementById('statusbar').textContent=parts;}
    \\async function toggleFavorite(i){if(i>=vms.length)return;const v=vms[i];const fav=v.favorite==='true'?'0':'1';
    \\const r=await apiPost('/api/save/'+i,'favorite='+fav);if(r){v.favorite=fav==='1'?'true':'false';renderList();if(sel===i)renderDetails();}}
    \\function select(i){sel=i;renderList();renderDetails();}
    \\function renderDetails(){if(sel===null||sel>=vms.length){document.getElementById('vmname').textContent='Select a VM';document.getElementById('details').innerHTML='';return;}
    \\const v=vms[sel];const sc=v.status==='running'?'#22c55e':v.status==='paused'?'#f97316':v.status==='suspended'?'#eab308':'#9aa1ab';
    \\document.getElementById('vmname').textContent=v.name;
    \\let h=`<div class="detail-row"><span class="detail-label">State</span><span style="color:${sc};font-weight:bold">${v.status}</span></div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Guest OS</span>${v.os}</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Memory</span>${v.mem} MB</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">CPU</span>${v.cpu} cores</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Hard Disk</span>${v.disk} GB (${v.fw})</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Network</span>${v.net}</div>`;
    \\if(v.mac)h+=`<div class="detail-row"><span class="detail-label">MAC</span>${v.mac}</div>`;
    \\if(v.nic2_mode&&v.nic2_mode!=='none')h+=`<div class="detail-row"><span class="detail-label">NIC 2</span>${v.nic2_mode}</div>`;
    \\if(v.nic3_mode&&v.nic3_mode!=='none')h+=`<div class="detail-row"><span class="detail-label">NIC 3</span>${v.nic3_mode}</div>`;
    \\if(v.shared_folder)h+=`<div class="detail-row"><span class="detail-label">Shared Folder</span>${v.shared_folder}</div>`;
    \\if(v.usb_device)h+=`<div class="detail-row"><span class="detail-label">USB Device</span>${v.usb_device}</div>`;
    \\if(v.guest_tools==='true')h+=`<div class="detail-row"><span class="detail-label">Guest Tools</span>✓ installed</div>`;
    \\if(v.autoprotect==='true')h+=`<div class="detail-row"><span class="detail-label">AutoProtect</span>every ${v.autoprotect_interval} min, keep ${v.autoprotect_max}</div>`;
    \\if(v.hasDisk2==='true')h+=`<div class="detail-row"><span class="detail-label">Disk 2</span>${v.disk2_size} GB</div>`;
    \\if(v.hasFloppy==='true')h+=`<div class="detail-row"><span class="detail-label">Floppy</span>attached</div>`;
    \\if(v.port_forwards)h+=`<div class="detail-row"><span class="detail-label">Port Fwds</span>${v.port_forwards}</div>`;
    \\if(v.notes)h+=`<div class="detail-row"><span class="detail-label">Notes</span>${v.notes}</div>`;
    \\document.getElementById('details').innerHTML=h;updatePowerBtn();}
    \\async function powerToggle(){if(sel===null)return;const r=await apiPost('/api/power/'+sel);if(r)refresh();}
    \\async function shutdownGuest(){if(sel===null)return;const r=await apiPost('/api/shutdown/'+sel);if(r)setStatus('Shut down guest — ACPI power button sent.');}
    \\async function resetGuest(){if(sel===null)return;const r=await apiPost('/api/reset/'+sel);if(r)setStatus('Reset guest — system_reset sent.');}
    \\async function pauseGuest(){if(sel===null)return;const r=await apiPost('/api/pause/'+sel);if(r){refresh();setStatus('Paused guest — execution frozen.');}}
    \\async function resumeGuest(){if(sel===null)return;const r=await apiPost('/api/resume/'+sel);if(r){refresh();setStatus('Resumed guest — execution continued.');}}
    \\async function renameGuest(){if(sel===null)return;const v=vms[sel];const n=prompt('Rename VM:',v.name);if(n&&n!==v.name){const r=await apiPost('/api/rename/'+sel,'name='+encodeURIComponent(n));if(r)refresh();}}
    \\async function suspendGuest(){if(sel===null)return;const r=await apiPost('/api/suspend/'+sel);if(r){refresh();setStatus('Suspended VM to disk.');}}
    \\async function cloneGuest(){if(sel===null)return;document.getElementById('clone_name').textContent=vms[sel].name;document.getElementById('clonedlg').showModal();}
    \\async function doClone(linked){if(sel===null)return;document.getElementById('clonedlg').close();const body=linked?'linked=1':'';const r=await apiPost('/api/clone/'+sel,body);if(r){refresh();setStatus(linked?'Linked clone created.':'VM cloned.');}}
    \\async function importGuest(){const p=prompt('Path to VM disk image (.qcow2):');if(p){const r=await apiPost('/api/import','path='+encodeURIComponent(p));if(r){refresh();setStatus('VM imported.');}}}
    \\async function batchStart(){for(let i=0;i<vms.length;i++){if(vms[i].status==='stopped'){await apiPost('/api/power/'+i);}}refresh();setStatus('Batch start complete.');}
    \\async function batchStop(){for(let i=0;i<vms.length;i++){if(vms[i].status==='running'||vms[i].status==='paused'){await apiPost('/api/power/'+i);}}refresh();setStatus('Batch stop complete.');}
    \\async function takeSnapshot(){if(sel===null)return;openSnapshots();}
    \\async function takeSnapshotFromDlg(){if(sel===null)return;const t=document.getElementById('s_tag').value;if(!t){alert('Enter a tag name');return;}
    \\const r=await apiPost('/api/snapshot/take/'+sel,'tag='+encodeURIComponent(t));if(r){document.getElementById('s_tag').value='';loadSnapshots();setStatus('Snapshot taken: '+t);}}
    \\async function openSnapshots(){if(sel===null)return;document.getElementById('snapdlg').showModal();loadSnapshots();}
    \\async function loadSnapshots(){if(sel===null)return;const r=await fetch('/api/snapshot/list/'+sel);const t=await r.text();
    \\const el=document.getElementById('snaplist');if(!t||t==='(none)'){el.innerHTML='<div style="color:#666">No snapshots</div>';return;}
    \\const lines=t.split('\\n');let h='';for(const ln of lines){if(!ln.trim())continue;if(/^\\s*(ID|Snapshot)\\s/.test(ln))continue;const parts=ln.trim().split(/\\s+/);const tag=parts[1]||ln;const rest=parts.slice(2).join(' ');
    \\h+=`<div style="padding:4px 0;border-bottom:1px solid #333;display:flex;justify-content:space-between;align-items:center"><span title="${rest}">${tag}</span><span><button class="btn" style="padding:2px 8px;font-size:11px" onclick="revertSnapshot('${tag}')">Revert</button><button class="btn danger" style="padding:2px 8px;font-size:11px" onclick="deleteSnapshot('${tag}')">Del</button></span></div>`;}
    \\el.innerHTML=h;}
    \\async function revertSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Revert to snapshot "'+tag+'"? This will discard current state.'))return;
    \\const r=await apiPost('/api/snapshot/revert/'+sel,'tag='+encodeURIComponent(tag));if(r){setStatus('Reverted to snapshot: '+tag);snapdlg.close();}}
    \\async function deleteSnapshot(tag){if(sel===null||!tag)return;if(!confirm('Delete snapshot "'+tag+'"?'))return;
    \\const r=await apiPost('/api/snapshot/delete/'+sel,'tag='+encodeURIComponent(tag));if(r){loadSnapshots();setStatus('Deleted snapshot: '+tag);}}
    \\async function sendCad(){if(sel===null)return;const r=await apiPost('/api/cad/'+sel);if(r)setStatus('Ctrl+Alt+Del sent to guest.');}
    \\async function exportOvf(){if(sel===null)return;try{const r=await fetch('/api/export/'+sel,{method:'POST',headers:{'X-API-Key':'kvmgui'}});if(!r.ok){setStatus('Export failed: '+r.status);return;}const blob=await r.blob();const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=vms[sel].name+'.ova';a.click();setStatus('Export downloaded.');}catch(e){setStatus('Export error: '+e);}}
    \\function updatePowerBtn(){const b=document.getElementById('powerbtn');if(sel===null||sel>=vms.length){b.textContent='▶ Power On';b.className='btn primary';return;}
    \\const v=vms[sel];if(v.status==='running'||v.status==='paused'){b.textContent='⏹ Power Off';b.className='btn danger';}else{b.textContent='▶ Power On';b.className='btn primary';}}
    \\function newVm(){document.getElementById('newdlg').showModal();}
    \\async function createVm(){const n=document.getElementById('n_name').value;const m=document.getElementById('n_mem').value;
    \\const c=document.getElementById('n_cpu').value;const d=document.getElementById('n_disk').value;
    \\const r=await apiPost('/api/new','name='+encodeURIComponent(n)+'&mem='+m+'&cpu='+c+'&disk='+d);if(r){document.getElementById('newdlg').close();refresh();}}
    \\async function deleteVm(){if(sel===null)return;if(!confirm('Delete this VM?'))return;const r=await apiPost('/api/delete/'+sel);if(r){sel=null;refresh();}}
    \\function editVm(){if(sel===null)return;const v=vms[sel];
    \\document.getElementById('e_name').value=v.name||'';document.getElementById('e_mem').value=v.mem||2048;
    \\document.getElementById('e_cpu').value=v.cpu||2;document.getElementById('e_disk').value=v.disk||20;
    \\document.getElementById('e_network').value=v.net||'user';document.getElementById('e_firmware').value=v.fw||'bios';
    \\document.getElementById('e_shared').value=v.shared_folder||'';document.getElementById('e_usb').value=v.usb_device||'';
    \\document.getElementById('e_gt').value=v.guest_tools==='true'?'1':'0';document.getElementById('e_ap').value=v.autoprotect==='true'?'1':'0';
    \\document.getElementById('e_apint').value=v.autoprotect_interval||60;document.getElementById('e_apmax').value=v.autoprotect_max||10;
    \\document.getElementById('e_d2path').value=v.disk2_path||'';document.getElementById('e_d2size').value=v.disk2_size||0;
    \\document.getElementById('e_floppy').value=v.floppy_path||'';document.getElementById('e_nic2').value=v.nic2_mode||'none';
    \\document.getElementById('e_nic3').value=v.nic3_mode||'none';document.getElementById('e_pf').value=v.port_forwards||'';
    \\document.getElementById('e_notes').value=v.notes||'';
    \\document.getElementById('e_cpu_sockets').value=v.cpu_sockets||1;document.getElementById('e_disk_format').value=v.disk_format||0;
    \\document.getElementById('e_iso_path').value=v.iso_path||'';document.getElementById('e_mac_address').value=v.mac_address||'';
    \\document.getElementById('e_disk2_format').value=v.disk2_format||0;document.getElementById('e_enable_3d').value=v.enable_3d==='true'?'1':'0';
    \\document.getElementById('e_gpu_device').value=v.gpu_device||0;document.getElementById('e_display').value=v.display||0;
    \\document.getElementById('e_display_resolution').value=v.display_resolution||0;document.getElementById('e_guest_os').value=v.guest_os||0;
    \\document.getElementById('e_audio').value=v.audio||0;document.getElementById('e_boot_order').value=v.boot_order||0;
    \\document.getElementById('e_enable_kvm').value=v.enable_kvm==='true'?'1':'0';document.getElementById('e_embed_display').value=v.embed_display==='true'?'1':'0';
    \\document.getElementById('e_vnc_port').value=v.vnc_port||5900;document.getElementById('e_spice_port').value=v.spice_port||5901;
    \\document.getElementById('e_enable_serial').value=v.enable_serial==='true'?'1':'0';document.getElementById('e_num_displays').value=v.num_displays||1;
    \\document.getElementById('e_favorite').value=v.favorite==='true'?'1':'0';document.getElementById('e_nic2_mac').value=v.nic2_mac||'';
    \\document.getElementById('e_nic3_mac').value=v.nic3_mac||'';document.getElementById('editdlg').showModal();}
    \\async function saveVm(){if(sel===null)return;
    \\const body=['name','mem','cpu','cpu_sockets','disk','disk_format','iso_path','mac_address','network','firmware','shared_folder','usb','guest_tools','autoprotect',
    \\'ap_interval','ap_max','disk2_path','disk2_size','disk2_format','floppy','nic2','nic2_mac','nic3','nic3_mac','portfw','notes',
    \\'enable_3d','gpu_device','display','display_resolution','guest_os','audio','boot_order',
    \\'enable_kvm','embed_display','vnc_port','spice_port','enable_serial','num_displays','favorite']
    \\.map(id=>{const el=document.getElementById('e_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
    \\const r=await apiPost('/api/save/'+sel,body);if(r){document.getElementById('editdlg').close();refresh();}
    \\// ── VNet Editor ──
    \\let vnetsData=[],vnetIdx=-1;
    \\async function openVnets(){await loadVnets();document.getElementById('vnetdlg').showModal();}
    \\async function loadVnets(){const r=await fetch('/api/vnets');if(r.ok)vnetsData=await r.json();renderVnetList();}
    \\function renderVnetList(){const sel=document.getElementById('vnet_sel');let h='';if(!vnetsData.networks)vnetsData={networks:[]};
    \\for(let i=0;i<vnetsData.networks.length;i++){const n=vnetsData.networks[i];const line=n.name+' — '+n.type;h+=`<option value="${i}"${i===vnetIdx?' selected':''}>${line}</option>`;}
    \\sel.innerHTML=h;if(vnetIdx>=0&&vnetIdx<vnetsData.networks.length)showVnetFields(vnetIdx);}
    \\function onVnetSelect(){const s=document.getElementById('vnet_sel');vnetIdx=parseInt(s.value);if(vnetIdx>=0)showVnetFields(vnetIdx);}
    \\function showVnetFields(i){const n=vnetsData.networks[i];if(!n)return;
    \\document.getElementById('vn_name').value=n.name||'';document.getElementById('vn_type').value=n.type||'nat';
    \\document.getElementById('vn_subnet').value=n.subnet||'';document.getElementById('vn_mask').value=n.mask||'';
    \\document.getElementById('vn_dhcp').value=n.dhcp?'1':'0';document.getElementById('vn_dstart').value=n.dhcp_start||'';
    \\document.getElementById('vn_dend').value=n.dhcp_end||'';document.getElementById('vn_iface').value=n.host_iface||'';
    \\document.getElementById('vn_gw').value=n.gateway||'';document.getElementById('vn_pf').value=n.port_forwards||'';}
    \\function vnetSaveCurrent(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;const n=vnetsData.networks[vnetIdx];
    \\n.name=document.getElementById('vn_name').value;n.type=document.getElementById('vn_type').value;
    \\n.subnet=document.getElementById('vn_subnet').value;n.mask=document.getElementById('vn_mask').value;
    \\n.dhcp=document.getElementById('vn_dhcp').value==='1';n.dhcp_start=document.getElementById('vn_dstart').value;
    \\n.dhcp_end=document.getElementById('vn_dend').value;n.host_iface=document.getElementById('vn_iface').value;
    \\n.gateway=document.getElementById('vn_gw').value;n.port_forwards=document.getElementById('vn_pf').value;renderVnetList();}
    \\function vnetAdd(){if(vnetsData.networks.length>=20)return;const n={name:'VMnet'+vnetsData.networks.length,type:'host_only',subnet:'192.168.100.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.100.128',dhcp_end:'192.168.100.254',host_iface:'',gateway:'',port_forwards:''};
    \\vnetsData.networks.push(n);vnetIdx=vnetsData.networks.length-1;renderVnetList();}
    \\function vnetRemove(){if(vnetIdx<0||vnetIdx>=vnetsData.networks.length)return;vnetsData.networks.splice(vnetIdx,1);if(vnetIdx>=vnetsData.networks.length)vnetIdx=vnetsData.networks.length-1;renderVnetList();}
    \\function vnetDefaults(){const def=[{name:'VMnet0',type:'bridged',subnet:'',mask:'',dhcp:false,dhcp_start:'',dhcp_end:'',host_iface:'auto',gateway:'',port_forwards:''},{name:'VMnet1',type:'host_only',subnet:'192.168.118.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.118.128',dhcp_end:'192.168.118.254',host_iface:'',gateway:'',port_forwards:''},{name:'VMnet8',type:'nat',subnet:'192.168.140.0',mask:'255.255.255.0',dhcp:true,dhcp_start:'192.168.140.128',dhcp_end:'192.168.140.254',host_iface:'',gateway:'192.168.140.2',port_forwards:'2222:192.168.140.128:22'}];
    \\vnetsData={networks:def};vnetIdx=0;renderVnetList();}
    \\async function vnetSaveAll(){const r=await apiPost('/api/vnets/save',JSON.stringify(vnetsData));if(r){document.getElementById('vnetdlg').close();setStatus('VNet settings saved.');}}
    \\// ── Preferences ──
    \\async function openPrefs(){const r=await fetch('/api/config');const cfg=r.ok?await r.json():{};
    \\document.getElementById('p_theme').value=cfg.theme||'system';document.getElementById('p_mem').value=cfg.default_memory_mb||2048;
    \\document.getElementById('p_cpu').value=cfg.default_cpu_cores||2;document.getElementById('p_ap').value=cfg.autoprotect_enabled_default?'1':'0';
    \\document.getElementById('p_apint').value=cfg.autoprotect_interval_min_default||60;document.getElementById('p_apmax').value=cfg.autoprotect_max_default||10;
    \\document.getElementById('prefsdlg').showModal();}
    \\async function savePrefs(){const body=['theme','default_memory_mb','default_cpu_cores','autoprotect_enabled','autoprotect_interval','autoprotect_max']
    \\.map(id=>{const el=document.getElementById('p_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
    \\const r=await apiPost('/api/config',body);if(r){document.getElementById('prefsdlg').close();setStatus('Preferences saved.');}}
    \\refresh();
    \\setInterval(refresh,5000);
    \\// WebGPU/Canvas2D framebuffer display
    \\let fbCanvas=document.getElementById('fbcanvas'),fbCtx=fbCanvas.getContext('2d'),fbInterval=null;
    \\async function startFb(){if(sel===null){document.getElementById('display').style.display='none';if(fbInterval)clearInterval(fbInterval);return;}
    \\document.getElementById('display').style.display='block';
    \\if(fbInterval)clearInterval(fbInterval);fbInterval=setInterval(async()=>{if(sel===null||sel>=vms.length)return;const v=vms[sel];if(v.status!=='running')return;
    \\try{const r=await fetch('/api/fb/'+sel);if(!r.ok)return;const buf=await r.arrayBuffer();if(buf.byteLength<100)return;const w=640,h=480;fbCanvas.width=w;fbCanvas.height=h;
    \\const img=fbCtx.createImageData(w,h);const src=new Uint8Array(buf);const dst=img.data;for(let i=0;i<w*h;i++){const o=i*4;dst[o]=src[o+2];dst[o+1]=src[o+1];dst[o+2]=src[o];dst[o+3]=255;}
    \\fbCtx.putImageData(img,0,0);}catch(e){}},200)};
    \\setInterval(()=>{if(sel!==null&&sel<vms.length&&vms[sel].status==='running')startFb();},2000);
    \\// Serial console
    \\let serialWs=null,serialIdx=null,serialManualOff=false;
    \\function startSerial(idx){if(serialManualOff)return;if(serialWs&&serialIdx===idx)return;stopSerial();
    \\if(idx===null||idx>=vms.length)return;const v=vms[idx];if(v.status!=='running'||!v.hasSerial)return;
    \\serialIdx=idx;const term=document.getElementById('serialterm');term.value='';document.getElementById('serialpanel').style.display='block';
    \\const proto=location.protocol==='https:'?'wss:':'ws:';serialWs=new WebSocket(proto+'//'+location.host+'/ws/serial/'+idx);
    \\serialWs.onmessage=e=>{term.value+=e.data;term.scrollTop=term.scrollHeight;};
    \\serialWs.onclose=()=>{stopSerial();};
    \\serialWs.onerror=()=>{stopSerial();};}
    \\function stopSerial(){if(serialWs){serialWs.close();serialWs=null;}serialIdx=null;document.getElementById('serialpanel').style.display='none';}
    \\function manualDisconnectSerial(){serialManualOff=true;stopSerial();}
    \\document.getElementById('serialterm').addEventListener('keydown',e=>{if(!serialWs||serialWs.readyState!==WebSocket.OPEN)return;
    \\e.preventDefault();let s=e.key;if(e.key==='Enter')s='\r\n';else if(e.key==='Backspace')s='\x08';else if(e.key==='Tab')s='\t';
    \\if(s.length===1||s==='\r\n'||s==='\x08'||s==='\t')serialWs.send(s);});
    \\setInterval(()=>{if(sel!==null&&sel<vms.length){const v=vms[sel];if(serialManualOff&&serialIdx!==sel)serialManualOff=false;if(v.status==='running'&&v.hasSerial)startSerial(sel);else stopSerial();}},3000);
    \\</script></body></html>
;

/// Background thread: periodically take AutoProtect snapshots for VMs that have it enabled.
fn autoprotectTicker() void {
    while (true) {
        appio.sleepMs(30_000);
        const now = time(null);
        var i: usize = 0;
        while (i < vm_count) : (i += 1) {
            const v = &vms[i];
            if (!v.autoprotect or v.status != .running or !v.hasDisk()) continue;
            if (!autoprotect.due(true, v.autoprotect_interval_min, v.autoprotect_last_epoch, now)) continue;

            const seq = v.autoprotect_last_seq;
            v.autoprotect_last_seq = seq +% 1; // wrapping add
            v.autoprotect_last_epoch = now;

            var name_buf: [40]u8 = undefined;
            const snap_name = autoprotect.snapName(&name_buf, seq);

            // Take snapshot via HV abstraction, fall back to qemu CLI
            if (getVmmHandle(i)) |h| {
                g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch continue;
            } else {
                qemu.snapshotCreate(v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch continue;
            }

            // Prune excess AutoProtect snapshots
            var list_buf: [4096]u8 = undefined;
            const list_n: usize = if (getVmmHandle(i)) |h|
                g_vmm.snapshotListFn(h, v.getDiskPathSlice(), &list_buf, std.heap.page_allocator) catch continue
            else
                qemu.snapshotList(v.getDiskPathSlice(), &list_buf, std.heap.page_allocator) catch continue;

            if (list_n == 0 or list_n > list_buf.len) continue;
            const list_str = list_buf[0..list_n];

            // Count AutoProtect snapshots and collect oldest names
            var auto_names: [32][]const u8 = undefined;
            var auto_count: usize = 0;
            var lines = std.mem.splitSequence(u8, list_str, "\n");
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r");
                if (trimmed.len == 0) continue;
                const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
                const name = trimmed[0..space];
                if (autoprotect.isAutoName(name)) {
                    if (auto_count < auto_names.len) {
                        auto_names[auto_count] = name;
                    }
                    auto_count += 1;
                }
            }

            const excess = autoprotect.pruneExcess(auto_count, v.autoprotect_max);
            // Delete the oldest AutoProtect snapshots (they come first in the list)
            var d: usize = 0;
            while (d < excess and d < auto_names.len) : (d += 1) {
                if (getVmmHandle(i)) |h| {
                    g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), auto_names[d], std.heap.page_allocator) catch {};
                } else {
                    qemu.snapshotDelete(v.getDiskPathSlice(), auto_names[d], std.heap.page_allocator) catch {};
                }
            }

            persist.save(&vms, vm_count, prefs) catch {};
        }
    }
}

pub fn main() !void {
    vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);
    g_vmm = hv_backend.createVmm(.auto);

    const sock = c.socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;
    defer _ = c.close(sock);

    const one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

    // Bind to 0.0.0.0 — accessible locally and remotely
    const bind_ip: u32 = (@as(u32, BIND_ADDR[0]) << 24) | (@as(u32, BIND_ADDR[1]) << 16) | (@as(u32, BIND_ADDR[2]) << 8) | @as(u32, BIND_ADDR[3]);
    var addr: c.sockaddr.in = .{ .family = AF_INET, .port = std.mem.nativeToBig(u16, PORT), .addr = std.mem.nativeToBig(u32, bind_ip), .zero = [_]u8{0} ** 8 };
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return;
    if (c.listen(sock, 10) != 0) return;

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/kvmgui-daemon.sock";
    _ = c.unlink(unix_path);
    const unix_sock = c.socket(AF_UNIX, SOCK_STREAM, 0);
    var unix_addr: c.sockaddr.un = .{ .family = AF_UNIX, .path = undefined };
    @memcpy(unix_addr.path[0..unix_path.len], unix_path);
    unix_addr.path[unix_path.len] = 0;
    const unix_len = @offsetOf(c.sockaddr.un, "path") + unix_path.len + 1;
    _ = c.setsockopt(unix_sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    _ = c.bind(unix_sock, @ptrCast(&unix_addr), @intCast(unix_len));
    _ = c.listen(unix_sock, 10);

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  KVMGUI Daemon v1.0                         ║\n", .{});
    std.debug.print("║  TCP:   http://0.0.0.0:{d}                 ║\n", .{PORT});
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    // Spawn thread to accept Unix socket connections
    _ = std.Thread.spawn(std.Thread.SpawnConfig{}, acceptLoop, .{ unix_sock }) catch {};

    // Spawn autoprotect background ticker
    _ = std.Thread.spawn(std.Thread.SpawnConfig{}, autoprotectTicker, .{}) catch {};

    while (true) {
        const conn = c.accept(sock, null, null);
        if (conn < 0) continue;
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
        th.detach();
    }
}
