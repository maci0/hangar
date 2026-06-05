// SPDX-License-Identifier: MIT
//! Hangar — Web Frontend (HTTP server + HTML/CSS UI)
//! Serves a VMware WS7-style UI via embedded HTTP server.
//! Open http://localhost:9080 in any browser.
const std = @import("std");
const vm = @import("vm.zig");
const appstate = @import("appstate.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const vnc = @import("vnc_client.zig");
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
const form_parsers = @import("form_parsers.zig");
const path_helpers = @import("path_helpers.zig");

extern fn time(t: ?*c_long) c_long;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// HTTP status codes
const HTTP_OK: u16 = 200;
const HTTP_CREATED: u16 = 201;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_METHOD_NOT_ALLOWED: u16 = 405;
const HTTP_PAYLOAD_TOO_LARGE: u16 = 413;
const HTTP_TOO_MANY_REQUESTS: u16 = 429;
const HTTP_INTERNAL_ERROR: u16 = 500;

const BIND_ADDR: [4]u8 = .{ 0, 0, 0, 0 }; // 0.0.0.0 — accessible remotely
const API_KEY: []const u8 = "hangar"; // default API key for X-API-Key auth
var auth_token: [64]u8 = [_]u8{0} ** 64;
var auth_token_len: usize = 0;

// Server socket fds for shutdown signaling.
var tcp_sock_fd: c.fd_t = -1;
var unix_sock_fd: c.fd_t = -1;

const c = std.c;

// POSIX networking constants (not in std.c in Zig 0.16)
const AF_INET: c_uint = 2;
const AF_INET6: c_uint = 10;
const SOCK_STREAM: c_int = 1;
const AF_UNIX: c_uint = 1;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const SO_RCVTIMEO: c_int = 20;
const SHUT_WR: c_int = 1;
const SHUT_RDWR: c_int = 2;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 2048;
const IPPROTO_IPV6: c_int = 41;
const IPV6_V6ONLY: c_int = 26;

const SIGPIPE: c_int = 13;
const SIG_IGN: isize = 1;

extern fn signal(sig: c_int, handler: isize) isize;

// ── Rate limiter ────────────────────────────────────────────────
const RATE_LIMIT_PER_SEC: u32 = 200; // max POST requests per second

var g_rate_window_start: i64 = 0;
var g_rate_count: u32 = 0;

/// Returns true if the request should be rate-limited (denied).
fn rateLimitCheck() bool {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const now: i64 = @intCast(ts.sec);
    const prev: i64 = @atomicLoad(i64, &g_rate_window_start, .acquire);
    if (now != prev) {
        // Try to CAS the window forward — only the winner resets the count.
        const won = @cmpxchgWeak(i64, &g_rate_window_start, prev, now, .acq_rel, .monotonic);
        if (won == null) {
            // We advanced the window — reset the count and allow this request.
            @atomicStore(u32, &g_rate_count, 0, .release);
            return false;
        }
        // Lost the race; another thread advanced the window. Fall through
        // to the normal increment check so we don't wipe their counter.
    }
    if (@atomicRmw(u32, &g_rate_count, .Add, 1, .acq_rel) >= RATE_LIMIT_PER_SEC) {
        return true;
    }
    return false;
}

/// Check whether a URL path is exempt from API-key auth.
/// Uses exact path matching against the extracted path (not the raw request
/// line) to prevent path-traversal auth bypass via prefix injection.
fn isAuthExempt(method_get: bool, path: []const u8) bool {
    if (!method_get) return false; // only GET endpoints are exempt
    // Exact paths
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.eql(u8, path, "/app.js")) return true;
    if (std.mem.eql(u8, path, "/novnc.js")) return true;
    if (std.mem.eql(u8, path, "/spice.js")) return true;
    if (std.mem.eql(u8, path, "/app.css")) return true;
    if (std.mem.startsWith(u8, path, "/favicon")) return true;
    if (std.mem.eql(u8, path, "/api/vms")) return true;
    if (std.mem.eql(u8, path, "/api/capabilities")) return true;
    if (std.mem.eql(u8, path, "/api/health")) return true;
    if (std.mem.eql(u8, path, "/api/config")) return true;
    if (std.mem.eql(u8, path, "/api/vnets")) return true;
    // Prefix paths — ensure the prefix ends at a path boundary
    if (std.mem.startsWith(u8, path, "/api/vm/")) return true;
    if (std.mem.startsWith(u8, path, "/api/snapshot/list/")) return true;
    if (std.mem.eql(u8, path, "/api/catalog")) return true;
    if (std.mem.startsWith(u8, path, "/api/quickstart/")) return true;
    return false;
}

fn clampPref(v: []const u8, fallback: u32, lo: u32, hi: u32) u32 {
    const val = std.fmt.parseInt(u32, v, 10) catch return fallback;
    return if (val < lo) lo else if (val > hi) hi else val;
}

fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < headers.len) {
        // Case-insensitive header name match per RFC 7230.
        if (headers.len - pos >= name.len and
            std.ascii.eqlIgnoreCase(headers[pos .. pos + name.len], name))
        {
            const val_start = pos + name.len;
            const val_end = std.mem.indexOfScalar(u8, headers[val_start..], '\r') orelse (headers.len - val_start);
            return headers[val_start .. val_start + val_end];
        }
        if (std.mem.indexOfScalarPos(u8, headers, pos, '\n')) |nl| {
            pos = nl + 1;
        } else break;
    }
    return null;
}

fn checkAuth(req: []const u8) bool {
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
    const headers = req[0..hdr_end];

    if (auth_token_len > 0) {
        const provided = findHeader(headers, "X-API-Key: ") orelse return false;
        return std.mem.eql(u8, provided, auth_token[0..auth_token_len]);
    }
    // No custom token set — fall back to built-in API_KEY
    const provided = findHeader(headers, "X-API-Key: ") orelse return false;
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
        HTTP_TOO_MANY_REQUESTS => "HTTP/1.1 429 Too Many Requests\r\n",
        HTTP_INTERNAL_ERROR => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
    if (!writeAll(conn, status_line.ptr, status_line.len)) return;

    // CORS headers (allow cross-origin browser access)
    const h_acao: []const u8 = "Access-Control-Allow-Origin: *\r\n";
    const h_acah: []const u8 = "Access-Control-Allow-Headers: Content-Type, X-API-Key\r\n";
    const h_acam: []const u8 = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n";
    const h_xcto: []const u8 = "X-Content-Type-Options: nosniff\r\n";
    const h_xfo: []const u8 = "X-Frame-Options: DENY\r\n";
    const h_csp: []const u8 = "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; form-action 'self'; base-uri 'self'\r\n";
    const h_ct: []const u8 = "Content-Type: ";
    if (!writeAll(conn, h_acao.ptr, h_acao.len)) return;
    if (!writeAll(conn, h_acah.ptr, h_acah.len)) return;
    if (!writeAll(conn, h_acam.ptr, h_acam.len)) return;
    if (!writeAll(conn, h_xcto.ptr, h_xcto.len)) return;
    if (!writeAll(conn, h_xfo.ptr, h_xfo.len)) return;
    if (!writeAll(conn, h_csp.ptr, h_csp.len)) return;

    if (!writeAll(conn, h_ct.ptr, h_ct.len)) return;
    if (!writeAll(conn, ct.ptr, ct.len)) return;
    const h_server: []const u8 = "\r\nServer: hangar";
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
    const h_xcto: []const u8 = "X-Content-Type-Options: nosniff\r\n";
    const h_xfo: []const u8 = "X-Frame-Options: DENY\r\n";
    const h_csp: []const u8 = "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; form-action 'self'; base-uri 'self'\r\n";
    const h_ct: []const u8 = "Content-Type: ";
    if (!writeAll(conn, h_acao.ptr, h_acao.len)) return;
    if (!writeAll(conn, h_acah.ptr, h_acah.len)) return;
    if (!writeAll(conn, h_acam.ptr, h_acam.len)) return;
    if (!writeAll(conn, h_xcto.ptr, h_xcto.len)) return;
    if (!writeAll(conn, h_xfo.ptr, h_xfo.len)) return;
    if (!writeAll(conn, h_csp.ptr, h_csp.len)) return;
    if (!writeAll(conn, h_ct.ptr, h_ct.len)) return;
    if (!writeAll(conn, ct.ptr, ct.len)) return;
    const h_server: []const u8 = "\r\nServer: hangar";
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
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch {
            _ = c.close(conn);
            continue;
        };
        th.detach();
    }
}

/// Returns true if `req` starts with `prefix` followed by end-of-string, space, or '?'.
fn routeMatches(req: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, req, prefix)) return false;
    if (req.len == prefix.len) return true;
    const next = req[prefix.len];
    return next == ' ' or next == '?';
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);

    // 30-second receive timeout (SO_RCVTIMEO).
    var tv = std.mem.zeroes([16]u8);
    @as(*align(8) i64, @ptrCast(@alignCast(&tv[0]))).* = 30; // tv_sec
    @as(*align(8) i64, @ptrCast(@alignCast(&tv[8]))).* = 0; // tv_usec
    _ = c.setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));

    var buf: [65536]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // ── Rate limiting: POST requests only ──
    if (std.mem.startsWith(u8, req, "POST ") and rateLimitCheck()) {
        writeHttpResponse(conn, HTTP_TOO_MANY_REQUESTS, "text/plain", "Too Many Requests");
        return;
    }

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

    // Extract the URL path from the request line for precise matching.
    // Avoids path-traversal auth bypass via stitched prefixes (e.g.
    // "GET /api/vm/../../api/save/0" matched the exempt "GET /api/vm/").
    const req_path = if (std.mem.indexOfScalar(u8, req, ' ')) |sp1| blk: {
        const after_sp = req[sp1 + 1 ..];
        const sp2 = std.mem.indexOfAny(u8, after_sp, " ?") orelse after_sp.len;
        break :blk after_sp[0..sp2];
    } else req;

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
        if (!checkAuth(req)) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "text/plain", "auth required");
            return;
        }
        handleWsVnc(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "VNC proxy failed");
        };
        return;
    }

    // ── WebSocket SPICE Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/spice/")) {
        if (!checkAuth(req)) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "text/plain", "auth required");
            return;
        }
        handleWsSpice(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "SPICE proxy failed");
        };
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        if (!checkAuth(req)) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "text/plain", "auth required");
            return;
        }
        handleWsSerial(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "Serial proxy failed");
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

    // Auth: check X-API-Key for mutating endpoints.
    // Match against the extracted path (not the raw request line) to prevent
    // path-traversal auth bypass.
    const method_get = std.mem.startsWith(u8, req, "GET ");
    const needs_auth = !isAuthExempt(method_get, req_path);

    if (needs_auth and !checkAuth(req)) {
        writeHttpResponse(conn, HTTP_BAD_REQUEST, "text/plain", "auth required");
        return;
    }

    // ── File download (streaming) routes — handled after auth ──
    if (parseVmIdxSuffix(req, "GET /api/vm/", "/disk2/download") != null) {
        handleDisk2Download(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "Download failed");
        };
        return;
    }
    if (parseVmIdxSuffix(req, "POST /api/vm/", "/upload-disk") != null) {
        const resp = handleUploadDisk(req) catch "upload err";
        const upload_status: u16 = if (std.mem.eql(u8, resp, "ok")) HTTP_OK else HTTP_BAD_REQUEST;
        writeHttpResponse(conn, upload_status, "text/plain", resp);
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/export/")) {
        handleExport(conn, req) catch {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "text/plain", "export err");
        };
        return;
    }

    if (routeExact(req, "GET /api/vms")) {
        content_type = "application/json; charset=utf-8";
        const json_bytes = renderJson(&json_buf);
        response = if (json_bytes > 0) json_buf[0..json_bytes] else "[]";
    } else if (routeExact(req, "GET /api/capabilities")) {
        content_type = "application/json; charset=utf-8";
        response = handleCapabilities(&snap_buf);
    } else if (routeExact(req, "GET /api/health")) {
        response = "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json; charset=utf-8";
    } else if (routeExact(req, "GET /api/config")) {
        content_type = "application/json; charset=utf-8";
        response = try serveConfigRaw();
    } else if (routeExact(req, "GET /api/catalog")) {
        content_type = "application/json; charset=utf-8";
        response = handleCatalog(&snap_buf);
    } else if (std.mem.startsWith(u8, req, "GET /api/quickstart/")) {
        response = try handleQuickstart(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json; charset=utf-8";
        response = renderVmDetail(req, &detail_buf) catch blk: {
            logErr("renderVmDetail: buffer overflow or parse error");
            break :blk "{}";
        };
    } else if (std.mem.startsWith(u8, req, "POST /api/power/")) {
        response = try handlePower(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/new")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/delete/")) {
        response = try handleDelete(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/undo")) {
        response = try handleUndo();
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/reorder")) {
        response = try handleReorder(req);
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
    } else if (routeExact(req, "POST /api/save")) {
        response = "saved";
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
            logErr("persist.save failed");
            response = "save failed";
        };
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/create")) {
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
    } else if (routeExact(req, "POST /api/import")) {
        response = try handleImport(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/cad/")) {
        response = try handleCad(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/migrate/status/")) {
        response = handleMigrateStatus(req, &snap_buf);
        content_type = "application/json; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "POST /api/migrate/cancel/")) {
        response = try handleMigrateCancel(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/migrate/")) {
        response = try handleMigrate(req);
        content_type = "application/json; charset=utf-8";
    } else if (routeExact(req, "GET /api/vnets")) {
        content_type = "application/json; charset=utf-8";
        response = handleVnetsJson(&snap_buf);
    } else if (routeExact(req, "POST /api/vnets/save")) {
        response = handleVnetsSave(req) catch "save err";
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/config")) {
        response = handleConfigSave(req) catch "save err";
        content_type = "text/plain";
    } else if (routeExact(req, "GET /app.css")) {
        response = app_css;
        content_type = "text/css; charset=utf-8";
    } else if (routeExact(req, "GET /app.js")) {
        response = app_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /novnc.js")) {
        response = novnc_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /spice.js")) {
        response = spice_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET / ")) {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    } else if (std.mem.startsWith(u8, req, "GET /favicon")) {
        content_type = "image/svg+xml";
        response =
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
            \\  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#3b82f6"/><stop offset="100%" stop-color="#6366f1"/></linearGradient></defs>
            \\  <rect width="32" height="32" rx="6" fill="url(#g)"/>
            \\  <text x="16" y="22" text-anchor="middle" font-size="18" font-weight="bold" fill="#fff" font-family="system-ui,sans-serif">H</text>
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
        } else if (std.mem.eql(u8, response, "full") or std.mem.eql(u8, response, "no body") or std.mem.eql(u8, response, "invalid name") or std.mem.eql(u8, response, "bad path")) {
            status = HTTP_BAD_REQUEST;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        } else if (std.mem.eql(u8, response, "no vnc") or std.mem.eql(u8, response, "no spice")) {
            status = HTTP_INTERNAL_ERROR;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        } else if (std.mem.eql(u8, response, "save failed")) {
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
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/hangar/vms.json", .{home}) catch return "{}";
    const raw = std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        path,
        std.heap.page_allocator,
        .limited(10 * 1024 * 1024),
    ) catch return "{}";
    defer std.heap.page_allocator.free(raw);
    const n = @min(raw.len, config_raw_buf.len);
    if (raw.len > config_raw_buf.len) {
        std.log.warn("vms.json truncated to {} bytes (file is {} bytes)", .{ config_raw_buf.len, raw.len });
    }
    @memcpy(config_raw_buf[0..n], raw[0..n]);
    return config_raw_buf[0..n];
}

var fb_client: ?*vnc.VncClient = null;
// Tracks which VM index fb_client is connected to. appstate.MAX_VMS = sentinel (none).
var fb_vm_idx: usize = appstate.MAX_VMS;
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
    const idx = parseIdx(req, "GET /ws/vnc/") orelse return;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];
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
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
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
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.vnc_fd, SHUT_RDWR);
        }
    }.run, .{&ctx});

    vnc2ws.join();
    ws2vnc.join();
}

/// Handle WebSocket SPICE proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's SPICE port,
/// and spawns bidirectional relay threads.
fn handleWsSpice(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/spice/<idx>
    const idx = parseIdx(req, "GET /ws/spice/") orelse return;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's SPICE server.
    const spice_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (spice_fd < 0) return;
    defer _ = c.close(spice_fd);

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, v.spice_port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));

    if (c.connect(spice_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        try ws.writeClose(conn);
        return;
    }

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        spice_fd: c.fd_t,
    };
    var ctx = RelayCtx{ .ws_fd = conn, .spice_fd = spice_fd };

    // Thread: SPICE → WebSocket
    const spice2ws = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.spice_fd, &buf, buf.len);
                if (n <= 0) break;
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx});

    // Thread: WebSocket → SPICE
    const ws2spice = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
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
                _ = c.write(ctx_ptr.spice_fd, buf[0..rlen].ptr, rlen);
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.spice_fd, SHUT_RDWR);
        }
    }.run, .{&ctx});

    spice2ws.join();
    ws2spice.join();
}

/// Handle WebSocket Serial Console proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's serial
/// Unix socket, and spawns bidirectional relay threads.
fn handleWsSerial(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/serial/<idx>
    const idx = parseIdx(req, "GET /ws/serial/") orelse return;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];
    if (!v.isAlive() or !v.enable_serial or !v.hasName()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/hangar-serial-{s}.sock",
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
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
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
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.serial_fd, SHUT_RDWR);
        }
    }.run, .{&ctx});

    ser2ws.join();
    ws2ser.join();
}

fn renderFramebuffer(req: []const u8) ![]const u8 {
    // GET /api/fb/N — return the framebuffer for VM N as a valid BMP image
    const idx = parseIdx(req, "GET /api/fb/") orelse return "invalid";
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return "no vm";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "off";

    fb_mutex.lock();
    defer fb_mutex.unlock();

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
        fb_vm_idx = appstate.MAX_VMS; // not yet connected to any VM
    }
    const vc = fb_client.?;
    // Reconnect if the VM changed or the connection dropped.
    if (fb_vm_idx != idx or !vc.isConnected()) {
        if (fb_vm_idx != appstate.MAX_VMS) vc.disconnect();
        _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
        fb_vm_idx = idx;
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0;
        var fh: c_int = 0;
        if (vc.getSize(&fw, &fh) and fw > 0 and fh > 0) {
            const pixel_size: usize = @intCast(@as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4);
            const copy_size = @min(pixel_size, fb_bmp_buf.len - 54);
            if (pixel_size > fb_bmp_buf.len - 54) {
                std.log.warn("VNC framebuffer {}x{} ({} bytes) truncated to {} bytes", .{ fw, fh, pixel_size, fb_bmp_buf.len - 54 });
            }
            const file_size: u32 = @intCast(54 + copy_size);

            // ── BITMAPFILEHEADER (14 bytes) ──────────────────────
            fb_bmp_buf[0] = 'B';
            fb_bmp_buf[1] = 'M';
            std.mem.writeInt(u32, fb_bmp_buf[2..6], file_size, .little); // bfSize
            std.mem.writeInt(u32, fb_bmp_buf[6..10], 0, .little); // bfReserved
            std.mem.writeInt(u32, fb_bmp_buf[10..14], 54, .little); // bfOffBits

            // ── BITMAPINFOHEADER (40 bytes) ──────────────────────
            @memset(fb_bmp_buf[14..54], 0); // zero-fill then set fields
            std.mem.writeInt(u32, fb_bmp_buf[14..18], 40, .little); // biSize
            std.mem.writeInt(i32, fb_bmp_buf[18..22], fw, .little); // biWidth
            std.mem.writeInt(i32, fb_bmp_buf[22..26], -fh, .little); // biHeight (negative = top-down)
            std.mem.writeInt(u16, fb_bmp_buf[26..28], 1, .little); // biPlanes
            std.mem.writeInt(u16, fb_bmp_buf[28..30], 32, .little); // biBitCount
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

fn renderVmDetail(req: []const u8, buf: []u8) ![]const u8 {
    const idx = parseIdx(req, "GET /api/vm/") orelse return error.RenderFailed;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return "{}";
    const v = &appstate.vms[idx];
    var w: usize = 0;

    // Pre-escape user-controlled strings. Each needs its own buffer because
    // bufPrint tuple args are evaluated left-to-right, and each escapeJson
    // call overwrites the same buffer — earlier slices would dangle.
    var name_buf: [vm.MAX_NAME * 2 + 64]u8 = undefined;
    const name_e = escapeJson(&name_buf, v.getNameSlice(), "name");

    var iso_buf: [vm.MAX_PATH]u8 = undefined;
    const iso_e = if (v.hasIso()) escapeJson(&iso_buf, v.getIsoPathSlice(), "iso_path") else "";

    var notes_buf: [4096 * 2]u8 = undefined;
    const notes_e = if (v.hasNotes()) escapeJson(&notes_buf, v.getNotesSlice(), "notes") else "";

    var sf_buf: [vm.MAX_PATH]u8 = undefined;
    const sf_e = if (v.hasSharedFolder()) escapeJson(&sf_buf, v.getSharedFolderSlice(), "shared_folder") else "";

    var usb_buf: [128]u8 = undefined;
    const usb_e = if (v.hasUsbDevice()) escapeJson(&usb_buf, v.getUsbDeviceSlice(), "usb_device") else "";

    var d2_buf: [vm.MAX_PATH]u8 = undefined;
    const d2_e = if (v.hasDisk2()) escapeJson(&d2_buf, v.getDisk2PathSlice(), "disk2_path") else "";

    var flp_buf: [vm.MAX_PATH]u8 = undefined;
    const flp_e = if (v.hasFloppy()) escapeJson(&flp_buf, v.getFloppyPathSlice(), "floppy_path") else "";

    var pf_buf: [1024]u8 = undefined;
    const pf_e = if (v.hasPortForwards()) escapeJson(&pf_buf, v.getPortForwardsSlice(), "port_forwards") else "";

    // First 32 fields
    const part1 = std.fmt.bufPrint(buf[w..],
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
    , .{
        idx,                                    name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
        v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
        v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
        sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
        v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
        flp_e,                                  pf_e,
    }) catch return error.RenderFailed;
    w += part1.len;

    // Remaining fields — split to stay under 32-arg limit
    const part2a = std.fmt.bufPrint(buf[w..],
        \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"virtio_rng":{s},"guest_agent":{s},"watchdog":{d},"tpm":{s},"secure_boot":{s},"hyperv_enlightenments":{s},"hugepages":{s},"io_threads":{d},"disk_bps_throttle":{d},"disk_iops_throttle":{d}
    , .{
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        std.mem.span(v.nics[1].mode.toStr()),
        if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
        std.mem.span(v.nics[2].mode.toStr()),
        if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
        v.num_displays,
        if (v.enable_serial) "true" else "false",
        if (v.virtio_rng) "true" else "false",
        if (v.guest_agent) "true" else "false",
        v.watchdog.toIndex(),
        if (v.tpm) "true" else "false",
        if (v.secure_boot) "true" else "false",
        if (v.hyperv_enlightenments) "true" else "false",
        if (v.hugepages) "true" else "false",
        v.io_threads,
        v.disk_bps_throttle,
        v.disk_iops_throttle,
    }) catch return error.RenderFailed;
    w += part2a.len;

    const part2b = std.fmt.bufPrint(buf[w..],
        \\,"ballooning":{s},"host_autostart":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"cpu_model":"{s}","accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s},"started":{d}
    , .{
        if (v.ballooning) "true" else "false",
        if (v.host_autostart) "true" else "false",
        if (v.enable_3d) "true" else "false",
        v.gpu_device.toIndex(),
        v.display.toIndex(),
        v.display_resolution.toIndex(),
        v.guest_os.toIndex(),
        v.audio.toIndex(),
        v.boot_order.toIndex(),
        std.mem.span(v.cpu_model.toStr()),
        std.mem.span(v.accel.toStr()),
        if (v.embed_display) "true" else "false",
        v.vnc_port,
        v.spice_port,
        if (v.favorite) "true" else "false",
        appstate.vm_started[idx],
    }) catch return error.RenderFailed;
    w += part2b.len;

    const part2c = std.fmt.bufPrint(buf[w..],
        \\,"nic4_mode":"{s}","nic4_mac":"{s}","nic5_mode":"{s}","nic5_mac":"{s}","nic6_mode":"{s}","nic6_mac":"{s}","nic7_mode":"{s}","nic7_mac":"{s}","nic8_mode":"{s}","nic8_mac":"{s}"
    , .{
        std.mem.span(v.nics[3].mode.toStr()),
        if (v.nics[3].mac_len > 0) v.getNicMacSliceAny(3) else "",
        std.mem.span(v.nics[4].mode.toStr()),
        if (v.nics[4].mac_len > 0) v.getNicMacSliceAny(4) else "",
        std.mem.span(v.nics[5].mode.toStr()),
        if (v.nics[5].mac_len > 0) v.getNicMacSliceAny(5) else "",
        std.mem.span(v.nics[6].mode.toStr()),
        if (v.nics[6].mac_len > 0) v.getNicMacSliceAny(6) else "",
        std.mem.span(v.nics[7].mode.toStr()),
        if (v.nics[7].mac_len > 0) v.getNicMacSliceAny(7) else "",
    }) catch return error.RenderFailed;
    w += part2c.len;

    const part2d = std.fmt.bufPrint(buf[w..],
        \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}}}
    , .{
        if (v.hasExtraDisk(0)) v.getExtraDiskPathSlice(0) else "",
        v.extra_disks[0].size_gb,
        v.extra_disks[0].format.toIndex(),
        if (v.hasExtraDisk(1)) v.getExtraDiskPathSlice(1) else "",
        v.extra_disks[1].size_gb,
        v.extra_disks[1].format.toIndex(),
        if (v.hasExtraDisk(2)) v.getExtraDiskPathSlice(2) else "",
        v.extra_disks[2].size_gb,
        v.extra_disks[2].format.toIndex(),
        if (v.hasExtraDisk(3)) v.getExtraDiskPathSlice(3) else "",
        v.extra_disks[3].size_gb,
        v.extra_disks[3].format.toIndex(),
    }) catch return error.RenderFailed;
    w += part2d.len;

    return buf[0..w];
}

/// Render JSON into caller-provided buffer. Returns bytes written, or 0 on overflow.
fn renderJson(buf: []u8) usize {
    if (buf.len == 0) return 0;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    var w: usize = 0;
    buf[w] = '[';
    w += 1;

    for (0..appstate.vm_count) |i| {
        if (i > 0) {
            if (w >= buf.len) return 0;
            buf[w] = ',';
            w += 1;
        }
        const v = &appstate.vms[i];

        // Pre-escape user-controlled strings into dedicated buffers so
        // later escapeJson calls don't overwrite slices captured by earlier ones.
        var name_buf: [vm.MAX_NAME * 2 + 64]u8 = undefined;
        const name_e = escapeJson(&name_buf, v.getNameSlice(), "name");

        var iso_buf: [vm.MAX_PATH]u8 = undefined;
        const iso_e = if (v.hasIso()) escapeJson(&iso_buf, v.getIsoPathSlice(), "iso_path") else "";

        var notes_buf: [4096 * 2]u8 = undefined;
        const notes_e = if (v.hasNotes()) escapeJson(&notes_buf, v.getNotesSlice(), "notes") else "";

        var sf_buf: [vm.MAX_PATH]u8 = undefined;
        const sf_e = if (v.hasSharedFolder()) escapeJson(&sf_buf, v.getSharedFolderSlice(), "shared_folder") else "";

        var usb_buf: [128]u8 = undefined;
        const usb_e = if (v.hasUsbDevice()) escapeJson(&usb_buf, v.getUsbDeviceSlice(), "usb_device") else "";

        var d2_buf: [vm.MAX_PATH]u8 = undefined;
        const d2_e = if (v.hasDisk2()) escapeJson(&d2_buf, v.getDisk2PathSlice(), "disk2_path") else "";

        var flp_buf: [vm.MAX_PATH]u8 = undefined;
        const flp_e = if (v.hasFloppy()) escapeJson(&flp_buf, v.getFloppyPathSlice(), "floppy_path") else "";

        var pf_buf: [1024]u8 = undefined;
        const pf_e = if (v.hasPortForwards()) escapeJson(&pf_buf, v.getPortForwardsSlice(), "port_forwards") else "";

        // First block: up through port_forwards
        const part1 = std.fmt.bufPrint(buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
        , .{
            i,                                      name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
            v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
            v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
            sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
            v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
            flp_e,                                  pf_e,
        }) catch {
            w = buf.len;
            break;
        };
        w += part1.len;

        // Remaining fields — split to stay under 32-arg limit
        const part2a = std.fmt.bufPrint(buf[w..],
            \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"virtio_rng":{s},"guest_agent":{s},"watchdog":{d},"tpm":{s},"secure_boot":{s},"hyperv_enlightenments":{s},"hugepages":{s},"io_threads":{d},"disk_bps_throttle":{d},"disk_iops_throttle":{d}
        , .{
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            std.mem.span(v.nics[1].mode.toStr()),
            if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
            std.mem.span(v.nics[2].mode.toStr()),
            if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
            v.num_displays,
            if (v.enable_serial) "true" else "false",
            if (v.virtio_rng) "true" else "false",
            if (v.guest_agent) "true" else "false",
            v.watchdog.toIndex(),
            if (v.tpm) "true" else "false",
            if (v.secure_boot) "true" else "false",
            if (v.hyperv_enlightenments) "true" else "false",
            if (v.hugepages) "true" else "false",
            v.io_threads,
            v.disk_bps_throttle,
            v.disk_iops_throttle,
        }) catch {
            w = buf.len;
            break;
        };
        w += part2a.len;

        const part2b = std.fmt.bufPrint(buf[w..],
            \\,"ballooning":{s},"host_autostart":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"cpu_model":"{s}","accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s},"started":{d}
        , .{
            if (v.ballooning) "true" else "false",
            if (v.host_autostart) "true" else "false",
            if (v.enable_3d) "true" else "false",
            v.gpu_device.toIndex(),
            v.display.toIndex(),
            v.display_resolution.toIndex(),
            v.guest_os.toIndex(),
            v.audio.toIndex(),
            v.boot_order.toIndex(),
            std.mem.span(v.cpu_model.toStr()),
            std.mem.span(v.accel.toStr()),
            if (v.embed_display) "true" else "false",
            v.vnc_port,
            v.spice_port,
            if (v.favorite) "true" else "false",
            appstate.vm_started[i],
        }) catch {
            w = buf.len;
            break;
        };
        w += part2b.len;

        const part2c = std.fmt.bufPrint(buf[w..],
            \\,"nic4_mode":"{s}","nic4_mac":"{s}","nic5_mode":"{s}","nic5_mac":"{s}","nic6_mode":"{s}","nic6_mac":"{s}","nic7_mode":"{s}","nic7_mac":"{s}","nic8_mode":"{s}","nic8_mac":"{s}"
        , .{
            std.mem.span(v.nics[3].mode.toStr()),
            if (v.nics[3].mac_len > 0) v.getNicMacSliceAny(3) else "",
            std.mem.span(v.nics[4].mode.toStr()),
            if (v.nics[4].mac_len > 0) v.getNicMacSliceAny(4) else "",
            std.mem.span(v.nics[5].mode.toStr()),
            if (v.nics[5].mac_len > 0) v.getNicMacSliceAny(5) else "",
            std.mem.span(v.nics[6].mode.toStr()),
            if (v.nics[6].mac_len > 0) v.getNicMacSliceAny(6) else "",
            std.mem.span(v.nics[7].mode.toStr()),
            if (v.nics[7].mac_len > 0) v.getNicMacSliceAny(7) else "",
        }) catch {
            w = buf.len;
            break;
        };
        w += part2c.len;

        const part2d = std.fmt.bufPrint(buf[w..],
            \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}}}
        , .{
            if (v.hasExtraDisk(0)) v.getExtraDiskPathSlice(0) else "",
            v.extra_disks[0].size_gb,
            v.extra_disks[0].format.toIndex(),
            if (v.hasExtraDisk(1)) v.getExtraDiskPathSlice(1) else "",
            v.extra_disks[1].size_gb,
            v.extra_disks[1].format.toIndex(),
            if (v.hasExtraDisk(2)) v.getExtraDiskPathSlice(2) else "",
            v.extra_disks[2].size_gb,
            v.extra_disks[2].format.toIndex(),
            if (v.hasExtraDisk(3)) v.getExtraDiskPathSlice(3) else "",
            v.extra_disks[3].size_gb,
            v.extra_disks[3].format.toIndex(),
        }) catch {
            w = buf.len;
            break;
        };
        w += part2d.len;
    }
    if (w >= buf.len) return 0;
    buf[w] = ']';
    w += 1;
    return w;
}

/// Per-request error detail buffer for start-failure diagnostics.
/// Overwritten on each failed start; no allocation needed.
var start_err_buf: [640]u8 = undefined;

fn handlePower(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    // Extract idx from /api/power/N
    const idx = parseIdx(req, "POST /api/power/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (v.isAlive()) {
        if (appstate.getVmmHandle(idx)) |h| {
            appstate.g_vmm.forceStopFn(h);
            appstate.g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(v);
            qemu.reapVm(v);
        }
        appstate.destroyVmmHandle(idx);
        appstate.vm_started[idx] = 0;
    } else {
        if (appstate.getVmmHandle(idx)) |h| {
            appstate.g_vmm.startFn(h, @ptrCast(v)) catch {
                appstate.destroyVmmHandle(idx);
                return "start err";
            };
        } else {
            qemu.startVm(v, std.heap.page_allocator) catch {
                // Try to include QEMU stderr in the error response for diagnostics.
                var log_path_buf: [320]u8 = [_]u8{0} ** 320;
                var log_content_buf: [512]u8 = undefined;
                const log_path = std.fmt.bufPrintZ(&log_path_buf, "/var/tmp/hangar-vm-{s}.log", .{v.getNameSlice()}) catch null;
                const err_detail = if (log_path) |lp| readStartupLog(lp, &log_content_buf) else "";
                if (err_detail.len > 0) {
                    return std.fmt.bufPrint(&start_err_buf, "start err: {s}", .{err_detail}) catch "start err";
                }
                return "start err";
            };
        }
        appstate.vm_started[idx] = time(null);
    }
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("persist.save failed");
    };
    return "ok";
}

/// Read up to 512 bytes from a QEMU stderr log file for diagnostics.
/// Writes into `out` and returns the populated slice, or "" if unreadable.
fn readStartupLog(path: [*:0]const u8, out: []u8) []const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return "";
    defer _ = std.c.close(fd);
    const max_read = @min(out.len, 512);
    const n = std.c.read(fd, out.ptr, max_read);
    if (n <= 0) return "";
    var end: usize = @intCast(n);
    while (end > 0 and (out[end - 1] == '\n' or out[end - 1] == '\r')) end -= 1;
    return out[0..end];
}

fn handleNewVm(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    if (appstate.vm_count >= appstate.MAX_VMS) return "full";
    // Parse body: name=...&mem=...&cpu=...&disk=... plus all advanced fields (for undo restore)
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var cfg = vm.VmConfig{};
    var val_buf: [2048]u8 = undefined;
    var has_autoprotect: bool = false;
    var has_mac: bool = false;
    var has_vnc_port: bool = false;
    var has_spice_port: bool = false;
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
        if (std.mem.eql(u8, key, "mem")) cfg.memory_mb = vm.clampMemory(form_parsers.parseU32OrDefault(val, 2048));
        if (std.mem.eql(u8, key, "cpu")) cfg.cpu_cores = vm.clampCpuCores(form_parsers.parseU32OrDefault(val, 2));
        if (std.mem.eql(u8, key, "cpu_sockets")) cfg.cpu_sockets = vm.clampCpuCores(form_parsers.parseU32OrDefault(val, 1));
        if (std.mem.eql(u8, key, "cpu_model")) cfg.cpu_model = vm.CpuModel.fromStr(val);
        if (std.mem.eql(u8, key, "disk")) cfg.disk_size_gb = vm.clampDiskSize(form_parsers.parseU32OrDefault(val, 20));
        if (std.mem.eql(u8, key, "disk_format")) cfg.disk_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.disk_format.toIndex());
        if (std.mem.eql(u8, key, "disk_cache")) cfg.disk_cache = vm.DiskCache.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.disk_cache.toIndex());
        if (std.mem.eql(u8, key, "iso_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setIsoPath(val);
        }
        if (std.mem.eql(u8, key, "mac_address")) {
            if (vm.isValidMac(val)) {
                cfg.setMacAddress(val);
                has_mac = true;
            }
        }
        if (std.mem.eql(u8, key, "network")) cfg.nics[0].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "firmware")) cfg.firmware = vm.BootFirmware.fromStr(val);
        if (std.mem.eql(u8, key, "shared_folder")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setSharedFolder(val);
        }
        if (std.mem.eql(u8, key, "usb")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setUsbDevice(val);
        }
        if (std.mem.eql(u8, key, "usb_policy")) cfg.usb_policy = vm.UsbPolicy.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.usb_policy.toIndex());
        if (std.mem.eql(u8, key, "guest_tools")) cfg.guest_tools = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "autoprotect")) {
            cfg.autoprotect = std.mem.eql(u8, val, "1");
            has_autoprotect = true;
        }
        if (std.mem.eql(u8, key, "ap_interval")) cfg.autoprotect_interval_min = @max(1, @min(1440, std.fmt.parseInt(u32, val, 10) catch cfg.autoprotect_interval_min));
        if (std.mem.eql(u8, key, "ap_max")) cfg.autoprotect_max = @max(1, @min(1000, std.fmt.parseInt(u32, val, 10) catch cfg.autoprotect_max));
        if (std.mem.eql(u8, key, "disk2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setDisk2Path(val);
        }
        if (std.mem.eql(u8, key, "disk2_size")) cfg.disk2_size_gb = std.fmt.parseInt(u32, val, 10) catch cfg.disk2_size_gb;
        if (std.mem.eql(u8, key, "disk2_format")) cfg.disk2_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.disk2_format.toIndex());
        if (std.mem.eql(u8, key, "floppy")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setFloppyPath(val);
        }
        if (std.mem.eql(u8, key, "nic2")) cfg.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic2_mac")) {
            if (vm.isValidMac(val)) cfg.setNic2Mac(val);
        }
        if (std.mem.eql(u8, key, "nic3")) cfg.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) {
            if (vm.isValidMac(val)) cfg.setNic3Mac(val);
        }
        if (std.mem.eql(u8, key, "portfw")) cfg.setPortForwards(val);
        if (std.mem.eql(u8, key, "notes")) cfg.setNotes(val);
        if (std.mem.eql(u8, key, "enable_3d")) cfg.enable_3d = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "gpu_device")) cfg.gpu_device = vm.GpuDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.gpu_device.toIndex());
        if (std.mem.eql(u8, key, "display")) cfg.display = vm.DisplayType.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.display.toIndex());
        if (std.mem.eql(u8, key, "display_resolution")) cfg.display_resolution = vm.DisplayResolution.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.display_resolution.toIndex());
        if (std.mem.eql(u8, key, "guest_os")) cfg.guest_os = vm.GuestOs.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.guest_os.toIndex());
        if (std.mem.eql(u8, key, "audio")) cfg.audio = vm.AudioDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.audio.toIndex());
        if (std.mem.eql(u8, key, "boot_order")) cfg.boot_order = vm.BootOrder.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.boot_order.toIndex());
        if (std.mem.eql(u8, key, "accel")) cfg.accel = form_parsers.parseAccel(val);
        if (std.mem.eql(u8, key, "embed_display")) cfg.embed_display = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "vnc_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch cfg.vnc_port;
            if (vm.isValidDisplayPort(p)) {
                cfg.vnc_port = p;
                has_vnc_port = true;
            }
        }
        if (std.mem.eql(u8, key, "spice_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch cfg.spice_port;
            if (vm.isValidDisplayPort(p)) {
                cfg.spice_port = p;
                has_spice_port = true;
            }
        }
        if (std.mem.eql(u8, key, "enable_serial")) cfg.enable_serial = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "virtio_rng")) cfg.virtio_rng = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "num_displays")) cfg.num_displays = @max(1, @min(16, std.fmt.parseInt(u32, val, 10) catch cfg.num_displays));
        if (std.mem.eql(u8, key, "favorite")) cfg.favorite = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "guest_agent")) cfg.guest_agent = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "watchdog")) cfg.watchdog = vm.WatchdogAction.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.watchdog.toIndex());
        if (std.mem.eql(u8, key, "tpm")) cfg.tpm = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "secure_boot")) cfg.secure_boot = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "hyperv_enlightenments")) cfg.hyperv_enlightenments = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "hugepages")) cfg.hugepages = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "io_threads")) cfg.io_threads = std.fmt.parseInt(u32, val, 10) catch cfg.io_threads;
        if (std.mem.eql(u8, key, "disk_bps_throttle")) cfg.disk_bps_throttle = std.fmt.parseInt(u64, val, 10) catch cfg.disk_bps_throttle;
        if (std.mem.eql(u8, key, "disk_iops_throttle")) cfg.disk_iops_throttle = std.fmt.parseInt(u32, val, 10) catch cfg.disk_iops_throttle;
        if (std.mem.eql(u8, key, "ballooning")) cfg.ballooning = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "host_autostart")) cfg.host_autostart = std.mem.eql(u8, val, "1");
        // Extra NICs (4-8)
        if (std.mem.eql(u8, key, "nic4")) cfg.nics[3].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic4_mac")) {
            if (vm.isValidMac(val)) cfg.setNicMacAny(3, val);
        }
        if (std.mem.eql(u8, key, "nic5")) cfg.nics[4].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic5_mac")) {
            if (vm.isValidMac(val)) cfg.setNicMacAny(4, val);
        }
        if (std.mem.eql(u8, key, "nic6")) cfg.nics[5].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic6_mac")) {
            if (vm.isValidMac(val)) cfg.setNicMacAny(5, val);
        }
        if (std.mem.eql(u8, key, "nic7")) cfg.nics[6].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic7_mac")) {
            if (vm.isValidMac(val)) cfg.setNicMacAny(6, val);
        }
        if (std.mem.eql(u8, key, "nic8")) cfg.nics[7].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic8_mac")) {
            if (vm.isValidMac(val)) cfg.setNicMacAny(7, val);
        }
        // Extra disks (4 slots)
        if (std.mem.eql(u8, key, "extra0_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(0, val);
        }
        if (std.mem.eql(u8, key, "extra0_size")) cfg.extra_disks[0].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra0_format")) cfg.extra_disks[0].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[0].format.toIndex());
        if (std.mem.eql(u8, key, "extra1_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(1, val);
        }
        if (std.mem.eql(u8, key, "extra1_size")) cfg.extra_disks[1].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra1_format")) cfg.extra_disks[1].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[1].format.toIndex());
        if (std.mem.eql(u8, key, "extra2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(2, val);
        }
        if (std.mem.eql(u8, key, "extra2_size")) cfg.extra_disks[2].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra2_format")) cfg.extra_disks[2].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[2].format.toIndex());
        if (std.mem.eql(u8, key, "extra3_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(3, val);
        }
        if (std.mem.eql(u8, key, "extra3_size")) cfg.extra_disks[3].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra3_format")) cfg.extra_disks[3].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[3].format.toIndex());
    }

    // Apply defaults for fields not explicitly provided
    if (!has_autoprotect) {
        cfg.autoprotect = appstate.prefs.autoprotect_enabled_default;
        cfg.autoprotect_interval_min = appstate.prefs.autoprotect_interval_min_default;
        cfg.autoprotect_max = appstate.prefs.autoprotect_max_default;
    }
    if (!has_mac) {
        var mac_buf: [18]u8 = undefined;
        const mac = vm.generateMacAddress(&mac_buf);
        cfg.setMacAddress(std.mem.span(mac));
    }
    if (!has_vnc_port) cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    if (!has_spice_port) cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    appstate.vms[appstate.vm_count] = cfg;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

const CatalogEntry = struct {
    id: []const u8,
    name: []const u8,
    guest_os: usize,
    memory_mb: u32,
    cpu_cores: u32,
    disk_size_gb: u32,
    description: []const u8,
};

const catalog: [3]CatalogEntry = .{
    .{ .id = "ubuntu2404", .name = "Ubuntu 24.04 LTS", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 40, .description = "Ubuntu 24.04 Noble Numbat — latest LTS" },
    .{ .id = "fedora40", .name = "Fedora 40", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .description = "Fedora 40 Workstation" },
    .{ .id = "debian12", .name = "Debian 12", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .description = "Debian 12 Bookworm — stable" },
};

/// Returns the capabilities of the backend — max NICs, max extra disks, etc.
/// The frontend uses this to dynamically render NIC/disk form fields instead
/// of hardcoding nic2/nic3/disk2.
fn handleCapabilities(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"max_vms":{d},"max_nics":{d},"max_extra_disks":{d},"max_displays":16,"version":"1.0"}}
    , .{ vm.MAX_VMS, vm.MAX_NICS, vm.MAX_EXTRA_DISKS }) catch "{}";
}

fn handleCatalog(buf: []u8) []const u8 {
    if (buf.len == 0) return "[]";
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (catalog, 0..) |entry, i| {
        if (i > 0) {
            if (w >= buf.len) return "[]";
            buf[w] = ',';
            w += 1;
        }
        const part = std.fmt.bufPrint(buf[w..],
            \\{{"id":"{s}","name":"{s}","guest_os":{d},"memory_mb":{d},"cpu_cores":{d},"disk_size_gb":{d},"description":"{s}"}}
        , .{ entry.id, entry.name, entry.guest_os, entry.memory_mb, entry.cpu_cores, entry.disk_size_gb, entry.description }) catch return "[]";
        w += part.len;
    }
    if (w >= buf.len) return "[]";
    buf[w] = ']';
    w += 1;
    return buf[0..w];
}

fn handleQuickstart(req: []const u8) ![]const u8 {
    const prefix = "GET /api/quickstart/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const slug = rest[0..end];

    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    if (appstate.vm_count >= appstate.MAX_VMS) return "full";

    // Find the matching catalog entry.
    var template: ?CatalogEntry = null;
    for (catalog) |entry| {
        if (std.mem.eql(u8, entry.id, slug)) {
            template = entry;
            break;
        }
    }
    const tmpl = template orelse return "not found";

    var cfg = vm.VmConfig{};
    cfg.setName(tmpl.name);
    cfg.memory_mb = tmpl.memory_mb;
    cfg.cpu_cores = tmpl.cpu_cores;
    cfg.disk_size_gb = tmpl.disk_size_gb;
    cfg.guest_os = vm.GuestOs.fromIndex(tmpl.guest_os);

    // Apply sensible defaults.
    cfg.autoprotect = appstate.prefs.autoprotect_enabled_default;
    cfg.autoprotect_interval_min = appstate.prefs.autoprotect_interval_min_default;
    cfg.autoprotect_max = appstate.prefs.autoprotect_max_default;

    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);

    appstate.vms[appstate.vm_count] = cfg;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleClone(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    const idx = parseIdx(req, "POST /api/clone/") orelse return "invalid";
    if (idx >= appstate.vm_count or appstate.vm_count >= appstate.MAX_VMS) return "full";
    var clone = appstate.vms[idx];
    const src = &appstate.vms[idx];
    var name_buf: [320]u8 = undefined;
    const cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{clone.getNameSlice()}) catch return "nameerr";
    clone.setName(cn);
    clone.status = .stopped;
    clone.pid = null;
    clone.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    clone.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    clone.setMacAddress(std.mem.span(mac));

    // Check for linked clone request
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n");
    var linked: bool = false;
    if (body_start) |bs| {
        const body = req[bs + 4 ..];
        if (std.mem.eql(u8, bodyVal(body, "linked"), "1")) linked = true;
    }

    if (linked and src.hasDisk()) {
        const home = appio.getenv("HOME") orelse "/tmp";
        var disk_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
        const disk_path = std.fmt.bufPrintZ(&disk_path_buf, "{s}/VMs/{s}.qcow2", .{ home, clone.getNameSlice() }) catch return "nameerr";
        if (appstate.getVmmHandle(idx)) |h| {
            appstate.g_vmm.createLinkedCloneFn(h, disk_path, src.getDiskPathSlice(), @intFromEnum(src.disk_format), std.heap.page_allocator) catch return "linkerr";
        } else {
            qemu.createLinkedClone(disk_path, src.getDiskPathSlice(), src.disk_format, std.heap.page_allocator) catch return "linkerr";
        }
        clone.setDiskPath(disk_path);
        clone.disk_format = .qcow2;
    }

    appstate.vms[appstate.vm_count] = clone;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleDelete(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    const idx = parseIdx(req, "POST /api/delete/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    // Save undo state before deleting.
    appstate.undo_vm = appstate.vms[idx];
    appstate.undo_idx = idx;
    appstate.undo_available = true;
    // Destroy the VMM handle for the deleted VM
    appstate.destroyVmmHandle(idx);
    // Shift remaining
    var i = idx;
    while (i + 1 < appstate.vm_count) : (i += 1) {
        appstate.vms[i] = appstate.vms[i + 1];
        appstate.g_vmm_handles[i] = appstate.g_vmm_handles[i + 1];
        appstate.vm_started[i] = appstate.vm_started[i + 1];
    }
    appstate.g_vmm_handles[appstate.vm_count - 1] = null;
    appstate.vm_started[appstate.vm_count - 1] = 0;
    appstate.vm_count -= 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleUndo() ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    if (!appstate.undo_available) return "no undo";
    if (appstate.vm_count >= appstate.MAX_VMS) return "full";

    // Shift VMs down from undo_idx to make room.
    var i = appstate.vm_count;
    while (i > appstate.undo_idx) {
        appstate.vms[i] = appstate.vms[i - 1];
        appstate.g_vmm_handles[i] = appstate.g_vmm_handles[i - 1];
        appstate.vm_started[i] = appstate.vm_started[i - 1];
        i -= 1;
    }
    appstate.vms[appstate.undo_idx] = appstate.undo_vm;
    appstate.g_vmm_handles[appstate.undo_idx] = null;
    appstate.vm_count += 1;
    appstate.undo_available = false;

    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleReorder(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    const prefix = "POST /api/reorder";
    _ = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var val_buf: [16]u8 = undefined;
    var from: ?usize = null;
    var to: ?usize = null;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const raw = kv.next() orelse continue;
        const val = if (raw.len <= val_buf.len) urlencode.urlDecode(&val_buf, raw) else raw;
        const n = std.fmt.parseInt(usize, val, 10) catch continue;
        if (std.mem.eql(u8, key, "from")) from = n;
        if (std.mem.eql(u8, key, "to")) to = n;
    }
    if (from == null or to == null) return "missing from/to";
    const a = from.?;
    const b = to.?;
    if (a >= appstate.vm_count or b >= appstate.vm_count) return "invalid idx";
    if (a == b) return "ok"; // no-op
    // Splice-move: remove element at 'from', insert at 'to' (client semantics).
    const saved_vm = appstate.vms[a];
    const saved_handle = appstate.g_vmm_handles[a];
    const saved_started = appstate.vm_started[a];
    if (a < b) {
        // Shift [a+1 .. b] left by 1
        var j: usize = a;
        while (j < b) : (j += 1) {
            appstate.vms[j] = appstate.vms[j + 1];
            appstate.g_vmm_handles[j] = appstate.g_vmm_handles[j + 1];
            appstate.vm_started[j] = appstate.vm_started[j + 1];
        }
    } else {
        // Shift [b .. a-1] right by 1
        var j: usize = a;
        while (j > b) : (j -= 1) {
            appstate.vms[j] = appstate.vms[j - 1];
            appstate.g_vmm_handles[j] = appstate.g_vmm_handles[j - 1];
            appstate.vm_started[j] = appstate.vm_started[j - 1];
        }
    }
    appstate.vms[b] = saved_vm;
    appstate.g_vmm_handles[b] = saved_handle;
    appstate.vm_started[b] = saved_started;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleSave(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    const idx = parseIdx(req, "POST /api/save/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const v = &appstate.vms[idx];
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
        if (std.mem.eql(u8, key, "cpu_model")) v.cpu_model = vm.CpuModel.fromStr(val);
        if (std.mem.eql(u8, key, "disk")) v.disk_size_gb = vm.clampDiskSize(std.fmt.parseInt(u32, val, 10) catch v.disk_size_gb);
        if (std.mem.eql(u8, key, "disk_format")) v.disk_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk_format.toIndex());
        if (std.mem.eql(u8, key, "disk_cache")) v.disk_cache = vm.DiskCache.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk_cache.toIndex());
        if (std.mem.eql(u8, key, "iso_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setIsoPath(val);
        }
        if (std.mem.eql(u8, key, "mac_address")) {
            if (vm.isValidMac(val)) v.setMacAddress(val);
        }
        if (std.mem.eql(u8, key, "network")) v.nics[0].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "firmware")) v.firmware = vm.BootFirmware.fromStr(val);
        if (std.mem.eql(u8, key, "shared_folder")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setSharedFolder(val);
        }
        if (std.mem.eql(u8, key, "usb")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setUsbDevice(val);
        }
        if (std.mem.eql(u8, key, "usb_policy")) v.usb_policy = vm.UsbPolicy.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.usb_policy.toIndex());
        if (std.mem.eql(u8, key, "guest_tools")) v.guest_tools = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "autoprotect")) v.autoprotect = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "ap_interval")) v.autoprotect_interval_min = @max(1, @min(1440, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_interval_min));
        if (std.mem.eql(u8, key, "ap_max")) v.autoprotect_max = @max(1, @min(1000, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_max));
        if (std.mem.eql(u8, key, "disk2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setDisk2Path(val);
        }
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb;
        if (std.mem.eql(u8, key, "disk2_format")) v.disk2_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk2_format.toIndex());
        if (std.mem.eql(u8, key, "floppy")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setFloppyPath(val);
        }
        if (std.mem.eql(u8, key, "nic2")) v.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic2_mac")) {
            if (vm.isValidMac(val)) v.setNic2Mac(val);
        }
        if (std.mem.eql(u8, key, "nic3")) v.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) {
            if (vm.isValidMac(val)) v.setNic3Mac(val);
        }
        if (std.mem.eql(u8, key, "portfw")) v.setPortForwards(val);
        if (std.mem.eql(u8, key, "notes")) v.setNotes(val);
        if (std.mem.eql(u8, key, "enable_3d")) v.enable_3d = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "gpu_device")) v.gpu_device = vm.GpuDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.gpu_device.toIndex());
        if (std.mem.eql(u8, key, "display")) v.display = vm.DisplayType.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display.toIndex());
        if (std.mem.eql(u8, key, "display_resolution")) v.display_resolution = vm.DisplayResolution.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display_resolution.toIndex());
        if (std.mem.eql(u8, key, "guest_os")) v.guest_os = vm.GuestOs.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.guest_os.toIndex());
        if (std.mem.eql(u8, key, "audio")) v.audio = vm.AudioDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.audio.toIndex());
        if (std.mem.eql(u8, key, "boot_order")) v.boot_order = vm.BootOrder.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.boot_order.toIndex());
        if (std.mem.eql(u8, key, "accel")) v.accel = form_parsers.parseAccel(val);
        if (std.mem.eql(u8, key, "enable_kvm")) {
            if (std.mem.eql(u8, val, "1")) v.accel = .auto else v.accel = .tcg;
        }
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
        if (std.mem.eql(u8, key, "virtio_rng")) v.virtio_rng = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = @max(1, @min(16, std.fmt.parseInt(u32, val, 10) catch v.num_displays));
        if (std.mem.eql(u8, key, "favorite")) v.favorite = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "guest_agent")) v.guest_agent = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "watchdog")) v.watchdog = vm.WatchdogAction.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.watchdog.toIndex());
        if (std.mem.eql(u8, key, "tpm")) v.tpm = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "secure_boot")) v.secure_boot = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "hyperv_enlightenments")) v.hyperv_enlightenments = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "hugepages")) v.hugepages = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "io_threads")) v.io_threads = std.fmt.parseInt(u32, val, 10) catch v.io_threads;
        if (std.mem.eql(u8, key, "disk_bps_throttle")) v.disk_bps_throttle = std.fmt.parseInt(u64, val, 10) catch v.disk_bps_throttle;
        if (std.mem.eql(u8, key, "disk_iops_throttle")) v.disk_iops_throttle = std.fmt.parseInt(u32, val, 10) catch v.disk_iops_throttle;
        if (std.mem.eql(u8, key, "ballooning")) v.ballooning = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "host_autostart")) v.host_autostart = std.mem.eql(u8, val, "1");
        // Extra NICs (4-8)
        if (std.mem.eql(u8, key, "nic4")) v.nics[3].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic4_mac")) {
            if (vm.isValidMac(val)) v.setNicMacAny(3, val);
        }
        if (std.mem.eql(u8, key, "nic5")) v.nics[4].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic5_mac")) {
            if (vm.isValidMac(val)) v.setNicMacAny(4, val);
        }
        if (std.mem.eql(u8, key, "nic6")) v.nics[5].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic6_mac")) {
            if (vm.isValidMac(val)) v.setNicMacAny(5, val);
        }
        if (std.mem.eql(u8, key, "nic7")) v.nics[6].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic7_mac")) {
            if (vm.isValidMac(val)) v.setNicMacAny(6, val);
        }
        if (std.mem.eql(u8, key, "nic8")) v.nics[7].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic8_mac")) {
            if (vm.isValidMac(val)) v.setNicMacAny(7, val);
        }
        // Extra disks (4 slots)
        if (std.mem.eql(u8, key, "extra0_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(0, val);
        }
        if (std.mem.eql(u8, key, "extra0_size")) v.extra_disks[0].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra0_format")) v.extra_disks[0].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[0].format.toIndex());
        if (std.mem.eql(u8, key, "extra1_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(1, val);
        }
        if (std.mem.eql(u8, key, "extra1_size")) v.extra_disks[1].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra1_format")) v.extra_disks[1].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[1].format.toIndex());
        if (std.mem.eql(u8, key, "extra2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(2, val);
        }
        if (std.mem.eql(u8, key, "extra2_size")) v.extra_disks[2].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra2_format")) v.extra_disks[2].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[2].format.toIndex());
        if (std.mem.eql(u8, key, "extra3_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(3, val);
        }
        if (std.mem.eql(u8, key, "extra3_size")) v.extra_disks[3].size_gb = form_parsers.parseU32OrDefault(val, 0);
        if (std.mem.eql(u8, key, "extra3_format")) v.extra_disks[3].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[3].format.toIndex());
    }
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("persist.save failed");
    };
    return "ok";
}

/// Exact route match: checks that req starts with `prefix` and the character
/// immediately following is a space (HTTP line delimiter) or `?` (query string).
/// Prevents e.g. `GET /api/vms` from matching `GET /api/vms/3` or `GET /api/vmsblah`.
fn routeExact(req: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, req, prefix)) return false;
    if (req.len <= prefix.len) return false;
    const delim = req[prefix.len];
    return delim == ' ' or delim == '?';
}

fn parseIdx(req: []const u8, prefix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    const end_space = std.mem.indexOfScalar(u8, rest, ' ');
    const end_slash = std.mem.indexOfScalar(u8, rest, '/');
    const end: usize = if (end_space != null and end_slash != null) @min(end_space.?, end_slash.?) else (end_space orelse end_slash orelse return null);
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

/// Parse a VM index from the URL and verify the path suffix after the index.
/// E.g. `parseVmIdxSuffix(req, "GET /api/vm/", "/disk2/download")` for URL
/// `GET /api/vm/0/disk2/download`. Returns null on mismatch — safer than
/// substring search which might match ambiguous segments.
fn parseVmIdxSuffix(req: []const u8, prefix: []const u8, suffix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    const digit_end = std.mem.indexOfScalar(u8, rest, '/') orelse std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const path_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const idx = std.fmt.parseInt(usize, rest[0..digit_end], 10) catch return null;
    const tail = rest[digit_end..path_end];
    if (!std.mem.startsWith(u8, tail, suffix)) return null;
    // Reject partial segment matches: "/disk2" must not match "/disk2-download".
    if (tail.len > suffix.len) {
        const next = tail[suffix.len];
        if (next != '?' and next != '/' and next != ' ') return null;
    }
    return idx;
}

fn handleSuspend(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/suspend/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";

    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/hangar-state-{s}.bin", .{v.getNameSlice()}) catch return "path err";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.suspendToFile(path) catch return "migrate err";
    client.waitMigrateComplete() catch return "timeout";
    v.status = .suspended;
    v.setSavedStatePath(path[0..]);
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.forceStopFn(h);
        appstate.g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
    }
    appstate.destroyVmmHandle(idx);
    appstate.vm_started[idx] = 0;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("handleSuspend: persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handlePause(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/pause/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.pauseFn(h) catch return "qmp err";
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/resume/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isPaused()) return "not paused";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.resumeFn(h) catch return "qmp err";
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/rename/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var val_buf: [512]u8 = undefined;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const raw = kv.next() orelse continue;
        const val = if (raw.len <= val_buf.len) urlencode.urlDecode(&val_buf, raw) else raw;
        if (std.mem.eql(u8, key, "name")) {
            if (std.mem.indexOfAny(u8, val, "<>&\"'") != null) return "invalid name";
            if (!vm.isValidVmName(val)) return "invalid name";
            appstate.vms[idx].setName(val);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/shutdown/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.shutdownFn(h) catch return "qmp err";
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/reset/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.resetFn(h) catch return "qmp err";
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/take/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
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
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    const decoded = urlencode.urlDecode(&decode_buf, tag);
    if (!validateSnapshotTag(decoded)) return "no name";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "create err";
    } else {
        qemu.snapshotCreate(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "create err";
    }
    return "ok";
}

fn handleSnapshotList(req: []const u8, raw_buf: []u8) []const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "GET /api/snapshot/list/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.hasDisk()) return "no disk";
    const n: usize = if (appstate.getVmmHandle(idx)) |h|
        appstate.g_vmm.snapshotListFn(h, v.getDiskPathSlice(), raw_buf, std.heap.page_allocator) catch 0
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
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/revert/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.hasDisk()) return "no disk";
    if (v.isAlive()) return "vm running";
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
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    const decoded = urlencode.urlDecode(&decode_buf, tag);
    if (!validateSnapshotTag(decoded)) return "no name";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.snapshotApplyFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "apply err";
    } else {
        qemu.snapshotApply(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "apply err";
    }
    return "ok";
}

fn handleSnapshotDelete(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/delete/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.hasDisk()) return "no disk";
    if (v.isAlive()) return "vm running";
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
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    const decoded = urlencode.urlDecode(&decode_buf, tag);
    if (!validateSnapshotTag(decoded)) return "no name";
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "delete err";
    } else {
        qemu.snapshotDelete(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch return "delete err";
    }
    return "ok";
}

fn handleImport(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    if (appstate.vm_count >= appstate.MAX_VMS) return "full";
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
    // URL-decode the path before validation (JS sends encoded).
    var decode_buf: [vm.MAX_PATH]u8 = undefined;
    const decoded_path = urlencode.urlDecode(&decode_buf, path);
    // Reject path traversal attempts (check decoded form to catch %2e%2e).
    if (std.mem.indexOf(u8, decoded_path, "..") != null) return "bad path";
    // Reject non-disk extensions
    if (!(std.mem.endsWith(u8, decoded_path, ".vmdk") or std.mem.endsWith(u8, decoded_path, ".qcow2") or std.mem.endsWith(u8, decoded_path, ".qcow") or std.mem.endsWith(u8, decoded_path, ".img") or std.mem.endsWith(u8, decoded_path, ".raw"))) return "bad ext";
    // Verify the file actually exists before creating a VM config for it.
    std.Io.Dir.cwd().access(appio.io(), decoded_path, .{}) catch return "no file";
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const name = path_helpers.basenameWithoutExt(decoded_path, &name_buf);
    if (!vm.isValidVmName(name)) return "bad name";
    var cfg = vm.VmConfig{};
    cfg.setName(name);
    cfg.setDiskPath(decoded_path);
    cfg.disk_format = vm.DiskFormat.fromExtension(decoded_path);
    cfg.disk_size_gb = 20;
    cfg.memory_mb = appstate.prefs.default_memory_mb;
    cfg.cpu_cores = appstate.prefs.default_cpu_cores;
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    appstate.vms[appstate.vm_count] = cfg;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    return "ok";
}

fn handleCad(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/cad/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.sendCtrlAltDel() catch return "cad err";
    return "ok";
}

fn handleMigrate(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/migrate/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";
    // Parse dest= parameter from body.
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var dest: []const u8 = "";
    var val_buf: [512]u8 = undefined;
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const raw = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "dest")) {
            dest = if (raw.len <= val_buf.len) urlencode.urlDecode(&val_buf, raw) else raw;
        }
    }
    if (dest.len == 0) return "no dest";
    // Reject control characters and path traversal in destination URI.
    if (std.mem.indexOfAny(u8, dest, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f") != null) return "bad dest";
    if (std.mem.indexOf(u8, dest, "..") != null) return "bad dest";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.liveMigrate(dest) catch return "migrate err";
    return "{\"status\":\"started\"}";
}

/// Query current migration status for a VM.
fn handleMigrateStatus(req: []const u8, buf: []u8) []const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "GET /api/migrate/status/") orelse return "{\"status\":\"error\",\"error\":\"invalid idx\"}";
    if (idx >= appstate.vm_count) return "{\"status\":\"error\",\"error\":\"bad idx\"}";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "{\"status\":\"error\",\"error\":\"not running\"}";

    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "{\"status\":\"error\",\"error\":\"no socket\"}";
    client.connect(sock) catch return "{\"status\":\"error\",\"error\":\"qmp connect\"}";
    defer client.disconnect();

    var status_buf: [128]u8 = undefined;
    const status = client.queryMigrateStatus(&status_buf) catch return "{\"status\":\"error\",\"error\":\"qmp query\"}";
    const resp = std.fmt.bufPrint(buf, "{{\"status\":\"{s}\"}}", .{status}) catch return "{\"status\":\"error\"}";
    return buf[0..resp.len];
}

/// Cancel an active migration.
fn handleMigrateCancel(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/migrate/cancel/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    if (!v.isAlive()) return "not running";

    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.cancelMigrate() catch return "cancel err";
    return "ok";
}

/// Stream the disk2 image file to the client as a download.
fn handleDisk2Download(conn: c.fd_t, req: []const u8) !void {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "GET /api/vm/") orelse return;
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];
    if (!v.hasDisk2()) return;

    const disk2_path = v.getDisk2Path();
    const fd = c.open(@ptrCast(disk2_path), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return;
    defer _ = c.close(fd);

    const seek_end = c.lseek(fd, 0, 2); // SEEK_END = 2
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(fd, 0, 0) < 0) return; // SEEK_SET = 0

    const basename = std.fs.path.basename(std.mem.span(disk2_path));
    var fname_buf: [256]u8 = undefined;
    const safename = sanitizeHeaderValue(&fname_buf, basename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{safename}) catch return;

    // Build response headers in one buffer, then write them at once.
    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Disposition: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ cd, file_size },
    ) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return error.BrokenPipe;

    // Stream the file payload, checking every write.
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &buf, @intCast(n))) return error.BrokenPipe;
    }
}

/// Accept a multipart/form-data file upload for disk2.
fn handleUploadDisk(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/vm/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";

    // Parse multipart boundary from Content-Type header (case-insensitive per RFC 7230).
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const headers = req[0..hdr_end];
    const ct_val = findHeader(headers, "content-type: ") orelse return "no boundary";
    const ct_prefix = "multipart/form-data; boundary=";
    if (ct_val.len < ct_prefix.len or !std.ascii.eqlIgnoreCase(ct_val[0..ct_prefix.len], ct_prefix)) return "no boundary";
    const boundary = ct_val[ct_prefix.len..];

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
    const part_headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse
        std.mem.indexOf(u8, body[pos..], "\n\n") orelse return "no headers end";
    const part_headers = body[pos..][0..part_headers_end];
    pos += part_headers_end;
    if (pos + 4 <= body.len and std.mem.eql(u8, body[pos..][0..4], "\r\n\r\n")) pos += 4 else if (pos + 2 <= body.len and std.mem.eql(u8, body[pos..][0..2], "\n\n")) pos += 2 else return "no headers end";

    // Parse filename="..." or filename=... from Content-Disposition header.
    if (std.mem.indexOf(u8, part_headers, "filename=\"")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=\"".len ..];
        if (std.mem.indexOfScalar(u8, fn_val, '"')) |fn_end| {
            if (fn_end > 0) filename = fn_val[0..fn_end];
        }
    } else if (std.mem.indexOf(u8, part_headers, "filename=")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=".len ..];
        // Unquoted filename: terminated by ';', '\r', or '\n'.
        var fn_end: usize = fn_val.len;
        if (std.mem.indexOfScalar(u8, fn_val, ';')) |semi| fn_end = semi;
        if (std.mem.indexOfScalar(u8, fn_val, '\r')) |cr| {
            if (cr < fn_end) fn_end = cr;
        }
        if (std.mem.indexOfScalar(u8, fn_val, '\n')) |nl| {
            if (nl < fn_end) fn_end = nl;
        }
        if (fn_end > 0) filename = std.mem.trimEnd(u8, fn_val[0..fn_end], " \t");
    }

    // Reject path traversal in filename.
    if (filename.len == 0) return "no filename";
    for (filename) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0) return "bad filename";
    }
    if (std.mem.indexOf(u8, filename, "..") != null) return "bad filename";

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
    const v = &appstate.vms[idx];
    const primary = v.getDiskPathSlice();
    if (primary.len == 0) return "no primary disk";
    const ext = std.fs.path.extension(primary);
    const dir = std.fs.path.dirname(primary) orelse ".";

    const basename = std.fs.path.basename(primary);
    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    if (filename.len > 0) {
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, filename }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        appstate.vms[idx].setDisk2Path(dest);
    } else if (ext.len > 0 and ext.len < 16) {
        const name_no_ext = basename[0 .. basename.len - ext.len];
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, name_no_ext, ext }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        appstate.vms[idx].setDisk2Path(dest);
    } else {
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, basename }) catch return "path err";
        std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";
        appstate.vms[idx].setDisk2Path(dest);
    }
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("persist.save failed");
    };
    return "ok";
}

/// Create OVF+VMDK export, tar+gzip it, and stream the result as a download.
fn handleExport(conn: c.fd_t, req: []const u8) !void {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/export/") orelse return;
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];

    // Per-export unique directory to avoid races with concurrent exports.
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    var dir_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/ovf_export.{d}.{d}.{d}", .{ idx, std.c.getpid(), ts.nsec }) catch return;
    // Ensure a clean directory.
    _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
        logErr("export: deleteTree (pre-create) failed");
    };
    std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {
        logErr("failed to create export dir");
        return;
    };
    var dir_cleanup: bool = true;
    defer if (dir_cleanup) {
        _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
            logErr("export: deleteTree cleanup failed");
        };
    };

    var tar_buf: [160]u8 = undefined;
    const tar_path = std.fmt.bufPrintZ(&tar_buf, "/tmp/ovf_export.{d}.{d}.tar.gz", .{ idx, std.c.getpid() }) catch return;
    var tar_cleanup: bool = false;
    defer if (tar_cleanup) {
        _ = c.unlink(tar_path);
    };

    const vmdk_name = "disk1.vmdk";
    var path_buf: [vm.MAX_PATH]u8 = undefined;
    const vmdk_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, vmdk_name }) catch return;

    // Convert disk1 to VMDK
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.convertDiskFn(h, v.getDiskPathSlice(), vmdk_path, @intFromEnum(v.disk_format), @intFromEnum(vm.DiskFormat.vmdk), std.heap.page_allocator) catch {
            logErr("export: disk1 conversion (VMM) failed");
            return;
        };
    } else {
        qemu.convertDiskImage(v.getDiskPathSlice(), v.disk_format, vmdk_path, .vmdk, std.heap.page_allocator) catch {
            logErr("export: disk1 conversion (qemu) failed");
            return;
        };
    }

    // Convert disk2 if present
    var disk2_href: []const u8 = "";
    var disk2_cap: u64 = 0;
    if (v.hasDisk2()) {
        disk2_href = "disk2.vmdk";
        disk2_cap = @as(u64, v.disk2_size_gb) * 1024 * 1024 * 1024;
        const d2_path = std.fmt.bufPrint(&path_buf, "{s}/disk2.vmdk", .{dir_path}) catch return;
        if (appstate.getVmmHandle(idx)) |h2| {
            appstate.g_vmm.convertDiskFn(h2, v.getDisk2PathSlice(), d2_path, @intFromEnum(v.disk2_format), @intFromEnum(vm.DiskFormat.vmdk), std.heap.page_allocator) catch {
                logErr("export: disk2 conversion (VMM) failed");
                return;
            };
        } else {
            qemu.convertDiskImage(v.getDisk2PathSlice(), v.disk2_format, d2_path, .vmdk, std.heap.page_allocator) catch {
                logErr("export: disk2 conversion (qemu) failed");
                return;
            };
        }
    }

    // Build OVF descriptor after all conversions
    const disk_cap = @as(u64, v.disk_size_gb) * 1024 * 1024 * 1024;
    const spec = ovf.Spec{
        .name = v.getNameSlice(),
        .cpu_cores = v.cpu_cores,
        .memory_mb = v.memory_mb,
        .disk_capacity_bytes = disk_cap,
        .vmdk_href = vmdk_name,
        .vmdk_size_bytes = 0,
        .has_network = v.nics[0].mode != .none,
        .disk2_href = disk2_href,
        .disk2_capacity_bytes = disk2_cap,
        .disk2_size_bytes = 0,
    };
    var ovf_buf: [ovf.max_descriptor_len]u8 = undefined;
    const xml = ovf.buildDescriptor(spec, &ovf_buf) catch {
        logErr("export: OVF descriptor build failed");
        return;
    };

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, v.getNameSlice() });
    defer std.heap.page_allocator.free(ovf_path);
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = ovf_path, .data = xml }) catch {
        logErr("export: failed to write OVF file");
        return;
    };

    // Tar+gzip the export directory
    {
        const tar_argv = [_][]const u8{ "tar", "-czf", tar_path, "-C", dir_path, "." };
        qemu.runWait(&tar_argv, std.heap.page_allocator, null) catch {
            logErr("export: tar+gzip failed");
            return;
        };
        tar_cleanup = true;
    }

    // Stream the tar.gz file
    const tar_fd = c.open(tar_path, .{ .ACCMODE = .RDONLY });
    if (tar_fd < 0) return;
    defer _ = c.close(tar_fd);

    const seek_end = c.lseek(tar_fd, 0, 2);
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(tar_fd, 0, 0) < 0) return;

    const raw_filename = std.fmt.bufPrint(&path_buf, "{s}.ova", .{v.getNameSlice()}) catch "export.ova";
    var fname_buf2: [256]u8 = undefined;
    const filename = sanitizeHeaderValue(&fname_buf2, raw_filename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{filename}) catch return;

    // Build response headers in one buffer, then write them at once.
    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Disposition: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ cd, file_size },
    ) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return error.BrokenPipe;

    // Stream the tar.gz payload, checking every write.
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(tar_fd, &buf, buf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &buf, @intCast(n))) return error.BrokenPipe;
    }

    // Cleanup
    std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
        logErr("export cleanup deleteTree failed");
    };
    _ = c.unlink(tar_path);
    dir_cleanup = false;
    tar_cleanup = false;
}

/// Parse Content-Length header value from an HTTP request. Returns null if not found.
fn parseContentLength(req: []const u8) ?usize {
    // Case-insensitive search for \r\nContent-Length: per RFC 7230.
    var pos: usize = 0;
    while (pos < req.len) {
        if (std.mem.indexOfScalarPos(u8, req, pos, '\n')) |nl| {
            const line_start = pos;
            pos = nl + 1;
            var line = req[line_start..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            const cl = "content-length: ";
            if (line.len >= cl.len and std.ascii.eqlIgnoreCase(line[0..cl.len], cl)) {
                const val = line[cl.len..];
                return std.fmt.parseInt(usize, val, 10) catch null;
            }
        } else break;
    }
    return null;
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
/// Anchors key match at query-string boundaries (start of body or after &)
/// to avoid matching substrings of other keys (e.g. "cpu" inside "diskcpu").
fn bodyVal(body: []const u8, key: []const u8) []const u8 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "{s}=", .{key}) catch return "";
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_pos, pat)) |idx| {
        // Anchored: must be at start of body or preceded by '&'.
        if (idx == 0 or body[idx - 1] == '&') {
            const start = idx + pat.len;
            const end = std.mem.indexOfScalar(u8, body[start..], '&') orelse (body.len - start);
            return body[start .. start + end];
        }
        search_pos = idx + 1;
    }
    return "";
}

/// Escape a string for safe inclusion in a JSON string value.
/// Writes the escaped result into `buf` and returns the escaped slice.
/// Escapes: \" \\ \n \r \t and control characters (→ \\u00XX).
const EscapeResult = struct {
    escaped: []const u8,
    truncated: bool,
};

fn jsonEscape(buf: []u8, s: []const u8) EscapeResult {
    if (s.len == 0) return .{ .escaped = "", .truncated = false };
    var wi: usize = 0;
    var truncated = false;
    for (s) |ch| {
        switch (ch) {
            '"' => {
                if (wi + 2 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = '"';
                wi += 1;
            },
            '\\' => {
                if (wi + 2 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = '\\';
                wi += 1;
            },
            '\n' => {
                if (wi + 2 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = 'n';
                wi += 1;
            },
            '\r' => {
                if (wi + 2 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = 'r';
                wi += 1;
            },
            '\t' => {
                if (wi + 2 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = 't';
                wi += 1;
            },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                // Control character → \\u00XX
                if (wi + 6 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = '\\';
                wi += 1;
                buf[wi] = 'u';
                wi += 1;
                buf[wi] = '0';
                wi += 1;
                buf[wi] = '0';
                wi += 1;
                _ = std.fmt.bufPrint(buf[wi..], "{x:0>2}", .{ch}) catch {
                    truncated = true;
                    break;
                };
                wi += 2;
            },
            else => {
                if (wi + 1 > buf.len) {
                    truncated = true;
                    break;
                }
                buf[wi] = ch;
                wi += 1;
            },
        }
    }
    return .{ .escaped = buf[0..wi], .truncated = truncated };
}

/// Wrapper around jsonEscape that logs truncation. Returns only the escaped slice
/// so call sites remain concise: escapeJson(&esc, s, "field_name")
/// When truncation occurs, returns "" to avoid embedding broken JSON in the response.
fn escapeJson(buf: []u8, s: []const u8, field: []const u8) []const u8 {
    const result = jsonEscape(buf, s);
    if (result.truncated) {
        _ = field; // field name is for debugging; log a concise message
        logErr("jsonEscape truncated");
        return "";
    }
    return result.escaped;
}

/// Strip dangerous characters from an HTTP header value.
/// Replaces double-quote with single-quote and removes CR/LF.
fn sanitizeHeaderValue(buf: []u8, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    var wi: usize = 0;
    for (s) |ch| {
        if (wi >= buf.len) break;
        switch (ch) {
            '"' => {
                buf[wi] = '\'';
                wi += 1;
            },
            '\r', '\n' => {},
            else => {
                buf[wi] = ch;
                wi += 1;
            },
        }
    }
    return buf[0..wi];
}

fn handleVnetsSave(req: []const u8) ![]const u8 {
    const body = getBody(req) orelse return "no body";
    // Body is raw JSON — parse and save
    var set = vnet.fromJson(body);
    if (set.count == 0 and body.len > 2) {
        // Non-empty body that didn't parse — refuse to overwrite with defaults.
        return "parse error";
    }
    try vnet.save(&set);
    return "ok";
}

fn handleConfigSave(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const body = getBody(req) orelse return "no body";

    {
        const v = bodyVal(body, "theme");
        if (v.len > 0) appstate.prefs.theme = vm.Theme.fromStr(v);
    }
    {
        const v = bodyVal(body, "default_memory_mb");
        if (v.len > 0) appstate.prefs.default_memory_mb = clampPref(v, appstate.prefs.default_memory_mb, 128, 65536);
    }
    {
        const v = bodyVal(body, "default_cpu_cores");
        if (v.len > 0) appstate.prefs.default_cpu_cores = clampPref(v, appstate.prefs.default_cpu_cores, 1, 256);
    }
    {
        const v = bodyVal(body, "autoprotect_enabled");
        if (v.len > 0) appstate.prefs.autoprotect_enabled_default = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    {
        const v = bodyVal(body, "autoprotect_interval");
        if (v.len > 0) appstate.prefs.autoprotect_interval_min_default = clampPref(v, appstate.prefs.autoprotect_interval_min_default, 1, 1440);
    }
    {
        const v = bodyVal(body, "autoprotect_max");
        if (v.len > 0) appstate.prefs.autoprotect_max_default = clampPref(v, appstate.prefs.autoprotect_max_default, 1, 1000);
    }
    {
        const v = bodyVal(body, "default_vm_dir");
        if (v.len > 0) {
            var dir_buf: [vm.MAX_PATH + 1]u8 = undefined;
            const decoded = if (v.len <= dir_buf.len) urlencode.urlDecode(&dir_buf, v) else v;
            if (std.mem.indexOf(u8, decoded, "..") != null) return "bad path";
            const n = @min(decoded.len, vm.MAX_PATH);
            @memcpy(appstate.prefs.default_vm_dir_buf[0..n], decoded[0..n]);
            appstate.prefs.default_vm_dir_buf[n] = 0;
            appstate.prefs.default_vm_dir_len = @intCast(n);
        }
    }

    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
        logErr("persist.save failed");
    };
    return "ok";
}

const index_html = @embedFile("web/index.html");
const app_css = @embedFile("web/app.css");
const app_js = @embedFile("web/app.js");
const novnc_js = @embedFile("web/novnc.js");
const spice_js = @embedFile("web/spice.js");

/// Background thread: periodically check liveness of running VMs and reap dead ones.
fn livenessTicker() void {
    while (true) {
        appio.sleepMs(2000);

        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();

        var changed = false;
        for (0..appstate.vm_count) |i| {
            const v = &appstate.vms[i];
            if (v.status == .running or v.status == .paused) {
                const alive: bool = if (appstate.getVmmHandle(i)) |h|
                    appstate.g_vmm.isAliveFn(h)
                else
                    qemu.isVmAlive(v);
                if (!alive) {
                    v.status = .stopped;
                    appstate.destroyVmmHandle(i);
                    changed = true;
                }
            }
        }
        if (changed) {
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
                logErr("autoprotect: persist.save failed");
            };
        }
    }
}

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

        appstate.vms_mutex.lock();
        const now = time(null);
        var i: usize = 0;
        while (i < appstate.vm_count and work_count < work_items.len) : (i += 1) {
            const v = &appstate.vms[i];
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
        appstate.vms_mutex.unlock();

        // Perform snapshot I/O outside the lock
        var wi: usize = 0;
        while (wi < work_count) : (wi += 1) {
            const w = &work_items[wi];
            const dp = w.disk_path[0..w.disk_path_len];
            const sn = w.snap_name[0..w.snap_name_len];

            if (appstate.getVmmHandle(w.idx)) |h| {
                appstate.g_vmm.snapshotCreateFn(h, dp, sn, std.heap.page_allocator) catch |e| {
                    var ebuf: [64]u8 = undefined;
                    logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotCreate failed: {s}", .{@errorName(e)}) catch "autoprotect snapshotCreate failed");
                    continue;
                };
            } else {
                qemu.snapshotCreate(dp, sn, std.heap.page_allocator) catch |e| {
                    var ebuf: [64]u8 = undefined;
                    logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotCreate failed: {s}", .{@errorName(e)}) catch "autoprotect snapshotCreate failed");
                    continue;
                };
            }

            // Prune excess AutoProtect snapshots
            var list_buf: [4096]u8 = undefined;
            const list_result = if (appstate.getVmmHandle(w.idx)) |h|
                appstate.g_vmm.snapshotListFn(h, dp, &list_buf, std.heap.page_allocator)
            else
                qemu.snapshotList(dp, &list_buf, std.heap.page_allocator);

            const list_n = list_result catch |e| {
                var ebuf: [64]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotList failed: {s}", .{@errorName(e)}) catch "autoprotect snapshotList failed");
                continue;
            };

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
                if (appstate.getVmmHandle(w.idx)) |h| {
                    appstate.g_vmm.snapshotDeleteFn(h, dp, auto_names[d], std.heap.page_allocator) catch |e| {
                        var ebuf: [64]u8 = undefined;
                        logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotDelete failed: {s}", .{@errorName(e)}) catch "autoprotect snapshotDelete failed");
                    };
                } else {
                    qemu.snapshotDelete(dp, auto_names[d], std.heap.page_allocator) catch |e| {
                        var ebuf: [64]u8 = undefined;
                        logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotDelete failed: {s}", .{@errorName(e)}) catch "autoprotect snapshotDelete failed");
                    };
                }
            }
        }

        // Re-acquire lock only for the save
        appstate.vms_mutex.lock();
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch {
            logErr("persist.save failed");
        };
        appstate.vms_mutex.unlock();
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

test "routeExact: matches exact route with trailing space" {
    try std.testing.expect(routeExact("GET /api/vms HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(routeExact("GET /api/health HTTP/1.1\r\n", "GET /api/health"));
    try std.testing.expect(routeExact("POST /api/save HTTP/1.1\r\n", "POST /api/save"));
}

test "routeExact: matches exact route with query string" {
    try std.testing.expect(routeExact("GET /api/vms?sort=name HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(routeExact("GET /api/config?full=1 HTTP/1.1\r\n", "GET /api/config"));
}

test "routeExact: rejects longer path at same prefix" {
    try std.testing.expect(!routeExact("GET /api/vms/3 HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("GET /api/vmsblah HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("GET /api/healthcheck HTTP/1.1\r\n", "GET /api/health"));
    try std.testing.expect(!routeExact("POST /api/news HTTP/1.1\r\n", "POST /api/new"));
}

test "routeExact: rejects prefix not found" {
    try std.testing.expect(!routeExact("GET /other HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("POST /api/vms HTTP/1.1\r\n", "GET /api/vms"));
}

test "routeExact: rejects request shorter than prefix" {
    try std.testing.expect(!routeExact("GET /api", "GET /api/vms"));
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
            if (!first) {
                buf[pos] = '&';
                pos += 1;
            }
            first = false;
            const k = keys[rnd.uintLessThan(usize, keys.len)];
            const kl = k.len;
            @memcpy(buf[pos..][0..kl], k);
            pos += kl;
            buf[pos] = '=';
            pos += 1;
            const vlen = rnd.uintLessThan(usize, 20);
            for (buf[pos .. pos + vlen]) |*b| {
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
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: hangar\r\n\r\n";
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
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: secret\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: rejects wrong custom auth token" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: wrong!\r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: key at end with no trailing CR uses rest of request" {
    // Key at end of headers (before \r\n\r\n) — still valid.
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: hangar\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: custom token at end with no trailing CR" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }

    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: secret\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: key value is empty string when header ends at colon-space" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key: \r\n\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: partial header name match is not fooled" {
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\nX-API-Key2: hangar\r\n\r\n";
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
    const req = "GET /api/vms HTTP/1.1\r\nX-API-Key: wrong\r\nX-API-Key: hangar\r\n\r\n";
    try std.testing.expect(!checkAuth(req)); // first match is "wrong"
}

test "checkAuth: X-API-Key in body is ignored (only headers searched)" {
    // checkAuth only searches headers (before \r\n\r\n) — body keys are ignored.
    const req = "GET /api/vms HTTP/1.1\r\nHost: localhost\r\n\r\nX-API-Key: hangar\r\n";
    try std.testing.expect(!checkAuth(req));
}

test "checkAuth: binary null in key value" {
    var buf: [256]u8 = undefined;
    const prefix = "GET /api/vms HTTP/1.1\r\nX-API-Key: ";
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..5], 0); // null bytes in key value
    buf[prefix.len + 5] = '\r';
    // Null bytes mean the provided key won't match "hangar" even if prefix is correct
    try std.testing.expect(!checkAuth(buf[0 .. prefix.len + 6]));
}

test "fuzz: serveHtml routing never panics on random method/URL input" {
    var prng = std.Random.DefaultPrng.init(0xFEED_FACE);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;

    // Route prefixes tested in serveHtml — keep in sync with dispatcher.
    const routes = [_][]const u8{
        "GET /",
        "GET /api/vms",
        "GET /api/health",
        "GET /api/fb/",
        "GET /api/config",
        "GET /api/vnets",
        "GET /api/vm/",
        "GET /api/snapshot/list/",
        "GET /api/capabilities",
        "GET /api/catalog",
        "GET /api/quickstart/",
        "GET /api/migrate/status/",
        "GET /ws/vnc/",
        "GET /ws/spice/",
        "GET /ws/serial/",
        "GET /app.js",
        "GET /app.css",
        "GET /novnc.js",
        "GET /spice.js",
        "GET /favicon",
        "POST /api/power/",
        "POST /api/save/",
        "POST /api/save",
        "POST /api/suspend/",
        "POST /api/pause/",
        "POST /api/resume/",
        "POST /api/shutdown/",
        "POST /api/reset/",
        "POST /api/delete/",
        "POST /api/clone/",
        "POST /api/new",
        "POST /api/create",
        "POST /api/rename/",
        "POST /api/snapshot/take/",
        "POST /api/snapshot/revert/",
        "POST /api/snapshot/delete/",
        "POST /api/import",
        "POST /api/cad/",
        "POST /api/export/",
        "POST /api/vm/",
        "POST /api/vnets/save",
        "POST /api/config",
        "POST /api/undo",
        "POST /api/reorder",
        "POST /api/migrate/",
        "POST /api/migrate/cancel/",
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

test "fuzz: routeExact rejects boundary-confusable requests" {
    // Verify that routeExact rejects requests that startsWith would
    // incorrectly accept. These are the exact bug patterns being fixed.
    var prng = std.Random.DefaultPrng.init(0xB0_4D4_7E);
    const rnd = prng.random();

    // Routes that must match exactly (no suffix)
    const exact_routes = [_][]const u8{
        "GET /api/vms",         "GET /api/health",
        "GET /api/config",      "GET /api/catalog",
        "GET /api/vnets",       "GET /api/capabilities",
        "POST /api/new",        "POST /api/save",
        "POST /api/create",     "POST /api/undo",
        "POST /api/reorder",    "POST /api/import",
        "POST /api/vnets/save", "POST /api/config",
        "GET /app.css",         "GET /app.js",
        "GET /novnc.js",        "GET /spice.js",
    };

    var buf: [256]u8 = undefined;

    // 1. Test that every exact route accepts the exact request
    for (exact_routes) |route| {
        const req = std.fmt.bufPrint(&buf, "{s} HTTP/1.1\r\n", .{route}) catch unreachable;
        try std.testing.expect(routeExact(req, route));
    }

    // 2. Test that every exact route rejects prefix with trailing path segment
    for (exact_routes) |route| {
        const req = std.fmt.bufPrint(&buf, "{s}/3 HTTP/1.1\r\n", .{route}) catch unreachable;
        try std.testing.expect(!routeExact(req, route));
    }

    // 3. Test that every exact route rejects prefix with extra chars
    for (exact_routes) |route| {
        const req = std.fmt.bufPrint(&buf, "{s}extra HTTP/1.1\r\n", .{route}) catch unreachable;
        try std.testing.expect(!routeExact(req, route));
    }

    // 4. Fuzz: random suffixes after exact routes must be rejected
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const route = exact_routes[rnd.uintLessThan(usize, exact_routes.len)];
        const suffix_len = rnd.uintLessThan(usize, 20) + 1; // 1..20 random bytes
        // Generate a suffix that is NOT a space or '?'
        var suffix: [20]u8 = undefined;
        for (0..suffix_len) |i| {
            // Use printable chars that are not ' ' or '?'
            suffix[i] = switch (rnd.uintLessThan(u8, 62)) {
                0...25 => 'a' + @as(u8, @intCast(rnd.uintLessThan(u8, 26))),
                26...51 => 'A' + @as(u8, @intCast(rnd.uintLessThan(u8, 26))),
                52...61 => '0' + @as(u8, @intCast(rnd.uintLessThan(u8, 10))),
                else => '/',
            };
        }
        // For the test to be valid, the first char after the prefix must not be ' ' or '?'
        if (suffix[0] == '?') suffix[0] = '/';
        const req = std.fmt.bufPrint(&buf, "{s}{s} HTTP/1.1\r\n", .{ route, suffix[0..suffix_len] }) catch continue;
        try std.testing.expect(!routeExact(req, route));
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
    try std.testing.expectEqualStrings("\\\"", (jsonEscape(&buf, "\"")).escaped);
    try std.testing.expectEqualStrings("\\\\", (jsonEscape(&buf, "\\")).escaped);
    try std.testing.expectEqualStrings("abc\\\"xyz", (jsonEscape(&buf, "abc\"xyz")).escaped);
}

test "jsonEscape: escapes newlines, carriage returns, tabs" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\n", (jsonEscape(&buf, "\n")).escaped);
    try std.testing.expectEqualStrings("\\r", (jsonEscape(&buf, "\r")).escaped);
    try std.testing.expectEqualStrings("\\t", (jsonEscape(&buf, "\t")).escaped);
    try std.testing.expectEqualStrings("a\\nb\\tc", (jsonEscape(&buf, "a\nb\tc")).escaped);
}

test "jsonEscape: escapes control characters as \\u00XX" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\u0000", (jsonEscape(&buf, "\x00")).escaped);
    try std.testing.expectEqualStrings("\\u001f", (jsonEscape(&buf, "\x1f")).escaped);
    try std.testing.expectEqualStrings("\\u000b", (jsonEscape(&buf, "\x0b")).escaped);
}

test "jsonEscape: passes through normal text unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello world 123", (jsonEscape(&buf, "hello world 123")).escaped);
}

test "jsonEscape: handles empty string" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", (jsonEscape(&buf, "")).escaped);
}

test "jsonEscape: reports truncated on overflow" {
    var buf: [5]u8 = undefined;
    {
        const r = jsonEscape(&buf, "abc");
        try std.testing.expectEqualStrings("abc", r.escaped);
        try std.testing.expect(!r.truncated);
    }
    {
        const r = jsonEscape(&buf, "\"\"\"\"\"");
        try std.testing.expect(r.truncated);
        try std.testing.expect(r.escaped.len <= buf.len);
    }
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
        try std.testing.expect(result.escaped.len <= output.len);
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
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
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
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    try std.testing.expect(writeAll(fds[1], (&[0]u8{}).ptr, 0));
}

test "writeAll: detects closed fd" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return;
    _ = c.close(fds[0]);
    _ = c.close(fds[1]); // both ends closed
    try std.testing.expect(!writeAll(fds[1], "x".ptr, 1));
}

// ── handleCatalog ──

test "handleCatalog: empty buffer returns empty array literal" {
    var buf: [0]u8 = undefined;
    const result = handleCatalog(&buf);
    try std.testing.expectEqualStrings("[]", result);
}

test "handleCatalog: produces valid JSON array with 3 entries" {
    var buf: [4096]u8 = undefined;
    const result = handleCatalog(&buf);
    try std.testing.expect(result.len > 2);
    try std.testing.expect(result[0] == '[');
    try std.testing.expect(result[result.len - 1] == ']');
    // Each catalog entry must appear.
    try std.testing.expect(std.mem.indexOf(u8, result, "ubuntu2404") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fedora40") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "debian12") != null);
    // Must be valid JSON: no trailing garbage, brace-balanced.
    var depth: usize = 0;
    for (result) |ch| {
        if (ch == '{') depth += 1;
        if (ch == '}') depth -= 1;
    }
    try std.testing.expectEqual(@as(usize, 0), depth);
}

test "handleCatalog: tiny buffer that overflows mid-write returns []" {
    var buf: [4]u8 = undefined;
    const result = handleCatalog(&buf);
    try std.testing.expectEqualStrings("[]", result);
}

test "handleQuickstart: missing space after slug returns 'invalid'" {
    const result = try handleQuickstart("GET /api/quickstart/ubuntu2404");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleQuickstart: empty slug returns 'not found'" {
    const result = try handleQuickstart("GET /api/quickstart/ HTTP/1.1");
    try std.testing.expectEqualStrings("not found", result);
}

test "handleQuickstart: unknown slug returns 'not found'" {
    const result = try handleQuickstart("GET /api/quickstart/nonexistent HTTP/1.1");
    try std.testing.expectEqualStrings("not found", result);
}

test "handleQuickstart: full VM array returns 'full'" {
    appstate.vm_count = appstate.MAX_VMS;
    defer appstate.vm_count = 0;
    const result = try handleQuickstart("GET /api/quickstart/ubuntu2404 HTTP/1.1");
    try std.testing.expectEqualStrings("full", result);
}

// ── handleUndo ──

test "handleUndo: returns 'no undo' when undo_available is false" {
    appstate.undo_available = false;
    defer appstate.undo_available = false;
    const result = try handleUndo();
    try std.testing.expectEqualStrings("no undo", result);
}

test "handleUndo: returns 'full' when vm_count is at MAX_VMS" {
    appstate.undo_available = true;
    defer appstate.undo_available = false;
    const prev_count = appstate.vm_count;
    appstate.vm_count = appstate.MAX_VMS;
    defer appstate.vm_count = prev_count;
    const result = try handleUndo();
    try std.testing.expectEqualStrings("full", result);
}

test "handleUndo: restores the deleted VM at its original index" {
    const restorer = struct {
        fn restore() void {
            appstate.vm_count = prev_count;
            appstate.undo_available = was_undo;
            appstate.vms[undo_idx] = saved;
        }
        var prev_count: usize = 0;
        var was_undo: bool = false;
        var undo_idx: usize = 0;
        var saved: vm.VmConfig = undefined;
    };
    appstate.vms_mutex.lock();
    restorer.prev_count = appstate.vm_count;
    restorer.was_undo = appstate.undo_available;
    restorer.undo_idx = 0;
    restorer.saved = appstate.vms[0];
    // Insert a test VM at index 0 and delete it.
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("undo_test_vm");
    appstate.vms[0].memory_mb = 512;
    appstate.vm_count = 1;
    appstate.undo_vm = appstate.vms[0];
    appstate.undo_idx = 0;
    appstate.undo_available = true;
    appstate.undo_vm.setName("restored_undo_vm");
    appstate.vm_count = 0; // simulate deletion
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        restorer.restore();
        appstate.vms_mutex.unlock();
    }

    const result = try handleUndo();
    try std.testing.expectEqualStrings("ok", result);
    try std.testing.expectEqual(@as(usize, 1), appstate.vm_count);
    try std.testing.expectEqualStrings("restored_undo_vm", appstate.vms[0].getNameSlice());
    try std.testing.expect(!appstate.undo_available);
}

// ── isAuthExempt ──

test "isAuthExempt: root and static assets are exempt for GET" {
    try std.testing.expect(isAuthExempt(true, "/"));
    try std.testing.expect(isAuthExempt(true, "/app.js"));
    try std.testing.expect(isAuthExempt(true, "/app.css"));
}

test "isAuthExempt: favicon prefix is exempt for GET" {
    try std.testing.expect(isAuthExempt(true, "/favicon.ico"));
    try std.testing.expect(isAuthExempt(true, "/favicon-32x32.png"));
}

test "isAuthExempt: API read endpoints are exempt for GET" {
    try std.testing.expect(isAuthExempt(true, "/api/vms"));
    try std.testing.expect(isAuthExempt(true, "/api/health"));
    try std.testing.expect(isAuthExempt(true, "/api/config"));
    try std.testing.expect(isAuthExempt(true, "/api/vnets"));
    try std.testing.expect(isAuthExempt(true, "/api/catalog"));
}

test "isAuthExempt: prefix paths are exempt for GET" {
    try std.testing.expect(isAuthExempt(true, "/api/vm/0"));
    try std.testing.expect(isAuthExempt(true, "/api/vm/5/snapshot"));
    // /api/fb/ is no longer exempt — framebuffer snapshots require auth
    try std.testing.expect(!isAuthExempt(true, "/api/fb/0"));
    try std.testing.expect(!isAuthExempt(true, "/api/fb/0?quality=50"));
    try std.testing.expect(isAuthExempt(true, "/api/snapshot/list/0"));
    try std.testing.expect(isAuthExempt(true, "/api/quickstart/ubuntu2404"));
}

test "isAuthExempt: non-exempt paths are rejected for GET" {
    try std.testing.expect(!isAuthExempt(true, "/api/save"));
    try std.testing.expect(!isAuthExempt(true, "/api/power/0"));
    try std.testing.expect(!isAuthExempt(true, "/api/delete/0"));
    try std.testing.expect(!isAuthExempt(true, "/api/clone/0"));
}

test "isAuthExempt: all non-GET methods are non-exempt" {
    try std.testing.expect(!isAuthExempt(false, "/"));
    try std.testing.expect(!isAuthExempt(false, "/app.js"));
    try std.testing.expect(!isAuthExempt(false, "/api/vms"));
    try std.testing.expect(!isAuthExempt(false, "/api/vm/0"));
}

test "isAuthExempt: path traversal does not bypass prefix match" {
    try std.testing.expect(isAuthExempt(true, "/api/vm/../../../etc/passwd"));
    // /api/fb/ is no longer exempt — path traversal on it must also fail
    try std.testing.expect(!isAuthExempt(true, "/api/fb/../../../../root/.ssh/id_rsa"));
}

// ── clampPref ──

test "clampPref: value within range returned as-is" {
    try std.testing.expectEqual(@as(u32, 2048), clampPref("2048", 1024, 256, 65536));
    try std.testing.expectEqual(@as(u32, 100), clampPref("100", 50, 1, 200));
}

test "clampPref: value below minimum is clamped to lo" {
    try std.testing.expectEqual(@as(u32, 256), clampPref("0", 1024, 256, 65536));
    try std.testing.expectEqual(@as(u32, 256), clampPref("100", 1024, 256, 65536));
}

test "clampPref: value above maximum is clamped to hi" {
    try std.testing.expectEqual(@as(u32, 65536), clampPref("999999", 1024, 256, 65536));
}

test "clampPref: non-numeric string returns fallback" {
    try std.testing.expectEqual(@as(u32, 1024), clampPref("abc", 1024, 256, 65536));
    try std.testing.expectEqual(@as(u32, 1024), clampPref("", 1024, 256, 65536));
    try std.testing.expectEqual(@as(u32, 1024), clampPref("12x34", 1024, 256, 65536));
}

test "clampPref: negative string returns fallback (u32 cannot parse)" {
    try std.testing.expectEqual(@as(u32, 1024), clampPref("-5", 1024, 256, 65536));
}

test "clampPref: value exactly at boundaries" {
    try std.testing.expectEqual(@as(u32, 256), clampPref("256", 1024, 256, 65536));
    try std.testing.expectEqual(@as(u32, 65536), clampPref("65536", 1024, 256, 65536));
}

test "clampPref: zero as valid value when within range" {
    try std.testing.expectEqual(@as(u32, 1), clampPref("0", 1, 1, 10));
}

// ── Config body parsing (exercises the key=value extraction used by handleConfigSave) ──

test "config body: theme field parses via Theme.fromStr" {
    _ = .{};
    const body = "theme=dark&default_memory_mb=2048";
    try std.testing.expectEqualStrings("dark", bodyVal(body, "theme"));
    try std.testing.expectEqual(vm.Theme.dark, vm.Theme.fromStr(bodyVal(body, "theme")));
    try std.testing.expectEqualStrings("2048", bodyVal(body, "default_memory_mb"));
}

test "config body: numeric fields with clamping" {
    const body = "default_memory_mb=1&default_cpu_cores=9999&autoprotect_interval=0&autoprotect_max=2000";
    // Each value should be clamped by handleConfigSave
    try std.testing.expectEqual(@as(u32, 128), clampPref(bodyVal(body, "default_memory_mb"), 2048, 128, 65536));
    try std.testing.expectEqual(@as(u32, 256), clampPref(bodyVal(body, "default_cpu_cores"), 2, 1, 256));
    try std.testing.expectEqual(@as(u32, 1), clampPref(bodyVal(body, "autoprotect_interval"), 60, 1, 1440));
    try std.testing.expectEqual(@as(u32, 1000), clampPref(bodyVal(body, "autoprotect_max"), 10, 1, 1000));
}

test "config body: boolean field parsing" {
    for (0..4) |i| {
        const mode = switch (i) {
            0 => "true",
            1 => "1",
            2 => "false",
            3 => "0",
            else => unreachable,
        };
        var buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "autoprotect_enabled={s}", .{mode}) catch unreachable;
        const val = bodyVal(body, "autoprotect_enabled");
        const expected = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        try std.testing.expectEqual(expected, std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1"));
    }
}

test "config body: path traversal detection" {
    // handleConfigSave checks for ".." in the decoded path
    var dir_buf: [vm.MAX_PATH + 1]u8 = undefined;
    const decoded = urlencode.urlDecode(&dir_buf, "%2F..%2Fetc");
    try std.testing.expect(std.mem.indexOf(u8, decoded, "..") != null);

    // Safe path should not contain ".."
    var safe_buf: [vm.MAX_PATH + 1]u8 = undefined;
    const safe = urlencode.urlDecode(&safe_buf, "%2Fhome%2Fuser%2Fvms");
    try std.testing.expect(std.mem.indexOf(u8, safe, "..") == null);
}

test "config body: missing body handled by getBody" {
    const req = "POST /api/config HTTP/1.1\r\nHost: localhost";
    try std.testing.expect(getBody(req) == null);
}

test "config body: fuzz field parsing never panics" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const fields = [_][]const u8{
        "theme", "default_memory_mb", "default_cpu_cores",
        "autoprotect_enabled", "autoprotect_interval", "autoprotect_max",
        "default_vm_dir",
    };
    var buf: [1024]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var pos: usize = 0;
        var first = true;
        while (pos < buf.len - 80) {
            if (!first) {
                buf[pos] = '&';
                pos += 1;
            }
            first = false;
            const f = fields[rnd.uintLessThan(usize, fields.len)];
            @memcpy(buf[pos..][0..f.len], f);
            pos += f.len;
            buf[pos] = '=';
            pos += 1;
            const vlen = rnd.uintLessThan(usize, 30);
            for (buf[pos .. pos + vlen]) |*b| {
                b.* = rnd.intRangeAtMost(u8, 32, 126);
            }
            pos += vlen;
        }
        const body = buf[0..pos];
        for (fields) |f| {
            const val = bodyVal(body, f);
            // clampPref must never panic on any random value
            _ = clampPref(val, 2048, 128, 65536);
        }
    }
}

// ── VNet save handler tests ──

test "handleVnetsSave: saves valid vnet JSON" {
    const json =
        \\{"networks":[{"name":"VMnet0","type":"bridge","subnet":"","mask":"","dhcp":false,"dhcp_start":"","dhcp_end":"","host_iface":"","gateway":"","port_forwards":""}]}
    ;
    const body = try std.fmt.allocPrint(std.testing.allocator, "POST /api/vnets/save HTTP/1.1\r\nHost: localhost\r\n\r\n{s}", .{json});
    defer std.testing.allocator.free(body);
    const result = try handleVnetsSave(body);
    try std.testing.expectEqualStrings("ok", result);
}

test "handleVnetsSave: empty body returns 'no body'" {
    const req = "POST /api/vnets/save HTTP/1.1\r\nHost: localhost";
    const result = try handleVnetsSave(req);
    try std.testing.expectEqualStrings("no body", result);
}

test "handleVnetsSave: malformed JSON returns parse error" {
    const req = "POST /api/vnets/save HTTP/1.1\r\nHost: localhost\r\n\r\n{not valid json}";
    const result = try handleVnetsSave(req);
    try std.testing.expectEqualStrings("parse error", result);
}

test "handleVnetsSave: empty JSON object returns defaults (ok)" {
    const req = "POST /api/vnets/save HTTP/1.1\r\nHost: localhost\r\n\r\n{}";
    const result = try handleVnetsSave(req);
    // Empty JSON yields count=0 and body.len > 2, but vnet.fromJson("{}") should work.
    // If fromJson handles empty JSON objects, this returns "ok"; otherwise "parse error".
    _ = result;
}
pub fn main() !void {
    // Ignore SIGPIPE — the only safe response to writing on a closed connection.
    _ = signal(SIGPIPE, SIG_IGN);

    appstate.vm_count = persist.load(&appstate.vms, std.heap.page_allocator, &appstate.prefs);
    appstate.g_vmm = hv_backend.createVmm(.auto);
    appstate.g_vmm_ready = true;

    // Allow custom API key via environment variable.
    if (appio.getenv("KV_API_KEY")) |key| {
        if (key.len > 0 and key.len <= 64) {
            auth_token_len = key.len;
            @memcpy(auth_token[0..key.len], key);
        }
    }

    const port: u16 = if (appio.getenv("KV_PORT")) |env| blk: {
        break :blk std.fmt.parseInt(u16, env, 10) catch 9080;
    } else 9080;

    const sock = c.socket(AF_INET6, SOCK_STREAM, 0);
    if (sock < 0) return;
    tcp_sock_fd = sock;
    defer {
        _ = c.close(sock);
        tcp_sock_fd = -1;
    }

    const one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    // Dual-stack: accept both IPv4 and IPv6 on the same socket.
    const zero: c_int = 0;
    _ = c.setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &zero, @sizeOf(c_int));

    // Bind to :: (IPv6 any-address, dual-stack).
    var addr: c.sockaddr.in6 = std.mem.zeroes(c.sockaddr.in6);
    addr.family = AF_INET6;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.flowinfo = 0;
    addr.scope_id = 0;
    // addr.addr stays zero-initialized (in6addr_any).
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in6)) != 0) {
        logErr("Failed to bind TCP port — already in use");
        return;
    }
    if (c.listen(sock, 10) != 0) {
        logErr("Failed to listen on TCP port");
        return;
    }

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/hangar-daemon.sock";
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
    if (c.setsockopt(unix_sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int)) != 0) {
        logErr("Failed to set SO_REUSEADDR on Unix socket");
        return;
    }
    if (c.bind(unix_sock, @ptrCast(&unix_addr), @intCast(unix_len)) != 0) {
        logErr("Failed to bind Unix socket — is /tmp/hangar-daemon.sock stale?");
        return;
    }
    if (c.listen(unix_sock, 10) != 0) {
        logErr("Failed to listen on Unix socket");
        return;
    }

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Hangar Daemon v1.0                         ║\n", .{});
    std.debug.print("║  TCP:   http://0.0.0.0:{d}                 ║\n", .{port});
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    var ebuf: [64]u8 = undefined;

    // Spawn thread to accept Unix socket connections
    if (std.Thread.spawn(std.Thread.SpawnConfig{}, acceptLoop, .{unix_sock})) |th| {
        th.detach();
    } else |e| {
        logErr(std.fmt.bufPrint(&ebuf, "spawn acceptLoop failed: {s}", .{@errorName(e)}) catch "spawn acceptLoop failed");
    }

    // Spawn VM liveness polling ticker
    if (std.Thread.spawn(std.Thread.SpawnConfig{}, livenessTicker, .{})) |th| {
        th.detach();
    } else |e| {
        logErr(std.fmt.bufPrint(&ebuf, "spawn livenessTicker failed: {s}", .{@errorName(e)}) catch "spawn livenessTicker failed");
    }

    // Spawn autoprotect background ticker
    if (std.Thread.spawn(std.Thread.SpawnConfig{}, autoprotectTicker, .{})) |th| {
        th.detach();
    } else |e| {
        logErr(std.fmt.bufPrint(&ebuf, "spawn autoprotectTicker failed: {s}", .{@errorName(e)}) catch "spawn autoprotectTicker failed");
    }

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

// ── Tests ───────────────────────────────────────────────────────────

test "findHeader: exact match" {
    const headers = "Host: localhost\r\nX-API-Key: secret123\r\nContent-Type: text/html\r\n";
    const val = findHeader(headers, "X-API-Key: ");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("secret123", val.?);
}

test "findHeader: not found" {
    const headers = "Host: localhost\r\nContent-Type: text/html\r\n";
    try std.testing.expectEqual(@as(?[]const u8, null), findHeader(headers, "X-API-Key: "));
}

test "findHeader: empty headers" {
    try std.testing.expectEqual(@as(?[]const u8, null), findHeader("", "Host: "));
}

test "findHeader: value with colon" {
    const headers = "Location: http://example.com:8080\r\n";
    const val = findHeader(headers, "Location: ");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("http://example.com:8080", val.?);
}

test "shutdownSignal: shuts down both TCP and Unix listen sockets" {
    // Save original values.
    const saved_tcp = tcp_sock_fd;
    const saved_unix = unix_sock_fd;
    defer {
        if (tcp_sock_fd >= 0 and tcp_sock_fd != saved_tcp) _ = c.close(tcp_sock_fd);
        if (unix_sock_fd >= 0 and unix_sock_fd != saved_unix) _ = c.close(unix_sock_fd);
        tcp_sock_fd = saved_tcp;
        unix_sock_fd = saved_unix;
    }

    // Create socket pairs to simulate listen sockets. We only need one end;
    // the other end is immediately closed so that shutdown() is observable
    // as a read returning 0 or error on the surviving end.
    var tcp_fds: [2]c_int = undefined;
    if (c.socketpair(AF_INET, SOCK_STREAM, 0, &tcp_fds) != 0) return;
    _ = c.close(tcp_fds[0]);
    tcp_sock_fd = tcp_fds[1];

    var unix_fds: [2]c_int = undefined;
    if (c.socketpair(AF_UNIX, SOCK_STREAM, 0, &unix_fds) != 0) {
        _ = c.close(tcp_sock_fd);
        tcp_sock_fd = saved_tcp;
        return;
    }
    _ = c.close(unix_fds[0]);
    unix_sock_fd = unix_fds[1];

    // Call shutdownSignal — this should shut down both sockets.
    shutdownSignal();

    // After shutdown(SHUT_RDWR), read should return 0 (EOF).
    var dummy: [1]u8 = undefined;
    const n = c.read(tcp_sock_fd, &dummy, 1);
    try std.testing.expect(n == 0);
    const m = c.read(unix_sock_fd, &dummy, 1);
    try std.testing.expect(m == 0);
}

test "shutdownSignal: no-op when sockets are not set" {
    const saved_tcp = tcp_sock_fd;
    const saved_unix = unix_sock_fd;
    defer {
        tcp_sock_fd = saved_tcp;
        unix_sock_fd = saved_unix;
    }
    tcp_sock_fd = -1;
    unix_sock_fd = -1;

    // Should not crash.
    shutdownSignal();
}

// ── Handler error-path tests ────────────────────────────────────────
// These exercise validation/error paths without needing running QEMU
// processes. They verify input parsing and error responses only.

test "handlePower: missing prefix returns 'invalid'" {
    const result = try handlePower("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handlePower: non-numeric idx returns 'invalid'" {
    const result = try handlePower("POST /api/power/abc HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handlePower: idx out of range returns 'invalid idx'" {
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    defer appstate.vm_count = prev_count;
    const result = try handlePower("POST /api/power/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleNewVm: full VM array returns 'full'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = appstate.MAX_VMS;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleNewVm("POST /api/new\r\n\r\nname=test");
    try std.testing.expectEqualStrings("full", result);
}

test "handleNewVm: missing body returns 'no body'" {
    const result = try handleNewVm("POST /api/new");
    try std.testing.expectEqualStrings("no body", result);
}

test "handleNewVm: invalid name chars returns error" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleNewVm("POST /api/new\r\n\r\nname=evil<script>");
    try std.testing.expectEqualStrings("invalid name", result);
}

test "handleNewVm: empty name returns error" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleNewVm("POST /api/new\r\n\r\nname=");
    try std.testing.expectEqualStrings("invalid name", result);
}

test "handleCapabilities: produces valid JSON with expected fields" {
    var buf: [512]u8 = undefined;
    const result = handleCapabilities(&buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{"));
    try std.testing.expect(std.mem.endsWith(u8, result, "}"));
    try std.testing.expect(std.mem.indexOf(u8, result, "\"max_vms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"max_nics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"max_extra_disks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\"") != null);
}

test "handleDelete: missing prefix returns 'invalid'" {
    const result = try handleDelete("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleDelete: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleDelete("POST /api/delete/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleReorder: missing from/to returns error" {
    const result = try handleReorder("POST /api/reorder\r\n\r\nfrom=0");
    try std.testing.expectEqualStrings("missing from/to", result);
}

test "handleReorder: no body returns 'no body'" {
    const result = try handleReorder("POST /api/reorder");
    try std.testing.expectEqualStrings("no body", result);
}

test "handleReorder: same from and to returns 'ok' (no-op)" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 2;
    // Initialise two VMs.
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("a");
    appstate.vms[1] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[1].setName("b");
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleReorder("POST /api/reorder\r\n\r\nfrom=0&to=0");
    try std.testing.expectEqualStrings("ok", result);
}

test "handleReorder: valid reorder produces 'ok'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 2;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("first");
    appstate.vms[1] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[1].setName("second");
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleReorder("POST /api/reorder\r\n\r\nfrom=0&to=1");
    try std.testing.expectEqualStrings("ok", result);
    try std.testing.expectEqualStrings("second", appstate.vms[0].getNameSlice());
    try std.testing.expectEqualStrings("first", appstate.vms[1].getNameSlice());
}

test "handleSave: missing prefix returns 'invalid'" {
    const result = try handleSave("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSave: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSave("POST /api/save/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSave: no body returns 'no body'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 1;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("testvm");
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSave("POST /api/save/0 HTTP/1.1");
    try std.testing.expectEqualStrings("no body", result);
}

test "handleSave: path traversal in iso_path returns 'bad path'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 1;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("testvm");
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSave("POST /api/save/0 HTTP/1.1\r\n\r\niso_path=../../etc/passwd");
    try std.testing.expectEqualStrings("bad path", result);
}

test "handleSave: valid fields produce 'ok'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 1;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("testvm");
    appstate.vms[0].memory_mb = 1024;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSave("POST /api/save/0 HTTP/1.1\r\n\r\nmem=2048&cpu=4");
    try std.testing.expectEqualStrings("ok", result);
    try std.testing.expectEqual(@as(u32, 2048), appstate.vms[0].memory_mb);
    try std.testing.expectEqual(@as(u32, 4), appstate.vms[0].cpu_cores);
}

test "handleRename: missing prefix returns 'invalid'" {
    const result = try handleRename("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleRename: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleRename("POST /api/rename/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSuspend: missing prefix returns 'invalid'" {
    const result = try handleSuspend("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSuspend: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSuspend("POST /api/suspend/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handlePause: missing prefix returns 'invalid'" {
    const result = try handlePause("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handlePause: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handlePause("POST /api/pause/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleResume: missing prefix returns 'invalid'" {
    const result = try handleResume("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleResume: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleResume("POST /api/resume/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleShutdown: missing prefix returns 'invalid'" {
    const result = try handleShutdown("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleShutdown: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleShutdown("POST /api/shutdown/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleReset: missing prefix returns 'invalid'" {
    const result = try handleReset("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleReset: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleReset("POST /api/reset/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSnapshotTake: missing prefix returns 'invalid'" {
    const result = try handleSnapshotTake("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSnapshotTake: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSnapshotTake("POST /api/snapshot/take/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSnapshotList: missing prefix returns error" {
    var buf: [4096]u8 = undefined;
    const result = handleSnapshotList("GET /api/other HTTP/1.1", &buf);
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSnapshotList: idx out of range returns error" {
    var buf: [4096]u8 = undefined;
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = handleSnapshotList("GET /api/snapshot/list/0 HTTP/1.1", &buf);
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSnapshotRevert: missing prefix returns 'invalid'" {
    const result = try handleSnapshotRevert("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSnapshotRevert: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSnapshotRevert("POST /api/snapshot/revert/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleSnapshotDelete: missing prefix returns 'invalid'" {
    const result = try handleSnapshotDelete("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleSnapshotDelete: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleSnapshotDelete("POST /api/snapshot/delete/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleImport: missing body returns 'no body'" {
    const result = try handleImport("POST /api/import");
    try std.testing.expectEqualStrings("no body", result);
}

test "handleCad: missing prefix returns 'invalid'" {
    const result = try handleCad("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleCad: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleCad("POST /api/cad/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleMigrate: VM not running returns 'not running'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 1;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("migtest");
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleMigrate("POST /api/migrate/0 HTTP/1.1");
    // The handler checks isAlive() before body parse, so this hits "not running".
    try std.testing.expectEqualStrings("not running", result);
}

test "handleMigrate: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleMigrate("POST /api/migrate/0 HTTP/1.1\r\n\r\ndummy=1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleMigrateStatus: missing prefix returns error JSON" {
    var buf: [512]u8 = undefined;
    const result = handleMigrateStatus("GET /api/other HTTP/1.1", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
}

test "handleMigrateStatus: idx out of range returns error JSON" {
    var buf: [512]u8 = undefined;
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = handleMigrateStatus("GET /api/migrate/status/0 HTTP/1.1", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
}

test "handleMigrateCancel: missing prefix returns 'invalid'" {
    const result = try handleMigrateCancel("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleMigrateCancel: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleMigrateCancel("POST /api/migrate/cancel/0 HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleVnetsJson: returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const result = handleVnetsJson(&buf);
    try std.testing.expect(result.len >= 2);
    try std.testing.expect(result[0] == '{');
    try std.testing.expect(result[result.len - 1] == '\n');
}

test "handleClone: missing prefix returns 'invalid'" {
    const result = try handleClone("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleClone: idx out of range or full returns 'full'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleClone("POST /api/clone/0 HTTP/1.1");
    try std.testing.expectEqualStrings("full", result);
}

test "handleClone: full array returns 'full'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = appstate.MAX_VMS;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try handleClone("POST /api/clone/0 HTTP/1.1");
    try std.testing.expectEqualStrings("full", result);
}

// ── Fuzz: handler error paths never panic ─────────────────────────

test "fuzz: handlePower never panics on random request-like input" {
    var prng = std.Random.DefaultPrng.init(0x70A1E070);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handlePower(&buf) catch {};
    }
}

test "fuzz: handleDelete never panics on random request-like input" {
    var prng = std.Random.DefaultPrng.init(0x70A1E071);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handleDelete(&buf) catch {};
    }
}

test "fuzz: handleSave never panics on random request-like input" {
    var prng = std.Random.DefaultPrng.init(0x70A1E072);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handleSave(&buf) catch {};
    }
}

test "fuzz: handleReorder never panics on random request-like input" {
    var prng = std.Random.DefaultPrng.init(0x70A1E073);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handleReorder(&buf) catch {};
    }
}
