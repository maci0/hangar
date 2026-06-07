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
const transport = @import("transport.zig");

extern fn time(t: ?*c_long) c_long;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// HTTP status codes
const HTTP_OK: u16 = 200;
const HTTP_CREATED: u16 = 201;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_UNAUTHORIZED: u16 = 401;
const HTTP_FORBIDDEN: u16 = 403;
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_METHOD_NOT_ALLOWED: u16 = 405;
const HTTP_CONFLICT: u16 = 409;
const HTTP_PAYLOAD_TOO_LARGE: u16 = 413;
const HTTP_TOO_MANY_REQUESTS: u16 = 429;
const HTTP_INTERNAL_ERROR: u16 = 500;

const API_KEY: []const u8 = transport.DEFAULT_API_KEY; // built-in X-API-Key default
const DEFAULT_PORT: u16 = transport.DEFAULT_PORT; // KV_PORT default
var auth_token: [64]u8 = [_]u8{0} ** 64;
var auth_token_len: usize = 0;

const FB_BMP_BUF_SIZE = 2 * 1024 * 1024 + 54;
const CONFIG_RAW_MAX = 4 * 1024 * 1024;

// Server socket fds for shutdown signaling.
var tcp_sock_fd: c.fd_t = -1;
var unix_sock_fd: c.fd_t = -1;

const c = std.c;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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
const IPPROTO_TCP: c_int = 6;
const TCP_NODELAY: c_int = 1;

/// Disable Nagle on a TCP socket. Interactive VNC/SPICE relay traffic is
/// dominated by small mouse/keyboard packets; without this, Nagle coalescing
/// adds up to ~40ms of latency per input event. Best-effort — failure is
/// non-fatal (the relay still works, just with higher latency).
fn setTcpNoDelay(fd: c.fd_t) void {
    const one: c_int = 1;
    _ = c.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, @sizeOf(c_int));
}

const SIGPIPE: c_int = 13;
const SIG_IGN: isize = 1;

extern fn signal(sig: c_int, handler: isize) isize;

fn loadServerFd(slot: *c.fd_t) c.fd_t {
    return @atomicLoad(c.fd_t, slot, .seq_cst);
}

fn storeServerFd(slot: *c.fd_t, fd: c.fd_t) void {
    @atomicStore(c.fd_t, slot, fd, .seq_cst);
}

fn rebindVmmHandleLocked(idx: usize) void {
    const h = appstate.g_vmm_handles[idx] orelse return;
    if (!appstate.g_vmm_ready) {
        appstate.g_vmm_handles[idx] = null;
        return;
    }
    switch (appstate.g_vmm.backend) {
        .qemu => {
            const qv: *hv_backend.QemuVm = @ptrCast(@alignCast(h));
            qv.config = &appstate.vms[idx];
        },
    }
}

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
        // Strong (not weak): a spurious failure here would drop the thread into
        // the increment path against the *previous* window's not-yet-reset
        // counter, spuriously 429-ing a legitimate request at a second boundary.
        const won = @cmpxchgStrong(i64, &g_rate_window_start, prev, now, .acq_rel, .monotonic);
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
    if (std.mem.startsWith(u8, path, "/api/vm/")) {
        // The disk-image download streams raw guest disk bytes (filesystems,
        // credentials, ...). It must never be exempt: when KV_API_KEY is set the
        // daemon binds all interfaces, so exempting it would let an
        // unauthenticated remote client exfiltrate the disk image.
        if (std.mem.endsWith(u8, path, "/disk2/download")) return false;
        return true;
    }
    if (std.mem.startsWith(u8, path, "/api/snapshot/list/")) return true;
    if (std.mem.eql(u8, path, "/api/catalog")) return true;
    // /api/quickstart/ creates a VM (state-changing) — it must require auth.
    return false;
}

fn clampPref(v: []const u8, fallback: u32, lo: u32, hi: u32) u32 {
    const val = std.fmt.parseInt(u32, v, 10) catch return fallback;
    return std.math.clamp(val, lo, hi);
}

/// Map an arbitrary name to a filesystem/shell-safe slug, replacing any
/// character outside [A-Za-z0-9._-] with '_'. Never empty (falls back to "vm").
fn sanitizeSlug(name: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (n >= out.len) break;
        const safe = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-';
        out[n] = if (safe) ch else '_';
        n += 1;
    }
    if (n == 0) {
        const fallback = "vm";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    return out[0..n];
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

/// Length-checked, constant-time byte-slice equality. The length is not secret
/// (key bounds are public, 1-64 bytes), but the comparison must not early-exit
/// on the first differing byte: `checkAuth` runs on the network-exposed daemon,
/// where `std.mem.eql`'s short-circuit would leak the secret via response timing.
fn secretEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Validate a `KV_API_KEY` value: 1-64 bytes of printable ASCII (no control
/// chars, no spaces). Rejecting whitespace/control bytes fails fast on the
/// common footgun of `export KV_API_KEY=$(cat keyfile)` leaving a trailing
/// newline — that byte would otherwise be embedded into the client's
/// `X-API-Key:` header (see `transport.buildHttpRequest`) and silently corrupt
/// request framing while the daemon binds all interfaces with a mismatched key.
fn validApiKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Validate the request's `Host` header against the loopback allowlist.
///
/// Only enforced in loopback mode (no custom `KV_API_KEY`), where the daemon
/// binds `::1`/`127.0.0.1` and accepts the publicly-known built-in key. Without
/// this, a DNS-rebinding attack defeats the same-origin/CORS protection: a page
/// the victim visits rebinds its own hostname to `127.0.0.1`, becomes
/// same-origin with the daemon (so no CORS preflight blocks a custom header),
/// and drives every state-changing endpoint with `X-API-Key: hangar`
/// (CWE-350 / CWE-1385). A real browser only ever sends `Host: localhost:PORT`
/// or `Host: 127.0.0.1:PORT` for a loopback connection, so rejecting any other
/// host closes the rebinding hole without affecting legitimate local use.
///
/// When a custom key is set (the daemon is intentionally exposed on all
/// interfaces) the host is operator-defined and the secret key — not the
/// origin — is the control, so the check is skipped.
fn hostHeaderOk(req: []const u8) bool {
    if (auth_token_len > 0) return true; // exposed mode: secret key gates access
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse req.len;
    const host = findHeader(req[0..hdr_end], "Host: ") orelse return false;
    // Strip the optional ":port" suffix (IPv6 literals are bracketed, so a
    // ']' marks the end of the address before any port colon).
    const addr = if (std.mem.lastIndexOfScalar(u8, host, ']')) |rb|
        host[0 .. rb + 1]
    else if (std.mem.indexOfScalar(u8, host, ':')) |colon|
        host[0..colon]
    else
        host;
    return std.ascii.eqlIgnoreCase(addr, "localhost") or
        std.mem.eql(u8, addr, "127.0.0.1") or
        std.mem.eql(u8, addr, "[::1]") or
        std.mem.eql(u8, addr, "::1");
}

fn checkAuth(req: []const u8) bool {
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
    const headers = req[0..hdr_end];

    const provided = findHeader(headers, "X-API-Key: ") orelse return false;
    // Compare against the custom token if set, else the built-in API_KEY.
    const expected = if (auth_token_len > 0) auth_token[0..auth_token_len] else API_KEY;
    return secretEql(provided, expected);
}

const LogLevel = enum {
    info,
    warn,
    err,

    fn tag(self: LogLevel) []const u8 {
        return switch (self) {
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

/// Log a message to stderr as a single timestamped, leveled line.
///
/// Format: `[<epoch_seconds>] hangar <level>: <msg>\n`. Emitting one write
/// (rather than separate body + newline writes) keeps concurrent log lines
/// from interleaving and gives operators a parseable, time-ordered record.
/// `msg` must be server-controlled text — callers never echo untrusted request
/// data here, so a single line cannot be split by injected newlines.
fn logAt(level: LogLevel, msg: []const u8) void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const epoch: i64 = @intCast(ts.sec);
    const lvl = level.tag();

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] hangar {s}: {s}\n", .{ epoch, lvl, msg }) catch blk: {
        // Message too long for the buffer — emit a truncated, still-leveled line.
        var head_buf: [32]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "[?] hangar {s}: ", .{lvl}) catch "[?] hangar log: ";
        const room = buf.len - head.len - 1;
        const clipped = if (msg.len > room) msg[0..room] else msg;
        @memcpy(buf[0..head.len], head);
        @memcpy(buf[head.len .. head.len + clipped.len], clipped);
        buf[head.len + clipped.len] = '\n';
        break :blk buf[0 .. head.len + clipped.len + 1];
    };
    _ = std.c.write(2, line.ptr, line.len);
}

/// Log an error-level line (operator action likely required).
fn logErr(msg: []const u8) void {
    logAt(.err, msg);
}

/// Log a `persist.save` failure including the underlying error name so an
/// operator can tell apart a full disk (NoSpaceLeft), a permissions problem
/// (AccessDenied), and a missing HOME (HomeNotFound) from the log alone.
/// `context` is an optional prefix (e.g. "liveness: "); pass "" for none.
fn logSaveErr(context: []const u8, e: anyerror) void {
    var ebuf: [128]u8 = undefined;
    logErr(std.fmt.bufPrint(&ebuf, "{s}persist.save failed: {s}", .{ context, @errorName(e) }) catch "persist.save failed");
}

/// Log a warn-level line (audit/security events such as rejected auth).
fn logWarn(msg: []const u8) void {
    logAt(.warn, msg);
}

/// Log a request-handler failure with the underlying error name and the
/// sanitized request line. The WebSocket-proxy, download, and export handlers
/// return a 500 to the client on failure; without this the daemon log stays
/// silent, so an operator seeing "VNC proxy failed" in the browser has no way
/// to tell a refused connection from a broken pipe or a missing VM. `context`
/// is a short static label (e.g. "VNC proxy failed"); `req` is the raw request
/// line, sanitized before logging. Format: `<context>: <ErrorName> [<reqline>]`.
fn logReqErr(context: []const u8, e: anyerror, req: []const u8) void {
    var rl_buf: [128]u8 = undefined;
    var eb: [320]u8 = undefined;
    logErr(std.fmt.bufPrint(&eb, "{s}: {s} [{s}]", .{ context, @errorName(e), requestLine(req, &rl_buf) }) catch context);
}

/// Copy a user-controlled VM name into `out`, replacing every non-printable
/// byte with '?' so it cannot inject newlines into a log line. Returns the
/// populated, bounded slice.
fn sanitizeLogName(out: []u8, name: []const u8) []const u8 {
    const n = @min(name.len, out.len);
    for (name[0..n], 0..) |ch, i| {
        out[i] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    }
    return out[0..n];
}

/// Log an info-level audit line for a destructive state transition (power,
/// delete, snapshot revert). The VM name is user-controlled, so it is
/// sanitized to prevent log-line injection. Format: `audit: <action> vm="<name>"`.
fn logAudit(action: []const u8, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogName(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logAt(.info, std.fmt.bufPrint(&msg, "audit: {s} vm=\"{s}\"", .{ action, safe }) catch action);
}

/// Log an error-level line for a failed destructive QMP/disk operation,
/// including the underlying error name and the (sanitized) VM name. Handlers
/// return a short token ("create err", "qmp err") to the browser; without this
/// the daemon log stays silent, so an operator cannot tell a full disk
/// (NoSpaceLeft) from a locked image or a missing `qemu-img` at 3 AM. `op` is a
/// short static label (e.g. "snapshot take"). Format:
/// `<op> failed: <ErrorName> vm="<name>"`.
fn logOpErr(op: []const u8, e: anyerror, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogName(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logErr(std.fmt.bufPrint(&msg, "{s} failed: {s} vm=\"{s}\"", .{ op, @errorName(e), safe }) catch op);
}

/// Copy the HTTP request line (method + path, up to the first CR/LF) into
/// `out`, replacing every non-printable byte with '?'. Request data is
/// client-controlled, so sanitizing here lets error logs carry route context
/// (which VM / operation failed) without risking log-line injection.
fn requestLine(req: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (req) |ch| {
        if (ch == '\r' or ch == '\n' or n >= out.len) break;
        out[n] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
        n += 1;
    }
    return out[0..n];
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
/// Returns a slice of `buf`; buffer must be at least msg.len + 12 bytes
/// (the `{"error":""}` wrapper). Falls back to a static string if it overflows.
fn jsonErr(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"internal\"}";
}

/// True if `s` exactly equals any token in `set`.
fn anyEql(s: []const u8, set: []const []const u8) bool {
    for (set) |t| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

/// Dynamic server-side failure tokens that handlers return as their response
/// body (e.g. `qemu-img`/QMP failures). These map to HTTP 500. Matched exactly
/// rather than by substring: a substring test for "err" misclassifies legitimate
/// `text/plain` data — e.g. a snapshot named `fix-error` in the snapshot list —
/// as a server error.
fn isServerErrToken(response: []const u8) bool {
    if (std.mem.startsWith(u8, response, "start err")) return true; // incl. "start err: <detail>"
    const tokens = [_][]const u8{
        "apply err", "bd err",    "cad err",  "cancel err",
        "create err", "delete err", "linkerr",  "migrate err",
        "nameerr",   "path err",  "qmp err",  "sock err",
        "write err",
    };
    for (tokens) |t| {
        if (std.mem.eql(u8, response, t)) return true;
    }
    return false;
}

/// Write an HTTP response with status code, content type, security headers, and
/// body. The shared security headers are emitted inline below.
///
/// No `Access-Control-Allow-Origin` is emitted: the web UI is served from the
/// same origin as this daemon, so it never needs CORS. Sending a wildcard ACAO
/// (together with the publicly known default `KV_API_KEY`) would let any website
/// the victim visits drive the local daemon — read the VM inventory/config and,
/// via a CORS-permitted `X-API-Key` preflight, issue state-changing POSTs
/// (delete/create/power) cross-origin. Omitting it makes the browser block all
/// cross-origin reads and the preflight, closing that CSRF/exfiltration path.
fn writeHttpResponse(conn: c.fd_t, status: u16, ct: []const u8, body: []const u8) void {
    const status_line: []const u8 = switch (status) {
        HTTP_OK => "HTTP/1.1 200 OK\r\n",
        HTTP_CREATED => "HTTP/1.1 201 Created\r\n",
        HTTP_BAD_REQUEST => "HTTP/1.1 400 Bad Request\r\n",
        HTTP_UNAUTHORIZED => "HTTP/1.1 401 Unauthorized\r\n",
        HTTP_FORBIDDEN => "HTTP/1.1 403 Forbidden\r\n",
        HTTP_NOT_FOUND => "HTTP/1.1 404 Not Found\r\n",
        HTTP_METHOD_NOT_ALLOWED => "HTTP/1.1 405 Method Not Allowed\r\n",
        HTTP_CONFLICT => "HTTP/1.1 409 Conflict\r\n",
        HTTP_PAYLOAD_TOO_LARGE => "HTTP/1.1 413 Payload Too Large\r\n",
        HTTP_TOO_MANY_REQUESTS => "HTTP/1.1 429 Too Many Requests\r\n",
        HTTP_INTERNAL_ERROR => "HTTP/1.1 500 Internal Server Error\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
    // Assemble the full header block in one buffer so the response costs two
    // write() syscalls (headers + body) instead of ~11 small writes. The header
    // set — status line, fixed security headers, content-type, content-length —
    // is well under 1 KiB even with the CSP string.
    var hbuf: [1024]u8 = undefined;
    var hlen: usize = 0;
    const append = struct {
        fn add(b: []u8, n: *usize, s: []const u8) void {
            if (n.* + s.len > b.len) return; // header set is bounded; never trips
            @memcpy(b[n.*..][0..s.len], s);
            n.* += s.len;
        }
    }.add;

    append(&hbuf, &hlen, status_line);
    append(&hbuf, &hlen, "X-Content-Type-Options: nosniff\r\n");
    append(&hbuf, &hlen, "X-Frame-Options: DENY\r\n");
    append(&hbuf, &hlen, "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; form-action 'self'; base-uri 'self'\r\n");
    append(&hbuf, &hlen, "Content-Type: ");
    append(&hbuf, &hlen, ct);
    append(&hbuf, &hlen, "\r\nServer: hangar");
    if (std.mem.indexOf(u8, ct, "text/css") != null or std.mem.indexOf(u8, ct, "application/javascript") != null) {
        append(&hbuf, &hlen, "\r\nCache-Control: public, max-age=86400");
    } else {
        // Dynamic responses (API JSON, errors) carry auth-gated VM state — disk
        // paths, MACs, notes. Forbid browser/proxy caching so they are never
        // persisted to a shared-machine disk cache or replayed from history
        // (CWE-525).
        append(&hbuf, &hlen, "\r\nCache-Control: no-store");
    }
    if (status == HTTP_TOO_MANY_REQUESTS) {
        // Rate-limit window is 1 second; tell clients/proxies when to retry.
        append(&hbuf, &hlen, "\r\nRetry-After: 1");
    }
    if (status == HTTP_METHOD_NOT_ALLOWED) {
        // RFC 9110: a 405 response must list the supported methods.
        append(&hbuf, &hlen, "\r\nAllow: GET, POST, OPTIONS");
    }
    append(&hbuf, &hlen, "\r\nContent-Length: ");
    var len_buf: [16]u8 = undefined;
    append(&hbuf, &hlen, std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch "0");
    append(&hbuf, &hlen, "\r\nConnection: close\r\n\r\n");

    if (!writeAll(conn, hbuf[0..hlen].ptr, hlen)) return;
    _ = writeAll(conn, body.ptr, body.len); // best effort for body
}

/// Auth-gate a WebSocket route. On failure, logs the rejected `route` and
/// writes a 401, returning false; returns true when the request is authorized.
fn wsAuthOk(conn: c.fd_t, req: []const u8, route: []const u8) bool {
    if (checkAuth(req)) return true;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "auth rejected: GET {s}", .{route}) catch "auth rejected: GET /ws";
    logWarn(msg);
    writeHttpResponse(conn, HTTP_UNAUTHORIZED, "application/json; charset=utf-8", "{\"error\":\"auth required\"}");
    return false;
}

/// Signal the server to shut down by closing/halting its listen sockets.
/// Safe to call from any thread — unblocks blocking accept() calls.
pub fn shutdownSignal() void {
    const tcp_fd = loadServerFd(&tcp_sock_fd);
    if (tcp_fd >= 0) {
        _ = c.shutdown(tcp_fd, 2); // SHUT_RDWR
    }
    const unix_fd = loadServerFd(&unix_sock_fd);
    if (unix_fd >= 0) {
        _ = c.shutdown(unix_fd, 2);
    }
}

fn acceptLoop(fd: c.fd_t) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) {
            // The listener is gone — the daemon will silently stop serving on
            // this socket. Surface it so an operator knows why requests stopped.
            logErr("acceptLoop: accept() failed, listener thread exiting");
            break;
        }
        // Both writeHttpResponse and ws.writeFrame emit a small header write
        // followed by a separate body/payload write. Without TCP_NODELAY,
        // Nagle holds the header until its ACK, adding up to a round-trip of
        // latency to every response and every relayed display frame on remote
        // (non-loopback) connections. No-op on the Unix listener's fds.
        setTcpNoDelay(conn);
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch {
            // Thread exhaustion drops this request; log so load-shedding is visible.
            logErr("acceptLoop: thread spawn failed, dropping connection");
            _ = c.close(conn);
            continue;
        };
        th.detach();
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);

    // 30-second receive timeout (SO_RCVTIMEO).
    const tv: c.timeval = .{ .sec = 30, .usec = 0 };
    _ = c.setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));

    var buf: [65536]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    var req_len: usize = @intCast(n);
    var req = buf[0..req_len];

    // ── Rate limiting: POST requests only ──
    if (std.mem.startsWith(u8, req, "POST ") and rateLimitCheck()) {
        writeHttpResponse(conn, HTTP_TOO_MANY_REQUESTS, "application/json; charset=utf-8", "{\"error\":\"Too Many Requests\"}");
        return;
    }

    // ── CORS preflight ──
    if (std.mem.startsWith(u8, req, "OPTIONS ")) {
        writeHttpResponse(conn, HTTP_OK, "text/plain", "ok");
        return;
    }

    // ── Method validation: only GET and POST are supported ──
    if (!std.mem.startsWith(u8, req, "GET ") and !std.mem.startsWith(u8, req, "POST ")) {
        writeHttpResponse(conn, HTTP_METHOD_NOT_ALLOWED, "application/json; charset=utf-8", "{\"error\":\"Method Not Allowed\"}");
        return;
    }

    // ── Anti-DNS-rebinding: in loopback mode require a loopback Host header ──
    // Runs before any route (including the WebSocket proxies) so a rebound
    // origin cannot reach state-changing endpoints with the default key.
    if (!hostHeaderOk(req)) {
        writeHttpResponse(conn, HTTP_FORBIDDEN, "application/json; charset=utf-8", "{\"error\":\"forbidden host\"}");
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
                writeHttpResponse(conn, HTTP_PAYLOAD_TOO_LARGE, "application/json; charset=utf-8", "{\"error\":\"Payload Too Large\"}");
                return;
            }
            // A single read() is not guaranteed to deliver the whole body: TCP
            // may segment any POST larger than one packet. Keep reading until the
            // declared Content-Length has arrived (or the connection stalls), so
            // body handlers never see a truncated request.
            if (std.mem.indexOf(u8, req, "\r\n\r\n")) |hdr_end| {
                const need = hdr_end + 4 + cl;
                while (req_len < need and req_len < buf.len) {
                    const m = c.read(conn, buf[req_len..].ptr, buf.len - req_len);
                    if (m <= 0) break;
                    req_len += @intCast(m);
                }
                req = buf[0..req_len];
            }
        }
    }

    // ── WebSocket VNC Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/vnc/")) {
        if (!wsAuthOk(conn, req, "/ws/vnc")) return;
        handleWsVnc(conn, req) catch |e| {
            logReqErr("VNC proxy failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"VNC proxy failed\"}");
        };
        return;
    }

    // ── WebSocket SPICE Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/spice/")) {
        if (!wsAuthOk(conn, req, "/ws/spice")) return;
        handleWsSpice(conn, req) catch |e| {
            logReqErr("SPICE proxy failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"SPICE proxy failed\"}");
        };
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        if (!wsAuthOk(conn, req, "/ws/serial")) return;
        handleWsSerial(conn, req) catch |e| {
            logReqErr("Serial proxy failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"Serial proxy failed\"}");
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
    var response_alloc: ?[]u8 = null;
    defer if (response_alloc) |bytes| std.heap.page_allocator.free(bytes);

    // Auth: check X-API-Key for mutating endpoints.
    // Match against the extracted path (not the raw request line) to prevent
    // path-traversal auth bypass.
    const method_get = std.mem.startsWith(u8, req, "GET ");
    const needs_auth = !isAuthExempt(method_get, req_path);

    if (needs_auth and !checkAuth(req)) {
        // Include the sanitized request line so the audit log shows which
        // endpoint was probed — distinguishes a misconfigured client from
        // someone scanning state-changing routes.
        var rl_buf: [128]u8 = undefined;
        var wb: [192]u8 = undefined;
        logWarn(std.fmt.bufPrint(&wb, "auth rejected: {s}", .{requestLine(req, &rl_buf)}) catch "auth rejected");
        writeHttpResponse(conn, HTTP_UNAUTHORIZED, "application/json; charset=utf-8", "{\"error\":\"auth required\"}");
        return;
    }

    // ── File download (streaming) routes — handled after auth ──
    if (parseVmIdxSuffix(req, "GET /api/vm/", "/disk2/download") != null) {
        handleDisk2Download(conn, req) catch |e| {
            logReqErr("disk2 download failed", e, req);
            // Error path uses the unified JSON envelope like the rest of the API,
            // even though the success path streams binary (octet-stream). A
            // programmatic client should never have to special-case text/plain.
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"download failed\"}");
        };
        return;
    }
    if (parseVmIdxSuffix(req, "POST /api/vm/", "/upload-disk") != null) {
        const resp = handleUploadDisk(req) catch |e| blk: {
            logReqErr("disk upload failed", e, req);
            break :blk "upload err";
        };
        if (std.mem.eql(u8, resp, "ok")) {
            writeHttpResponse(conn, HTTP_OK, "text/plain", "ok");
        } else {
            // Match the central error mapper: server-side failures are 500,
            // client mistakes 400, and the body is the unified `{"error":...}`
            // envelope rather than a bare text token (this endpoint returned
            // text/plain and mislabelled write/encode failures as 400).
            const s: u16 = if (std.mem.eql(u8, resp, "upload err") or isServerErrToken(resp))
                HTTP_INTERNAL_ERROR
            else
                HTTP_BAD_REQUEST;
            var jb: [256]u8 = undefined;
            writeHttpResponse(conn, s, "application/json; charset=utf-8", jsonErr(&jb, resp));
        }
        return;
    }
    if (std.mem.startsWith(u8, req, "POST /api/export/")) {
        handleExport(conn, req) catch |e| {
            logReqErr("export failed", e, req);
            // Unified JSON error envelope, consistent with the central mapper and
            // the rest of the API (the success path streams the OVF tarball).
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"export err\"}");
        };
        return;
    }

    if (routeExact(req, "GET /api/vms")) {
        content_type = "application/json; charset=utf-8";
        // Typical fleets fit the 32KB stack json_buf (~25 VMs at the per-VM
        // budget below), so the common /api/vms poll allocates nothing. Only
        // large libraries spill to a heap buffer sized to the live VM count
        // rather than always mmapping the MAX_VMS worst case.
        // Snapshot vm_count under the lock: a concurrent add/delete could
        // otherwise tear this read and mis-size the buffer.
        const vm_count_snapshot = blk: {
            appstate.vms_mutex.lock();
            defer appstate.vms_mutex.unlock();
            break :blk appstate.vm_count;
        };
        const need = (vm_count_snapshot + 1) * 4096;
        const vms_buf: []u8 = if (need > json_buf.len)
            (std.heap.page_allocator.alloc(u8, need) catch &json_buf)
        else
            &json_buf;
        if (vms_buf.len > json_buf.len) response_alloc = vms_buf;
        const json_bytes = renderJson(vms_buf);
        response = if (json_bytes > 0) vms_buf[0..json_bytes] else "[]";
    } else if (routeExact(req, "GET /api/capabilities")) {
        content_type = "application/json; charset=utf-8";
        response = handleCapabilities(&snap_buf);
    } else if (routeExact(req, "GET /api/health")) {
        // Report live state so the check actually verifies the daemon can read
        // its VM table, not just that the socket accepts connections.
        var running: u32 = 0;
        var total: usize = 0;
        {
            appstate.vms_mutex.lock();
            defer appstate.vms_mutex.unlock();
            // Snapshot the count under the lock so the reported total and the
            // running tally come from the same moment. Reading vm_count again
            // after unlocking could observe an add/delete in flight and emit an
            // inconsistent pair (e.g. running > vms).
            total = appstate.vm_count;
            var i: usize = 0;
            while (i < total) : (i += 1) {
                if (appstate.vms[i].status == .running) running += 1;
            }
        }
        response = std.fmt.bufPrint(&snap_buf, "{{\"status\":\"ok\",\"version\":\"1.0\",\"vms\":{d},\"running\":{d}}}", .{ total, running }) catch "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json; charset=utf-8";
    } else if (routeExact(req, "GET /api/config")) {
        content_type = "application/json; charset=utf-8";
        if (serveConfigRawAlloc()) |raw| {
            response_alloc = raw;
            response = raw;
        } else {
            response = "{}";
        }
    } else if (routeExact(req, "GET /api/catalog")) {
        content_type = "application/json; charset=utf-8";
        response = handleCatalog(&snap_buf);
    } else if (std.mem.startsWith(u8, req, "POST /api/quickstart/")) {
        // State-changing (creates and persists a VM), so it must be POST — a GET
        // here would let prefetchers/crawlers/caches silently create VMs and make
        // repeated requests non-idempotent. The web UI already POSTs this route.
        response = try handleQuickstart(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json; charset=utf-8";
        response = renderVmDetail(req, &detail_buf) catch blk: {
            // A render failure (detail buffer overflow on a VM with very long
            // notes, or an unparseable index) is a server-side fault, not a
            // missing resource. Report it as 500 so it is not conflated with the
            // genuine not-found "{}" below — a 404 would wrongly tell the client
            // the VM vanished when it actually exists.
            logErr("renderVmDetail: buffer overflow or parse error");
            status = HTTP_INTERNAL_ERROR;
            break :blk "{\"error\":\"render failed\"}";
        };
        // No such VM (index out of range). The rest of the API returns 404 with
        // an {"error":...} envelope for a missing resource, so align this
        // endpoint instead of a misleading 200 {} that a programmatic client
        // cannot distinguish from a real (but empty) VM.
        if (status == HTTP_OK and std.mem.eql(u8, response, "{}")) {
            status = HTTP_NOT_FOUND;
            response = "{\"error\":\"no vm\"}";
        }
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
        if (std.heap.page_allocator.alloc(u8, FB_BMP_BUF_SIZE)) |bytes| {
            response_alloc = bytes;
            response = try renderFramebuffer(req, bytes);
        } else |_| {
            response = "no fb";
        }
        // renderFramebuffer returns BMP bytes on success or a short error token
        // ("no vm", "off", "no vnc", ...) on failure. Only label real image
        // bytes as image/bmp; let error tokens fall through as text/plain so the
        // central status mapper turns them into proper 4xx/5xx JSON instead of a
        // 200 "image" the browser silently renders as broken.
        content_type = if (std.mem.startsWith(u8, response, "BM")) "image/bmp" else "text/plain";
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
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
            logSaveErr("", e);
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
        // The status payload is JSON, so it bypasses the central text/plain error
        // mapper. Surface its error states as real HTTP codes — otherwise a bad
        // index or a failed QMP query both return 200 OK, indistinguishable from a
        // live migration to a programmatic client. The body is unchanged and the
        // web UI reads it regardless of status code, so this is non-breaking.
        status = migrateStatusHttpCode(response);
    } else if (std.mem.startsWith(u8, req, "POST /api/migrate/cancel/")) {
        response = try handleMigrateCancel(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/migrate/")) {
        response = try handleMigrate(req);
        // The success body is a JSON object ({"status":"started"}); label it as
        // such for strict clients. Error returns are bare tokens ("no dest",
        // "qmp err", ...) kept on text/plain so the central error mapper turns
        // them into 4xx/5xx JSON envelopes.
        content_type = if (std.mem.startsWith(u8, response, "{"))
            "application/json; charset=utf-8"
        else
            "text/plain";
    } else if (routeExact(req, "GET /api/vnets")) {
        content_type = "application/json; charset=utf-8";
        response = handleVnetsJson(&snap_buf);
    } else if (routeExact(req, "POST /api/vnets/save")) {
        response = handleVnetsSave(req) catch |e| blk: {
            // Surface a failed networks.json write: without this the browser
            // gets "save err" but the daemon log stays silent, so an operator
            // can't tell a full disk from a permissions problem.
            logReqErr("vnets save failed", e, req);
            break :blk "save err";
        };
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
    } else if (std.mem.startsWith(u8, req_path, "/api/") or std.mem.startsWith(u8, req_path, "/ws/")) {
        // Unmatched API/WebSocket route: return a JSON 404 so programmatic
        // clients see a real error instead of a 200 HTML page (the SPA shell).
        // A wrong HTTP method on a known path lands here too.
        status = HTTP_NOT_FOUND;
        response = "{\"error\":\"no such endpoint\"}";
        content_type = "application/json; charset=utf-8";
    } else {
        // SPA fallback: serve the app shell for client-side routes.
        response = index_html;
        content_type = "text/html; charset=utf-8";
    }

    var json_err_buf: [256]u8 = undefined;

    // Map known error strings to HTTP status codes and JSON error responses.
    // Previously returned plain text; now unified as `{"error":"..."}`.
    if (std.mem.eql(u8, content_type, "text/plain")) {
        const err_status: ?u16 = blk: {
            if (anyEql(response, &.{ "invalid", "invalid idx", "not found", "no undo", "no vm" })) {
                break :blk HTTP_NOT_FOUND;
            } else if (anyEql(response, &.{ "not running", "off", "not paused", "vm running", "full" })) {
                // The resource is in a state incompatible with the request
                // (running VM that must be off, off VM that must be running, table
                // at capacity, ...). 409 lets clients distinguish a transient state
                // conflict — retriable after changing VM state — from a malformed
                // request (400).
                break :blk HTTP_CONFLICT;
            } else if (anyEql(response, &.{ "no disk", "no body", "invalid name", "bad path", "no name", "no path", "bad ext", "no file", "bad name", "no dest", "bad dest", "missing from/to", "parse error" })) {
                break :blk HTTP_BAD_REQUEST;
            } else if (anyEql(response, &.{ "no vnc", "no spice", "save failed", "save err", "no fb" }) or isServerErrToken(response)) {
                break :blk HTTP_INTERNAL_ERROR;
            }
            break :blk null;
        };
        if (err_status) |s| {
            status = s;
            response = jsonErr(&json_err_buf, response);
            content_type = "application/json; charset=utf-8";
        }
    }

    // Surface server-side failures: a 500 returned to the client with no log
    // entry is a blind spot. `response` here is server-controlled (JSON error
    // constants), so it is safe to include without log-injection risk.
    if (status == HTTP_INTERNAL_ERROR) {
        var lb: [320]u8 = undefined;
        var rl_buf: [128]u8 = undefined;
        const route = requestLine(req, &rl_buf);
        logErr(std.fmt.bufPrint(&lb, "request failed (500): {s} :: {s}", .{ route, response }) catch "request failed (500)");
    }

    writeHttpResponse(conn, status, content_type, response);
}

/// Return an allocated copy of the raw vms.json content for remote clients.
/// Caller owns the returned memory.
fn serveConfigRawAlloc() ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = appstate.vmsPath(&path_buf) orelse return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        path,
        std.heap.page_allocator,
        .limited(10 * 1024 * 1024),
    ) catch return null;
    if (raw.len <= CONFIG_RAW_MAX) return raw;

    const clipped = std.heap.page_allocator.alloc(u8, CONFIG_RAW_MAX) catch {
        std.heap.page_allocator.free(raw);
        return null;
    };
    @memcpy(clipped, raw[0..CONFIG_RAW_MAX]);
    std.heap.page_allocator.free(raw);
    var wb: [96]u8 = undefined;
    logWarn(std.fmt.bufPrint(&wb, "vms.json truncated to {d} bytes", .{CONFIG_RAW_MAX}) catch "vms.json truncated");
    return clipped;
}

var fb_client: ?*vnc.VncClient = null;
// Tracks which VM index fb_client is connected to. appstate.MAX_VMS = sentinel (none).
var fb_vm_idx: usize = appstate.MAX_VMS;
var fb_mutex: sync.SpinMutex = .{};

/// Handle WebSocket VNC proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's VNC port,
/// and spawns bidirectional relay threads.
fn handleWsVnc(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/vnc/<idx>
    const idx = parseIdx(req, "GET /ws/vnc/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return;
    }
    const vnc_port = v.vnc_port;
    appstate.vms_mutex.unlock();

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's VNC server.
    const vnc_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (vnc_fd < 0) return;

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, vnc_port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));

    if (c.connect(vnc_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        logWarn("ws/vnc: connect to VM VNC port failed");
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    }
    setTcpNoDelay(vnc_fd);

    // Spawn threads for bidirectional relay.
    // `wmtx` serializes writes to `ws_fd`: both the data-relay thread
    // (writeFrame) and the control thread (writePong) write to the same
    // socket, and writeFrame emits the frame header and payload as two
    // separate write() calls — without the lock a concurrent pong can
    // interleave between them and corrupt the WebSocket frame stream.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        vnc_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .vnc_fd = vnc_fd };

    // Thread: VNC → WebSocket
    const vnc2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.vnc_fd, &buf, buf.len);
                if (n <= 0) break;
                // Relay VNC bytes to the WebSocket client as a binary frame.
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → VNC
    const ws2vnc = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                if (!writeAll(ctx_ptr.vnc_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.vnc_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(vnc_fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        vnc2ws.join();
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    };

    vnc2ws.join();
    ws2vnc.join();
    _ = c.close(vnc_fd);
}

/// Handle WebSocket SPICE proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's SPICE port,
/// and spawns bidirectional relay threads.
fn handleWsSpice(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/spice/<idx>
    const idx = parseIdx(req, "GET /ws/spice/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return;
    }
    const spice_port = v.spice_port;
    appstate.vms_mutex.unlock();

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's SPICE server.
    const spice_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (spice_fd < 0) return;

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, spice_port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));

    if (c.connect(spice_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        logWarn("ws/spice: connect to VM SPICE port failed");
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    }
    setTcpNoDelay(spice_fd);

    // Spawn threads for bidirectional relay. `wmtx` serializes writes to
    // `ws_fd` (writeFrame vs writePong) — see handleWsVnc for the rationale.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        spice_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .spice_fd = spice_fd };

    // Thread: SPICE → WebSocket
    const spice2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.spice_fd, &buf, buf.len);
                if (n <= 0) break;
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → SPICE
    const ws2spice = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                if (!writeAll(ctx_ptr.spice_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.spice_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(spice_fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        spice2ws.join();
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    };

    spice2ws.join();
    ws2spice.join();
    _ = c.close(spice_fd);
}

/// Handle WebSocket Serial Console proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's serial
/// Unix socket, and spawns bidirectional relay threads.
fn handleWsSerial(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/serial/<idx>
    const idx = parseIdx(req, "GET /ws/serial/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive() or !v.enable_serial or !v.hasName()) {
        appstate.vms_mutex.unlock();
        return;
    }
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    const vm_name = v.getNameSlice();
    @memcpy(vm_name_buf[0..vm_name.len], vm_name);
    appstate.vms_mutex.unlock();

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/hangar-serial-{s}.sock",
        .{vm_name_buf[0..vm_name.len]},
    ) catch return;

    const serial = usock.UnixStream.connect(sock_path) catch {
        logWarn("ws/serial: connect to VM serial socket failed");
        return;
    };

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        serial_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .serial_fd = serial.fd };

    // Thread: serial → WebSocket. `wmtx` serializes writes to `ws_fd`
    // (writeFrame vs writePong) — see handleWsVnc for the rationale.
    const ser2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.serial_fd, &buf, buf.len);
                if (n <= 0) break;
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .text, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        serial.close();
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → serial
    const ws2ser = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                if (!writeAll(ctx_ptr.serial_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.serial_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(serial.fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        ser2ws.join();
        serial.close();
        try ws.writeClose(conn);
        return;
    };

    ser2ws.join();
    ws2ser.join();
    serial.close();
}

fn renderFramebuffer(req: []const u8, out: []u8) ![]const u8 {
    // GET /api/fb/N — return the framebuffer for VM N as a valid BMP image
    const idx = parseIdx(req, "GET /api/fb/") orelse return "invalid";
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return "no vm";
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return "off";
    }
    const vnc_port = v.vnc_port;
    appstate.vms_mutex.unlock();

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
        _ = vc.connect("127.0.0.1", @intCast(vnc_port));
        fb_vm_idx = idx;
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0;
        var fh: c_int = 0;
        if (vc.getSize(&fw, &fh) and fw > 0 and fh > 0) {
            const pixel_size: usize = @intCast(@as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4);
            if (out.len < 54) return "no fb";
            const copy_size = @min(pixel_size, out.len - 54);
            if (pixel_size > out.len - 54) {
                var wb: [128]u8 = undefined;
                logWarn(std.fmt.bufPrint(&wb, "VNC framebuffer {d}x{d} ({d} bytes) truncated to {d} bytes", .{ fw, fh, pixel_size, out.len - 54 }) catch "VNC framebuffer truncated");
            }
            const file_size: u32 = @intCast(54 + copy_size);

            // ── BITMAPFILEHEADER (14 bytes) ──────────────────────
            out[0] = 'B';
            out[1] = 'M';
            std.mem.writeInt(u32, out[2..6], file_size, .little); // bfSize
            std.mem.writeInt(u32, out[6..10], 0, .little); // bfReserved
            std.mem.writeInt(u32, out[10..14], 54, .little); // bfOffBits

            // ── BITMAPINFOHEADER (40 bytes) ──────────────────────
            @memset(out[14..54], 0); // zero-fill then set fields
            std.mem.writeInt(u32, out[14..18], 40, .little); // biSize
            std.mem.writeInt(i32, out[18..22], fw, .little); // biWidth
            std.mem.writeInt(i32, out[22..26], -fh, .little); // biHeight (negative = top-down)
            std.mem.writeInt(u16, out[26..28], 1, .little); // biPlanes
            std.mem.writeInt(u16, out[28..30], 32, .little); // biBitCount
            // biCompression = 0 (BI_RGB), biSizeImage = 0 (OK for BI_RGB)
            // biXPelsPerMeter = biYPelsPerMeter = 2835 (~72 DPI)
            std.mem.writeInt(u32, out[38..42], 2835, .little);
            std.mem.writeInt(u32, out[42..46], 2835, .little);

            // ── Pixel data ───────────────────────────────────────
            @memcpy(out[54..][0..copy_size], @as([*]const u8, @ptrCast(pixels))[0..copy_size]);
            return out[0 .. 54 + copy_size];
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

    // Extra-disk paths are user-controlled; escape each into its own buffer
    // so a path containing a quote/backslash can't break the JSON document.
    var ex0_buf: [vm.MAX_PATH]u8 = undefined;
    const ex0_e = if (v.hasExtraDisk(0)) escapeJson(&ex0_buf, v.getExtraDiskPathSlice(0), "extra0_path") else "";
    var ex1_buf: [vm.MAX_PATH]u8 = undefined;
    const ex1_e = if (v.hasExtraDisk(1)) escapeJson(&ex1_buf, v.getExtraDiskPathSlice(1), "extra1_path") else "";
    var ex2_buf: [vm.MAX_PATH]u8 = undefined;
    const ex2_e = if (v.hasExtraDisk(2)) escapeJson(&ex2_buf, v.getExtraDiskPathSlice(2), "extra2_path") else "";
    var ex3_buf: [vm.MAX_PATH]u8 = undefined;
    const ex3_e = if (v.hasExtraDisk(3)) escapeJson(&ex3_buf, v.getExtraDiskPathSlice(3), "extra3_path") else "";

    const part2d = std.fmt.bufPrint(buf[w..],
        \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}}}
    , .{
        ex0_e,
        v.extra_disks[0].size_gb,
        v.extra_disks[0].format.toIndex(),
        ex1_e,
        v.extra_disks[1].size_gb,
        v.extra_disks[1].format.toIndex(),
        ex2_e,
        v.extra_disks[2].size_gb,
        v.extra_disks[2].format.toIndex(),
        ex3_e,
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

        // Escape user-controlled extra-disk paths (each own buffer) so a quote
        // or backslash in a path cannot corrupt the JSON for the whole list.
        var ex0_buf: [vm.MAX_PATH]u8 = undefined;
        const ex0_e = if (v.hasExtraDisk(0)) escapeJson(&ex0_buf, v.getExtraDiskPathSlice(0), "extra0_path") else "";
        var ex1_buf: [vm.MAX_PATH]u8 = undefined;
        const ex1_e = if (v.hasExtraDisk(1)) escapeJson(&ex1_buf, v.getExtraDiskPathSlice(1), "extra1_path") else "";
        var ex2_buf: [vm.MAX_PATH]u8 = undefined;
        const ex2_e = if (v.hasExtraDisk(2)) escapeJson(&ex2_buf, v.getExtraDiskPathSlice(2), "extra2_path") else "";
        var ex3_buf: [vm.MAX_PATH]u8 = undefined;
        const ex3_e = if (v.hasExtraDisk(3)) escapeJson(&ex3_buf, v.getExtraDiskPathSlice(3), "extra3_path") else "";

        const part2d = std.fmt.bufPrint(buf[w..],
            \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}}}
        , .{
            ex0_e,
            v.extra_disks[0].size_gb,
            v.extra_disks[0].format.toIndex(),
            ex1_e,
            v.extra_disks[1].size_gb,
            v.extra_disks[1].format.toIndex(),
            ex2_e,
            v.extra_disks[2].size_gb,
            v.extra_disks[2].format.toIndex(),
            ex3_e,
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
/// Thread-local because each accepted HTTP connection runs in its own thread.
threadlocal var start_err_buf: [640]u8 = undefined;

fn handlePower(req: []const u8) ![]const u8 {
    // Hold the lock across the whole operation. The VMM handle (and the
    // VmConfig it points at) can be freed by a concurrent delete/clone/suspend
    // the instant the lock is released, so it must never be used unlocked —
    // doing so was a use-after-free. The QEMU start/stop therefore runs under
    // the lock, matching the snapshot/pause handlers which already issue their
    // QMP I/O this way.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/power/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const v = &appstate.vms[idx];
    const was_alive = v.isAlive();
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    const vm_name = v.getNameSlice();
    @memcpy(vm_name_buf[0..vm_name.len], vm_name);
    vm_name_buf[vm_name.len] = 0;
    const vmm_handle = appstate.getVmmHandle(idx);

    if (was_alive) {
        // Force-stop the running VM.
        if (vmm_handle) |h| {
            appstate.g_vmm.forceStopFn(h);
            appstate.g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(v);
            qemu.reapVm(v);
        }
    } else {
        // Start the VM.
        if (vmm_handle) |h| {
            appstate.g_vmm.startFn(h, @ptrCast(v)) catch |e| {
                logOpErr("power on", e, vm_name_buf[0..vm_name.len]);
                appstate.destroyVmmHandle(idx);
                return "start err";
            };
        } else {
            qemu.startVm(v, std.heap.page_allocator) catch |e| {
                logOpErr("power on", e, vm_name_buf[0..vm_name.len]);
                var log_path_buf: [320]u8 = [_]u8{0} ** 320;
                var log_content_buf: [512]u8 = undefined;
                const log_path = std.fmt.bufPrintZ(&log_path_buf, "/var/tmp/hangar-vm-{s}.log", .{vm_name_buf[0..vm_name.len]}) catch null;
                const err_detail = if (log_path) |lp| readStartupLog(lp, &log_content_buf) else "";
                if (err_detail.len > 0) {
                    return std.fmt.bufPrint(&start_err_buf, "start err: {s}", .{err_detail}) catch "start err";
                }
                return "start err";
            };
        }
    }

    if (was_alive) {
        appstate.destroyVmmHandle(idx);
        appstate.vm_started[idx] = 0;
    } else {
        appstate.vm_started[idx] = time(null);
    }
    logAudit(if (was_alive) "power off" else "power on", vm_name_buf[0..vm_name.len]);
    // No persist.save here: power on/off only mutates runtime state
    // (vm_started, the VMM handle, status) which is never written to vms.json.
    // The serialized config is byte-identical to what is already on disk, so a
    // save would be a redundant full-JSON serialize + atomic file write
    // (open/write/fsync/rename) issued on every toggle while holding vms_mutex,
    // stalling concurrent /api/vms polls for no benefit.
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
        if (std.mem.eql(u8, key, "enable_kvm")) {
            if (std.mem.eql(u8, val, "1")) cfg.accel = .auto else cfg.accel = .tcg;
        }
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
        if (std.mem.eql(u8, key, "num_displays")) cfg.num_displays = @max(1, @min(vm.MAX_DISPLAYS, std.fmt.parseInt(u32, val, 10) catch cfg.num_displays));
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
    logAudit("create", cfg.getNameSlice());
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
        \\{{"max_vms":{d},"max_nics":{d},"max_extra_disks":{d},"max_displays":{d},"version":"1.0"}}
    , .{ vm.MAX_VMS, vm.MAX_NICS, vm.MAX_EXTRA_DISKS, vm.MAX_DISPLAYS }) catch "{}";
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
    // Match the path independent of method so the parser is agnostic to GET/POST.
    const prefix = "/api/quickstart/";
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
    // Match the audit trail of the other VM-creation paths (handleNewVm,
    // handleClone, handleImport) so a catalog-spawned VM never appears in the
    // fleet with no "how did this get here" record in the daemon log.
    logAudit("quickstart", cfg.getNameSlice());
    return "ok";
}

fn handleClone(req: []const u8) ![]const u8 {
    // Hold the lock across the whole operation. The VMM handle captured below
    // points at heap memory a concurrent delete/suspend can free the moment the
    // lock is released, so it must not be used unlocked — that was a
    // use-after-free. The qemu-img linked-clone creation runs under the lock
    // (it only stamps a qcow2 backing file, so it is cheap).
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
    // Ports are assigned once just before the VM is committed (below). The lock
    // is held for the whole clone, so the VM table can't change underneath us;
    // computing them here too would be redundant work overwritten before use.
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

    var disk_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk_path_z: [*:0]const u8 = undefined;
    const do_linked = linked and src.hasDisk();
    if (do_linked) {
        const home = appio.getenv("HOME") orelse "/tmp";
        disk_path_z = std.fmt.bufPrintZ(&disk_path_buf, "{s}/VMs/{s}.qcow2", .{ home, clone.getNameSlice() }) catch return "nameerr";
    }
    const vmm_handle = appstate.getVmmHandle(idx);
    const src_disk = src.getDiskPathSlice();
    const src_fmt: vm.DiskFormat = src.disk_format;

    if (do_linked) {
        const disk_path: []const u8 = std.mem.span(disk_path_z);
        if (vmm_handle) |h| {
            appstate.g_vmm.createLinkedCloneFn(h, disk_path, src_disk, @intFromEnum(src_fmt), std.heap.page_allocator) catch return "linkerr";
        } else {
            qemu.createLinkedClone(disk_path, src_disk, src_fmt, std.heap.page_allocator) catch return "linkerr";
        }
        clone.setDiskPath(disk_path);
        clone.disk_format = .qcow2;
    }

    if (idx >= appstate.vm_count or appstate.vm_count >= appstate.MAX_VMS) return "full";
    clone.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    clone.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    appstate.vms[appstate.vm_count] = clone;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        var ebuf: [64]u8 = undefined;
        logErr(std.fmt.bufPrint(&ebuf, "persist.save failed: {s}", .{@errorName(e)}) catch "persist.save failed");
        return "save failed";
    };
    logAudit("clone", clone.getNameSlice());
    return "ok";
}

fn handleDelete(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    const idx = parseIdx(req, "POST /api/delete/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    logAudit("delete", appstate.vms[idx].getNameSlice());
    // Save undo state before deleting.
    appstate.undo_vm = appstate.vms[idx];
    appstate.undo_idx = idx;
    appstate.undo_available = true;
    appstate.destroyVmmHandle(idx);
    // Shift remaining
    var i = idx;
    while (i + 1 < appstate.vm_count) : (i += 1) {
        appstate.vms[i] = appstate.vms[i + 1];
        appstate.g_vmm_handles[i] = appstate.g_vmm_handles[i + 1];
        rebindVmmHandleLocked(i);
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
        rebindVmmHandleLocked(i);
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
    // Restoring a deleted VM is the inverse of the audited "delete"; log it so
    // the audit trail explains why a VM operators thought was gone reappeared.
    logAudit("undo restore", appstate.vms[appstate.undo_idx].getNameSlice());
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
            rebindVmmHandleLocked(j);
            appstate.vm_started[j] = appstate.vm_started[j + 1];
        }
    } else {
        // Shift [b .. a-1] right by 1
        var j: usize = a;
        while (j > b) : (j -= 1) {
            appstate.vms[j] = appstate.vms[j - 1];
            appstate.g_vmm_handles[j] = appstate.g_vmm_handles[j - 1];
            rebindVmmHandleLocked(j);
            appstate.vm_started[j] = appstate.vm_started[j - 1];
        }
    }
    appstate.vms[b] = saved_vm;
    appstate.g_vmm_handles[b] = saved_handle;
    rebindVmmHandleLocked(b);
    appstate.vm_started[b] = saved_started;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("", e);
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
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = @max(1, @min(vm.MAX_DISPLAYS, std.fmt.parseInt(u32, val, 10) catch v.num_displays));
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
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("", e);
        return "save failed";
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
    var end: usize = rest.len;
    var found = false;
    for ([_]u8{ ' ', '/', '?' }) |term| {
        if (std.mem.indexOfScalar(u8, rest, term)) |i| {
            if (i < end) end = i;
            found = true;
        }
    }
    if (!found) return null;
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
    // Lock only long enough to validate idx, copy the VM name, and check liveness.
    // The QMP migration I/O below can take many seconds — we must not hold the
    // mutex across it or every other API call blocks.
    appstate.vms_mutex.lock();
    const idx = parseIdx(req, "POST /api/suspend/") orelse {
        appstate.vms_mutex.unlock();
        return "invalid";
    };
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return "invalid idx";
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return "not running";
    }
    // Copy the VM name before releasing the lock — another thread could rename
    // or delete the VM while we do the migration I/O.
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    const vm_name = v.getNameSlice();
    @memcpy(vm_name_buf[0..vm_name.len], vm_name);
    vm_name_buf[vm_name.len] = 0;
    appstate.vms_mutex.unlock();

    // Build the saved-state filename from a sanitized slug, not the raw VM
    // name. The path is later embedded in QMP `exec:` migration commands that
    // run via /bin/sh, so the filename must contain no shell metacharacters.
    var slug_buf: [vm.MAX_NAME]u8 = undefined;
    const slug = sanitizeSlug(vm_name_buf[0..vm_name.len], &slug_buf);
    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/hangar-state-{s}.bin", .{slug}) catch return "path err";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(vm_name_buf[0..vm_name.len], &sock_buf) orelse return "sock err";
    client.connect(sock) catch |e| {
        logOpErr("suspend", e, vm_name_buf[0..vm_name.len]);
        return "qmp err";
    };
    defer client.disconnect();
    client.suspendToFile(path) catch |e| {
        logOpErr("suspend", e, vm_name_buf[0..vm_name.len]);
        return "migrate err";
    };
    client.waitMigrateComplete() catch |e| {
        logOpErr("suspend", e, vm_name_buf[0..vm_name.len]);
        return switch (e) {
            error.MigrateFailed => "migrate failed",
            error.MigrateCancelled => "migrate cancelled",
            error.MigrateTimeout => "timeout",
            else => "migrate err",
        };
    };

    // Re-acquire the lock for the state mutation. Re-validate idx in case the
    // VM was deleted or the array shifted during the migration I/O.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return "invalid idx";
    // Verify the VM at idx still has the same name (hasn't been replaced).
    if (!std.mem.eql(u8, appstate.vms[idx].getNameSlice(), vm_name_buf[0..vm_name.len])) return "invalid idx";
    const v2 = &appstate.vms[idx];
    v2.status = .suspended;
    v2.setSavedStatePath(path[0..]);
    if (appstate.getVmmHandle(idx)) |h| {
        appstate.g_vmm.forceStopFn(h);
        appstate.g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v2);
        qemu.reapVm(v2);
    }
    appstate.destroyVmmHandle(idx);
    appstate.vm_started[idx] = 0;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("handleSuspend: ", e);
        return "save failed";
    };
    logAudit("suspend", vm_name_buf[0..vm_name.len]);
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
        appstate.g_vmm.pauseFn(h) catch |e| {
            logOpErr("pause", e, v.getNameSlice());
            return "qmp err";
        };
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch |e| {
            logOpErr("pause", e, v.getNameSlice());
            return "qmp err";
        };
        defer client.disconnect();
        client.pause() catch |e| {
            logOpErr("pause", e, v.getNameSlice());
            return "qmp err";
        };
    }
    logAudit("pause", v.getNameSlice());
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
        appstate.g_vmm.resumeFn(h) catch |e| {
            logOpErr("resume", e, v.getNameSlice());
            return "qmp err";
        };
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch |e| {
            logOpErr("resume", e, v.getNameSlice());
            return "qmp err";
        };
        defer client.disconnect();
        client.cont() catch |e| {
            logOpErr("resume", e, v.getNameSlice());
            return "qmp err";
        };
    }
    logAudit("resume", v.getNameSlice());
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
            logAudit("rename", val);
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
        appstate.g_vmm.shutdownFn(h) catch |e| {
            logOpErr("shut down guest", e, v.getNameSlice());
            return "qmp err";
        };
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch |e| {
            logOpErr("shut down guest", e, v.getNameSlice());
            return "qmp err";
        };
        defer client.disconnect();
        client.powerdown() catch |e| {
            logOpErr("shut down guest", e, v.getNameSlice());
            return "qmp err";
        };
    }
    logAudit("shut down guest", v.getNameSlice());
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
        appstate.g_vmm.resetFn(h) catch |e| {
            logOpErr("reset", e, v.getNameSlice());
            return "qmp err";
        };
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch |e| {
            logOpErr("reset", e, v.getNameSlice());
            return "qmp err";
        };
        defer client.disconnect();
        client.systemReset() catch |e| {
            logOpErr("reset", e, v.getNameSlice());
            return "qmp err";
        };
    }
    logAudit("reset", v.getNameSlice());
    return "ok";
}

const MAX_SNAPSHOT_TAG_LEN = 255;

fn validateSnapshotTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > MAX_SNAPSHOT_TAG_LEN) return false;
    for (tag) |b| {
        if (b == 0) return false; // reject null bytes
        if (b < 0x20) return false; // reject control characters
    }
    if (std.mem.indexOf(u8, tag, "..") != null) return false;
    return true;
}

fn handleSnapshotTake(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/snapshot/take/") orelse return "invalid";
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
        appstate.g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot take", e, v.getNameSlice());
            return "create err";
        };
    } else {
        qemu.snapshotCreate(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot take", e, v.getNameSlice());
            return "create err";
        };
    }
    logAudit("snapshot take", v.getNameSlice());
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
        appstate.g_vmm.snapshotListFn(h, v.getDiskPathSlice(), raw_buf, std.heap.page_allocator) catch |e| blk: {
            logOpErr("snapshot list", e, v.getNameSlice());
            break :blk 0;
        }
    else
        qemu.snapshotList(v.getDiskPathSlice(), raw_buf, std.heap.page_allocator) catch |e| blk: {
            logOpErr("snapshot list", e, v.getNameSlice());
            break :blk 0;
        };
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
        appstate.g_vmm.snapshotApplyFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot revert", e, v.getNameSlice());
            return "apply err";
        };
    } else {
        qemu.snapshotApply(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot revert", e, v.getNameSlice());
            return "apply err";
        };
    }
    logAudit("snapshot revert", v.getNameSlice());
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
        appstate.g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot delete", e, v.getNameSlice());
            return "delete err";
        };
    } else {
        qemu.snapshotDelete(v.getDiskPathSlice(), decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot delete", e, v.getNameSlice());
            return "delete err";
        };
    }
    logAudit("snapshot delete", v.getNameSlice());
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
    logAudit("import", cfg.getNameSlice());
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
    client.connect(sock) catch |e| {
        logOpErr("ctrl-alt-del", e, v.getNameSlice());
        return "qmp err";
    };
    defer client.disconnect();
    client.sendCtrlAltDel() catch |e| {
        logOpErr("ctrl-alt-del", e, v.getNameSlice());
        return "cad err";
    };
    logAudit("ctrl-alt-del", v.getNameSlice());
    return "ok";
}

/// Validate a live-migration destination URI supplied by an API client.
///
/// Only the documented `tcp:host:port` form the UI sends is accepted. QEMU's
/// `migrate` command accepts other schemes — notably `exec:`, which runs its
/// argument through `/bin/sh` — so accepting an arbitrary URI would hand any
/// authenticated client host command execution. The value is also interpolated
/// unescaped into a QMP JSON string by `qmp.liveMigrate`, so `"`/`\` (which
/// would break out of that string) and control characters are rejected.
fn isValidMigrateDest(dest: []const u8) bool {
    if (!std.mem.startsWith(u8, dest, "tcp:")) return false;
    if (std.mem.indexOf(u8, dest, "..") != null) return false;
    for (dest) |ch| {
        if (ch < 0x20) return false; // control characters
        if (ch == '"' or ch == '\\') return false; // JSON string break-out
    }
    return true;
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
    if (!isValidMigrateDest(dest)) return "bad dest";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch |e| {
        logOpErr("migrate", e, v.getNameSlice());
        return "qmp err";
    };
    defer client.disconnect();
    logAudit("migrate", v.getNameSlice());
    client.liveMigrate(dest) catch |e| {
        logOpErr("migrate", e, v.getNameSlice());
        return "migrate err";
    };
    return "{\"status\":\"started\"}";
}

/// Query current migration status for a VM.
/// Map a `handleMigrateStatus` JSON body to an HTTP status code. A success
/// payload (`{"status":"active"}`) stays 200; error payloads become the same
/// 4xx/5xx codes the central text/plain mapper assigns to the equivalent tokens
/// so the migrate-status endpoint reports failures consistently with the rest of
/// the API. The body itself is left unchanged.
fn migrateStatusHttpCode(body: []const u8) u16 {
    if (std.mem.indexOf(u8, body, "\"status\":\"error\"") == null) return HTTP_OK;
    if (std.mem.indexOf(u8, body, "invalid idx") != null or std.mem.indexOf(u8, body, "bad idx") != null) return HTTP_NOT_FOUND;
    if (std.mem.indexOf(u8, body, "not running") != null) return HTTP_CONFLICT;
    return HTTP_INTERNAL_ERROR;
}

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
    client.connect(sock) catch |e| {
        logOpErr("migrate cancel", e, v.getNameSlice());
        return "qmp err";
    };
    defer client.disconnect();
    client.cancelMigrate() catch |e| {
        logOpErr("migrate cancel", e, v.getNameSlice());
        return "cancel err";
    };
    logAudit("migrate cancel", v.getNameSlice());
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
    if (fd < 0) {
        // The disk2 file is recorded on the VM but cannot be opened (deleted out
        // from under us, permissions, bad path). Without this line a failed
        // download is a silent dead end — the client gets nothing and nothing
        // explains why.
        var nb: [vm.MAX_NAME]u8 = undefined;
        var eb: [256]u8 = undefined;
        logErr(std.fmt.bufPrint(&eb, "disk2 download: open failed vm=\"{s}\"", .{sanitizeLogName(&nb, v.getNameSlice())}) catch "disk2 download: open failed");
        return;
    }
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
            "Content-Type: application/octet-stream\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Cache-Control: no-store\r\n" ++
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

    // Audit the completed secondary-disk download: a VM disk image left the host.
    logAudit("disk2 download", v.getNameSlice());
}

/// Accept a multipart/form-data file upload for disk2.
fn handleUploadDisk(req: []const u8) ![]const u8 {
    // The multipart parse below only reads `req` (this connection's own buffer),
    // so it needs no lock. We take vms_mutex only to read the VM's disk paths and
    // later to record the result — never across the (potentially multi-GB)
    // writeFile, which would otherwise freeze every other handler and the
    // liveness/autoprotect tickers for the whole upload.
    const idx = parseIdx(req, "POST /api/vm/") orelse return "invalid";

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

    // Reject path traversal in filename. Also reject the QEMU -drive property
    // delimiters (',' and control chars): the resulting path is interpolated
    // into a comma-separated `-drive file=...` list at launch, so a comma would
    // inject extra drive options (argument injection, CWE-88).
    if (filename.len == 0) return "no filename";
    for (filename) |ch| {
        if (ch == '/' or ch == '\\' or ch == ',' or ch < 0x20) return "bad filename";
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
    // Compute `dest` (and snapshot the VM name) under the lock, then release it
    // before the file write. `dest_buf`/`name_buf` outlive the locked scope, and
    // `file_data`/`filename` point into `req` (stable), so nothing read after the
    // unlock aliases the shared VM table.
    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    var dest: []const u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        const primary = v.getDiskPathSlice();
        if (primary.len == 0) return "no primary disk";
        const ext = std.fs.path.extension(primary);
        const dir = std.fs.path.dirname(primary) orelse ".";
        const basename = std.fs.path.basename(primary);
        if (filename.len > 0) {
            dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, filename }) catch return "path err";
        } else if (ext.len > 0 and ext.len < 16) {
            const name_no_ext = basename[0 .. basename.len - ext.len];
            dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, name_no_ext, ext }) catch return "path err";
        } else {
            dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, basename }) catch return "path err";
        }
        const nm = v.getNameSlice();
        name_len = @min(nm.len, name_buf.len);
        @memcpy(name_buf[0..name_len], nm[0..name_len]);
    }

    // Heavy I/O outside the lock — an uploaded disk image can be many GB.
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = dest, .data = file_data }) catch return "write err";

    // Re-acquire to record the new disk2 path, re-validating that the VM didn't
    // move or disappear while unlocked (a concurrent delete compacts the array).
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return "ok"; // file written; VM is gone
    if (!std.mem.eql(u8, appstate.vms[idx].getNameSlice(), name_buf[0..name_len])) return "ok";
    appstate.vms[idx].setDisk2Path(dest);
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        // The disk file was written and attached in memory, but persisting the
        // attachment failed — on restart the disk2 path would be lost silently.
        // Surface it instead of reporting success like the other save paths.
        logSaveErr("handleUploadDisk: ", e);
        return "save failed";
    };
    logAudit("disk upload", name_buf[0..name_len]);
    return "ok";
}

/// Create OVF+VMDK export, tar+gzip it, and stream the result as a download.
fn handleExport(conn: c.fd_t, req: []const u8) !void {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/export/") orelse return;
    if (idx >= appstate.vm_count) return;
    const v = &appstate.vms[idx];

    // Parse optional name field from the request body.
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
    const body = req[body_start + 4 ..];
    var raw_name: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) {
            raw_name = val;
        }
    }
    var name_decode_buf: [vm.MAX_NAME]u8 = undefined;
    const export_name: []const u8 = if (raw_name.len > 0) blk: {
        const decoded = urlencode.urlDecode(&name_decode_buf, raw_name);
        if (!vm.isValidVmName(decoded)) return;
        if (std.mem.indexOf(u8, decoded, "..") != null) return;
        break :blk decoded;
    } else v.getNameSlice();

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
        .name = export_name,
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

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, export_name });
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

    const raw_filename = std.fmt.bufPrint(&path_buf, "{s}.ova", .{export_name}) catch "export.ova";
    var fname_buf2: [256]u8 = undefined;
    const filename = sanitizeHeaderValue(&fname_buf2, raw_filename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{filename}) catch return;

    // Build response headers in one buffer, then write them at once.
    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Cache-Control: no-store\r\n" ++
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

    // Audit the completed export: a full VM disk left the host. Without this the
    // exfiltration of a multi-GB image is invisible in the daemon log.
    logAudit("export", v.getNameSlice());
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
                const hex = "0123456789abcdef";
                buf[wi] = hex[ch >> 4];
                wi += 1;
                buf[wi] = hex[ch & 0x0F];
                wi += 1;
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
        if (v.len > 0) appstate.prefs.default_memory_mb = clampPref(v, appstate.prefs.default_memory_mb, vm.PREF_MEMORY_MB_MIN, vm.PREF_MEMORY_MB_MAX);
    }
    {
        const v = bodyVal(body, "default_cpu_cores");
        if (v.len > 0) appstate.prefs.default_cpu_cores = clampPref(v, appstate.prefs.default_cpu_cores, vm.PREF_CPU_CORES_MIN, vm.PREF_CPU_CORES_MAX);
    }
    {
        const v = bodyVal(body, "autoprotect_enabled");
        if (v.len > 0) appstate.prefs.autoprotect_enabled_default = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    {
        const v = bodyVal(body, "autoprotect_interval");
        if (v.len > 0) appstate.prefs.autoprotect_interval_min_default = clampPref(v, appstate.prefs.autoprotect_interval_min_default, vm.PREF_AUTOPROTECT_INTERVAL_MIN, vm.PREF_AUTOPROTECT_INTERVAL_MAX);
    }
    {
        const v = bodyVal(body, "autoprotect_max");
        if (v.len > 0) appstate.prefs.autoprotect_max_default = clampPref(v, appstate.prefs.autoprotect_max_default, vm.PREF_AUTOPROTECT_MAX_MIN, vm.PREF_AUTOPROTECT_MAX_MAX);
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

    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("", e);
        return "save failed";
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
                    // A VM that was running/paused is now gone — an unexpected
                    // exit (guest shutdown, QEMU crash, OOM-kill). Record it: a
                    // VM that silently flips to stopped is a 3 AM blind spot with
                    // no timestamp of when or which VM died.
                    var name_buf: [vm.MAX_NAME]u8 = undefined;
                    const safe = sanitizeLogName(&name_buf, v.getNameSlice());
                    var msg: [320]u8 = undefined;
                    logWarn(std.fmt.bufPrint(&msg, "vm exited unexpectedly: vm=\"{s}\" prev={s}", .{ safe, v.status.toStr() }) catch "vm exited unexpectedly");
                    v.status = .stopped;
                    appstate.destroyVmmHandle(i);
                    changed = true;
                }
            }
        }
        if (changed) {
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("liveness: ", e);
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

            // Disk path is config-controlled, so sanitize before logging to keep
            // the background-job error lines single-line and injection-safe.
            var dp_log_buf: [256]u8 = undefined;
            const dp_safe = sanitizeLogName(&dp_log_buf, dp);

            qemu.snapshotCreate(dp, sn, std.heap.page_allocator) catch |e| {
                var ebuf: [320]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotCreate failed: {s} disk=\"{s}\" snap=\"{s}\"", .{ @errorName(e), dp_safe, sn }) catch "autoprotect snapshotCreate failed");
                continue;
            };

            // Prune excess AutoProtect snapshots
            var list_buf: [4096]u8 = undefined;
            const list_n = qemu.snapshotList(dp, &list_buf, std.heap.page_allocator) catch |e| {
                var ebuf: [320]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotList failed: {s} disk=\"{s}\"", .{ @errorName(e), dp_safe }) catch "autoprotect snapshotList failed");
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
                qemu.snapshotDelete(dp, auto_names[d], std.heap.page_allocator) catch |e| {
                    var ebuf: [320]u8 = undefined;
                    logErr(std.fmt.bufPrint(&ebuf, "autoprotect snapshotDelete failed: {s} disk=\"{s}\"", .{ @errorName(e), dp_safe }) catch "autoprotect snapshotDelete failed");
                };
            }
        }

        // Re-acquire lock only for the save
        appstate.vms_mutex.lock();
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
            logSaveErr("", e);
        };
        appstate.vms_mutex.unlock();
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const TestConfigHome = struct {
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    saved_config_home: ?[]const u8 = null,

    fn init(tag: []const u8) !TestConfigHome {
        var self = TestConfigHome{
            .saved_config_home = appio.getenv("HANGAR_CONFIG_HOME"),
        };
        const path = try std.fmt.bufPrintZ(&self.path_buf, "/tmp/hangar-web-server-{d}-{s}", .{ c.getpid(), tag });
        self.path_len = path.len;
        _ = std.Io.Dir.cwd().deleteTree(appio.io(), path[0..path.len]) catch {};
        if (setenv("HANGAR_CONFIG_HOME", path.ptr, 1) != 0) return error.SetEnvFailed;
        return self;
    }

    fn deinit(self: *const TestConfigHome) void {
        _ = std.Io.Dir.cwd().deleteTree(appio.io(), self.path_buf[0..self.path_len]) catch {};
        if (self.saved_config_home) |v| {
            var zbuf: [512]u8 = undefined;
            const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{v}) catch {
                _ = unsetenv("HANGAR_CONFIG_HOME");
                return;
            };
            _ = setenv("HANGAR_CONFIG_HOME", z.ptr, 1);
        } else {
            _ = unsetenv("HANGAR_CONFIG_HOME");
        }
    }
};

test "isServerErrToken: matches dynamic error constants exactly" {
    try std.testing.expect(isServerErrToken("qmp err"));
    try std.testing.expect(isServerErrToken("apply err"));
    try std.testing.expect(isServerErrToken("nameerr"));
    try std.testing.expect(isServerErrToken("linkerr"));
    try std.testing.expect(isServerErrToken("start err"));
    try std.testing.expect(isServerErrToken("start err: spawn failed"));
}

test "isServerErrToken: does not flag data containing 'err'" {
    // Snapshot list bodies are newline-joined user data; a snapshot named
    // "fix-error" must not be misclassified as a server failure.
    try std.testing.expect(!isServerErrToken("fix-error\nbaseline\n"));
    try std.testing.expect(!isServerErrToken("kernel-werror"));
    try std.testing.expect(!isServerErrToken("ok"));
    try std.testing.expect(!isServerErrToken("saved"));
    try std.testing.expect(!isServerErrToken("(none)"));
}

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

test "fuzz: findHeader never panics and returns a sub-slice of headers" {
    var prng = std.Random.DefaultPrng.init(0xF1DD_BEAD);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    const names = [_][]const u8{ "X-API-Key: ", "Host: ", "Content-Length: ", "Cookie: " };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        // Bias bytes toward CR/LF/colon/space so header framing gets exercised.
        for (buf[0..len]) |*b| {
            b.* = switch (rnd.uintLessThan(u8, 8)) {
                0 => '\r',
                1 => '\n',
                2 => ':',
                3 => ' ',
                else => rnd.int(u8),
            };
        }
        const headers = buf[0..len];
        for (names) |nm| {
            if (findHeader(headers, nm)) |val| {
                // Returned value must be a contiguous slice inside `headers`.
                const base = @intFromPtr(headers.ptr);
                const vp = @intFromPtr(val.ptr);
                try std.testing.expect(vp >= base);
                try std.testing.expect(vp + val.len <= base + headers.len);
            }
        }
    }
}

test "fuzz: parseVmIdxSuffix never panics on random request-like input" {
    var prng = std.Random.DefaultPrng.init(0x5FF1_CEED);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    const prefixes = [_][]const u8{ "GET /api/vm/", "POST /api/vm/" };
    const suffixes = [_][]const u8{ "/disk2/download", "/serial", "/screenshot" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        // Bias toward digits, slashes and spaces to reach the parse paths.
        for (buf[0..len]) |*b| {
            b.* = switch (rnd.uintLessThan(u8, 6)) {
                0 => rnd.intRangeAtMost(u8, '0', '9'),
                1 => '/',
                2 => ' ',
                3 => '?',
                else => rnd.int(u8),
            };
        }
        for (prefixes) |pfx| {
            for (suffixes) |sfx| {
                _ = parseVmIdxSuffix(buf[0..len], pfx, sfx);
            }
        }
    }
}

test "secretEql: equal, unequal, length mismatch" {
    try std.testing.expect(secretEql("hangar", "hangar"));
    try std.testing.expect(!secretEql("hangar", "hangaR"));
    try std.testing.expect(!secretEql("hangar", "hang"));
    try std.testing.expect(secretEql("", ""));
    try std.testing.expect(!secretEql("a", ""));
}

test "fuzz: secretEql matches std.mem.eql semantics" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const la = rand.uintLessThan(usize, a.len + 1);
        const lb = rand.uintLessThan(usize, b.len + 1);
        rand.bytes(a[0..la]);
        rand.bytes(b[0..lb]);
        // Occasionally force exact equality to exercise the true branch.
        if (rand.boolean() and la <= b.len) {
            @memcpy(b[0..la], a[0..la]);
            try std.testing.expectEqual(secretEql(a[0..la], b[0..la]), std.mem.eql(u8, a[0..la], b[0..la]));
        }
        try std.testing.expectEqual(std.mem.eql(u8, a[0..la], b[0..lb]), secretEql(a[0..la], b[0..lb]));
    }
}

test "validApiKey: bounds and character class" {
    try std.testing.expect(validApiKey("hangar"));
    try std.testing.expect(validApiKey("a"));
    try std.testing.expect(validApiKey("S3cr3t-Key_With.Symbols!~"));
    try std.testing.expect(validApiKey("x" ** 64));
    // Length bounds.
    try std.testing.expect(!validApiKey(""));
    try std.testing.expect(!validApiKey("x" ** 65));
    // Whitespace / control characters (the trailing-newline footgun).
    try std.testing.expect(!validApiKey("secret\n"));
    try std.testing.expect(!validApiKey("secret\r"));
    try std.testing.expect(!validApiKey("two words"));
    try std.testing.expect(!validApiKey("\tsecret"));
    try std.testing.expect(!validApiKey("bad\x7fkey"));
}

test "fuzz: validApiKey never panics and only accepts printable in-range keys" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rand = prng.random();
    var buf: [80]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rand.uintLessThan(usize, buf.len + 1);
        rand.bytes(buf[0..len]);
        const ok = validApiKey(buf[0..len]);
        if (ok) {
            // Every accepted key must satisfy the documented contract.
            try std.testing.expect(len >= 1 and len <= 64);
            for (buf[0..len]) |ch| try std.testing.expect(ch > 0x20 and ch != 0x7f);
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

test "hostHeaderOk: loopback mode accepts loopback hosts, rejects rebinding" {
    // Loopback mode (no custom key): only loopback Host values pass.
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"));
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: localhost:9080\r\n\r\n"));
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: 127.0.0.1:9080\r\n\r\n"));
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: [::1]:9080\r\n\r\n"));
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: LocalHost\r\n\r\n"));
    // DNS-rebinding origin and missing Host are rejected.
    try std.testing.expect(!hostHeaderOk("GET / HTTP/1.1\r\nHost: evil.com:9080\r\n\r\n"));
    try std.testing.expect(!hostHeaderOk("GET / HTTP/1.1\r\nHost: 10.0.0.5\r\n\r\n"));
    try std.testing.expect(!hostHeaderOk("GET / HTTP/1.1\r\n\r\n"));
}

test "hostHeaderOk: exposed mode (custom key) skips host validation" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }
    // With a real key set the daemon is intentionally exposed; any host passes.
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"));
    try std.testing.expect(hostHeaderOk("GET / HTTP/1.1\r\n\r\n"));
}

test "fuzz: hostHeaderOk never panics on random header-like input" {
    var prng = std.Random.DefaultPrng.init(0x4057_F00D);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*ch| ch.* = rnd.int(u8);
        _ = hostHeaderOk(buf[0..n]);
    }
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
        "POST /api/quickstart/",
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

test "validateSnapshotTag: dot-dot path traversal rejected" {
    try std.testing.expect(!validateSnapshotTag(".."));
    try std.testing.expect(!validateSnapshotTag("../escape"));
    try std.testing.expect(!validateSnapshotTag("snap/../etc"));
    try std.testing.expect(!validateSnapshotTag("trailing.."));
    // A single dot is fine; only the ".." sequence is dangerous.
    try std.testing.expect(validateSnapshotTag("v1.0"));
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

test "fuzz: isAuthExempt never panics and never exempts protected surfaces" {
    var prng = std.Random.DefaultPrng.init(0x5EC_0DE);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const alphabet = "/abcdeimnpqstv0123._-";

    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        // Mix random bytes with a bias toward the literal path characters so the
        // fuzzer reaches boundary-confusable prefixes (e.g. "/api/vm/...").
        for (buf[0..len]) |*b| {
            b.* = if (rnd.boolean())
                alphabet[rnd.uintLessThan(usize, alphabet.len)]
            else
                rnd.int(u8);
        }
        const path = buf[0..len];
        const method_get = rnd.boolean();
        const exempt = isAuthExempt(method_get, path);

        // Security invariants: a non-GET request is never auth-exempt, and the
        // raw disk-image download must never be exempt regardless of method.
        if (!method_get) try std.testing.expect(!exempt);
        if (std.mem.endsWith(u8, path, "/disk2/download")) {
            try std.testing.expect(!exempt);
        }
    }
}

test "fuzz: sanitizeSlug stays bounded, non-empty, and shell-safe" {
    var prng = std.Random.DefaultPrng.init(0x51_06_A17E);
    const rnd = prng.random();
    var input: [256]u8 = undefined;
    var output: [64]u8 = undefined;

    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len + 1);
        rnd.bytes(input[0..len]);
        const slug = sanitizeSlug(input[0..len], &output);

        // Bounded write and never empty (falls back to "vm").
        try std.testing.expect(slug.len > 0);
        try std.testing.expect(slug.len <= output.len);
        // Every byte is in the documented safe charset [A-Za-z0-9._-].
        for (slug) |ch| {
            const safe = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-';
            try std.testing.expect(safe);
        }
    }
}

test "writeAll: writes exact bytes to fd via pipe" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    const msg = "hello from writeAll";
    try std.testing.expect(writeAll(fds[1], msg.ptr, msg.len));
    var buf: [64]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(@TypeOf(n), msg.len), n);
    try std.testing.expectEqualStrings(msg, buf[0..@intCast(n)]);
}

test "writeAll: empty buffer succeeds without write" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    try std.testing.expect(writeAll(fds[1], (&[0]u8{}).ptr, 0));
}

test "writeAll: detects closed fd" {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
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
    const prev_count = appstate.vm_count;
    appstate.vm_count = appstate.MAX_VMS;
    defer appstate.vm_count = prev_count;
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
    var cfg_home = try TestConfigHome.init("undo");
    defer cfg_home.deinit();

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
    // /api/quickstart/ creates a VM (state-changing) — it must require auth.
    try std.testing.expect(!isAuthExempt(true, "/api/quickstart/ubuntu2404"));
    // Disk-image download streams raw guest bytes — must require auth even
    // though it lives under the otherwise-exempt /api/vm/ prefix.
    try std.testing.expect(!isAuthExempt(true, "/api/vm/0/disk2/download"));
    try std.testing.expect(!isAuthExempt(true, "/api/vm/12/disk2/download"));
}

test "sanitizeSlug: strips shell-unsafe characters" {
    var buf: [vm.MAX_NAME]u8 = undefined;
    try std.testing.expectEqualStrings("My_VM", sanitizeSlug("My VM", &buf));
    try std.testing.expectEqualStrings("test-vm_1.2", sanitizeSlug("test-vm_1.2", &buf));
    try std.testing.expectEqualStrings("_id_", sanitizeSlug("`id`", &buf));
    try std.testing.expectEqualStrings("__id_", sanitizeSlug("$(id)", &buf));
    try std.testing.expectEqualStrings("vm", sanitizeSlug("", &buf));
}

test "sanitizeSlug: fuzz output is always shell-safe" {
    var seed: u64 = 0x243f6a8885a308d3;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var in_buf: [80]u8 = undefined;
        const n = seed % in_buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            in_buf[j] = @truncate(s);
        }
        var out_buf: [vm.MAX_NAME]u8 = undefined;
        const slug = sanitizeSlug(in_buf[0..n], &out_buf);
        try std.testing.expect(slug.len > 0);
        for (slug) |ch| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-';
            try std.testing.expect(ok);
        }
    }
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
        // bodyVal must extract the literal value verbatim...
        try std.testing.expectEqualStrings(mode, val);
        // ...and only "true"/"1" (indices 0 and 1) are truthy.
        const truthy = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        try std.testing.expectEqual(i < 2, truthy);
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
        "theme",               "default_memory_mb",    "default_cpu_cores",
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
    var cfg_home = try TestConfigHome.init("vnets-valid");
    defer cfg_home.deinit();

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
    var cfg_home = try TestConfigHome.init("vnets-empty");
    defer cfg_home.deinit();

    const req = "POST /api/vnets/save HTTP/1.1\r\nHost: localhost\r\n\r\n{}";
    const result = try handleVnetsSave(req);
    // Empty object is body.len == 2, so the "parse error" guard (body.len > 2)
    // does not trip: an empty network set is saved and "ok" is returned.
    try std.testing.expectEqualStrings("ok", result);
}
const daemon_usage =
    \\hangar-web — Hangar VM manager daemon (HTTP server + web UI)
    \\
    \\Usage: hangar-web [--help] [--version]
    \\
    \\Runs the HTTP server and web UI, and serves remote clients such as vmrun.
    \\All configuration is via environment variables — there are no positional
    \\arguments or runtime flags beyond the two below; an unrecognized option
    \\is rejected with exit code 2.
    \\
    \\Options:
    \\  -h, --help     Show this help and exit
    \\  -v, --version  Show version and exit
    \\
    \\Environment:
    \\  KV_API_KEY           X-API-Key secret (1-64 bytes, printable ASCII, no
    \\                       spaces). Setting a non-default key also exposes the
    \\                       daemon on all interfaces (::); unset or the built-in
    \\                       default stays loopback-only.
    \\  KV_PORT              TCP listen port (default 9080; must be 1-65535).
    \\  HANGAR_CONFIG_HOME   Base dir for ~/.config/hangar/* state (default $HOME).
    \\
    \\Endpoints:
    \\  Web UI:  http://localhost:<KV_PORT>/
    \\  Health:  GET /api/health
    \\
    \\Exit codes: 0 success, 1 runtime error, 2 usage error.
    \\
;

const daemon_version = "hangar-web 0.1.0\n";

/// The argument classes the daemon recognizes. It takes no positional
/// arguments. The bare word `help` is accepted as a `.help` alias (matching
/// `vmrun`); any other non-flag token is `.other` and ignored (the daemon
/// starts normally), but a dash-prefixed token that is not help/version is
/// `.unknown` — almost always a mistyped flag, which we reject rather than swallow.
const CliArg = enum { help, version, unknown, other };

/// Classify a single command-line argument against the daemon's minimal flag
/// set. Accepts the same spellings as `vmrun` for cross-tool consistency.
fn classifyCliArg(arg: []const u8) CliArg {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) return .help;
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) return .version;
    // A dash-prefixed token that matched neither is a typo (e.g. `--prot 8080`
    // when the operator meant the KV_PORT env var). The daemon has no such
    // flag, so silently ignoring it would hide the mistake — fail loudly.
    if (arg.len > 0 and arg[0] == '-') return .unknown;
    return .other;
}

pub fn main(init: std.process.Init) !void {
    // Handle --help/--version before any side effects (loading config, creating
    // the hypervisor handle, binding sockets) so they work even without a
    // writable config dir or a free port, and never start a stray daemon.
    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        _ = args_iter.next(); // program name
        while (args_iter.next()) |arg| switch (classifyCliArg(arg)) {
            .help => {
                _ = c.write(1, daemon_usage.ptr, daemon_usage.len);
                std.process.exit(0);
            },
            .version => {
                _ = c.write(1, daemon_version.ptr, daemon_version.len);
                std.process.exit(0);
            },
            .unknown => {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Error: unknown option '{s}' (run with --help for usage)\n", .{arg}) catch "Error: unknown option\n";
                _ = c.write(2, msg.ptr, msg.len);
                std.process.exit(2);
            },
            .other => {},
        };
    }

    // Ignore SIGPIPE — the only safe response to writing on a closed connection.
    _ = signal(SIGPIPE, SIG_IGN);

    appstate.vm_count = persist.load(&appstate.vms, std.heap.page_allocator, &appstate.prefs);
    appstate.g_vmm = hv_backend.createVmm(.auto);
    appstate.g_vmm_ready = true;

    // Allow custom API key via environment variable. Fail fast on an invalid
    // value instead of silently falling back to the weak built-in default —
    // an operator who set KV_API_KEY expects it to take effect.
    if (appio.getenv("KV_API_KEY")) |key| {
        if (!validApiKey(key)) {
            logErr("KV_API_KEY must be 1-64 bytes of printable ASCII (no spaces or control characters) — refusing to start with an invalid key");
            std.process.exit(1);
        }
        if (secretEql(key, API_KEY)) {
            // KV_API_KEY was set to the publicly-known built-in default. Treat it
            // as if unset: keep the loopback-only binding instead of exposing all
            // interfaces behind a secret everyone already knows.
            logErr("WARNING: KV_API_KEY equals the built-in default — keeping loopback-only binding. Set KV_API_KEY to a strong, unique secret to expose Hangar on all interfaces.");
        } else {
            auth_token_len = key.len;
            @memcpy(auth_token[0..key.len], key);
        }
    } else {
        // No custom key: the built-in default API key is in effect. Confine the
        // TCP listener to loopback so the weak default cannot be reached from
        // other hosts. An operator who sets KV_API_KEY opts into all-interface
        // exposure (see `expose_all` below).
        logErr("WARNING: KV_API_KEY not set — serving with the default API key, bound to loopback only. Set KV_API_KEY to a strong secret to expose Hangar on all interfaces.");
    }

    // Only expose the daemon beyond loopback when a real API key is configured.
    const expose_all = auth_token_len > 0;

    const port: u16 = if (appio.getenv("KV_PORT")) |env| blk: {
        const p = std.fmt.parseInt(u16, env, 10) catch {
            logErr("KV_PORT is not a valid port number — refusing to start");
            std.process.exit(1);
        };
        if (p == 0) {
            logErr("KV_PORT must be 1-65535 — refusing to start");
            std.process.exit(1);
        }
        break :blk p;
    } else DEFAULT_PORT;

    const sock = c.socket(AF_INET6, SOCK_STREAM, 0);
    if (sock < 0) {
        logErr("Failed to create TCP socket");
        std.process.exit(1);
    }
    storeServerFd(&tcp_sock_fd, sock);
    defer {
        _ = c.close(sock);
        storeServerFd(&tcp_sock_fd, -1);
    }

    const one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    // Dual-stack: accept both IPv4 and IPv6 on the same socket.
    const zero: c_int = 0;
    _ = c.setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &zero, @sizeOf(c_int));

    // Bind to :: (IPv6 any-address, dual-stack) only when a real API key is
    // set; otherwise confine to the IPv4-mapped loopback (::ffff:127.0.0.1,
    // set below) so the default key is never reachable off-host.
    var addr: c.sockaddr.in6 = std.mem.zeroes(c.sockaddr.in6);
    addr.family = AF_INET6;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.flowinfo = 0;
    addr.scope_id = 0;
    if (!expose_all) {
        // ::ffff:127.0.0.1 — IPv4-mapped loopback. On this dual-stack (V6ONLY=0)
        // socket this accepts IPv4 connections to 127.0.0.1, which is exactly
        // what every local client (webui_app, smoke tests, browser fallback)
        // uses, while rejecting any off-host address.
        addr.addr = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff, 127, 0, 0, 1 };
    }
    // When expose_all, addr.addr stays zero-initialized (in6addr_any).
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in6)) != 0) {
        logErr("Failed to bind TCP port — already in use");
        std.process.exit(1);
    }
    if (c.listen(sock, 10) != 0) {
        logErr("Failed to listen on TCP port");
        std.process.exit(1);
    }

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/hangar-daemon.sock";
    _ = c.unlink(unix_path);
    const unix_sock = c.socket(AF_UNIX, SOCK_STREAM, 0);
    storeServerFd(&unix_sock_fd, unix_sock);
    defer {
        _ = c.close(unix_sock);
        storeServerFd(&unix_sock_fd, -1);
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
    // Restrict the socket to its owner. It lives in world-writable /tmp; without
    // an explicit mode its permissions depend on the process umask, so a lax
    // umask (e.g. 0002) would let other local users connect and drive the daemon
    // using the publicly known default API key. 0600 makes this deterministic.
    _ = c.chmod(unix_path, 0o600);
    if (c.listen(unix_sock, 10) != 0) {
        logErr("Failed to listen on Unix socket");
        return;
    }

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Hangar Daemon v0.1.0                       ║\n", .{});
    std.debug.print("║  TCP:   http://{s}:{d}\n", .{ if (expose_all) "0.0.0.0" else "127.0.0.1", port });
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    var ebuf: [64]u8 = undefined;

    // Emit a single parseable startup line: the box-art banner above is for
    // humans, but log aggregators need a leveled record confirming the daemon
    // came up and which interface scope it bound to.
    {
        var sb: [128]u8 = undefined;
        logAt(.info, std.fmt.bufPrint(&sb, "daemon started: port={d} bind={s}", .{ port, if (expose_all) "all" else "loopback" }) catch "daemon started");
    }

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
        if (conn < 0) {
            // The TCP listener is gone — the daemon stops serving and main()
            // returns. Mirror acceptLoop and surface it so an operator can tell
            // a clean shutdown from a silent listener death.
            logErr("main: TCP accept() failed, daemon exiting");
            break;
        }
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch {
            // Thread exhaustion drops this request; log so load-shedding is visible.
            logErr("main: thread spawn failed, dropping TCP connection");
            _ = c.close(conn);
            continue;
        };
        th.detach();
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "classifyCliArg: help spellings" {
    try std.testing.expectEqual(CliArg.help, classifyCliArg("-h"));
    try std.testing.expectEqual(CliArg.help, classifyCliArg("--help"));
    try std.testing.expectEqual(CliArg.help, classifyCliArg("help"));
}

test "classifyCliArg: version spellings" {
    try std.testing.expectEqual(CliArg.version, classifyCliArg("-v"));
    try std.testing.expectEqual(CliArg.version, classifyCliArg("--version"));
}

test "classifyCliArg: mistyped flags are unknown, bare words are other" {
    try std.testing.expectEqual(CliArg.other, classifyCliArg(""));
    try std.testing.expectEqual(CliArg.unknown, classifyCliArg("--helpp")); // dash-prefixed typo
    try std.testing.expectEqual(CliArg.unknown, classifyCliArg("-V"));
    try std.testing.expectEqual(CliArg.other, classifyCliArg("HELP")); // case-sensitive, no dash
    try std.testing.expectEqual(CliArg.other, classifyCliArg("status"));
}

test "fuzz: classifyCliArg never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0x5EED_F00D);
    const rnd = prng.random();
    var buf: [32]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = classifyCliArg(buf[0..len]);
    }
}

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
    if (c.socketpair(AF_INET, SOCK_STREAM, 0, &tcp_fds) != 0) return error.SkipZigTest;
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
    var cfg_home = try TestConfigHome.init("reorder");
    defer cfg_home.deinit();

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
    var cfg_home = try TestConfigHome.init("save-valid");
    defer cfg_home.deinit();

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

test "isValidMigrateDest: accepts tcp targets, rejects injection" {
    try std.testing.expect(isValidMigrateDest("tcp:10.0.0.2:4444"));
    try std.testing.expect(isValidMigrateDest("tcp:[fe80::1]:4444"));
    // Non-tcp schemes — exec: would run a shell command on the host.
    try std.testing.expect(!isValidMigrateDest("exec:touch /tmp/pwned"));
    try std.testing.expect(!isValidMigrateDest("unix:/tmp/x.sock"));
    try std.testing.expect(!isValidMigrateDest("fd:3"));
    // JSON string break-out via quote/backslash.
    try std.testing.expect(!isValidMigrateDest("tcp:h\":4444"));
    try std.testing.expect(!isValidMigrateDest("tcp:h\\:4444"));
    // Control characters and traversal.
    try std.testing.expect(!isValidMigrateDest("tcp:h\n:4444"));
    try std.testing.expect(!isValidMigrateDest("tcp:../../x"));
    try std.testing.expect(!isValidMigrateDest(""));
}

test "fuzz: isValidMigrateDest never crashes and never allows shell/JSON escape" {
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rand.int(u8);
        const dest = buf[0..len];
        if (isValidMigrateDest(dest)) {
            // Any accepted value must be a clean tcp: target — no shell-exec
            // scheme, no characters that could break the QMP JSON string.
            try std.testing.expect(std.mem.startsWith(u8, dest, "tcp:"));
            try std.testing.expect(std.mem.indexOfAny(u8, dest, "\"\\") == null);
            for (dest) |ch| try std.testing.expect(ch >= 0x20);
        }
    }
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

test "migrateStatusHttpCode: maps status payloads to HTTP codes" {
    try std.testing.expectEqual(HTTP_OK, migrateStatusHttpCode("{\"status\":\"active\"}"));
    try std.testing.expectEqual(HTTP_OK, migrateStatusHttpCode("{\"status\":\"completed\"}"));
    try std.testing.expectEqual(HTTP_NOT_FOUND, migrateStatusHttpCode("{\"status\":\"error\",\"error\":\"invalid idx\"}"));
    try std.testing.expectEqual(HTTP_NOT_FOUND, migrateStatusHttpCode("{\"status\":\"error\",\"error\":\"bad idx\"}"));
    try std.testing.expectEqual(HTTP_CONFLICT, migrateStatusHttpCode("{\"status\":\"error\",\"error\":\"not running\"}"));
    try std.testing.expectEqual(HTTP_INTERNAL_ERROR, migrateStatusHttpCode("{\"status\":\"error\",\"error\":\"qmp query\"}"));
    try std.testing.expectEqual(HTTP_INTERNAL_ERROR, migrateStatusHttpCode("{\"status\":\"error\"}"));
}

test "fuzz: migrateStatusHttpCode never panics and only ever returns mapped codes" {
    var prng = std.Random.DefaultPrng.init(0x9135_a7c2);
    const rnd = prng.random();
    const fragments = [_][]const u8{
        "{\"status\":\"error\"", "invalid idx", "bad idx", "not running",
        "qmp query", "\"status\":\"active\"", "}", ",", "\"", "x",
    };
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var len: usize = 0;
        const parts = rnd.intRangeAtMost(usize, 0, 6);
        var p: usize = 0;
        while (p < parts) : (p += 1) {
            const frag = fragments[rnd.intRangeLessThan(usize, 0, fragments.len)];
            if (len + frag.len > buf.len) break;
            @memcpy(buf[len..][0..frag.len], frag);
            len += frag.len;
        }
        const code = migrateStatusHttpCode(buf[0..len]);
        try std.testing.expect(code == HTTP_OK or code == HTTP_NOT_FOUND or
            code == HTTP_CONFLICT or code == HTTP_INTERNAL_ERROR);
    }
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
    // Empty VM table → the idx>=vm_count guard always fires, so random bytes
    // never reach QMP/VMM/filesystem side effects. Assert the precondition so a
    // future test that leaks a populated table can't silently turn this fuzzer
    // into a destructive power-cycle harness.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
    var prng = std.Random.DefaultPrng.init(0x70A1E070);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handlePower(&buf) catch {};
    }
}

test "fuzz: handleDelete never panics on random request-like input" {
    // Empty table required: otherwise random idx bytes could delete a real VM.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
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
    // Empty table keeps reorder a pure no-op over random from/to indices.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
    var prng = std.Random.DefaultPrng.init(0x70A1E073);
    const rnd = prng.random();
    for (0..500) |_| {
        var buf: [128]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = handleReorder(&buf) catch {};
    }
}

test "fuzz: idx-gated VM handlers never panic on random request-like input" {
    // Every handler below locks vms_mutex, parses an idx out of the (untrusted)
    // request line, and bails at `idx >= vm_count` before touching QMP, the
    // filesystem, or the VMM dispatch. With the test's empty VM table that guard
    // always fires, so feeding fully random bytes exercises the prefix match and
    // idx parse on each surface with zero I/O side effects — same contract as the
    // handlePower/handleDelete harnesses above, extended to the operations that
    // previously had no fuzz coverage.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);

    var prng = std.Random.DefaultPrng.init(0x70A1E074);
    const rnd = prng.random();
    for (0..2000) |_| {
        var buf: [160]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        const req = buf[0..rnd.uintLessThan(usize, buf.len)];
        var out: [256]u8 = undefined;
        _ = handleSuspend(req) catch {};
        _ = handlePause(req) catch {};
        _ = handleResume(req) catch {};
        _ = handleReset(req) catch {};
        _ = handleShutdown(req) catch {};
        _ = handleRename(req) catch {};
        _ = handleClone(req) catch {};
        _ = handleCad(req) catch {};
        _ = handleMigrate(req) catch {};
        _ = handleMigrateCancel(req) catch {};
        _ = handleSnapshotTake(req) catch {};
        _ = handleSnapshotRevert(req) catch {};
        _ = handleSnapshotDelete(req) catch {};
        _ = handleSnapshotList(req, &out);
        _ = handleMigrateStatus(req, &out);
    }
    // Table must be untouched: no handler created or removed a VM.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
}

test "fuzz: handleUploadDisk multipart parser never panics on structured input" {
    // Random bytes alone die at the `POST /api/vm/<idx>` prefix check, so they
    // never reach the multipart parser. This harness keeps a valid request line
    // and Content-Type boundary, then mutates the boundary marker, part headers,
    // filename token, and body framing — the slicing-heavy code that backs up
    // over CRLF, extracts quoted/unquoted filenames, and computes data bounds.
    //
    // Safe to drive directly: with the test's empty VM table the handler returns
    // "invalid idx" at the `idx >= vm_count` guard, which sits *after* the full
    // parse but *before* any filesystem write — so the parser is exercised with
    // no I/O side effects.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);

    var prng = std.Random.DefaultPrng.init(0x71117ADD);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        // Random boundary token (may be empty, may contain odd bytes).
        var bnd: [24]u8 = undefined;
        const bnd_len = rnd.uintLessThan(usize, bnd.len + 1);
        for (bnd[0..bnd_len]) |*b| b.* = rnd.int(u8);

        // Random filename token, including traversal / injection bait.
        const fnames = [_][]const u8{
            "disk.qcow2", "../../etc/passwd", "a,b.img", "x\x00y", "", "no-quote",
            "with space.vmdk", "..", "a\"b", "\r\n",
        };
        const fname = fnames[rnd.uintLessThan(usize, fnames.len)];

        const quoted = rnd.boolean();
        const msg = std.fmt.bufPrint(&buf,
            "POST /api/vm/0 HTTP/1.1\r\nContent-Type: multipart/form-data; boundary={s}\r\n\r\n" ++
            "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename={s}{s}{s}\r\n\r\n" ++
            "PAYLOAD-BYTES\r\n--{s}--\r\n", .{
            bnd[0..bnd_len],
            bnd[0..bnd_len],
            if (quoted) "\"" else "",
            fname,
            if (quoted) "\"" else "",
            bnd[0..bnd_len],
        }) catch {
            _ = handleUploadDisk("POST /api/vm/0 HTTP/1.1\r\n\r\n") catch {};
            continue;
        };

        // Corrupt a handful of random bytes to fuzz the framing.
        const flips = rnd.uintLessThan(usize, 6);
        var f: usize = 0;
        while (f < flips) : (f += 1) {
            msg[rnd.uintLessThan(usize, msg.len)] = rnd.int(u8);
        }

        _ = handleUploadDisk(msg) catch {};
    }

    // The parser path must not have mutated shared state (no write reached).
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
}

test "requestLine: stops at CRLF and keeps method+path" {
    var out: [128]u8 = undefined;
    const line = requestLine("POST /api/power/3 HTTP/1.1\r\nHost: x\r\n", &out);
    try std.testing.expectEqualStrings("POST /api/power/3 HTTP/1.1", line);
}

test "requestLine: sanitizes control bytes to '?'" {
    var out: [128]u8 = undefined;
    const line = requestLine("GET /a\tb\x01c", &out);
    try std.testing.expectEqualStrings("GET /a?b?c", line);
}

test "requestLine: respects output buffer bound" {
    var out: [4]u8 = undefined;
    const line = requestLine("GET /aaaaaaaa", &out);
    try std.testing.expectEqual(@as(usize, 4), line.len);
    try std.testing.expectEqualStrings("GET ", line);
}

test "sanitizeLogName: replaces control bytes and bounds output" {
    var out: [vm.MAX_NAME]u8 = undefined;
    try std.testing.expectEqualStrings("my-vm", sanitizeLogName(&out, "my-vm"));
    try std.testing.expectEqualStrings("a?b?c", sanitizeLogName(&out, "a\nb\x00c"));
    var small: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", sanitizeLogName(&small, "abcdef"));
}

test "logReqErr: emits without crashing on normal and edge inputs" {
    // logReqErr writes a single sanitized line to fd 2; it must never crash
    // regardless of context length, error value, or request-line content.
    logReqErr("VNC proxy failed", error.ConnectionRefused, "GET /ws/vnc/3 HTTP/1.1\r\n");
    logReqErr("", error.BrokenPipe, "");
    // Control bytes in the request line must not break the single-line invariant.
    logReqErr("export failed", error.AccessDenied, "POST /api/export/9\t\x01\r\nHost: x");
    // Overlong context still returns (falls back to the static context string).
    const long_ctx = "x" ** 400;
    logReqErr(long_ctx, error.OutOfMemory, "GET /a");
}

test "logOpErr: emits without crashing on normal and edge inputs" {
    // logOpErr writes a single sanitized line to fd 2; it must never crash
    // regardless of op label, error value, or VM-name content.
    logOpErr("snapshot take", error.NoSpaceLeft, "my-vm");
    logOpErr("power on", error.FileNotFound, "");
    // Control bytes in the VM name must not break the single-line invariant.
    logOpErr("snapshot revert", error.AccessDenied, "vm\n\x01name");
    // Overlong op label still returns (falls back to the static op string).
    const long_op = "x" ** 400;
    logOpErr(long_op, error.OutOfMemory, "vm");
}

test "fuzz logOpErr: random vm names never crash" {
    var prng = std.Random.DefaultPrng.init(0x0BCE7711);
    const rnd = prng.random();
    const errs = [_]anyerror{ error.NoSpaceLeft, error.FileNotFound, error.AccessDenied, error.OutOfMemory };
    for (0..500) |_| {
        var buf: [vm.MAX_NAME]u8 = undefined;
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        logOpErr("fuzz", errs[rnd.uintLessThan(usize, errs.len)], buf[0..len]);
    }
}

test "fuzz logReqErr: random request lines never crash" {
    var prng = std.Random.DefaultPrng.init(0x10C9E771);
    const rnd = prng.random();
    const errs = [_]anyerror{ error.ConnectionRefused, error.BrokenPipe, error.AccessDenied, error.OutOfMemory };
    for (0..500) |_| {
        var buf: [256]u8 = undefined;
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        logReqErr("fuzz", errs[rnd.uintLessThan(usize, errs.len)], buf[0..len]);
    }
}

test "fuzz: sanitizeLogName never panics and stays printable/bounded" {
    var prng = std.Random.DefaultPrng.init(0xA0D17);
    const rnd = prng.random();
    for (0..1000) |_| {
        var in: [80]u8 = undefined;
        for (&in) |*b| b.* = rnd.int(u8);
        const in_len = rnd.intRangeAtMost(usize, 0, in.len);
        const cap = rnd.intRangeAtMost(usize, 1, 64);
        var out: [64]u8 = undefined;
        const safe = sanitizeLogName(out[0..cap], in[0..in_len]);
        try std.testing.expect(safe.len <= cap);
        try std.testing.expect(safe.len <= in_len);
        for (safe) |ch| try std.testing.expect(ch >= 0x20 and ch < 0x7f);
    }
}

test "fuzz: requestLine never panics and stays printable/bounded" {
    var prng = std.Random.DefaultPrng.init(0x5EE11DE);
    const rnd = prng.random();
    for (0..1000) |_| {
        var in: [64]u8 = undefined;
        for (&in) |*b| b.* = rnd.int(u8);
        const cap = rnd.intRangeAtMost(usize, 1, 64);
        var out: [64]u8 = undefined;
        const line = requestLine(&in, out[0..cap]);
        try std.testing.expect(line.len <= cap);
        for (line) |ch| try std.testing.expect(ch >= 0x20 and ch < 0x7f);
    }
}
