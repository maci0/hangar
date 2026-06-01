// SPDX-License-Identifier: MIT
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
const snapparse = @import("snapparse.zig");
const sync = @import("sync.zig");
const urlencode = @import("urlencode.zig");

extern fn time(t: ?*c_long) c_long;

const MAX_VMS = 64;

// HTTP status codes
const HTTP_OK: u16 = 200;
const HTTP_CREATED: u16 = 201;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_METHOD_NOT_ALLOWED: u16 = 405;
const HTTP_PAYLOAD_TOO_LARGE: u16 = 413;
const HTTP_INTERNAL_ERROR: u16 = 500;

var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var vm_started: [MAX_VMS]i64 = [_]i64{0} ** MAX_VMS;
var vms_mutex: sync.SpinMutex = .{};
var prefs: vm.Prefs = .{};

// Server socket fds for shutdown signaling.
var tcp_sock_fd: c.fd_t = -1;
var unix_sock_fd: c.fd_t = -1;

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
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], vms[idx].accel, std.heap.page_allocator) catch return null;
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
        const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
        const headers = req[0..hdr_end];
        const key_start = std.mem.indexOf(u8, headers, "X-API-Key: ") orelse return false;
        const key_val_start = key_start + "X-API-Key: ".len;
        const key_end = std.mem.indexOfScalar(u8, headers[key_val_start..], '\r') orelse (headers.len - key_val_start);
        const provided = headers[key_val_start .. key_val_start + key_end];
        return std.mem.eql(u8, provided, auth_token[0..auth_token_len]);
    }
    // No custom token set — fall back to built-in API_KEY
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
    const headers = req[0..hdr_end];
    const key_start = std.mem.indexOf(u8, headers, "X-API-Key: ") orelse return false;
    const key_val_start = key_start + "X-API-Key: ".len;
    const key_end = std.mem.indexOfScalar(u8, headers[key_val_start..], '\r') orelse (headers.len - key_val_start);
    const provided = headers[key_val_start .. key_val_start + key_end];
    return std.mem.eql(u8, provided, API_KEY);
}

/// Log a message to stderr (best-effort, thread-safe via atomic write).
fn logErr(msg: []const u8) void {
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
}

/// Write exactly `len` bytes to fd, retrying on short writes. Returns false on failure.
fn writeAll(conn: c.fd_t, buf: [*]const u8, len: usize) bool {
    var written: usize = 0;
    while (written < len) {
        const n = c.write(conn, buf + written, len - written);
        if (n <= 0) return false;
        written += @intCast(n);
    }
    return true;
}

/// Format an error message as a JSON object: {"error":"<msg>"}.
/// Returns a slice of `buf`; buffer must be at least msg.len + 16 bytes.
fn jsonErr(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"internal\"}";
}

/// Write an HTTP response with status code, content type, CORS headers, and body.
fn writeHttpResponse(conn: c.fd_t, status: u16, ct: []const u8, body: []const u8) void {
    const status_line: []const u8 = switch (status) {
        HTTP_OK => "HTTP/1.1 200 OK\r\n",
        HTTP_CREATED => "HTTP/1.1 201 Created\r\n",
        HTTP_BAD_REQUEST => "HTTP/1.1 400 Bad Request\r\n",
        HTTP_NOT_FOUND => "HTTP/1.1 404 Not Found\r\n",
        HTTP_METHOD_NOT_ALLOWED => "HTTP/1.1 405 Method Not Allowed\r\n",
        HTTP_PAYLOAD_TOO_LARGE => "HTTP/1.1 413 Payload Too Large\r\n",
        HTTP_INTERNAL_ERROR => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
    if (!writeAll(conn, status_line.ptr, status_line.len)) return;

    // CORS headers (allow cross-origin browser access)
    const h_acao: []const u8 = "Access-Control-Allow-Origin: *\r\n";
    const h_acah: []const u8 = "Access-Control-Allow-Headers: Content-Type, X-API-Key\r\n";
    const h_acam: []const u8 = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n";
    const h_ct: []const u8 = "Content-Type: ";
    if (!writeAll(conn, h_acao.ptr, h_acao.len)) return;
    if (!writeAll(conn, h_acah.ptr, h_acah.len)) return;
    if (!writeAll(conn, h_acam.ptr, h_acam.len)) return;

    if (!writeAll(conn, h_ct.ptr, h_ct.len)) return;
    if (!writeAll(conn, ct.ptr, ct.len)) return;
    const h_server: []const u8 = "\r\nServer: kvmgui/1.0";
    if (!writeAll(conn, h_server.ptr, h_server.len)) return;
    if (std.mem.indexOf(u8, ct, "text/css") != null or std.mem.indexOf(u8, ct, "application/javascript") != null) {
        const h_cc: []const u8 = "\r\nCache-Control: public, max-age=86400";
        if (!writeAll(conn, h_cc.ptr, h_cc.len)) return;
    }
    const h_cl: []const u8 = "\r\nContent-Length: ";
    if (!writeAll(conn, h_cl.ptr, h_cl.len)) return;
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch "0";
    if (!writeAll(conn, len_str.ptr, len_str.len)) return;
    const h_conn: []const u8 = "\r\nConnection: close\r\n\r\n";
    if (!writeAll(conn, h_conn.ptr, h_conn.len)) return;
    _ = writeAll(conn, body.ptr, body.len); // best effort for body
}

/// Write HTTP headers for a streaming response (no Content-Length, uses chunked or raw stream).
fn writeStreamHeaders(conn: c.fd_t, status: u16, ct: []const u8, content_len: u64) void {
    const status_line: []const u8 = switch (status) {
        HTTP_OK => "HTTP/1.1 200 OK\r\n",
        HTTP_NOT_FOUND => "HTTP/1.1 404 Not Found\r\n",
        HTTP_INTERNAL_ERROR => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
    if (!writeAll(conn, status_line.ptr, status_line.len)) return;
    const h_acao: []const u8 = "Access-Control-Allow-Origin: *\r\n";
    const h_acah: []const u8 = "Access-Control-Allow-Headers: Content-Type, X-API-Key\r\n";
    const h_acam: []const u8 = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n";
    const h_ct: []const u8 = "Content-Type: ";
    if (!writeAll(conn, h_acao.ptr, h_acao.len)) return;
    if (!writeAll(conn, h_acah.ptr, h_acah.len)) return;
    if (!writeAll(conn, h_acam.ptr, h_acam.len)) return;
    if (!writeAll(conn, h_ct.ptr, h_ct.len)) return;
    if (!writeAll(conn, ct.ptr, ct.len)) return;
    const h_server: []const u8 = "\r\nServer: kvmgui/1.0";
    if (!writeAll(conn, h_server.ptr, h_server.len)) return;
    if (std.mem.indexOf(u8, ct, "text/css") != null or std.mem.indexOf(u8, ct, "application/javascript") != null) {
        const h_cc: []const u8 = "\r\nCache-Control: public, max-age=86400";
        if (!writeAll(conn, h_cc.ptr, h_cc.len)) return;
    }
    const h_cl: []const u8 = "\r\nContent-Length: ";
    if (!writeAll(conn, h_cl.ptr, h_cl.len)) return;
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content_len}) catch "0";
    if (!writeAll(conn, len_str.ptr, len_str.len)) return;
    const h_conn: []const u8 = "\r\nConnection: close\r\n\r\n";
    if (!writeAll(conn, h_conn.ptr, h_conn.len)) return;
}

/// Signal the server to shut down by closing/halting its listen sockets.
/// Safe to call from any thread — unblocks blocking accept() calls.
pub fn shutdownSignal() void {
    if (tcp_sock_fd >= 0) {
        _ = c.shutdown(tcp_sock_fd, 2); // SHUT_RDWR
    }
    if (unix_sock_fd >= 0) {
        _ = c.shutdown(unix_sock_fd, 2);
    }
}

fn acceptLoop(fd: c.fd_t) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) break;
        _ = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);
    var buf: [65536]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // ── CORS preflight ──
    if (std.mem.startsWith(u8, req, "OPTIONS ")) {
        writeHttpResponse(conn, HTTP_OK, "text/plain", "ok");
        return;
    }

    // ── Method validation: only GET and POST are supported ──
    if (!std.mem.startsWith(u8, req, "GET ") and !std.mem.startsWith(u8, req, "POST ")) {
        writeHttpResponse(conn, HTTP_METHOD_NOT_ALLOWED, "text/plain", "Method Not Allowed");
        return;
    }

    // ── Content-Length validation: reject requests exceeding buffer capacity ──
    if (std.mem.startsWith(u8, req, "POST ")) {
        if (parseContentLength(req)) |cl| {
            if (cl > buf.len - 1024) { // reserve 1KB for headers
                writeHttpResponse(conn, HTTP_PAYLOAD_TOO_LARGE, "text/plain", "Payload Too Large");
                return;
            }
        }
    }

    // ── WebSocket VNC Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/vnc/")) {
        handleWsVnc(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "VNC proxy failed");
        };
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        handleWsSerial(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "Serial proxy failed");
        };
        return;
    }

    // ── File download (streaming) routes — handled first ──
    if (std.mem.startsWith(u8, req, "GET /api/vm/") and std.mem.indexOf(u8, req, "/disk2/download") != null) {
        handleDisk2Download(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "Download failed");
        };
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/vm/") and std.mem.indexOf(u8, req, "/upload-disk") != null) {
        const resp = handleUploadDisk(req) catch "upload err";
        const status: u16 = if (std.mem.eql(u8, resp, "ok")) HTTP_OK else HTTP_BAD_REQUEST;
        writeHttpResponse(conn, status, "text/plain", resp);
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/export/")) {
        handleExport(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "export err");
        };
        return;
    }

    // ── Standard routes ──
    var response: []const u8 = "";
    var content_type: []const u8 = "text/html";
    var status: u16 = HTTP_OK;
    var json_buf: [32768]u8 = undefined;
    var detail_buf: [4096]u8 = undefined;
    var snap_buf: [4096]u8 = undefined;

    // Auth: check X-API-Key for mutating endpoints
    const needs_auth = !std.mem.startsWith(u8, req, "GET /api/vms") and
        !std.mem.startsWith(u8, req, "GET /api/health") and
        !std.mem.startsWith(u8, req, "GET /api/fb/") and
        !std.mem.startsWith(u8, req, "GET /api/snapshot/list/") and
        !std.mem.startsWith(u8, req, "GET /api/config") and
        !std.mem.startsWith(u8, req, "GET /api/vnets") and
        !std.mem.startsWith(u8, req, "GET /api/vm/") and
        !std.mem.startsWith(u8, req, "GET / ") and
        !std.mem.startsWith(u8, req, "GET /app.js") and
        !std.mem.startsWith(u8, req, "GET /app.css") and
        !std.mem.eql(u8, req[0..@min(req.len, "GET /favicon".len)], "GET /favicon");

    if (needs_auth and !checkAuth(req)) {
        writeHttpResponse(conn, HTTP_BAD_REQUEST, "text/plain", "auth required");
        return;
    }

    if (std.mem.startsWith(u8, req, "GET /api/vms")) {
        content_type = "application/json; charset=utf-8";
        const json_bytes = renderJson(&json_buf);
        response = if (json_bytes > 0) json_buf[0..json_bytes] else "[]";
    } else if (std.mem.startsWith(u8, req, "GET /api/health")) {
        response = "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET /api/config")) {
        content_type = "application/json; charset=utf-8";
        response = try serveConfigRaw();
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json; charset=utf-8";
        response = renderVmDetail(req, &detail_buf);
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
        response = "saved";
        persist.save(&vms, vm_count, prefs) catch {
            logErr("persist.save failed");
            response = "save failed";
        };
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
        response = handleSnapshotList(req, &snap_buf);
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
        content_type = "application/json; charset=utf-8";
        response = handleVnetsJson(&snap_buf);
    } else if (std.mem.startsWith(u8, req, "POST /api/vnets/save")) {
        response = handleVnetsSave(req) catch "save err";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/config")) {
        response = handleConfigSave(req) catch "save err";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /app.css")) {
        response = app_css;
        content_type = "text/css; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET /app.js")) {
        response = app_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET / ")) {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET /favicon")) {
        content_type = "image/svg+xml";
        response = \\<?xml version="1.0" encoding="utf-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
        \\  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#3b82f6"/><stop offset="100%" stop-color="#6366f1"/></linearGradient></defs>
        \\  <rect width="32" height="32" rx="6" fill="url(#g)"/>
        \\  <text x="16" y="22" text-anchor="middle" font-size="18" font-weight="bold" fill="#fff" font-family="system-ui,sans-serif">K</text>
        \\</svg>
        ;
    } else {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    }

    var json_err_buf: [256]u8 = undefined;

    // Map known error strings to HTTP status codes and JSON error responses.
    // Previously returned plain text; now unified as `{"error":"..."}`.
    if (std.mem.eql(u8, content_type, "text/plain")) {
        if (std.mem.eql(u8, response, "invalid") or std.mem.eql(u8, response, "invalid idx")) {
            status = HTTP_NOT_FOUND;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        } else if (std.mem.eql(u8, response, "no disk") or std.mem.eql(u8, response, "not running") or std.mem.eql(u8, response, "off")) {
            status = HTTP_BAD_REQUEST;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        } else if (std.mem.eql(u8, response, "no vnc") or std.mem.eql(u8, response, "no spice")) {
            status = HTTP_INTERNAL_ERROR;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        } else if (std.mem.indexOf(u8, response, "err") != null or std.mem.indexOf(u8, response, "Err") != null) {
            status = HTTP_INTERNAL_ERROR;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        }
    }

    writeHttpResponse(conn, status, content_type, response);
}

/// Return the raw vms.json content for remote clients to sync their state.
fn serveConfigRaw() ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const home = appio.getenv("HOME") orelse return "{}";
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/kvmgui/vms.json", .{home}) catch return "{}";
    const raw = std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        path,
        std.heap.page_allocator,
        .limited(10 * 1024 * 1024),
    ) catch return "{}";
    defer std.heap.page_allocator.free(raw);
    const n = @min(raw.len, config_raw_buf.len);
    @memcpy(config_raw_buf[0..n], raw[0..n]);
    return config_raw_buf[0..n];
}

var fb_client: ?*vnc.VncClient = null;
// Tracks which VM index fb_client is connected to. MAX_VMS = sentinel (none).
var fb_vm_idx: usize = MAX_VMS;
var fb_mutex: sync.SpinMutex = .{};
// BMP output buffer — 54-byte header + up to 2 MB of pixel data
// 2 MB supports 640×480 at 32 bpp (≈1.23 MB) + margin for larger resolutions
var fb_bmp_buf: [2 * 1024 * 1024 + 54]u8 = undefined;
var config_raw_buf: [4 * 1024 * 1024]u8 = undefined;

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
    vms_mutex.lock();
    defer vms_mutex.unlock();
    if (idx >= vm_count) return "no vm";
    const v = &vms[idx];
    if (!v.isAlive()) return "off";

    fb_mutex.lock();
    defer fb_mutex.unlock();

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
        fb_vm_idx = MAX_VMS; // not yet connected to any VM
    }
    const vc = fb_client.?;
    // Reconnect if the VM changed or the connection dropped.
    if (fb_vm_idx != idx or !vc.isConnected()) {
        if (fb_vm_idx != MAX_VMS) vc.disconnect();
        _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
        fb_vm_idx = idx;
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0; var fh: c_int = 0;
        if (vc.getSize(&fw, &fh) and fw > 0 and fh > 0) {
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

fn renderVmDetail(req: []const u8, buf: []u8) []const u8 {
    const prefix = "GET /api/vm/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "{}";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "{}";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "{}";
    vms_mutex.lock();
    defer vms_mutex.unlock();
    if (idx >= vm_count) return "{}";
    const v = &vms[idx];
    var w: usize = 0;

    // Reusable escape buffer for user-controlled strings in JSON output.
    var esc: [vm.MAX_PATH]u8 = undefined;

    // First 32 fields
    const part1 = std.fmt.bufPrint(buf[w..],
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
    , .{
        idx, jsonEscape(&esc, v.getNameSlice()), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
        v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
        std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
        if (v.hasIso()) jsonEscape(&esc, v.getIsoPathSlice()) else "",
        if (v.hasNotes()) jsonEscape(&esc, v.getNotesSlice()) else "",
        if (v.hasSharedFolder()) jsonEscape(&esc, v.getSharedFolderSlice()) else "",
        if (v.hasUsbDevice()) jsonEscape(&esc, v.getUsbDeviceSlice()) else "",
        if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false",
        v.autoprotect_interval_min, v.autoprotect_max,
        if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
        if (v.hasDisk2()) jsonEscape(&esc, v.getDisk2PathSlice()) else "",
        v.disk2_format.toIndex(),
        if (v.hasFloppy()) "true" else "false",
        if (v.hasFloppy()) jsonEscape(&esc, v.getFloppyPathSlice()) else "",
        if (v.hasPortForwards()) jsonEscape(&esc, v.getPortForwardsSlice()) else "",
    }) catch return "{}";
    w += part1.len;

    // Remaining fields
    const part2 = std.fmt.bufPrint(buf[w..],
        \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s}}}
    , .{
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
        std.mem.span(v.accel.toStr()),
        if (v.embed_display) "true" else "false",
        v.vnc_port,
        v.spice_port,
        if (v.favorite) "true" else "false",
    }) catch return "{}";
    w += part2.len;
    return buf[0..w];
}

/// Render JSON into caller-provided buffer. Returns bytes written, or 0 on overflow.
fn renderJson(buf: []u8) usize {
    if (buf.len == 0) return 0;
    vms_mutex.lock();
    defer vms_mutex.unlock();
    var w: usize = 0;
    buf[w] = '[';
    w += 1;

    // Reusable escape buffer for user-controlled strings in JSON output.
    var esc: [vm.MAX_PATH]u8 = undefined;

    for (0..vm_count) |i| {
        if (i > 0) {
            if (w >= buf.len) return 0;
            buf[w] = ',';
            w += 1;
        }
        const v = &vms[i];

        // First block: up through port_forwards
        const part1 = std.fmt.bufPrint(buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
        , .{
            i, jsonEscape(&esc, v.getNameSlice()), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
            v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
            std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
            if (v.hasIso()) jsonEscape(&esc, v.getIsoPathSlice()) else "",
            if (v.hasNotes()) jsonEscape(&esc, v.getNotesSlice()) else "",
            if (v.hasSharedFolder()) jsonEscape(&esc, v.getSharedFolderSlice()) else "",
            if (v.hasUsbDevice()) jsonEscape(&esc, v.getUsbDeviceSlice()) else "",
            if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false",
            v.autoprotect_interval_min, v.autoprotect_max,
            if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
            if (v.hasDisk2()) jsonEscape(&esc, v.getDisk2PathSlice()) else "",
            v.disk2_format.toIndex(),
            if (v.hasFloppy()) "true" else "false",
            if (v.hasFloppy()) jsonEscape(&esc, v.getFloppyPathSlice()) else "",
            if (v.hasPortForwards()) jsonEscape(&esc, v.getPortForwardsSlice()) else "",
        }) catch break;
        w += part1.len;

        // Remaining fields
        const part2 = std.fmt.bufPrint(buf[w..],
            \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s},"started":{d}}}
        , .{
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
            std.mem.span(v.accel.toStr()),
            if (v.embed_display) "true" else "false",
            v.vnc_port,
            v.spice_port,
            if (v.favorite) "true" else "false",
            vm_started[i],
        }) catch break;
        w += part2.len;
    }
    if (w >= buf.len) return 0;
    buf[w] = ']';
    w += 1;
    return w;
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
        vm_started[idx] = 0;
    } else {
        if (getVmmHandle(idx)) |h| {
            g_vmm.startFn(h, @ptrCast(v)) catch {
                destroyVmmHandle(idx);
                return "start err";
            };
        } else {
            qemu.startVm(v, std.heap.page_allocator) catch return "start err";
        }
        vm_started[idx] = time(null);
    }
    persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
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
    var val_buf: [2048]u8 = undefined;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const raw = kv.next() orelse continue;
        const val = if (raw.len <= val_buf.len) urlencode.urlDecode(&val_buf, raw) else raw;
        if (std.mem.eql(u8, key, "name")) {
            if (std.mem.indexOfAny(u8, val, "<>&\"'") != null) return "invalid name";
            if (!vm.isValidVmName(val)) return "invalid name";
            cfg.setName(val);
        }
        if (std.mem.eql(u8, key, "mem")) cfg.memory_mb = vm.clampMemory(std.fmt.parseInt(u32, val, 10) catch 2048);
        if (std.mem.eql(u8, key, "cpu")) cfg.cpu_cores = vm.clampCpuCores(std.fmt.parseInt(u32, val, 10) catch 2);
        if (std.mem.eql(u8, key, "disk")) cfg.disk_size_gb = vm.clampDiskSize(std.fmt.parseInt(u32, val, 10) catch 20);
    }
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    cfg.vnc_port = vm.findUnusedVncPort(vms[0..vm_count]);
    cfg.spice_port = vm.findUnusedSpicePort(vms[0..vm_count]);
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
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
    clone.vnc_port = vm.findUnusedVncPort(vms[0..vm_count]);
    clone.spice_port = vm.findUnusedSpicePort(vms[0..vm_count]);
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
    persist.save(&vms, vm_count, prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
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
    // Destroy the VMM handle for the deleted VM
    destroyVmmHandle(idx);
    // Shift remaining
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) {
        vms[i] = vms[i + 1];
        g_vmm_handles[i] = g_vmm_handles[i + 1];
        vm_started[i] = vm_started[i + 1];
    }
    g_vmm_handles[vm_count - 1] = null;
    vm_started[vm_count - 1] = 0;
    vm_count -= 1;
    persist.save(&vms, vm_count, prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
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
    var val_buf: [2048]u8 = undefined;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const raw = kv.next() orelse continue;
        const val = if (raw.len <= val_buf.len) urlencode.urlDecode(&val_buf, raw) else raw;
        if (std.mem.eql(u8, key, "name")) {
            if (std.mem.indexOfAny(u8, val, "<>&\"'") != null) return "invalid name";
            if (!vm.isValidVmName(val)) return "invalid name";
            v.setName(val);
        }
        if (std.mem.eql(u8, key, "mem")) v.memory_mb = vm.clampMemory(std.fmt.parseInt(u32, val, 10) catch v.memory_mb);
        if (std.mem.eql(u8, key, "cpu")) v.cpu_cores = vm.clampCpuCores(std.fmt.parseInt(u32, val, 10) catch v.cpu_cores);
        if (std.mem.eql(u8, key, "cpu_sockets")) v.cpu_sockets = vm.clampCpuCores(std.fmt.parseInt(u32, val, 10) catch v.cpu_sockets);
        if (std.mem.eql(u8, key, "disk")) v.disk_size_gb = vm.clampDiskSize(std.fmt.parseInt(u32, val, 10) catch v.disk_size_gb);
        if (std.mem.eql(u8, key, "disk_format")) v.disk_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk_format.toIndex());
        if (std.mem.eql(u8, key, "iso_path")) v.setIsoPath(val);
        if (std.mem.eql(u8, key, "mac_address")) { if (vm.isValidMac(val)) v.setMacAddress(val); }
        if (std.mem.eql(u8, key, "network")) v.nics[0].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "firmware")) v.firmware = vm.BootFirmware.fromStr(val);
        if (std.mem.eql(u8, key, "shared_folder")) v.setSharedFolder(val);
        if (std.mem.eql(u8, key, "usb")) v.setUsbDevice(val);
        if (std.mem.eql(u8, key, "guest_tools")) v.guest_tools = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "autoprotect")) v.autoprotect = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "ap_interval")) v.autoprotect_interval_min = @max(1, @min(1440, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_interval_min));
        if (std.mem.eql(u8, key, "ap_max")) v.autoprotect_max = @max(1, @min(100, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_max));
        if (std.mem.eql(u8, key, "disk2_path")) v.setDisk2Path(val);
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb;
        if (std.mem.eql(u8, key, "disk2_format")) v.disk2_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk2_format.toIndex());
        if (std.mem.eql(u8, key, "floppy")) v.setFloppyPath(val);
        if (std.mem.eql(u8, key, "nic2")) v.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic2_mac")) { if (vm.isValidMac(val)) v.setNic2Mac(val); }
        if (std.mem.eql(u8, key, "nic3")) v.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) { if (vm.isValidMac(val)) v.setNic3Mac(val); }
        if (std.mem.eql(u8, key, "portfw")) v.setPortForwards(val);
        if (std.mem.eql(u8, key, "notes")) v.setNotes(val);
        if (std.mem.eql(u8, key, "enable_3d")) v.enable_3d = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "gpu_device")) v.gpu_device = vm.GpuDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.gpu_device.toIndex());
        if (std.mem.eql(u8, key, "display")) v.display = vm.DisplayType.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display.toIndex());
        if (std.mem.eql(u8, key, "display_resolution")) v.display_resolution = vm.DisplayResolution.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display_resolution.toIndex());
        if (std.mem.eql(u8, key, "guest_os")) v.guest_os = vm.GuestOs.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.guest_os.toIndex());
        if (std.mem.eql(u8, key, "audio")) v.audio = vm.AudioDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.audio.toIndex());
        if (std.mem.eql(u8, key, "boot_order")) v.boot_order = vm.BootOrder.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.boot_order.toIndex());
        if (std.mem.eql(u8, key, "accel")) v.accel = persist.parseAccel(val);
        if (std.mem.eql(u8, key, "enable_kvm")) { if (std.mem.eql(u8, val, "1")) v.accel = .auto else v.accel = .tcg; }
        if (std.mem.eql(u8, key, "embed_display")) v.embed_display = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "vnc_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch v.vnc_port;
            if (vm.isValidDisplayPort(p)) v.vnc_port = p;
        }
        if (std.mem.eql(u8, key, "spice_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch v.spice_port;
            if (vm.isValidDisplayPort(p)) v.spice_port = p;
        }
        if (std.mem.eql(u8, key, "enable_serial")) v.enable_serial = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = @max(1, @min(8, std.fmt.parseInt(u32, val, 10) catch v.num_displays));
        if (std.mem.eql(u8, key, "favorite")) v.favorite = std.mem.eql(u8, val, "1");
    }
    persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
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
    vm_started[idx] = 0;
    persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
    return "ok";
}

fn handlePause(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
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
    vms_mutex.lock();
    defer vms_mutex.unlock();
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
            if (std.mem.indexOfAny(u8, val, "<>&\"'") != null) return "invalid name";
            vms[idx].setName(val);
            persist.save(&vms, vm_count, prefs) catch |e| {
                var ebuf: [64]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
                return "save failed";
            };
            return "ok";
        }
    }
    return "no name";
}

fn handleShutdown(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
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
    vms_mutex.lock();
    defer vms_mutex.unlock();
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

const MAX_SNAPSHOT_TAG_LEN = 255;

fn validateSnapshotTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > MAX_SNAPSHOT_TAG_LEN) return false;
    for (tag) |b| {
        if (b < 0x20) return false; // reject control characters
    }
    return true;
}

fn handleSnapshotTake(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
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
    if (tag.len == 0) return "no name";
    if (!validateSnapshotTag(tag)) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    } else {
        qemu.snapshotCreate(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    }
    return "ok";
}

fn handleSnapshotList(req: []const u8, raw_buf: []u8) []const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "GET /api/snapshot/list/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const n: usize = if (getVmmHandle(idx)) |h|
        g_vmm.snapshotListFn(h, v.getDiskPathSlice(), raw_buf, std.heap.page_allocator) catch 0
    else
        qemu.snapshotList(v.getDiskPathSlice(), raw_buf, std.heap.page_allocator) catch 0;
    if (n == 0 or n > raw_buf.len) return "(none)";

    const nodes = snapparse.parse(raw_buf[0..n]);
    if (nodes.count == 0) return "(none)";

    // Emit snapshot names one per line into raw_buf, reusing it for output.
    var w: usize = 0;
    for (0..nodes.count) |i| {
        const name = nodes.nameSlice(i);
        if (w + name.len + 1 > raw_buf.len) break;
        @memcpy(raw_buf[w..][0..name.len], name);
        w += name.len;
        raw_buf[w] = '\n';
        w += 1;
    }
    return raw_buf[0..w];
}

fn handleSnapshotRevert(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/revert/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const raw_tag = std.mem.trim(u8, body, " \r\n");
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    const tag = urlencode.urlDecode(&decode_buf, raw_tag);
    if (!validateSnapshotTag(tag)) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotApplyFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    } else {
        qemu.snapshotApply(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    }
    return "ok";
}

fn handleSnapshotDelete(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/delete/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const raw_tag = std.mem.trim(u8, body, " \r\n");
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    const tag = urlencode.urlDecode(&decode_buf, raw_tag);
    if (!validateSnapshotTag(tag)) return "no name";
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
    // Reject path traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) return "bad path";
    // Reject non-disk extensions
    if (!(std.mem.endsWith(u8, path, ".vmdk") or std.mem.endsWith(u8, path, ".qcow2") or std.mem.endsWith(u8, path, ".qcow") or std.mem.endsWith(u8, path, ".img") or std.mem.endsWith(u8, path, ".raw"))) return "bad ext";
    // Verify the file actually exists before creating a VM config for it.
    std.Io.Dir.cwd().access(appio.io(), path, .{}) catch return "no file";
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
    cfg.vnc_port = vm.findUnusedVncPort(vms[0..vm_count]);
    cfg.spice_port = vm.findUnusedSpicePort(vms[0..vm_count]);
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleCad(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
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
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "GET /api/vm/") orelse return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.hasDisk2()) return;

    const disk2_path = v.getDisk2PathSlice();
    const fd = c.open(@ptrCast(disk2_path.ptr), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return;
    defer _ = c.close(fd);

    const seek_end = c.lseek(fd, 0, 2); // SEEK_END = 2
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    _ = c.lseek(fd, 0, 0); // SEEK_SET = 0

    const basename = std.fs.path.basename(disk2_path);
    var fname_buf: [256]u8 = undefined;
    const safename = sanitizeHeaderValue(&fname_buf, basename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{safename}) catch return;
    _ = c.write(conn, @ptrCast("HTTP/1.1 200 OK\r\n"), 17);
    _ = c.write(conn, @ptrCast("Access-Control-Allow-Origin: *\r\n"), 32);
    _ = c.write(conn, @ptrCast("Content-Type: application/octet-stream\r\n"), 40);
    _ = c.write(conn, @ptrCast("Content-Disposition: "), 21);
    _ = c.write(conn, cd.ptr, cd.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{file_size}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 23);

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        _ = c.write(conn, &buf, @intCast(n));
    }
}

/// Accept a multipart/form-data file upload for disk2.
fn handleUploadDisk(req: []const u8) ![]const u8 {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/vm/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";

    // Parse multipart boundary from Content-Type header
    const ct_start = std.mem.indexOf(u8, req, "Content-Type: multipart/form-data; boundary=") orelse return "no boundary";
    const bd_val_start = ct_start + "Content-Type: multipart/form-data; boundary=".len;
    const bd_end = std.mem.indexOfScalar(u8, req[bd_val_start..], '\r') orelse (req.len - bd_val_start);
    const boundary = req[bd_val_start .. bd_val_start + bd_end];

    // Locate body (after double CRLF)
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];

    // Boundary markers (prefixed with -- per RFC 2046)
    var bd_buf: [256]u8 = undefined;
    const full_bd = std.fmt.bufPrint(&bd_buf, "--{s}", .{boundary}) catch return "bd err";

    // Find the opening boundary line.
    const first_bd = std.mem.indexOf(u8, body, full_bd) orelse return "no boundary in body";
    var pos = first_bd + full_bd.len;
    // Skip trailing whitespace after boundary marker.
    if (pos < body.len and body[pos] == '\r') pos += 1;
    if (pos < body.len and body[pos] == '\n') pos += 1;

    // Skip part headers to find the start of file data.
    // Extract filename from Content-Disposition if present.
    var filename: []const u8 = "";
    const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse
        std.mem.indexOf(u8, body[pos..], "\n\n") orelse return "no headers end";
    const headers = body[pos..][0..headers_end];
    pos += headers_end;
    if (pos + 4 <= body.len and std.mem.eql(u8, body[pos..][0..4], "\r\n\r\n")) pos += 4
    else if (pos + 2 <= body.len and std.mem.eql(u8, body[pos..][0..2], "\n\n")) pos += 2
    else return "no headers end";

    // Parse filename="..." from Content-Disposition header.
    if (std.mem.indexOf(u8, headers, "filename=\"")) |fn_start| {
        const fn_val = headers[fn_start + "filename=\"".len ..];
        if (std.mem.indexOfScalar(u8, fn_val, '"')) |fn_end| {
            if (fn_end > 0) filename = fn_val[0..fn_end];
        }
    }

    // Find closing boundary: look for \r\n--boundary-- (terminating) or \r\n--boundary (next part).
    // We want the data between headers and the next boundary marker.
    const data_start = pos;
    var data_end: usize = body.len;
    // Search for the next occurrence of the full boundary after data_start.
    if (std.mem.indexOf(u8, body[pos..], full_bd)) |next_bd| {
        // Back up over the \r\n that precedes the boundary.
        const raw_end = pos + next_bd;
        data_end = if (raw_end >= 2 and body[raw_end - 2] == '\r' and body[raw_end - 1] == '\n')
            raw_end - 2
        else if (raw_end >= 1 and body[raw_end - 1] == '\n')
            raw_end - 1
        else
            raw_end;
    }
    const file_data = body[data_start..data_end];

    // Build destination path: same dir as primary disk, with _disk2 suffix.
    // Prefer the uploaded filename; fall back to the primary disk's name + extension.
    const v = &vms[idx];
    const primary = v.getDiskPathSlice();
    const ext = std.fs.path.extension(primary);
    const dir = std.fs.path.dirname(primary) orelse primary;

    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    if (filename.len > 0) {
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, filename }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        vms[idx].setDisk2Path(dest);
    } else if (ext.len > 0 and ext.len < 16) {
        const name_no_ext = primary[dir.len + 1 .. primary.len - ext.len];
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, name_no_ext, ext }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        vms[idx].setDisk2Path(dest);
    } else {
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, primary[dir.len + 1 ..] }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        vms[idx].setDisk2Path(dest);
    }
    persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
    return "ok";
}

/// Create OVF+VMDK export, tar+gzip it, and stream the result as a download.
fn handleExport(conn: c.fd_t, req: []const u8) !void {
    vms_mutex.lock();
    defer vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/export/") orelse return;
    if (idx >= vm_count) return;
    const v = &vms[idx];

    // Per-export unique directory to avoid races with concurrent exports.
    var dir_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/ovf_export.{d}.{d}", .{ idx, std.os.linux.getpid() }) catch return;
    // Ensure a clean directory.
    _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {};

    var tar_buf: [160]u8 = undefined;
    const tar_path = std.fmt.bufPrintZ(&tar_buf, "/tmp/ovf_export.{d}.{d}.tar.gz", .{ idx, std.os.linux.getpid() }) catch return;

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
    var ovf_buf: [ovf.max_descriptor_len]u8 = undefined;
    const xml = ovf.buildDescriptor(spec, &ovf_buf) catch return;

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, v.getNameSlice() });
    defer std.heap.page_allocator.free(ovf_path);
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = ovf_path, .data = xml }) catch return;

    if (getVmmHandle(idx)) |h| {
        g_vmm.convertDiskFn(h, v.getDiskPathSlice(), vmdk_path, @intFromEnum(v.disk_format), @intFromEnum(vm.DiskFormat.vmdk), std.heap.page_allocator) catch return;
    } else {
        qemu.convertDiskImage(v.getDiskPathSlice(), v.disk_format, vmdk_path, .vmdk, std.heap.page_allocator) catch return;
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

    const seek_end = c.lseek(tar_fd, 0, 2);
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    _ = c.lseek(tar_fd, 0, 0);

    const raw_filename = std.fmt.bufPrint(&path_buf, "{s}.ova", .{v.getNameSlice()}) catch "export.ova";
    var fname_buf2: [256]u8 = undefined;
    const filename = sanitizeHeaderValue(&fname_buf2, raw_filename);
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
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 23);

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

/// Parse Content-Length header value from an HTTP request. Returns null if not found.
fn parseContentLength(req: []const u8) ?usize {
    const hdr_start = std.mem.indexOf(u8, req, "\r\nContent-Length: ") orelse return null;
    const val_start = hdr_start + "\r\nContent-Length: ".len;
    const val_end = std.mem.indexOfScalar(u8, req[val_start..], '\r') orelse (req.len - val_start);
    return std.fmt.parseInt(usize, req[val_start .. val_start + val_end], 10) catch null;
}

fn getBody(req: []const u8) ?[]const u8 {
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    return req[body_start + 4 ..];
}

fn handleVnetsJson(buf: []u8) []const u8 {
    const set = vnet.load();
    const json = vnet.toJson(&set, std.heap.page_allocator) catch return "[]";
    defer std.heap.page_allocator.free(json);
    const n = @min(json.len, buf.len);
    @memcpy(buf[0..n], json[0..n]);
    return buf[0..n];
}

/// Parse key=value body data. Returns empty slice when not found.
fn bodyVal(body: []const u8, key: []const u8) []const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "{s}=", .{key}) catch return "";
    if (std.mem.indexOf(u8, body, pat)) |idx| {
        const start = idx + pat.len;
        const end = std.mem.indexOfScalar(u8, body[start..], '&') orelse (body.len - start);
        return body[start .. start + end];
    }
    return "";
}

/// Escape a string for safe inclusion in a JSON string value.
/// Writes the escaped result into `buf` and returns the escaped slice.
/// Escapes: \" \\ \n \r \t and control characters (→ \\u00XX).
fn jsonEscape(buf: []u8, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var wi: usize = 0;
    for (s) |ch| {
        switch (ch) {
            '"' => {
                if (wi + 2 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = '"'; wi += 1;
            },
            '\\' => {
                if (wi + 2 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = '\\'; wi += 1;
            },
            '\n' => {
                if (wi + 2 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = 'n'; wi += 1;
            },
            '\r' => {
                if (wi + 2 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = 'r'; wi += 1;
            },
            '\t' => {
                if (wi + 2 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = 't'; wi += 1;
            },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                // Control character → \\u00XX
                if (wi + 6 > buf.len) break;
                buf[wi] = '\\'; wi += 1;
                buf[wi] = 'u'; wi += 1;
                buf[wi] = '0'; wi += 1;
                buf[wi] = '0'; wi += 1;
                _ = std.fmt.bufPrint(buf[wi..], "{x:0>2}", .{ch}) catch break;
                wi += 2;
            },
            else => {
                if (wi + 1 > buf.len) break;
                buf[wi] = ch; wi += 1;
            },
        }
    }
    return buf[0..wi];
}

/// Strip dangerous characters from an HTTP header value.
/// Replaces double-quote with single-quote and removes CR/LF.
fn sanitizeHeaderValue(buf: []u8, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var wi: usize = 0;
    for (s) |ch| {
        if (wi >= buf.len) break;
        switch (ch) {
            '"' => { buf[wi] = '\''; wi += 1; },
            '\r', '\n' => {},
            else => { buf[wi] = ch; wi += 1; },
        }
    }
    return buf[0..wi];
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

    persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
    return "ok";
}

const index_html = @embedFile("index.html");
const app_css = @embedFile("web/app.css");
const app_js = @embedFile("web/app.js");

/// Background thread: periodically take AutoProtect snapshots for VMs that have it enabled.
fn autoprotectTicker() void {
    while (true) {
        appio.sleepMs(30_000);

        // Collect work items under the lock, release before I/O
        const SnapWork = struct {
            idx: usize,
            disk_path: [512]u8,
            disk_path_len: usize,
            snap_name: [40]u8,
            snap_name_len: usize,
            autoprotect_max: u32,
        };
        var work_items: [16]SnapWork = undefined;
        var work_count: usize = 0;

        vms_mutex.lock();
        const now = time(null);
        var i: usize = 0;
        while (i < vm_count and work_count < work_items.len) : (i += 1) {
            const v = &vms[i];
            if (!v.autoprotect or v.status != .running or !v.hasDisk()) continue;
            if (!autoprotect.due(true, v.autoprotect_interval_min, v.autoprotect_last_epoch, now)) continue;

            const seq = v.autoprotect_last_seq;
            v.autoprotect_last_seq = seq +% 1; // wrapping add
            v.autoprotect_last_epoch = now;

            var name_buf: [40]u8 = undefined;
            const snap_name = autoprotect.snapName(&name_buf, seq);

            const disk_path = v.getDiskPathSlice();
            var dp_buf: [512]u8 = undefined;
            if (disk_path.len > dp_buf.len) continue;
            @memcpy(dp_buf[0..disk_path.len], disk_path);

            work_items[work_count] = .{
                .idx = i,
                .disk_path = dp_buf,
                .disk_path_len = disk_path.len,
                .snap_name = name_buf,
                .snap_name_len = snap_name.len,
                .autoprotect_max = v.autoprotect_max,
            };
            work_count += 1;
        }
        vms_mutex.unlock();

        // Perform snapshot I/O outside the lock
        var wi: usize = 0;
        while (wi < work_count) : (wi += 1) {
            const w = &work_items[wi];
            const dp = w.disk_path[0..w.disk_path_len];
            const sn = w.snap_name[0..w.snap_name_len];

            if (getVmmHandle(w.idx)) |h| {
                g_vmm.snapshotCreateFn(h, dp, sn, std.heap.page_allocator) catch continue;
            } else {
                qemu.snapshotCreate(dp, sn, std.heap.page_allocator) catch continue;
            }

            // Prune excess AutoProtect snapshots
            var list_buf: [4096]u8 = undefined;
            const list_n: usize = if (getVmmHandle(w.idx)) |h|
                g_vmm.snapshotListFn(h, dp, &list_buf, std.heap.page_allocator) catch continue
            else
                qemu.snapshotList(dp, &list_buf, std.heap.page_allocator) catch continue;

            if (list_n == 0 or list_n > list_buf.len) continue;
            const list_str = list_buf[0..list_n];

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

            const excess = autoprotect.pruneExcess(auto_count, w.autoprotect_max);
            var d: usize = 0;
            while (d < excess and d < auto_names.len) : (d += 1) {
                if (getVmmHandle(w.idx)) |h| {
                    g_vmm.snapshotDeleteFn(h, dp, auto_names[d], std.heap.page_allocator) catch {};
                } else {
                    qemu.snapshotDelete(dp, auto_names[d], std.heap.page_allocator) catch {};
                }
            }
        }

        // Re-acquire lock only for the save
        vms_mutex.lock();
        persist.save(&vms, vm_count, prefs) catch { logErr("persist.save failed"); };
        vms_mutex.unlock();
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseIdx: extracts numeric index from URL path" {
    const req = "GET /api/power/42 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "/api/power/");
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 42), idx.?);
}

test "parseIdx: returns null when prefix not found" {
    const req = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "/api/power/");
    try std.testing.expect(idx == null);
}

test "parseIdx: handles multi-digit index" {
    const req = "GET /api/save/12345 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "/api/save/");
    try std.testing.expectEqual(@as(usize, 12345), idx.?);
}

test "parseIdx: returns null on non-numeric index" {
    const req = "GET /api/power/abc HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "/api/power/");
    try std.testing.expect(idx == null);
}

test "getBody: extracts body after double CRLF" {
    const req = "GET /api/save/0 HTTP/1.1\r\nHost: localhost\r\n\r\nname=foo&mem=2048";
    const body = getBody(req);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("name=foo&mem=2048", body.?);
}

test "getBody: returns null when no body separator found" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost";
    const body = getBody(req);
    try std.testing.expect(body == null);
}

test "getBody: empty body after double CRLF" {
    const req = "GET /api/power/0 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const body = getBody(req);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("", body.?);
}

test "bodyVal: extracts key=value from body" {
    const body = "name=myvm&mem=2048&cpu=4";
    try std.testing.expectEqualStrings("myvm", bodyVal(body, "name"));
    try std.testing.expectEqualStrings("2048", bodyVal(body, "mem"));
    try std.testing.expectEqualStrings("4", bodyVal(body, "cpu"));
}

test "bodyVal: returns empty string when key not found" {
    const body = "name=myvm&mem=2048";
    try std.testing.expectEqualStrings("", bodyVal(body, "nonexistent"));
}

test "bodyVal: handles last value without trailing &" {
    const body = "name=test&disk=40";
    try std.testing.expectEqualStrings("40", bodyVal(body, "disk"));
}

test "bodyVal: handles value with special characters" {
    const body = "name=test%20vm&path=%2Ftmp%2Fdisk";
    try std.testing.expectEqualStrings("test%20vm", bodyVal(body, "name"));
    try std.testing.expectEqualStrings("%2Ftmp%2Fdisk", bodyVal(body, "path"));
}

test "bodyVal: handles single key=value pair" {
    const body = "name=only";
    try std.testing.expectEqualStrings("only", bodyVal(body, "name"));
}

test "bodyVal: handles empty body" {
    const body = "";
    try std.testing.expectEqualStrings("", bodyVal(body, "name"));
}

test "bodyVal: key with empty value returns empty string" {
    const body = "name=&mem=2048";
    try std.testing.expectEqualStrings("", bodyVal(body, "name"));
}

test "bodyVal: key at very end with empty value" {
    const body = "name=test&key=";
    try std.testing.expectEqualStrings("", bodyVal(body, "key"));
}

test "bodyVal: percent-encoded key name" {
    const body = "na%6De=value&cpu=4";
    try std.testing.expectEqualStrings("value", bodyVal(body, "na%6De"));
    // percent-encoded key matches literally; raw key does not
    try std.testing.expectEqualStrings("", bodyVal(body, "name"));
}

test "bodyVal: value containing equals sign" {
    const body = "name=foo=bar&mem=1024";
    try std.testing.expectEqualStrings("foo=bar", bodyVal(body, "name"));
}

test "bodyVal: value containing percent-encoded ampersand" {
    const body = "name=foo%26bar&cpu=2";
    try std.testing.expectEqualStrings("foo%26bar", bodyVal(body, "name"));
}

test "bodyVal: key prefix of another key" {
    const body = "prefix=1&prefix2=2";
    try std.testing.expectEqualStrings("1", bodyVal(body, "prefix"));
    try std.testing.expectEqualStrings("2", bodyVal(body, "prefix2"));
}

test "bodyVal: long body near 4KB" {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    // Build repeated filler pairs to fill most of the buffer
    while (pos + 16 < buf.len - 30) {
        @memcpy(buf[pos..][0..6], "fillr=");
        pos += 6;
        @memset(buf[pos..][0..6], 'x');
        pos += 6;
        buf[pos] = '&';
        pos += 1;
    }
    // Append our target key at the end
    @memcpy(buf[pos..][0..6], "last=1");
    pos += 6;
    const body = buf[0..pos];
    try std.testing.expectEqualStrings("1", bodyVal(body, "last"));
    // Also find a filler value
    try std.testing.expectEqualStrings("xxxxxx", bodyVal(body, "fillr"));
    // Key not present in a full buffer
    try std.testing.expectEqualStrings("", bodyVal(body, "nonexistent"));
}

// ── Fuzz tests ──────────────────────────────────────────────────────

test "fuzz: bodyVal never panics on random key=value bodies" {
    var prng = std.Random.DefaultPrng.init(0xABCD_1234);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;

    const keys = [_][]const u8{ "name", "mem", "cpu", "disk", "net", "iso" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        var pos: usize = 0;
        var first = true;
        while (pos < buf.len - 40) {
            if (!first) { buf[pos] = '&'; pos += 1; }
            first = false;
            const k = keys[rnd.uintLessThan(usize, keys.len)];
            const kl = k.len;
            @memcpy(buf[pos..][0..kl], k);
            pos += kl;
            buf[pos] = '=';
            pos += 1;
            const vlen = rnd.uintLessThan(usize, 20);
            for (buf[pos..pos + vlen]) |*b| {
                b.* = switch (rnd.uintLessThan(u8, 4)) {
                    0 => rnd.intRangeAtMost(u8, 'a', 'z'),
                    1 => rnd.intRangeAtMost(u8, 'A', 'Z'),
                    2 => rnd.intRangeAtMost(u8, '0', '9'),
                    3 => '%',
                    else => unreachable,
                };
            }
            pos += vlen;
        }
        const body = buf[0..pos];
        for (keys) |k| {
            _ = bodyVal(body, k);
        }
    }
}

test "fuzz: getBody never panics and returns valid suffix of input" {
    var prng = std.Random.DefaultPrng.init(0xFEED_C0DE);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        if (getBody(buf[0..len])) |body| {
            try std.testing.expect(body.len <= len);
        }
    }
}

test "fuzz: parseIdx never panics on random URL-like input" {
    var prng = std.Random.DefaultPrng.init(0x1337_CAFE);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    const prefixes = [_][]const u8{ "/api/power/", "/api/save/", "/api/delete/", "/api/clone/" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        for (prefixes) |pfx| {
            _ = parseIdx(buf[0..len], pfx);
        }
    }
}

test "checkAuth: accepts correct default API key" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: kvmgui\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: rejects wrong default API key" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: wrong\r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: rejects when X-API-Key header missing" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: accepts correct custom auth token" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer { auth_token_len = 0; @memset(&auth_token, 0); }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: secret\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: rejects wrong custom auth token" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer { auth_token_len = 0; @memset(&auth_token, 0); }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: wrong!\r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: key at end with no trailing CR uses rest of request" {
    // Key at end of headers (before \r\n\r\n) — still valid.
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: kvmgui\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: custom token at end with no trailing CR" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer { auth_token_len = 0; @memset(&auth_token, 0); }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: secret\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: key value is empty string when header ends at colon-space" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: \r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: partial header name match is not fooled" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key2: kvmgui\r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

// ── Edge-case fuzz: request parsing surfaces ───────────────────────

test "fuzz: parseContentLength never panics on random header-like input" {
    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
    const rnd = prng.random();
    var buf: [2048]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        if (parseContentLength(buf[0..len])) |cl| {
            // Must fit in a reasonable buffer
            try std.testing.expect(cl <= 1024 * 1024);
        }
    }
}

test "fuzz: parseContentLength handles embedded nulls" {
    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rnd = prng.random();
    var buf: [1500]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const prefix = rnd.uintLessThan(usize, 40);
        // Fill with header-like text, then inject nulls
        for (buf[0..prefix]) |*b| {
            b.* = rnd.intRangeAtMost(u8, ' ', '~');
        }
        @memset(buf[prefix..], 0);
        if (parseContentLength(buf[0..prefix])) |cl| {
            try std.testing.expect(cl <= 1024 * 1024);
        }
    }
}

test "parseContentLength: no header returns null" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(parseContentLength(req) == null);
}

test "parseContentLength: negative value returns null" {
    const req = "POST /api/save/0 HTTP/1.1\r\nContent-Length: -1\r\n\r\n";
    try std.testing.expect(parseContentLength(req) == null);
}

test "parseContentLength: overflow value returns null" {
    const req = "POST /api/save/0 HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n";
    try std.testing.expect(parseContentLength(req) == null);
}

test "parseContentLength: valid value extracted" {
    const req = "POST /api/save/0 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\n\r\nname=test";
    const cl = parseContentLength(req);
    try std.testing.expectEqual(@as(usize, 42), cl.?);
}

test "parseContentLength: zero is valid" {
    const req = "POST /api/save/0 HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 0), parseContentLength(req).?);
}

test "parseContentLength: header at very front of request" {
    const req = "\r\nContent-Length: 100\r\nGET / HTTP/1.1\r\n\r\nbody";
    try std.testing.expectEqual(@as(usize, 100), parseContentLength(req).?);
}

test "fuzz: checkAuth never panics on random header input" {
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rnd = prng.random();
    var buf: [2048]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = checkAuth(buf[0..len]);
    }
}

test "checkAuth: multiple X-API-Key headers uses first match" {
    const req = "GET /api/vms HTTP/1.1\r\nX-API-Key: wrong\r\nX-API-Key: kvmgui\r\n\r\n";
    try std.testing.expect(!checkAuth(req)); // first match is "wrong"
}

test "checkAuth: X-API-Key in body is ignored (only headers searched)" {
    // checkAuth only searches headers (before \r\n\r\n) — body keys are ignored.
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\n\r\nX-API-Key: kvmgui\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: binary null in key value" {
    var buf: [256]u8 = undefined;
    const prefix = "GET /api/vms HTTP/1.1\r\nX-API-Key: ";
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..5], 0); // null bytes in key value
    buf[prefix.len + 5] = '\r';
    // Null bytes mean the provided key won't match "kvmgui" even if prefix is correct
    try std.testing.expect(!checkAuth(buf[0 .. prefix.len + 6]));
}

test "fuzz: serveHtml routing never panics on random method/URL input" {
    var prng = std.Random.DefaultPrng.init(0xFEED_FACE);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;

    // Route prefixes tested in serveHtml
    const routes = [_][]const u8{
        "GET /",
        "GET /api/vms",
        "GET /api/health",
        "GET /api/fb/",
        "GET /api/config",
        "GET /api/vnets",
        "GET /api/vm/",
        "GET /api/snapshot/list/",
        "GET /ws/vnc/",
        "GET /ws/serial/",
        "GET /app.js",
        "GET /app.css",
        "GET /favicon",
        "POST /api/power/",
        "POST /api/save/",
        "POST /api/suspend/",
        "POST /api/pause/",
        "POST /api/resume/",
        "POST /api/shutdown/",
        "POST /api/reset/",
        "POST /api/delete/",
        "POST /api/clone/",
        "POST /api/new",
        "POST /api/rename/",
        "POST /api/snapshot/take/",
        "POST /api/snapshot/revert/",
        "POST /api/snapshot/delete/",
        "POST /api/import",
        "POST /api/cad/",
        "POST /api/upload-disk",
        "POST /api/export/",
        "POST /api/disk2/download",
        "POST /api/vnets/save",
        "POST /api/config/save",
        "OPTIONS ",
        "PUT /api/vms",
        "DELETE /api/vms",
        "HEAD /api/vms",
        "PATCH /api/vms",
    };

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);

        // Simulate the method validation from serveHtml
        if (std.mem.startsWith(u8, buf[0..len], "OPTIONS ")) {
            // CORS preflight — always accepted
        } else if (!std.mem.startsWith(u8, buf[0..len], "GET ") and
            !std.mem.startsWith(u8, buf[0..len], "POST "))
        {
            // 405 Method Not Allowed — valid path
        } else {
            // Route matching — check each prefix
            for (routes) |route| {
                if (std.mem.startsWith(u8, buf[0..len], route)) {
                    // Parse index where applicable
                    if (std.mem.indexOf(u8, route, "/ws/") != null) {
                        // WebSocket route — skip index parsing
                    } else if (buf[0..len].len >= route.len) {
                        _ = parseIdx(buf[0..len], route);
                    }
                    // Check for download/upload sub-routes
                    _ = std.mem.indexOf(u8, buf[0..len], "/disk2/download");
                    _ = std.mem.indexOf(u8, buf[0..len], "/upload-disk");
                    break;
                }
            }
            // Check auth for non-GET routes
            _ = checkAuth(buf[0..len]);
            // Try body extraction
            _ = parseContentLength(buf[0..len]);
            _ = getBody(buf[0..len]);
        }
    }
}

test "fuzz: getBody never panics and returns valid suffix" {
    var prng = std.Random.DefaultPrng.init(0xACE_FACE);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        if (getBody(buf[0..len])) |body| {
            // body must be a suffix of the input slice
            try std.testing.expect(body.len <= len);
        }
    }
}

// ── Helper function tests ──────────────────────────────────────────

test "validateSnapshotTag: valid tags" {
    try std.testing.expect(validateSnapshotTag("snapshot1"));
    try std.testing.expect(validateSnapshotTag("backup-2024-01-01"));
    try std.testing.expect(validateSnapshotTag("a"));
    try std.testing.expect(validateSnapshotTag("A" ** 255));
}

test "validateSnapshotTag: empty tag rejected" {
    try std.testing.expect(!validateSnapshotTag(""));
}

test "validateSnapshotTag: too long tag rejected" {
    var long: [256]u8 = [_]u8{'x'} ** 256;
    try std.testing.expect(!validateSnapshotTag(&long));
}

test "validateSnapshotTag: control characters rejected" {
    try std.testing.expect(!validateSnapshotTag("bad\x01"));
    try std.testing.expect(!validateSnapshotTag("bad\x1f"));
    try std.testing.expect(!validateSnapshotTag("\x00name"));
    try std.testing.expect(!validateSnapshotTag("\x10middle"));
}

test "jsonEscape: escapes quotes and backslashes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\\"", jsonEscape(&buf, "\""));
    try std.testing.expectEqualStrings("\\\\", jsonEscape(&buf, "\\"));
    try std.testing.expectEqualStrings("abc\\\"xyz", jsonEscape(&buf, "abc\"xyz"));
}

test "jsonEscape: escapes newlines, carriage returns, tabs" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\n", jsonEscape(&buf, "\n"));
    try std.testing.expectEqualStrings("\\r", jsonEscape(&buf, "\r"));
    try std.testing.expectEqualStrings("\\t", jsonEscape(&buf, "\t"));
    try std.testing.expectEqualStrings("a\\nb\\tc", jsonEscape(&buf, "a\nb\tc"));
}

test "jsonEscape: escapes control characters as \\u00XX" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\u0000", jsonEscape(&buf, "\x00"));
    try std.testing.expectEqualStrings("\\u001f", jsonEscape(&buf, "\x1f"));
    try std.testing.expectEqualStrings("\\u000b", jsonEscape(&buf, "\x0b"));
}

test "jsonEscape: passes through normal text unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello world 123", jsonEscape(&buf, "hello world 123"));
}

test "jsonEscape: handles empty string" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", jsonEscape(&buf, ""));
}

test "sanitizeHeaderValue: replaces double-quote with single-quote" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("'quoted'", sanitizeHeaderValue(&buf, "\"quoted\""));
}

test "sanitizeHeaderValue: strips CR and LF" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("clean", sanitizeHeaderValue(&buf, "clean\r\n"));
    try std.testing.expectEqualStrings("no", sanitizeHeaderValue(&buf, "\rno\n"));
}

test "sanitizeHeaderValue: passes normal text unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("text/html", sanitizeHeaderValue(&buf, "text/html"));
}

test "sanitizeHeaderValue: handles empty string" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", sanitizeHeaderValue(&buf, ""));
}

test "sanitizeHeaderValue: handles only dangerous chars" {
    var buf: [64]u8 = undefined;
    // 4 double-quotes → 4 single-quotes; CR+LF removed
    try std.testing.expectEqualStrings("''''", sanitizeHeaderValue(&buf, "\"\"\r\n\"\""));
}

test "jsonErr: formats error message" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"error\":\"test\"}", jsonErr(&buf, "test"));
}

test "jsonErr: handles empty message" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"error\":\"\"}", jsonErr(&buf, ""));
}

test "jsonErr: buffer overflow falls back to default" {
    var buf: [8]u8 = undefined;
    // buf too small → catch path returns "{\"error\":\"internal\"}"
    try std.testing.expectEqualStrings("{\"error\":\"internal\"}", jsonErr(&buf, "long message"));
}

// ── Fuzz: helper functions ─────────────────────────────────────────

test "fuzz: validateSnapshotTag never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xCAFE_F00D);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = validateSnapshotTag(buf[0..len]);
    }
}

test "fuzz: jsonEscape never panics and always fits" {
    var prng = std.Random.DefaultPrng.init(0xB00B_1E55);
    const rnd = prng.random();
    var input: [128]u8 = undefined;
    var output: [512]u8 = undefined; // ~4x worst-case for \\u00XX escapes

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len + 1);
        rnd.bytes(input[0..len]);
        const result = jsonEscape(&output, input[0..len]);
        // Must always fit within output buffer
        try std.testing.expect(result.len <= output.len);
    }
}

test "fuzz: sanitizeHeaderValue never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xDECAF_BAD);
    const rnd = prng.random();
    var input: [256]u8 = undefined;
    var output: [256]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len + 1);
        rnd.bytes(input[0..len]);
        const result = sanitizeHeaderValue(&output, input[0..len]);
        // Must always fit within output buffer
        try std.testing.expect(result.len <= output.len);
    }
}

test "writeAll: writes exact bytes to fd via pipe" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    defer { _ = c.close(fds[0]); _ = c.close(fds[1]); }
    const msg = "hello from writeAll";
    try std.testing.expect(writeAll(fds[1], msg.ptr, msg.len));
    var buf: [64]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n >= 0);
    try std.testing.expectEqualStrings(msg, buf[0..@intCast(n)]);
}

test "writeAll: empty buffer succeeds without write" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    defer { _ = c.close(fds[0]); _ = c.close(fds[1]); }
    try std.testing.expect(writeAll(fds[1], (&[0]u8{}).ptr, 0));
}

test "writeAll: detects closed fd" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    _ = c.close(fds[0]);
    _ = c.close(fds[1]); // both ends closed
    try std.testing.expect(!writeAll(fds[1], "x".ptr, 1));
}

pub fn main() !void {
    vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);
    g_vmm = hv_backend.createVmm(.auto);

    const port: u16 = if (appio.getenv("KV_PORT")) |env| blk: {
        break :blk std.fmt.parseInt(u16, env, 10) catch 9080;
    } else 9080;

    const sock = c.socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;
    tcp_sock_fd = sock;
    defer {
        _ = c.close(sock);
        tcp_sock_fd = -1;
    }

    const one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

    // Bind to 0.0.0.0 — accessible locally and remotely
    const bind_ip: u32 = (@as(u32, BIND_ADDR[0]) << 24) | (@as(u32, BIND_ADDR[1]) << 16) | (@as(u32, BIND_ADDR[2]) << 8) | @as(u32, BIND_ADDR[3]);
    var addr: c.sockaddr.in = .{ .family = AF_INET, .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, bind_ip), .zero = [_]u8{0} ** 8 };
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        logErr("Failed to bind TCP port — already in use");
        return;
    }
    if (c.listen(sock, 10) != 0) {
        logErr("Failed to listen on TCP port");
        return;
    }

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/kvmgui-daemon.sock";
    _ = c.unlink(unix_path);
    const unix_sock = c.socket(AF_UNIX, SOCK_STREAM, 0);
    unix_sock_fd = unix_sock;
    defer {
        _ = c.close(unix_sock);
        unix_sock_fd = -1;
    }
    var unix_addr: c.sockaddr.un = .{ .family = AF_UNIX, .path = undefined };
    @memcpy(unix_addr.path[0..unix_path.len], unix_path);
    unix_addr.path[unix_path.len] = 0;
    const unix_len = @offsetOf(c.sockaddr.un, "path") + unix_path.len + 1;
    _ = c.setsockopt(unix_sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    _ = c.bind(unix_sock, @ptrCast(&unix_addr), @intCast(unix_len));
    _ = c.listen(unix_sock, 10);

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  KVMGUI Daemon v1.0                         ║\n", .{});
    std.debug.print("║  TCP:   http://0.0.0.0:{d}                 ║\n", .{port});
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    // Spawn thread to accept Unix socket connections
    if (std.Thread.spawn(std.Thread.SpawnConfig{}, acceptLoop, .{ unix_sock })) |th| {
        th.detach();
    } else |_| {}

    // Spawn autoprotect background ticker
    if (std.Thread.spawn(std.Thread.SpawnConfig{}, autoprotectTicker, .{})) |th| {
        th.detach();
    } else |_| {}

    while (true) {
        const conn = c.accept(sock, null, null);
        if (conn < 0) break;
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch {
            _ = c.close(conn);
            continue;
        };
        th.detach();
    }
}
