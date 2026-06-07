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
const catalog = @import("catalog.zig");
const framebuffer = @import("framebuffer.zig");
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
const SO_SNDTIMEO: c_int = 21;
const SHUT_RDWR: c_int = 2;
const IPPROTO_IPV6: c_int = 41;

/// Cap on concurrent client connections. Each accepted connection spends a
/// thread plus a 64 KB request buffer (and a WebSocket relay spends two more
/// threads), so without a bound a flood of connections — including ones that
/// stall mid-request or never read their response — would exhaust host threads
/// and memory. New connections past the cap are dropped (cheap close).
const MAX_CONNECTIONS: u32 = 256;
var active_connections: u32 = 0;
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
    if (std.mem.eql(u8, path, "/api/catalog")) return true;
    if (std.mem.eql(u8, path, "/api/networks")) return true;
    // Prefix paths — ensure the prefix ends at a path boundary
    if (std.mem.startsWith(u8, path, "/api/vms/")) {
        // Strip any query string so suffix checks match regardless of `?...`.
        const p = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
        // The disk-image download streams raw guest disk bytes (filesystems,
        // credentials, ...). It must never be exempt: when KV_API_KEY is set the
        // daemon binds all interfaces, so exempting it would let an
        // unauthenticated remote client exfiltrate the disk image.
        if (std.mem.endsWith(u8, p, "/disk2/download")) return false;
        // The framebuffer and migrate-status read endpoints stay auth-required,
        // matching the pre-refactor posture.
        if (std.mem.endsWith(u8, p, "/framebuffer")) return false;
        if (std.mem.endsWith(u8, p, "/migrate")) return false;
        // Screenshot exposes the guest display — require auth like framebuffer.
        if (std.mem.endsWith(u8, p, "/screenshot")) return false;
        // Guest IPs are sensitive — require auth.
        if (std.mem.endsWith(u8, p, "/guestinfo")) return false;
        // Detail, /log, and /snapshots are read-only and exempt.
        return true;
    }
    // POST /api/vms/quickstart/ creates a VM (state-changing) — it must require
    // auth. Since it is POST, the early return above already covers it.
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
/// binds the IPv4-mapped loopback (`::ffff:127.0.0.1`) and accepts the
/// publicly-known built-in key. Without
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
        "write err", "change err", "eject err", "resize err",
        "upload err", "save failed",
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
    if (std.mem.indexOf(u8, ct, "text/css") != null or std.mem.indexOf(u8, ct, "application/javascript") != null or std.mem.indexOf(u8, ct, "image/svg+xml") != null) {
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
    // Browsers cannot set request headers on a WebSocket handshake, so the UI's
    // console/serial sockets carry no X-API-Key. In loopback mode (no KV_API_KEY)
    // the daemon binds ::1 only and hostHeaderOk has already required a loopback
    // Host, so the origin is gated without the key — allow the upgrade, otherwise
    // the embedded VNC/SPICE/serial console never connects. When KV_API_KEY is
    // set the daemon is exposed and these routes stay key-gated (browser console
    // is then local/CLI-only, matching the write-action policy).
    if (auth_token_len == 0) return true;
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
        // Bound concurrent connections. Reserve a slot before spawning; serveHtml
        // releases it on exit. Shed cheaply (close) when over the cap so a flood
        // can't exhaust threads/memory.
        const in_use = @atomicRmw(u32, &active_connections, .Add, 1, .seq_cst) + 1;
        if (in_use > MAX_CONNECTIONS) {
            _ = @atomicRmw(u32, &active_connections, .Sub, 1, .seq_cst);
            logWarn("acceptLoop: connection cap reached, dropping connection");
            _ = c.close(conn);
            continue;
        }
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch {
            // Thread exhaustion drops this request; log so load-shedding is visible.
            logErr("acceptLoop: thread spawn failed, dropping connection");
            _ = @atomicRmw(u32, &active_connections, .Sub, 1, .seq_cst);
            _ = c.close(conn);
            continue;
        };
        th.detach();
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer {
        _ = c.close(conn);
        _ = @atomicRmw(u32, &active_connections, .Sub, 1, .seq_cst);
    }

    // 30-second receive AND send timeout. SO_SNDTIMEO is essential: without it a
    // client that issues a valid request but never reads the response fills the
    // socket send buffer and parks this thread in write() forever (slow-read DoS,
    // reachable unauthenticated on the auth-exempt HTML/api routes).
    const tv: c.timeval = .{ .sec = 30, .usec = 0 };
    _ = c.setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = c.setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));

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
    // "GET /api/vms/../../api/vms/0" matched the exempt "GET /api/vms/").
    const req_path = if (std.mem.indexOfScalar(u8, req, ' ')) |sp1| blk: {
        const after_sp = req[sp1 + 1 ..];
        const sp2 = std.mem.indexOfAny(u8, after_sp, " ?") orelse after_sp.len;
        break :blk after_sp[0..sp2];
    } else req;

    // ── Large disk2 upload: stream the body straight to disk ──
    // Intercepted here, before the Content-Length cap below, so a multi-GB disk
    // image isn't rejected by the 64 KB request-buffer limit. Auth normally runs
    // after the body read; this path reads the body itself, so authenticate now
    // (hostHeaderOk + the POST rate limit already ran above).
    if (std.mem.startsWith(u8, req, "POST ") and parseVmIdxSuffix(req, "POST /api/vms/", "/disk2") != null) {
        if (!checkAuth(req)) {
            writeHttpResponse(conn, HTTP_UNAUTHORIZED, "application/json; charset=utf-8", "{\"error\":\"auth required\"}");
            return;
        }
        handleUploadDiskStreaming(conn, req);
        return;
    }

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
                // Total deadline across the whole body read. SO_RCVTIMEO bounds a
                // single read(), but a slow-loris that dribbles one byte just under
                // the timeout resets it every read and could hold the thread for
                // hours. Bound the aggregate read time too.
                var start_ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &start_ts);
                while (req_len < need and req_len < buf.len) {
                    const m = c.read(conn, buf[req_len..].ptr, buf.len - req_len);
                    if (m <= 0) break;
                    req_len += @intCast(m);
                    var now_ts: std.c.timespec = undefined;
                    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now_ts);
                    if (now_ts.sec - start_ts.sec > 30) break;
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
    var detail_buf: [vm.MAX_CLOUD_INIT * 6]u8 = undefined; // holds cloud-init user-data JSON-escaped (~6x)
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
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/disk2/download") != null) {
        handleDisk2Download(conn, req) catch |e| {
            logReqErr("disk2 download failed", e, req);
            // Error path uses the unified JSON envelope like the rest of the API,
            // even though the success path streams binary (octet-stream). A
            // programmatic client should never have to special-case text/plain.
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"download failed\"}");
        };
        return;
    }
    // disk2 upload is handled by the streaming interception earlier in serveHtml
    // (before the Content-Length cap), so it never reaches here.
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/log") != null) {
        handleVmLog(conn, req) catch |e| {
            logReqErr("vm log read failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"log read failed\"}");
        };
        return;
    }
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/diskinfo") != null) {
        var di_buf: [160]u8 = undefined;
        const body = handleDiskInfo(req, &di_buf);
        // The body is already a JSON object; pick a status that matches it rather
        // than always 200 (an error body served as 200 is misleading to clients).
        const di_status: u16 = if (!std.mem.startsWith(u8, body, "{\"error\""))
            HTTP_OK
        else if (std.mem.indexOf(u8, body, "unavailable") != null)
            HTTP_INTERNAL_ERROR
        else if (std.mem.indexOf(u8, body, "invalid idx") != null)
            HTTP_NOT_FOUND
        else
            HTTP_BAD_REQUEST;
        writeHttpResponse(conn, di_status, "application/json; charset=utf-8", body);
        return;
    }
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/screenshot") != null) {
        handleScreenshot(conn, req);
        return;
    }
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/guestinfo") != null) {
        var gi_buf: [640]u8 = undefined;
        writeHttpResponse(conn, HTTP_OK, "application/json; charset=utf-8", handleGuestInfo(req, &gi_buf));
        return;
    }
    if (parseVmIdxSuffix(req, "POST /api/vms/", "/export") != null) {
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
        response = catalog.capabilitiesJson(&snap_buf);
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
        // Report a degraded status when persistence is disabled (unreadable or
        // newer vms.json) so a probe sees a service that accepts requests but
        // silently drops every config change, instead of a flat "ok".
        const health_status = if (persist.loadDegraded()) "degraded" else "ok";
        response = std.fmt.bufPrint(&snap_buf, "{{\"status\":\"{s}\",\"version\":\"1.0\",\"vms\":{d},\"running\":{d},\"persist\":\"{s}\"}}", .{ health_status, total, running, health_status }) catch "{\"status\":\"ok\",\"version\":\"1.0\"}";
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
        response = catalog.catalogJson(&snap_buf);
    } else if (std.mem.startsWith(u8, req, "POST /api/vms/quickstart/")) {
        // State-changing (creates and persists a VM), so it must be POST — a GET
        // here would let prefetchers/crawlers/caches silently create VMs and make
        // repeated requests non-idempotent. The web UI already POSTs this route.
        response = try handleQuickstart(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/vms")) {
        // Create a VM (collection POST).
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/vms/import")) {
        response = try handleImport(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/vms/reorder")) {
        response = try handleReorder(req);
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/vms/undo")) {
        response = try handleUndo();
        content_type = "text/plain";
    } else if (routeExact(req, "POST /api/vms/save")) {
        // Save-all (persist the whole library).
        response = "saved";
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
            logSaveErr("", e);
            response = "save failed";
        };
        content_type = "text/plain";
        // ── Item sub-action routes (longest suffix first where ambiguous) ──
    } else if (parseVmIdxSuffix(req, "GET /api/vms/", "/framebuffer")) |fb_idx| {
        if (std.heap.page_allocator.alloc(u8, framebuffer.BMP_BUF_SIZE)) |bytes| {
            response_alloc = bytes;
            response = framebuffer.render(fb_idx, bytes);
        } else |_| {
            response = "no fb";
        }
        // renderFramebuffer returns BMP bytes on success or a short error token
        // ("no vm", "off", "no vnc", ...) on failure. Only label real image
        // bytes as image/bmp; let error tokens fall through as text/plain so the
        // central status mapper turns them into proper 4xx/5xx JSON instead of a
        // 200 "image" the browser silently renders as broken.
        content_type = if (std.mem.startsWith(u8, response, "BM")) "image/bmp" else "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/power") != null) {
        response = try handlePower(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/delete") != null) {
        response = try handleDelete(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/clone") != null) {
        response = try handleClone(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/rename") != null) {
        response = try handleRename(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/suspend") != null) {
        response = try handleSuspend(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/pause") != null) {
        response = try handlePause(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/resume") != null) {
        response = try handleResume(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/shutdown") != null) {
        response = try handleShutdown(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/reset") != null) {
        response = try handleReset(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/cad") != null) {
        response = try handleCad(req);
        content_type = "text/plain";
        // Snapshots: longer suffixes before the bare `/snapshots`.
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/disk/resize") != null) {
        response = try handleResizeDisk(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/cdrom/eject") != null) {
        response = try handleCdromEject(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/cdrom") != null) {
        response = try handleCdromChange(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/snapshots/revert") != null) {
        response = try handleSnapshotRevert(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/snapshots/delete") != null) {
        response = try handleSnapshotDelete(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/snapshots") != null) {
        response = try handleSnapshotTake(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "GET /api/vms/", "/snapshots") != null) {
        response = handleSnapshotList(req, &snap_buf);
        content_type = "text/plain";
        // Migrate: `/migrate/cancel` before `/migrate`.
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/migrate/cancel") != null) {
        response = try handleMigrateCancel(req);
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "GET /api/vms/", "/migrate") != null) {
        response = handleMigrateStatus(req, &snap_buf);
        content_type = "application/json; charset=utf-8";
        // The status payload is JSON, so it bypasses the central text/plain error
        // mapper. Surface its error states as real HTTP codes — otherwise a bad
        // index or a failed QMP query both return 200 OK, indistinguishable from a
        // live migration to a programmatic client. The body is unchanged and the
        // web UI reads it regardless of status code, so this is non-breaking.
        status = migrateStatusHttpCode(response);
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/migrate") != null) {
        response = try handleMigrate(req);
        // The success body is a JSON object ({"status":"started"}); label it as
        // such for strict clients. Error returns are bare tokens ("no dest",
        // "qmp err", ...) kept on text/plain so the central error mapper turns
        // them into 4xx/5xx JSON envelopes.
        content_type = if (std.mem.startsWith(u8, response, "{"))
            "application/json; charset=utf-8"
        else
            "text/plain";
        // ── Bare item routes (no trailing segment) — matched LAST. ──
    } else if (parseVmIdxExact(req, "GET /api/vms/") != null) {
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
    } else if (parseVmIdxExact(req, "POST /api/vms/") != null) {
        // Update VM settings (bare POST on the item).
        response = try handleSave(req);
        content_type = "text/plain";
    } else if (routeExact(req, "GET /api/networks")) {
        content_type = "application/json; charset=utf-8";
        response = handleVnetsJson(&snap_buf);
    } else if (routeExact(req, "POST /api/networks")) {
        response = handleVnetsSave(req) catch |e| blk: {
            // Surface a failed networks.json write: without this the browser
            // gets "save err" but the daemon log stays silent, so an operator
            // can't tell a full disk from a permissions problem.
            logReqErr("networks save failed", e, req);
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
            } else if (anyEql(response, &.{ "not running", "off", "not paused", "vm running", "full", "shrink not allowed" })) {
                // The resource is in a state incompatible with the request
                // (running VM that must be off, off VM that must be running, table
                // at capacity, ...). 409 lets clients distinguish a transient state
                // conflict — retriable after changing VM state — from a malformed
                // request (400).
                break :blk HTTP_CONFLICT;
            } else if (anyEql(response, &.{ "no disk", "no body", "invalid name", "bad path", "no name", "no path", "bad ext", "no file", "bad name", "no dest", "bad dest", "missing from/to", "parse error", "bad size", "no primary disk", "name collides with primary disk", "no filename", "bad filename", "no content-length", "no boundary", "no headers end", "no boundary in body" })) {
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
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                // A pong may also carry a payload; consume it to stay frame-aligned.
                if (hdr.opcode == .pong) {
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    continue;
                }
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
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                // A pong may also carry a payload; consume it to stay frame-aligned.
                if (hdr.opcode == .pong) {
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    continue;
                }
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
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                // A pong may also carry a payload; consume it to stay frame-aligned.
                if (hdr.opcode == .pong) {
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    continue;
                }
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

fn renderVmDetail(req: []const u8, buf: []u8) ![]const u8 {
    const idx = parseIdx(req, "GET /api/vms/") orelse return error.RenderFailed;
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
    var tags_buf: [512]u8 = undefined;
    const tags_e = if (v.tags_len > 0) escapeJson(&tags_buf, v.getTagsSlice(), "tags") else "";

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
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}","tags":"{s}"
    , .{
        idx,                                    name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
        v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
        v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
        sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
        v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
        flp_e,                                  pf_e,                                 tags_e,
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
        \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}
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

    // cloud-init user-data can be multi-KB and contain quotes/newlines — escape
    // it into its own buffer. This part closes the JSON object.
    var ci_esc: [vm.MAX_CLOUD_INIT * 3]u8 = undefined;
    const ci_e = if (v.hasCloudInit()) escapeJson(&ci_esc, v.getCloudInitSlice(), "cloud_init") else "";
    const part2e = std.fmt.bufPrint(buf[w..], ",\"cloud_init\":\"{s}\"}}", .{ci_e}) catch return error.RenderFailed;
    w += part2e.len;

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

        var tags_buf: [512]u8 = undefined;
        const tags_e = if (v.tags_len > 0) escapeJson(&tags_buf, v.getTagsSlice(), "tags") else "";

        // First block: up through tags
        const part1 = std.fmt.bufPrint(buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}","tags":"{s}"
        , .{
            i,                                      name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
            v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
            v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
            sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
            v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
            flp_e,                                  pf_e,                                 tags_e,
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
    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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

/// Return the last `cap` bytes of `data` (all of it when shorter). Pure helper
/// so the tail-window math is unit/fuzz testable without touching the filesystem.
fn tailSlice(data: []const u8, cap: usize) []const u8 {
    if (data.len <= cap) return data;
    return data[data.len - cap ..];
}

/// Read the tail of a log file into `out` (its last `out.len` bytes). Returns
/// the populated slice, or "" if the file is missing, empty, or unreadable.
fn readLogTail(path: [*:0]const u8, out: []u8) []const u8 {
    if (out.len == 0) return "";
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return "";
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, 2); // SEEK_END = 2
    if (end <= 0) return "";
    const size: u64 = @intCast(end);
    const want: usize = @intCast(@min(size, @as(u64, out.len)));
    const off: i64 = @intCast(size - want);
    if (std.c.lseek(fd, off, 0) < 0) return ""; // SEEK_SET = 0
    var got: usize = 0;
    while (got < want) {
        const n = std.c.read(fd, out.ptr + got, want - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    return out[0..got];
}

/// Serve the tail of a VM's QEMU stderr log (`/var/tmp/hangar-vm-<name>.log`)
/// as text/plain for diagnostics. Auth-gated like the rest of `/api/vms/*`; the
/// VM name is copied out under the lock so no filesystem I/O runs while held.
fn handleVmLog(conn: c.fd_t, req: []const u8) !void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad index\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no vm\"}");
            return;
        }
        const name = appstate.vms[idx].getNameSlice();
        // qmp.isPathSafeName rejects '/', '.', and control bytes — the same guard
        // QMP uses before building socket paths, so a hostile config name cannot
        // escape /var/tmp via traversal even if it slipped past creation checks.
        if (name.len == 0 or name.len > name_buf.len or !qmp.isPathSafeName(name)) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad name\"}");
            return;
        }
        @memcpy(name_buf[0..name.len], name);
        name_len = name.len;
    }

    var path_buf: [320]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/var/tmp/hangar-vm-{s}.log", .{name_buf[0..name_len]}) catch {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"path err\"}");
        return;
    };
    var log_buf: [65536]u8 = undefined;
    const body = readLogTail(path, &log_buf);
    if (body.len == 0) {
        // No log file yet: the VM never started, or QEMU emitted nothing on stderr.
        writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no log\"}");
        return;
    }
    writeHttpResponse(conn, HTTP_OK, "text/plain; charset=utf-8", body);
    logAudit("vm log read", name_buf[0..name_len]);
}

/// Best-effort: create the primary disk image for a freshly-configured VM and
/// point its `disk_path` at it.
///
/// VM creation (`POST /api/vms`, `/api/vms/quickstart`) collects a "Disk Size (GB)" but
/// no disk path — the path is derived here as `$HOME/VMs/<name>.<ext>`, matching
/// the clone flow. Without this the size was stored but no image was ever
/// created and `disk_path` stayed empty, so the VM booted with no hard disk and
/// `disk_size_gb` had no effect.
///
/// Best-effort by design: if `qemu-img` is missing or the write fails, the
/// failure is logged and `disk_path` is left empty (so no broken `-drive` is
/// emitted and VM creation still succeeds, exactly as before this wiring). An
/// existing image at the target path is adopted, never recreated, so a name
/// collision can't destroy on-disk guest data.
/// Returns true only when a NEW image was created by this call (so the caller
/// can safely delete it on rollback). Adopting a pre-existing image or any
/// no-op/failure returns false — those must never be deleted.
fn ensurePrimaryDisk(cfg: *vm.VmConfig) bool {
    if (cfg.hasDisk()) return false; // path already set (import/clone path)
    if (cfg.disk_size_gb == 0 or !cfg.hasName()) return false;
    const home = appio.getenv("HOME") orelse "/tmp";
    var dir_buf: [vm.MAX_PATH]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/VMs", .{home}) catch return false;
    std.Io.Dir.cwd().createDirPath(appio.io(), dir) catch {};
    var path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/VMs/{s}.{s}", .{ home, cfg.getNameSlice(), std.mem.span(cfg.disk_format.toStr()) }) catch return false;
    // Adopt an existing image rather than letting qemu-img recreate (destroy) it.
    if (std.Io.Dir.cwd().access(appio.io(), path, .{})) |_| {
        cfg.setDiskPath(path);
        return false; // adopted, not created — caller must not delete it
    } else |_| {}
    qemu.createDiskImage(path, cfg.disk_size_gb, cfg.disk_format, std.heap.page_allocator) catch |e| {
        logOpErr("create disk", e, cfg.getNameSlice());
        return false; // leave disk_path empty: no -drive emitted, same as before
    };
    cfg.setDiskPath(path);
    return true;
}

fn handleNewVm(req: []const u8) ![]const u8 {
    // Build + validate the config without touching shared state, then take the
    // lock only to read prefs / assign ports. `ensurePrimaryDisk` forks
    // `qemu-img create` (a blocking runWait), so it must run with the lock
    // released — holding vms_mutex across it would freeze every other handler
    // and the liveness/autoprotect tickers (project rule: never hold a lock
    // across I/O). After the disk is created we re-acquire the lock, RE-CHECK
    // capacity (the table may have filled while unlocked), then commit.
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (appstate.vm_count >= appstate.MAX_VMS) return "full";
    }
    // Parse body: name=...&mem=...&cpu=...&disk=... plus all advanced fields (for undo restore)
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var cfg = vm.VmConfig{};
    var val_buf: [vm.MAX_CLOUD_INIT * 3]u8 = undefined; // fits URL-encoded cloud-init user-data
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
        if (std.mem.eql(u8, key, "disk2_size")) cfg.disk2_size_gb = vm.clampOptionalDiskSize(std.fmt.parseInt(u32, val, 10) catch cfg.disk2_size_gb);
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
        if (std.mem.eql(u8, key, "tags")) cfg.setTags(val);
        if (std.mem.eql(u8, key, "cloud_init")) cfg.setCloudInit(val);
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
        if (std.mem.eql(u8, key, "extra0_size")) cfg.extra_disks[0].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra0_format")) cfg.extra_disks[0].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[0].format.toIndex());
        if (std.mem.eql(u8, key, "extra1_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(1, val);
        }
        if (std.mem.eql(u8, key, "extra1_size")) cfg.extra_disks[1].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra1_format")) cfg.extra_disks[1].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[1].format.toIndex());
        if (std.mem.eql(u8, key, "extra2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(2, val);
        }
        if (std.mem.eql(u8, key, "extra2_size")) cfg.extra_disks[2].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra2_format")) cfg.extra_disks[2].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[2].format.toIndex());
        if (std.mem.eql(u8, key, "extra3_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setExtraDiskPath(3, val);
        }
        if (std.mem.eql(u8, key, "extra3_size")) cfg.extra_disks[3].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra3_format")) cfg.extra_disks[3].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[3].format.toIndex());
    }

    // Apply defaults for fields not explicitly provided. Reading prefs/ports
    // needs the lock; port assignment is recomputed after the disk is created
    // (below) in case the table changed while unlocked.
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (!has_autoprotect) {
            cfg.autoprotect = appstate.prefs.autoprotect_enabled_default;
            cfg.autoprotect_interval_min = appstate.prefs.autoprotect_interval_min_default;
            cfg.autoprotect_max = appstate.prefs.autoprotect_max_default;
        }
    }
    if (!has_mac) {
        var mac_buf: [18]u8 = undefined;
        const mac = vm.generateMacAddress(&mac_buf);
        cfg.setMacAddress(std.mem.span(mac));
    }

    // Create the primary disk image with the lock released — this forks
    // `qemu-img create` (blocking). Best-effort: on failure disk_path stays
    // empty, exactly as before.
    const disk_created = ensurePrimaryDisk(&cfg);

    // Re-acquire the lock to assign ports and commit. RE-CHECK capacity: the
    // array may have filled while we were creating the disk unlocked.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (appstate.vm_count >= appstate.MAX_VMS) {
        if (disk_created) cleanupCreatedDisk(&cfg);
        return "full";
    }
    if (!has_vnc_port) cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    if (!has_spice_port) cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    appstate.vms[appstate.vm_count] = cfg;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("", e);
        return "save failed";
    };
    logAudit("create", cfg.getNameSlice());
    return "ok";
}

/// Delete a disk image `ensurePrimaryDisk` just created when the VM ends up not
/// being committed (the table filled while the lock was released). Only call
/// this when `ensurePrimaryDisk` returned true (it newly created the image) so a
/// pre-existing/adopted image is never destroyed. Best-effort.
fn cleanupCreatedDisk(cfg: *const vm.VmConfig) void {
    const dp = cfg.getDiskPathSlice();
    if (dp.len == 0 or dp.len >= vm.MAX_PATH) return;
    var path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    @memcpy(path_buf[0..dp.len], dp);
    path_buf[dp.len] = 0;
    _ = c.unlink(@ptrCast(&path_buf));
}

fn handleQuickstart(req: []const u8) ![]const u8 {
    // Match the path independent of method so the parser is agnostic to GET/POST.
    const prefix = "/api/vms/quickstart/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const slug = rest[0..end];

    // Look up the template (pure; no lock). VM creation below takes the lock.
    const tmpl = catalog.find(slug) orelse return "not found";

    var cfg = vm.VmConfig{};
    cfg.setName(tmpl.name);
    cfg.memory_mb = tmpl.memory_mb;
    cfg.cpu_cores = tmpl.cpu_cores;
    cfg.disk_size_gb = tmpl.disk_size_gb;
    cfg.guest_os = vm.GuestOs.fromIndex(tmpl.guest_os);

    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));

    // Take the lock only to check capacity and read prefs. `ensurePrimaryDisk`
    // (below) forks `qemu-img create`, a blocking call that must not run under
    // the lock (project rule: never hold a lock across I/O).
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (appstate.vm_count >= appstate.MAX_VMS) return "full";
        // Apply sensible defaults.
        cfg.autoprotect = appstate.prefs.autoprotect_enabled_default;
        cfg.autoprotect_interval_min = appstate.prefs.autoprotect_interval_min_default;
        cfg.autoprotect_max = appstate.prefs.autoprotect_max_default;
    }

    // Create the primary disk image with the lock released.
    const disk_created = ensurePrimaryDisk(&cfg);

    // Re-acquire the lock to assign ports and commit. RE-CHECK capacity: the
    // array may have filled while we were creating the disk unlocked.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (appstate.vm_count >= appstate.MAX_VMS) {
        if (disk_created) cleanupCreatedDisk(&cfg);
        return "full";
    }
    cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);

    appstate.vms[appstate.vm_count] = cfg;
    appstate.vm_count += 1;
    persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
        logSaveErr("", e);
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
    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
            appstate.g_vmm.createLinkedCloneFn(h, disk_path, src_disk, @intFromEnum(src_fmt), std.heap.page_allocator) catch |e| {
                logOpErr("clone (linked)", e, clone.getNameSlice());
                return "linkerr";
            };
        } else {
            qemu.createLinkedClone(disk_path, src_disk, src_fmt, std.heap.page_allocator) catch |e| {
                logOpErr("clone (linked)", e, clone.getNameSlice());
                return "linkerr";
            };
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
        logSaveErr("", e);
        return "save failed";
    };
    logAudit("clone", clone.getNameSlice());
    return "ok";
}

/// Remove a VM's name-derived runtime/temp artifacts. Without this they leak in
/// /tmp and — worse — a later VM created with the same name would silently reuse
/// the stale cloud-init seed or Secure Boot NVRAM. Caller must ensure the VM is
/// stopped (sockets in use otherwise). Best-effort; missing files are ignored.
fn cleanupVmTempFiles(name: []const u8) void {
    if (name.len == 0 or name.len > vm.MAX_NAME) return;
    var pbuf: [600]u8 = undefined;
    const transient = [_][]const u8{
        "/tmp/hangar-ci-{s}.iso",
        "/tmp/hangar-ci-ud-{s}",
        "/tmp/hangar-ci-md-{s}",
        "/tmp/hangar-serial-{s}.sock",
        "/tmp/hangar-ga-{s}.sock",
        "/tmp/hangar-qmp-{s}.sock",
        "/var/tmp/hangar-vm-{s}.log",
    };
    inline for (transient) |fmt| {
        if (std.fmt.bufPrintZ(&pbuf, fmt, .{name})) |p| {
            _ = c.unlink(p);
        } else |_| {}
    }
    // Persistent Secure Boot NVRAM (under the config dir).
    var nv_buf: [512]u8 = undefined;
    if (qemu.secbootVarsPath(name, &nv_buf)) |nv| {
        _ = c.unlink(nv);
    }
}

fn handleDelete(req: []const u8) ![]const u8 {
    // Snapshot what the post-unlock teardown needs: a copy of the VM (carries the
    // pid for kill/reap) and its name (for temp-file cleanup). The blocking reap
    // (waitpid) + unlink syscalls must NOT run under vms_mutex — a QEMU stuck in
    // uninterruptible sleep would otherwise pin the lock and freeze the daemon.
    var dead_copy: vm.VmConfig = undefined;
    var was_alive = false;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();

        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        logAudit("delete", appstate.vms[idx].getNameSlice());
        // Save undo state before deleting.
        appstate.undo_vm = appstate.vms[idx];
        appstate.undo_idx = idx;
        appstate.undo_available = true;
        dead_copy = appstate.vms[idx];
        was_alive = appstate.vms[idx].isAlive();
        const nm = appstate.vms[idx].getNameSlice();
        name_len = @min(nm.len, name_buf.len);
        @memcpy(name_buf[0..name_len], nm[0..name_len]);

        // destroyVmmHandle disconnects QMP / frees the dispatch handle; it does
        // NOT kill the process — we SIGKILL the captured copy after unlocking.
        appstate.destroyVmmHandle(idx);
        // Shift remaining.
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
            logSaveErr("", e);
            return "save failed";
        };
    }

    // Lock released. Kill + reap the now-removed VM (SIGKILL so the qcow2 write
    // lock releases promptly) and remove its leftover temp/runtime artifacts
    // (cloud-init seed, NVRAM, sockets, log) so they don't leak or get reused by
    // a future same-named VM.
    if (was_alive) {
        qemu.forceStopVm(&dead_copy);
        qemu.reapVm(&dead_copy);
    }
    cleanupVmTempFiles(name_buf[0..name_len]);
    return "ok";
}

fn handleUndo() ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();

    if (!appstate.undo_available) return "no undo";
    if (appstate.vm_count >= appstate.MAX_VMS) return "full";

    // undo_idx was captured at delete time; VMs deleted since then may have
    // shrunk vm_count below it. Clamp to the current end so the restore inserts
    // at a valid position — otherwise the shift loop is skipped and the write
    // would land past the live range, promoting a stale slot and dropping the
    // restored VM (then persisting the corruption).
    if (appstate.undo_idx > appstate.vm_count) appstate.undo_idx = appstate.vm_count;

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
        logSaveErr("", e);
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

    const prefix = "POST /api/vms/reorder";
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

    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
    if (idx >= appstate.vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const v = &appstate.vms[idx];
    var val_buf: [vm.MAX_CLOUD_INIT * 3]u8 = undefined; // fits URL-encoded cloud-init user-data
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
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = vm.clampOptionalDiskSize(std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb);
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
        if (std.mem.eql(u8, key, "tags")) v.setTags(val);
        if (std.mem.eql(u8, key, "cloud_init")) v.setCloudInit(val);
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
        if (std.mem.eql(u8, key, "extra0_size")) v.extra_disks[0].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra0_format")) v.extra_disks[0].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[0].format.toIndex());
        if (std.mem.eql(u8, key, "extra1_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(1, val);
        }
        if (std.mem.eql(u8, key, "extra1_size")) v.extra_disks[1].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra1_format")) v.extra_disks[1].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[1].format.toIndex());
        if (std.mem.eql(u8, key, "extra2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(2, val);
        }
        if (std.mem.eql(u8, key, "extra2_size")) v.extra_disks[2].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra2_format")) v.extra_disks[2].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[2].format.toIndex());
        if (std.mem.eql(u8, key, "extra3_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setExtraDiskPath(3, val);
        }
        if (std.mem.eql(u8, key, "extra3_size")) v.extra_disks[3].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
        if (std.mem.eql(u8, key, "extra3_format")) v.extra_disks[3].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[3].format.toIndex());
    }
    // Settings edits change disk paths, NIC modes, and display ports — data
    // modifications an operator must be able to reconstruct after the fact. Every
    // other destructive handler audits; this one persisted silently.
    logAudit("settings save", v.getNameSlice());
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
/// E.g. `parseVmIdxSuffix(req, "GET /api/vms/", "/disk2/download")` for URL
/// `GET /api/vms/0/disk2/download`. Returns null on mismatch — safer than
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

/// Parse a VM index from a BARE item path with no trailing `/segment`.
/// E.g. `parseVmIdxExact(req, "GET /api/vms/")` matches `GET /api/vms/12 HTTP/1.1`
/// (and `?query`) but returns null for `GET /api/vms/12/log` — that has an action
/// suffix and must be routed by `parseVmIdxSuffix`. Returns the index only when
/// the character following the digits is a space, `?`, or end of input.
fn parseVmIdxExact(req: []const u8, prefix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    var end: usize = rest.len;
    for ([_]u8{ ' ', '/', '?' }) |term| {
        if (std.mem.indexOfScalar(u8, rest, term)) |i| {
            if (i < end) end = i;
        }
    }
    if (end == 0) return null;
    // The char that terminated the digits must NOT be '/': a trailing segment
    // means this is an action route, not a bare item path.
    if (end < rest.len and rest[end] == '/') return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn handleSuspend(req: []const u8) ![]const u8 {
    // Lock only long enough to validate idx, copy the VM name, and check liveness.
    // The QMP migration I/O below can take many seconds — we must not hold the
    // mutex across it or every other API call blocks.
    appstate.vms_mutex.lock();
    const idx = parseIdx(req, "POST /api/vms/") orelse {
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

/// Capture a VM's name under the lock for a name-keyed action whose I/O runs
/// unlocked. Validates idx and (optionally) a state predicate. Returns the name
/// length in `out` (0 and an error-token via the `*?[]const u8` on failure).
/// Caller must NOT hold vms_mutex.
fn captureVmName(req: []const u8, out: *[vm.MAX_NAME]u8, require: enum { any, alive, paused }, err: *[]const u8) ?usize {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/vms/") orelse {
        err.* = "invalid";
        return null;
    };
    if (idx >= appstate.vm_count) {
        err.* = "invalid idx";
        return null;
    }
    const v = &appstate.vms[idx];
    switch (require) {
        .any => {},
        .alive => if (!v.isAlive()) {
            err.* = "not running";
            return null;
        },
        .paused => if (!v.isPaused()) {
            err.* = "not paused";
            return null;
        },
    }
    const nm = v.getNameSlice();
    const nl = @min(nm.len, out.len);
    @memcpy(out[0..nl], nm[0..nl]);
    return nl;
}

/// Run a QMP method on the VM named `name` over a fresh connection, with the
/// caller NOT holding vms_mutex (keeps QMP socket I/O off the lock — the
/// lifecycle handlers previously held vms_mutex across the QMP call). Centralizes
/// the connect/disconnect boilerplate that was duplicated across ~16 handlers.
fn vmQmpByName(name: []const u8, comptime op: fn (*qmp.QmpClient) anyerror!void) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(name, &sock_buf) orelse return error.SockPath;
    try client.connect(sock);
    defer client.disconnect();
    try op(&client);
}

fn handlePause(req: []const u8) ![]const u8 {
    var nb: [vm.MAX_NAME]u8 = undefined;
    var err: []const u8 = "";
    const nl = captureVmName(req, &nb, .alive, &err) orelse return err;
    vmQmpByName(nb[0..nl], qmp.QmpClient.pause) catch |e| {
        logOpErr("pause", e, nb[0..nl]);
        return "qmp err";
    };
    logAudit("pause", nb[0..nl]);
    return "ok";
}

fn handleResume(req: []const u8) ![]const u8 {
    var nb: [vm.MAX_NAME]u8 = undefined;
    var err: []const u8 = "";
    const nl = captureVmName(req, &nb, .paused, &err) orelse return err;
    vmQmpByName(nb[0..nl], qmp.QmpClient.cont) catch |e| {
        logOpErr("resume", e, nb[0..nl]);
        return "qmp err";
    };
    logAudit("resume", nb[0..nl]);
    return "ok";
}

fn handleRename(req: []const u8) ![]const u8 {
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
            // Drop the old name's temp artifacts so they don't leak / get reused by
            // a future same-named VM. Only when stopped — a running VM's sockets are
            // still in use under the old name.
            if (!appstate.vms[idx].isAlive()) {
                var on_buf: [vm.MAX_NAME]u8 = undefined;
                const on = appstate.vms[idx].getNameSlice();
                if (on.len <= on_buf.len and !std.mem.eql(u8, on, val)) {
                    @memcpy(on_buf[0..on.len], on);
                    cleanupVmTempFiles(on_buf[0..on.len]);
                }
            }
            appstate.vms[idx].setName(val);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("", e);
                return "save failed";
            };
            logAudit("rename", val);
            return "ok";
        }
    }
    return "no name";
}

fn handleShutdown(req: []const u8) ![]const u8 {
    var nb: [vm.MAX_NAME]u8 = undefined;
    var err: []const u8 = "";
    const nl = captureVmName(req, &nb, .alive, &err) orelse return err;
    vmQmpByName(nb[0..nl], qmp.QmpClient.powerdown) catch |e| {
        logOpErr("shut down guest", e, nb[0..nl]);
        return "qmp err";
    };
    logAudit("shut down guest", nb[0..nl]);
    return "ok";
}

fn handleReset(req: []const u8) ![]const u8 {
    var nb: [vm.MAX_NAME]u8 = undefined;
    var err: []const u8 = "";
    const nl = captureVmName(req, &nb, .alive, &err) orelse return err;
    vmQmpByName(nb[0..nl], qmp.QmpClient.systemReset) catch |e| {
        logOpErr("reset", e, nb[0..nl]);
        return "qmp err";
    };
    logAudit("reset", nb[0..nl]);
    return "ok";
}

/// Whether a VM should be powered on at daemon startup. Pure so the selection is
/// unit-testable independent of the QEMU spawn.
fn shouldAutostart(v: *const vm.VmConfig) bool {
    return v.host_autostart and v.hasDisk();
}

/// Reject a CD/ISO path that could inject `-drive` options (comma) or HMP/control
/// bytes. Empty is allowed by callers that mean "eject".
fn isSafeCdPath(p: []const u8) bool {
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    for (p) |ch| {
        if (ch == ',' or ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Change the mounted CD/ISO. A running VM swaps media live via QMP; a stopped VM
/// just records the new iso_path (mounted on next boot). Empty path on a running
/// VM is handled by handleCdromEject instead.
fn handleCdromChange(req: []const u8) ![]const u8 {
    var decode_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var was_alive = false;
    var decoded: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
        const body = req[body_start + 4 ..];
        var path: []const u8 = "";
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const val = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "path")) path = val;
        }
        if (path.len == 0) return "no path";
        decoded = urlencode.urlDecode(&decode_buf, path);
        if (decoded.len == 0 or !isSafeCdPath(decoded)) return "bad path";
        was_alive = v.isAlive();
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "change err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
        if (was_alive and !qmp.isPathSafeName(nm)) return "change err";
    }

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "change err";
        client.connect(sock) catch |e| {
            logOpErr("cdrom change", e, name_buf[0..name_len]);
            return "change err";
        };
        defer client.disconnect();
        client.changeCdrom(decoded) catch |e| {
            logOpErr("cdrom change", e, name_buf[0..name_len]);
            return "change err";
        };
    } else {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx_saved].setIsoPath(decoded);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("handleCdromChange: ", e);
                return "save failed";
            };
        }
    }
    logAudit("cdrom change", name_buf[0..name_len]);
    return "ok";
}

/// Eject the mounted CD/ISO. Running VM ejects live via QMP; stopped VM clears
/// its iso_path.
fn handleCdromEject(req: []const u8) ![]const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var was_alive = false;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        was_alive = v.isAlive();
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "eject err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
        if (was_alive and !qmp.isPathSafeName(nm)) return "eject err";
    }

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "eject err";
        client.connect(sock) catch |e| {
            logOpErr("cdrom eject", e, name_buf[0..name_len]);
            return "eject err";
        };
        defer client.disconnect();
        client.ejectCdrom() catch |e| {
            logOpErr("cdrom eject", e, name_buf[0..name_len]);
            return "eject err";
        };
    } else {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx_saved].clearIsoPath();
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("handleCdromEject: ", e);
                return "save failed";
            };
        }
    }
    logAudit("cdrom eject", name_buf[0..name_len]);
    return "ok";
}

/// Extract non-loopback IPv4 addresses from a qemu-guest-agent
/// `guest-network-get-interfaces` reply into `out` as a comma-separated list.
/// Pure (no I/O) so it is unit-testable against a captured GA response.
fn parseGuestIpv4s(json: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var cur = json;
    const key = "\"ip-address\":\"";
    while (std.mem.indexOf(u8, cur, key)) |at| {
        const after = cur[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const addr = after[0..end];
        cur = after[end..];
        // IPv4 only (has '.', no ':'); skip loopback.
        if (std.mem.indexOfScalar(u8, addr, ':') != null) continue;
        if (std.mem.indexOfScalar(u8, addr, '.') == null) continue;
        if (std.mem.startsWith(u8, addr, "127.")) continue;
        if (w != 0) {
            if (w >= out.len) break;
            out[w] = ',';
            w += 1;
        }
        if (w + addr.len > out.len) break;
        @memcpy(out[w .. w + addr.len], addr);
        w += addr.len;
    }
    return out[0..w];
}

/// Query the guest's IPv4 addresses via the qemu-guest-agent socket and return
/// them as `{"ips":"a,b"}`. Empty when the VM is stopped, the agent isn't
/// running, or it doesn't answer within the timeout (best-effort, never hangs).
fn handleGuestInfo(req: []const u8, out: []u8) []const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"ips\":\"\"}";
        if (idx >= appstate.vm_count) return "{\"ips\":\"\"}";
        const v = &appstate.vms[idx];
        if (!v.isAlive() or !v.guest_agent) return "{\"ips\":\"\"}";
        const nm = v.getNameSlice();
        if (nm.len == 0 or nm.len > name_buf.len) return "{\"ips\":\"\"}";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var sock_buf: [128]u8 = undefined;
    const sock = std.fmt.bufPrint(&sock_buf, "/tmp/hangar-ga-{s}.sock", .{name_buf[0..name_len]}) catch return "{\"ips\":\"\"}";
    const stream = usock.UnixStream.connect(sock) catch return "{\"ips\":\"\"}";
    defer stream.close();
    // Bound the read so a missing/unresponsive agent can't pin the thread.
    const tv: c.timeval = .{ .sec = 2, .usec = 0 };
    _ = c.setsockopt(stream.fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = stream.write("{\"execute\":\"guest-network-get-interfaces\"}\n") catch return "{\"ips\":\"\"}";
    // The reply (newline-terminated QGA JSON) can span multiple reads on a
    // multi-NIC guest; a single read() would truncate it and silently drop
    // addresses. Accumulate until the terminating newline, buffer full, or the
    // 2s read timeout fires.
    var resp: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len) {
        const n = stream.read(resp[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, resp[0..total], '\n') != null) break;
    }
    if (total == 0) return "{\"ips\":\"\"}";
    var ip_buf: [512]u8 = undefined;
    const ips = parseGuestIpv4s(resp[0..total], &ip_buf);
    return std.fmt.bufPrint(out, "{{\"ips\":\"{s}\"}}", .{ips}) catch "{\"ips\":\"\"}";
}

/// Report a VM's primary-disk virtual + actual (on-disk allocated) byte sizes
/// via `qemu-img info`. Captures the disk path under the lock, runs qemu-img with
/// it released. Returns a JSON object into `out`.
fn handleDiskInfo(req: []const u8, out: []u8) []const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"error\":\"invalid\"}";
        if (idx >= appstate.vm_count) return "{\"error\":\"invalid idx\"}";
        const dp = appstate.vms[idx].getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "{\"error\":\"no disk\"}";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
    }
    const info = qemu.diskInfo(disk_buf[0..disk_len], std.heap.page_allocator) orelse return "{\"error\":\"unavailable\"}";
    return std.fmt.bufPrint(out, "{{\"virtual_bytes\":{d},\"actual_bytes\":{d}}}", .{ info.virtual_bytes, info.actual_bytes }) catch "{\"error\":\"render\"}";
}

/// Capture the running guest's display and stream it back as PNG (QMP
/// screendump). Only meaningful for a running VM; a stopped VM gets 409.
fn handleScreenshot(conn: c.fd_t, req: []const u8) void {
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

/// Grow a VM's primary disk image (qemu-img resize). Stopped VMs only (resizing
/// a live qcow2 risks corruption), grow-only (shrinking a qcow2 truncates guest
/// data). Validates + copies the disk path under the lock, runs qemu-img with the
/// lock released, then records the new size.
fn handleResizeDisk(req: []const u8) ![]const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var new_gb: u32 = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        if (v.isAlive()) return "vm running";
        const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
        const body = req[body_start + 4 ..];
        var size_str: []const u8 = "";
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const val = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "size")) size_str = val;
        }
        const parsed = std.fmt.parseInt(u32, size_str, 10) catch return "bad size";
        new_gb = vm.clampDiskSize(parsed);
        if (new_gb <= v.disk_size_gb) return "shrink not allowed"; // grow only
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "resize err";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
        const nm = v.getNameSlice();
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
    }

    qemu.resizeDiskImage(disk_buf[0..disk_len], new_gb, std.heap.page_allocator) catch |e| {
        logOpErr("disk resize", e, name_buf[0..name_len]);
        return "resize err";
    };

    // Record the new size, re-validating the VM didn't move/disappear while
    // unlocked. If it did, the image is already grown — report success.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
        appstate.vms[idx_saved].disk_size_gb = new_gb;
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
            logSaveErr("handleResizeDisk: ", e);
            return "save failed";
        };
    }
    logAudit("disk resize", name_buf[0..name_len]);
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
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var was_alive = false;
    var decoded: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
            if (std.mem.eql(u8, key, "tag")) tag = val;
        }
        if (tag.len == 0) return "no name";
        decoded = urlencode.urlDecode(&decode_buf, tag);
        if (!validateSnapshotTag(decoded)) return "no name";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "create err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        was_alive = v.isAlive();
        if (was_alive) {
            // Live VM: snapshot through its running QMP monitor (savevm) — the
            // qcow2 is write-locked, so offline qemu-img would fail. Name must be
            // QMP-socket-safe.
            if (!qmp.isPathSafeName(nm)) return "create err";
        } else {
            const dp = v.getDiskPathSlice();
            if (dp.len == 0 or dp.len >= disk_buf.len) return "create err";
            @memcpy(disk_buf[0..dp.len], dp);
            disk_len = dp.len;
        }
    }

    // I/O with the lock released — it can take seconds and must not stall every
    // other handler / the poll thread.
    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "create err";
        client.connect(sock) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
        defer client.disconnect();
        client.saveSnapshot(decoded) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
    } else {
        qemu.snapshotCreate(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
    }
    logAudit("snapshot take", name_buf[0..name_len]);
    return "ok";
}

fn handleSnapshotList(req: []const u8, raw_buf: []u8) []const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var n: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
        // Capture the disk path and run qemu-img with the lock RELEASED for both
        // running and stopped VMs — qemu-img is a blocking subprocess and must
        // never run under vms_mutex (it would freeze every handler + the tickers).
        // `-U` (in qemu.snapshotList) lets it read a running VM's locked image.
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "no disk";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
    }

    // Offline qemu-img list with the lock released (it reads the image header).
    if (disk_len > 0) {
        n = qemu.snapshotList(disk_buf[0..disk_len], raw_buf, std.heap.page_allocator) catch |e| blk: {
            logOpErr("snapshot list", e, name_buf[0..name_len]);
            break :blk 0;
        };
    }
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
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var decoded: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
            if (std.mem.eql(u8, key, "tag")) tag = val;
        }
        if (tag.len == 0) return "no name";
        decoded = urlencode.urlDecode(&decode_buf, tag);
        if (!validateSnapshotTag(decoded)) return "no name";
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
        // The VM is guaranteed stopped (guarded above), so revert is always the
        // offline qemu-img path. Capture the disk path and run it with the lock
        // RELEASED — qemu-img is a blocking subprocess and must not run under
        // vms_mutex (it would freeze the daemon). (The previous getVmmHandle
        // branch ran qemu-img under the lock, since the handle is lazily created
        // even for a stopped VM.)
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "apply err";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
    }

    qemu.snapshotApply(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
        logOpErr("snapshot revert", e, name_buf[0..name_len]);
        return "apply err";
    };
    logAudit("snapshot revert", name_buf[0..name_len]);
    return "ok";
}

fn handleSnapshotDelete(req: []const u8) ![]const u8 {
    var decode_buf: [MAX_SNAPSHOT_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var was_alive = false;
    var decoded: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
            if (std.mem.eql(u8, key, "tag")) tag = val;
        }
        if (tag.len == 0) return "no name";
        decoded = urlencode.urlDecode(&decode_buf, tag);
        if (!validateSnapshotTag(decoded)) return "no name";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "delete err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        was_alive = v.isAlive();
        if (was_alive) {
            // Live VM: delete via QMP delvm (qcow2 is write-locked).
            if (!qmp.isPathSafeName(nm)) return "delete err";
        } else {
            const dp = v.getDiskPathSlice();
            if (dp.len == 0 or dp.len >= disk_buf.len) return "delete err";
            @memcpy(disk_buf[0..dp.len], dp);
            disk_len = dp.len;
        }
    }

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "delete err";
        client.connect(sock) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
        defer client.disconnect();
        client.deleteSnapshot(decoded) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
    } else {
        qemu.snapshotDelete(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
    }
    logAudit("snapshot delete", name_buf[0..name_len]);
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
        logSaveErr("", e);
        return "save failed";
    };
    logAudit("import", cfg.getNameSlice());
    return "ok";
}

fn handleCad(req: []const u8) ![]const u8 {
    var nb: [vm.MAX_NAME]u8 = undefined;
    var err: []const u8 = "";
    const nl = captureVmName(req, &nb, .alive, &err) orelse return err;
    vmQmpByName(nb[0..nl], qmp.QmpClient.sendCtrlAltDel) catch |e| {
        logOpErr("ctrl-alt-del", e, nb[0..nl]);
        return "cad err";
    };
    logAudit("ctrl-alt-del", nb[0..nl]);
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
    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
    const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"status\":\"error\",\"error\":\"invalid idx\"}";
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
    const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
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
    // Snapshot the disk path + name under the lock, then release it before any
    // filesystem I/O. Streaming a multi-GB disk image while holding vms_mutex
    // would freeze every other handler and the liveness/autoprotect tickers for
    // the whole transfer (project rule: never hold a lock across I/O).
    var path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        // Reply with a real HTTP status on every failure path. A bare `return`
        // here closes the socket with no response, so the client sees an empty
        // reply it cannot tell apart from a network drop instead of a 400/404.
        const idx = parseIdx(req, "GET /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad index\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no vm\"}");
            return;
        }
        const v = &appstate.vms[idx];
        if (!v.hasDisk2()) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no disk2\"}");
            return;
        }
        const dp = std.mem.span(v.getDisk2Path());
        if (dp.len == 0 or dp.len >= path_buf.len) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk2 path\"}");
            return;
        }
        @memcpy(path_buf[0..dp.len], dp);
        path_buf[dp.len] = 0;
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
    }

    const disk2_path: [*:0]const u8 = @ptrCast(&path_buf);
    const fd = c.open(disk2_path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) {
        // The disk2 file is recorded on the VM but cannot be opened (deleted out
        // from under us, permissions, bad path). Without this line a failed
        // download is a silent dead end — the client gets nothing and nothing
        // explains why.
        var nb: [vm.MAX_NAME]u8 = undefined;
        var eb: [256]u8 = undefined;
        logErr(std.fmt.bufPrint(&eb, "disk2 download: open failed vm=\"{s}\"", .{sanitizeLogName(&nb, name_buf[0..name_len])}) catch "disk2 download: open failed");
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"disk2 open failed\"}");
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
    logAudit("disk2 download", name_buf[0..name_len]);
}

/// Reply to an upload with the unified JSON error mapping (client mistakes 400,
/// server faults 500) and close.
fn uploadErr(conn: c.fd_t, token: []const u8) void {
    const s: u16 = if (std.mem.eql(u8, token, "upload err") or std.mem.eql(u8, token, "write err") or std.mem.eql(u8, token, "save failed") or isServerErrToken(token))
        HTTP_INTERNAL_ERROR
    else
        HTTP_BAD_REQUEST;
    var jb: [256]u8 = undefined;
    writeHttpResponse(conn, s, "application/json; charset=utf-8", jsonErr(&jb, token));
}

/// Extract the filename from a multipart part's Content-Disposition headers.
/// Handles quoted (`filename="x"`) and unquoted (`filename=x`) forms. Returns ""
/// when absent. The returned slice points into `part_headers`.
fn parseUploadFilename(part_headers: []const u8) []const u8 {
    if (std.mem.indexOf(u8, part_headers, "filename=\"")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=\"".len ..];
        if (std.mem.indexOfScalar(u8, fn_val, '"')) |fn_end| {
            if (fn_end > 0) return fn_val[0..fn_end];
        }
    } else if (std.mem.indexOf(u8, part_headers, "filename=")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=".len ..];
        var fn_end: usize = fn_val.len;
        if (std.mem.indexOfScalar(u8, fn_val, ';')) |semi| fn_end = semi;
        if (std.mem.indexOfScalar(u8, fn_val, '\r')) |cr| {
            if (cr < fn_end) fn_end = cr;
        }
        if (std.mem.indexOfScalar(u8, fn_val, '\n')) |nl| {
            if (nl < fn_end) fn_end = nl;
        }
        if (fn_end > 0) return std.mem.trimEnd(u8, fn_val[0..fn_end], " \t");
    }
    return "";
}

/// Accept a multipart/form-data disk2 upload, STREAMING the file body straight
/// to disk. `initial` is the first read of the request (HTTP headers + multipart
/// part headers + the start of the file bytes — all small enough to be in the
/// first 64 KB); the remaining file bytes are read directly from `conn`, so the
/// upload is not capped at the request-buffer size. Writes its own response.
fn handleUploadDiskStreaming(conn: c.fd_t, initial: []const u8) void {
    const idx = parseIdx(initial, "POST /api/vms/") orelse return uploadErr(conn, "invalid");
    const content_length = parseContentLength(initial) orelse return uploadErr(conn, "no content-length");
    const hdr_end = std.mem.indexOf(u8, initial, "\r\n\r\n") orelse return uploadErr(conn, "no body");
    const headers = initial[0..hdr_end];
    const ct_val = findHeader(headers, "content-type: ") orelse return uploadErr(conn, "no boundary");
    const ct_prefix = "multipart/form-data; boundary=";
    if (ct_val.len < ct_prefix.len or !std.ascii.eqlIgnoreCase(ct_val[0..ct_prefix.len], ct_prefix)) return uploadErr(conn, "no boundary");
    const boundary = ct_val[ct_prefix.len..];
    if (boundary.len == 0 or boundary.len > 200) return uploadErr(conn, "no boundary");

    // Honor Expect: 100-continue. curl/libcurl withhold a large body until the
    // server sends "100 Continue"; without this the body never arrives in the
    // first read and the parse below fails. (Browsers' fetch doesn't use Expect.)
    if (findHeader(headers, "expect: ")) |exv| {
        if (std.ascii.indexOfIgnoreCase(exv, "100-continue") != null) {
            const cont = "HTTP/1.1 100 Continue\r\n\r\n";
            _ = writeAll(conn, cont, cont.len);
        }
    }

    const body_off = hdr_end + 4;
    var bd_buf: [256]u8 = undefined;
    const full_bd = std.fmt.bufPrint(&bd_buf, "--{s}", .{boundary}) catch return uploadErr(conn, "bd err");

    // Accumulate the multipart prefix (opening boundary + part headers + start of
    // the file bytes) into pbuf, reading from the socket as needed — it may not
    // all be in `initial` (e.g. after a 100-continue, the body arrives only now).
    var pbuf: [65536 + 256]u8 = undefined;
    var plen: usize = 0;
    var body_seen: usize = 0; // multipart-body bytes consumed so far
    {
        const seed = initial[body_off..];
        const sn = @min(seed.len, pbuf.len);
        @memcpy(pbuf[0..sn], seed[0..sn]);
        plen = sn;
        body_seen = sn;
    }
    var data_pos: usize = 0; // offset in pbuf where the file bytes begin
    var filename: []const u8 = "";
    while (true) {
        const pb = pbuf[0..plen];
        if (std.mem.indexOf(u8, pb, full_bd)) |fb| {
            var p = fb + full_bd.len;
            if (p < pb.len and pb[p] == '\r') p += 1;
            if (p < pb.len and pb[p] == '\n') p += 1;
            if (std.mem.indexOf(u8, pb[p..], "\r\n\r\n")) |phe| {
                data_pos = p + phe + 4;
                filename = parseUploadFilename(pb[p..][0..phe]);
                break;
            } else if (std.mem.indexOf(u8, pb[p..], "\n\n")) |phe2| {
                data_pos = p + phe2 + 2;
                filename = parseUploadFilename(pb[p..][0..phe2]);
                break;
            }
        }
        if (plen >= pbuf.len or body_seen >= content_length) return uploadErr(conn, "no headers end");
        const want = @min(pbuf.len - plen, content_length - body_seen);
        const n = c.read(conn, pbuf[plen..].ptr, want);
        if (n <= 0) return uploadErr(conn, "upload err");
        plen += @intCast(n);
        body_seen += @intCast(n);
    }

    // Reject path traversal + QEMU -drive comma/control injection (CWE-88).
    if (filename.len == 0) return uploadErr(conn, "no filename");
    for (filename) |ch| {
        if (ch == '/' or ch == '\\' or ch == ',' or ch < 0x20) return uploadErr(conn, "bad filename");
    }
    if (std.mem.indexOf(u8, filename, "..") != null) return uploadErr(conn, "bad filename");

    // Compute dest path under the lock (same as the old buffered handler), copy
    // it + the VM name out, then release the lock before the streamed write.
    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    var dest: []const u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx >= appstate.vm_count) return uploadErr(conn, "invalid idx");
        const v = &appstate.vms[idx];
        const primary = v.getDiskPathSlice();
        if (primary.len == 0) return uploadErr(conn, "no primary disk");
        const ext = std.fs.path.extension(primary);
        const dir = std.fs.path.dirname(primary) orelse ".";
        const basename = std.fs.path.basename(primary);
        dest = (if (filename.len > 0)
            std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, filename })
        else if (ext.len > 0 and ext.len < 16)
            std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, basename[0 .. basename.len - ext.len], ext })
        else
            std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, basename })) catch return uploadErr(conn, "path err");
        if (std.mem.eql(u8, dest, primary)) return uploadErr(conn, "name collides with primary disk");
        const nm = v.getNameSlice();
        name_len = @min(nm.len, name_buf.len);
        @memcpy(name_buf[0..name_len], nm[0..name_len]);
    }

    // Open the destination, then stream the file body to it with the lock
    // released (it can be many GB).
    var dest_z: [vm.MAX_PATH + 1]u8 = undefined;
    if (dest.len >= dest_z.len) return uploadErr(conn, "path err");
    @memcpy(dest_z[0..dest.len], dest);
    dest_z[dest.len] = 0;
    const out_fd = std.c.open(@ptrCast(&dest_z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (out_fd < 0) {
        logOpErr("disk upload", error.AccessDenied, name_buf[0..name_len]);
        return uploadErr(conn, "write err");
    }

    // Hold-back delimiter stream: write file bytes but never the closing boundary
    // (`\r\n--<boundary>`), which may straddle two reads — retain the last
    // (marker-1) bytes until the next read confirms they aren't the boundary.
    var marker_buf: [256]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\r\n--{s}", .{boundary}) catch {
        _ = std.c.close(out_fd);
        return uploadErr(conn, "bd err");
    };
    const keep = marker.len - 1;
    var work: [65536 + 256]u8 = undefined;
    var hold: [256]u8 = undefined;
    var hold_len: usize = 0;
    var first = true;
    var done = false;

    while (true) {
        @memcpy(work[0..hold_len], hold[0..hold_len]);
        var total = hold_len;
        if (first) {
            // The file bytes already accumulated in pbuf (after the part headers).
            const chunk = pbuf[data_pos..plen];
            @memcpy(work[hold_len..][0..chunk.len], chunk);
            total += chunk.len;
            first = false;
        } else {
            if (body_seen >= content_length) break; // body exhausted, no closing boundary
            const want = @min(work.len - hold_len, content_length - body_seen);
            const n = c.read(conn, work[hold_len..].ptr, want);
            if (n <= 0) break;
            total += @intCast(n);
            body_seen += @intCast(n);
        }
        if (std.mem.indexOf(u8, work[0..total], marker)) |mi| {
            if (!writeAll(out_fd, &work, mi)) {
                _ = std.c.close(out_fd);
                _ = c.unlink(@ptrCast(&dest_z));
                return uploadErr(conn, "write err");
            }
            done = true;
            break;
        }
        if (total > keep) {
            if (!writeAll(out_fd, &work, total - keep)) {
                _ = std.c.close(out_fd);
                _ = c.unlink(@ptrCast(&dest_z));
                return uploadErr(conn, "write err");
            }
            hold_len = keep;
            @memcpy(hold[0..keep], work[total - keep .. total]);
        } else {
            hold_len = total;
            @memcpy(hold[0..total], work[0..total]);
        }
    }
    _ = std.c.close(out_fd);
    if (!done) {
        // Never saw the closing boundary — truncated/malformed upload.
        _ = c.unlink(@ptrCast(&dest_z));
        return uploadErr(conn, "upload err");
    }

    // Record the new disk2 path, re-validating the VM under the lock.
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx].setDisk2Path(dest);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("handleUploadDiskStreaming: ", e);
                return uploadErr(conn, "save failed");
            };
        }
    }
    logAudit("disk upload", name_buf[0..name_len]);
    writeHttpResponse(conn, HTTP_OK, "text/plain", "ok");
}

/// Byte size of a file, or 0 if it can't be stat'd. Used to fill the OVF
/// descriptor's `ovf:size` from the converted VMDKs (strict importers/ovftool
/// validate it against the actual file in the OVA).
fn fileByteSize(path: []const u8) u64 {
    var pbuf: [vm.MAX_PATH + 1]u8 = undefined;
    if (path.len >= pbuf.len) return 0;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, 2); // SEEK_END
    if (end < 0) return 0;
    return @intCast(end);
}

/// Create OVF+VMDK export, tar+gzip it, and stream the result as a download.
fn handleExport(conn: c.fd_t, req: []const u8) !void {
    // Snapshot everything the conversion/tar/stream below needs under the lock,
    // then release it before any qemu-img/tar/filesystem I/O. A multi-GB export
    // runs for minutes; holding vms_mutex across it would freeze every other
    // handler and the liveness/autoprotect tickers for the whole transfer
    // (project rule: never hold a lock across I/O).
    var disk1_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk1_path_len: usize = 0;
    var disk2_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk2_path_len: usize = 0;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var export_name_buf: [vm.MAX_NAME]u8 = undefined;
    var export_name_len: usize = 0;
    var disk_format: vm.DiskFormat = undefined;
    var disk2_format: vm.DiskFormat = undefined;
    var disk_size_gb: u32 = 0;
    var disk2_size_gb: u32 = 0;
    var has_disk2: bool = false;
    var has_network: bool = false;
    var cpu_cores: u32 = 0;
    var memory_mb: u32 = 0;
    var idx: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        // Client-input failures get a real HTTP status; a bare `return` would close
        // the socket with no response (an empty reply indistinguishable from a drop).
        idx = parseIdx(req, "POST /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad index\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no vm\"}");
            return;
        }
        const v = &appstate.vms[idx];

        // The name field is optional, so a request without a body is valid and must
        // fall back to the VM's own name rather than silently abort.
        const body: []const u8 = if (std.mem.indexOf(u8, req, "\r\n\r\n")) |bs| req[bs + 4 ..] else "";
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
            if (!vm.isValidVmName(decoded) or std.mem.indexOf(u8, decoded, "..") != null) {
                writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid name\"}");
                return;
            }
            break :blk decoded;
        } else v.getNameSlice();
        if (export_name.len > export_name_buf.len) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid name\"}");
            return;
        }
        @memcpy(export_name_buf[0..export_name.len], export_name);
        export_name_len = export_name.len;

        // Capture disk paths into local buffers — `v` is dangling after unlock.
        const d1 = v.getDiskPathSlice();
        if (d1.len > disk1_path_buf.len - 1) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk path\"}");
            return;
        }
        @memcpy(disk1_path_buf[0..d1.len], d1);
        disk1_path_len = d1.len;

        has_disk2 = v.hasDisk2();
        if (has_disk2) {
            const d2 = v.getDisk2PathSlice();
            if (d2.len > disk2_path_buf.len - 1) {
                writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk2 path\"}");
                return;
            }
            @memcpy(disk2_path_buf[0..d2.len], d2);
            disk2_path_len = d2.len;
        }

        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }

        disk_format = v.disk_format;
        disk2_format = v.disk2_format;
        disk_size_gb = v.disk_size_gb;
        disk2_size_gb = v.disk2_size_gb;
        has_network = v.nics[0].mode != .none;
        cpu_cores = v.cpu_cores;
        memory_mb = v.memory_mb;
    }

    const disk1_path: []const u8 = disk1_path_buf[0..disk1_path_len];
    const disk2_path: []const u8 = disk2_path_buf[0..disk2_path_len];
    const export_name: []const u8 = export_name_buf[0..export_name_len];

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
        return error.ExportFailed;
    };
    var dir_cleanup: bool = true;
    defer if (dir_cleanup) {
        _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
            logErr("export: deleteTree cleanup failed");
        };
    };

    var tar_buf: [160]u8 = undefined;
    const tar_path = std.fmt.bufPrintZ(&tar_buf, "/tmp/ovf_export.{d}.{d}.{d}.tar.gz", .{ idx, std.c.getpid(), ts.nsec }) catch return;
    var tar_cleanup: bool = false;
    defer if (tar_cleanup) {
        _ = c.unlink(tar_path);
    };

    const vmdk_name = "disk1.vmdk";
    var path_buf: [vm.MAX_PATH]u8 = undefined;
    const vmdk_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, vmdk_name }) catch return;

    // Convert disk1 to VMDK. Offline qemu-img conversion (lock already released),
    // so call qemu directly — NOT through a VMM handle captured under the lock,
    // which a concurrent delete could have freed during this multi-second op
    // (latent use-after-free). The conversion needs no live handle state.
    qemu.convertDiskImage(disk1_path, disk_format, vmdk_path, .vmdk, std.heap.page_allocator) catch {
        logErr("export: disk1 conversion failed");
        return error.ExportFailed;
    };
    // Capture the converted size now — path_buf is reused for disk2 below.
    const vmdk1_size = fileByteSize(vmdk_path);

    // Convert disk2 if present
    var disk2_href: []const u8 = "";
    var disk2_cap: u64 = 0;
    var disk2_size: u64 = 0;
    if (has_disk2) {
        disk2_href = "disk2.vmdk";
        disk2_cap = @as(u64, disk2_size_gb) * 1024 * 1024 * 1024;
        const d2_path = std.fmt.bufPrint(&path_buf, "{s}/disk2.vmdk", .{dir_path}) catch return;
        qemu.convertDiskImage(disk2_path, disk2_format, d2_path, .vmdk, std.heap.page_allocator) catch {
            logErr("export: disk2 conversion failed");
            return error.ExportFailed;
        };
        disk2_size = fileByteSize(d2_path);
    }

    // Build OVF descriptor after all conversions
    const disk_cap = @as(u64, disk_size_gb) * 1024 * 1024 * 1024;
    const spec = ovf.Spec{
        .name = export_name,
        .cpu_cores = cpu_cores,
        .memory_mb = memory_mb,
        .disk_capacity_bytes = disk_cap,
        .vmdk_href = vmdk_name,
        .vmdk_size_bytes = vmdk1_size,
        .has_network = has_network,
        .disk2_href = disk2_href,
        .disk2_capacity_bytes = disk2_cap,
        .disk2_size_bytes = disk2_size,
    };
    var ovf_buf: [ovf.max_descriptor_len]u8 = undefined;
    const xml = ovf.buildDescriptor(spec, &ovf_buf) catch {
        logErr("export: OVF descriptor build failed");
        return error.ExportFailed;
    };

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, export_name });
    defer std.heap.page_allocator.free(ovf_path);
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = ovf_path, .data = xml }) catch {
        logErr("export: failed to write OVF file");
        return error.ExportFailed;
    };

    // Tar+gzip the export directory
    {
        const tar_argv = [_][]const u8{ "tar", "-czf", tar_path, "-C", dir_path, "." };
        qemu.runWait(&tar_argv, std.heap.page_allocator, null) catch {
            logErr("export: tar+gzip failed");
            return error.ExportFailed;
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
    logAudit("export", name_buf[0..name_len]);
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
    // Virtual-network topology change — record it so an operator can correlate a
    // VM losing connectivity with a networks.json rewrite.
    logAt(.info, "audit: vnets save");
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
            // urlDecode self-bounds its output to dir_buf.len (decoding only
            // shrinks), so always decode — the old length guard fell back to the
            // raw percent-encoded value and stored "%2F.." literally.
            const decoded = urlencode.urlDecode(&dir_buf, v);
            if (std.mem.indexOf(u8, decoded, "..") != null) return "bad path";
            const n = @min(decoded.len, vm.MAX_PATH);
            @memcpy(appstate.prefs.default_vm_dir_buf[0..n], decoded[0..n]);
            appstate.prefs.default_vm_dir_buf[n] = 0;
            appstate.prefs.default_vm_dir_len = @intCast(n);
        }
    }

    // Daemon-wide preference change (default VM dir, autoprotect defaults, ...).
    logAt(.info, "audit: config save");
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

        // Collect work items under the lock, release before I/O. AutoProtect
        // targets RUNNING VMs, whose qcow2 is write-locked by the live QEMU, so
        // offline `qemu-img snapshot` cannot touch it — snapshots must go through
        // the running monitor (QMP savevm/delvm). We capture the VM name (to
        // reach its QMP socket) rather than the disk path.
        const SnapWork = struct {
            vm_name: [vm.MAX_NAME]u8,
            vm_name_len: usize,
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

            // Need a QMP-socket-safe name; skip (without burning a seq) if unusable.
            const vname = v.getNameSlice();
            if (vname.len == 0 or vname.len > vm.MAX_NAME or !qmp.isPathSafeName(vname)) continue;

            const seq = v.autoprotect_last_seq;
            v.autoprotect_last_seq = seq +% 1; // wrapping add
            v.autoprotect_last_epoch = now;

            var name_buf: [40]u8 = undefined;
            const snap_name = autoprotect.snapName(&name_buf, seq);

            var nm_buf: [vm.MAX_NAME]u8 = undefined;
            @memcpy(nm_buf[0..vname.len], vname);

            work_items[work_count] = .{
                .vm_name = nm_buf,
                .vm_name_len = vname.len,
                .snap_name = name_buf,
                .snap_name_len = snap_name.len,
                .autoprotect_max = v.autoprotect_max,
            };
            work_count += 1;
        }
        appstate.vms_mutex.unlock();

        // Perform snapshot I/O outside the lock, through each VM's live QMP
        // monitor (savevm/info snapshots/delvm). qemu-img is unusable here: the
        // running QEMU holds a write lock on the qcow2.
        var wi: usize = 0;
        while (wi < work_count) : (wi += 1) {
            const w = &work_items[wi];
            const name = w.vm_name[0..w.vm_name_len];
            const sn = w.snap_name[0..w.snap_name_len];

            // VM name is config-controlled; sanitize before logging.
            var nlog: [vm.MAX_NAME]u8 = undefined;
            const name_safe = sanitizeLogName(&nlog, name);

            var client = qmp.QmpClient{};
            var sock_buf: [256]u8 = undefined;
            const sock = qmp.socketPath(name, &sock_buf) orelse continue;
            client.connect(sock) catch |e| {
                var ebuf: [320]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "autoprotect qmp connect failed: {s} vm=\"{s}\"", .{ @errorName(e), name_safe }) catch "autoprotect qmp connect failed");
                continue;
            };
            defer client.disconnect();

            client.saveSnapshot(sn) catch |e| {
                var ebuf: [320]u8 = undefined;
                logErr(std.fmt.bufPrint(&ebuf, "autoprotect savevm failed: {s} vm=\"{s}\" snap=\"{s}\"", .{ @errorName(e), name_safe, sn }) catch "autoprotect savevm failed");
                continue;
            };

            // Prune excess AutoProtect snapshots via the same monitor. Best
            // effort: a failed list/delete just leaves snapshots in place.
            var list_buf: [4096]u8 = undefined;
            const list_out = client.listSnapshots(&list_buf) catch continue;
            const nodes = snapparse.parse(list_out);

            var auto_total: usize = 0;
            var ni: usize = 0;
            while (ni < nodes.count) : (ni += 1) {
                if (autoprotect.isAutoName(nodes.nameSlice(ni))) auto_total += 1;
            }
            const excess = autoprotect.pruneExcess(auto_total, w.autoprotect_max);

            // Delete the oldest auto snapshots first (parse preserves order).
            var deleted: usize = 0;
            ni = 0;
            while (ni < nodes.count and deleted < excess) : (ni += 1) {
                const nm = nodes.nameSlice(ni);
                if (!autoprotect.isAutoName(nm)) continue;
                client.deleteSnapshot(nm) catch |e| {
                    var ebuf: [320]u8 = undefined;
                    logErr(std.fmt.bufPrint(&ebuf, "autoprotect delvm failed: {s} vm=\"{s}\"", .{ @errorName(e), name_safe }) catch "autoprotect delvm failed");
                    continue;
                };
                deleted += 1;
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
    const req = "POST /api/vms/42/power HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "POST /api/vms/");
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 42), idx.?);
}

test "parseIdx: returns null when prefix not found" {
    const req = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "POST /api/vms/");
    try std.testing.expect(idx == null);
}

test "parseIdx: handles multi-digit index" {
    const req = "POST /api/vms/12345 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "POST /api/vms/");
    try std.testing.expectEqual(@as(usize, 12345), idx.?);
}

test "parseIdx: returns null on non-numeric index" {
    const req = "POST /api/vms/abc/power HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const idx = parseIdx(req, "POST /api/vms/");
    try std.testing.expect(idx == null);
}

test "routeExact: matches exact route with trailing space" {
    try std.testing.expect(routeExact("GET /api/vms HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(routeExact("GET /api/health HTTP/1.1\r\n", "GET /api/health"));
    try std.testing.expect(routeExact("POST /api/vms/save HTTP/1.1\r\n", "POST /api/vms/save"));
}

test "routeExact: matches exact route with query string" {
    try std.testing.expect(routeExact("GET /api/vms?sort=name HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(routeExact("GET /api/config?full=1 HTTP/1.1\r\n", "GET /api/config"));
}

test "routeExact: rejects longer path at same prefix" {
    try std.testing.expect(!routeExact("GET /api/vms/3 HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("GET /api/vmsblah HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("GET /api/healthcheck HTTP/1.1\r\n", "GET /api/health"));
    try std.testing.expect(!routeExact("POST /api/vmss HTTP/1.1\r\n", "POST /api/vms"));
}

test "routeExact: rejects prefix not found" {
    try std.testing.expect(!routeExact("GET /other HTTP/1.1\r\n", "GET /api/vms"));
    try std.testing.expect(!routeExact("POST /api/vms HTTP/1.1\r\n", "GET /api/vms"));
}

test "routeExact: rejects request shorter than prefix" {
    try std.testing.expect(!routeExact("GET /api", "GET /api/vms"));
}

test "getBody: extracts body after double CRLF" {
    const req = "POST /api/vms/0 HTTP/1.1\r\nHost: localhost\r\n\r\nname=foo&mem=2048";
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
    const req = "POST /api/vms/0/power HTTP/1.1\r\nHost: localhost\r\n\r\n";
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

    const prefixes = [_][]const u8{ "POST /api/vms/", "GET /api/vms/" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        for (prefixes) |pfx| {
            _ = parseIdx(buf[0..len], pfx);
        }
    }
}

test "tailSlice: returns whole slice when shorter than cap" {
    const data = "short";
    try std.testing.expectEqualStrings("short", tailSlice(data, 64));
    try std.testing.expectEqualStrings("short", tailSlice(data, data.len));
}

test "tailSlice: returns last cap bytes when longer" {
    const data = "0123456789";
    try std.testing.expectEqualStrings("789", tailSlice(data, 3));
    try std.testing.expectEqualStrings("9", tailSlice(data, 1));
    try std.testing.expectEqualStrings("", tailSlice(data, 0));
}

test "tailSlice: empty input yields empty" {
    try std.testing.expectEqualStrings("", tailSlice("", 0));
    try std.testing.expectEqualStrings("", tailSlice("", 16));
}

test "fuzz: tailSlice never panics and returns a valid suffix" {
    var prng = std.Random.DefaultPrng.init(0x70A1_5EED);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        const cap = rnd.uintLessThan(usize, buf.len + 8);
        const out = tailSlice(buf[0..len], cap);
        // Result is always a tail-anchored sub-slice no longer than the input.
        try std.testing.expect(out.len <= len);
        try std.testing.expect(out.len <= @max(cap, len));
        if (out.len > 0) {
            const expected_start = len - out.len;
            try std.testing.expectEqualSlices(u8, buf[expected_start..len], out);
        }
        if (len <= cap) try std.testing.expectEqual(len, out.len);
    }
}

test "parseVmIdxSuffix: matches the /log route" {
    try std.testing.expectEqual(@as(?usize, 0), parseVmIdxSuffix("GET /api/vms/0/log HTTP/1.1", "GET /api/vms/", "/log"));
    try std.testing.expectEqual(@as(?usize, 12), parseVmIdxSuffix("GET /api/vms/12/log HTTP/1.1", "GET /api/vms/", "/log"));
    // Partial-segment guard: "/logs" must not match "/log".
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxSuffix("GET /api/vms/0/logs HTTP/1.1", "GET /api/vms/", "/log"));
    // The plain detail route has no suffix and must not match.
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxSuffix("GET /api/vms/0 HTTP/1.1", "GET /api/vms/", "/log"));
}

test "parseVmIdxExact: matches bare item path only" {
    // Bare detail / update paths return the index.
    try std.testing.expectEqual(@as(?usize, 0), parseVmIdxExact("GET /api/vms/0 HTTP/1.1", "GET /api/vms/"));
    try std.testing.expectEqual(@as(?usize, 12), parseVmIdxExact("POST /api/vms/12 HTTP/1.1", "POST /api/vms/"));
    // Query string after the id is allowed.
    try std.testing.expectEqual(@as(?usize, 3), parseVmIdxExact("GET /api/vms/3?full=1 HTTP/1.1", "GET /api/vms/"));
    // A trailing action segment must NOT match the bare item route.
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("POST /api/vms/0/power HTTP/1.1", "POST /api/vms/"));
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("GET /api/vms/0/log HTTP/1.1", "GET /api/vms/"));
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("POST /api/vms/0/snapshots/revert HTTP/1.1", "POST /api/vms/"));
    // Non-numeric id is rejected.
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("GET /api/vms/abc HTTP/1.1", "GET /api/vms/"));
    // Prefix not present.
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("GET /api/health HTTP/1.1", "GET /api/vms/"));
}

test "dispatch disambiguation: snapshots/revert is not the bare /snapshots take route" {
    // The longer suffix must win: a revert request must not be swallowed by the
    // /snapshots (take) matcher, and must not be seen as a bare item route.
    try std.testing.expect(parseVmIdxSuffix("POST /api/vms/0/snapshots/revert HTTP/1.1", "POST /api/vms/", "/snapshots/revert") != null);
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("POST /api/vms/0/snapshots/revert HTTP/1.1", "POST /api/vms/"));
    // The bare /snapshots matcher does still match the take request itself.
    try std.testing.expect(parseVmIdxSuffix("POST /api/vms/0/snapshots HTTP/1.1", "POST /api/vms/", "/snapshots") != null);
}

test "dispatch disambiguation: bare item path matches no action route" {
    // A bare /api/vms/0 must not be matched by any /<action> suffix matcher.
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxSuffix("POST /api/vms/0 HTTP/1.1", "POST /api/vms/", "/power"));
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxSuffix("POST /api/vms/0 HTTP/1.1", "POST /api/vms/", "/delete"));
    // ...but the exact matcher accepts it.
    try std.testing.expectEqual(@as(?usize, 0), parseVmIdxExact("POST /api/vms/0 HTTP/1.1", "POST /api/vms/"));
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

    const prefixes = [_][]const u8{ "GET /api/vms/", "POST /api/vms/" };
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
    // X-API-Key is followed by another header, so its value is terminated by
    // the CR scan in findHeader (the common case, distinct from the
    // end-of-headers branch covered by the "key at end" test below).
    const req = "GET /api/vms HTTP/1.1\r\nX-API-Key: hangar\r\nHost: localhost\r\n\r\n";
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

test "wsAuthOk: loopback (no KV_API_KEY) allows keyless WebSocket upgrade" {
    // The browser cannot send X-API-Key on a WS handshake; in loopback mode the
    // upgrade must still be allowed (hostHeaderOk already gated the origin) or the
    // console/serial console never connects.
    const prev = auth_token_len;
    auth_token_len = 0;
    defer auth_token_len = prev;
    // No X-API-Key header, conn=-1 (only touched on the failure path, which we
    // don't take here).
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
}

test "wsAuthOk: exposed (KV_API_KEY set) still requires the key" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }
    // Correct key upgrades; the no-key path would write a 401 to conn, so only
    // assert the accepting case here.
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nX-API-Key: secret\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
}

test "checkAuth: accepts correct custom auth token" {
    auth_token_len = 6;
    @memcpy(auth_token[0..6], "secret");
    defer {
        auth_token_len = 0;
        @memset(&auth_token, 0);
    }

    // X-API-Key precedes another header → value terminated by the CR scan,
    // not by end-of-headers (that case is the "custom token at end" test).
    const req = "GET /api/vms HTTP/1.1\r\nX-API-Key: secret\r\nHost: localhost\r\n\r\n";
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
    const req = "POST /api/vms/0 HTTP/1.1\r\nContent-Length: -1\r\n\r\n";
    try std.testing.expect(parseContentLength(req) == null);
}

test "parseContentLength: overflow value returns null" {
    const req = "POST /api/vms/0 HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n";
    try std.testing.expect(parseContentLength(req) == null);
}

test "parseContentLength: valid value extracted" {
    const req = "POST /api/vms/0 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\n\r\nname=test";
    const cl = parseContentLength(req);
    try std.testing.expectEqual(@as(usize, 42), cl.?);
}

test "parseContentLength: zero is valid" {
    const req = "POST /api/vms/0 HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
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
        "GET /api/vms/0/framebuffer",
        "GET /api/config",
        "GET /api/networks",
        "GET /api/vms/0",
        "GET /api/vms/0/snapshots",
        "GET /api/capabilities",
        "GET /api/catalog",
        "POST /api/vms/quickstart/",
        "GET /api/vms/0/migrate",
        "GET /ws/vnc/",
        "GET /ws/spice/",
        "GET /ws/serial/",
        "GET /app.js",
        "GET /app.css",
        "GET /novnc.js",
        "GET /spice.js",
        "GET /favicon",
        "POST /api/vms/0/power",
        "POST /api/vms/0",
        "POST /api/vms/save",
        "POST /api/vms/0/suspend",
        "POST /api/vms/0/pause",
        "POST /api/vms/0/resume",
        "POST /api/vms/0/shutdown",
        "POST /api/vms/0/reset",
        "POST /api/vms/0/delete",
        "POST /api/vms/0/clone",
        "POST /api/vms",
        "POST /api/vms/0/rename",
        "POST /api/vms/0/snapshots",
        "POST /api/vms/0/snapshots/revert",
        "POST /api/vms/0/snapshots/delete",
        "POST /api/vms/import",
        "POST /api/vms/0/cad",
        "POST /api/vms/0/export",
        "POST /api/vms/0/disk2",
        "POST /api/networks",
        "POST /api/config",
        "POST /api/vms/undo",
        "POST /api/vms/reorder",
        "POST /api/vms/0/migrate",
        "POST /api/vms/0/migrate/cancel",
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
                    _ = std.mem.indexOf(u8, buf[0..len], "/disk2");
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
        "GET /api/vms",          "GET /api/health",
        "GET /api/config",       "GET /api/catalog",
        "GET /api/networks",     "GET /api/capabilities",
        "POST /api/vms",         "POST /api/vms/save",
        "POST /api/vms/undo",    "POST /api/vms/reorder",
        "POST /api/vms/import",  "POST /api/networks",
        "POST /api/config",      "GET /app.css",
        "GET /app.js",           "GET /novnc.js",
        "GET /spice.js",
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
        // fuzzer reaches boundary-confusable prefixes (e.g. "/api/vms/...").
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

// handleCatalog/handleCapabilities moved to catalog.zig (tested there).

test "handleQuickstart: missing space after slug returns 'invalid'" {
    const result = try handleQuickstart("POST /api/vms/quickstart/ubuntu2404");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handleQuickstart: empty slug returns 'not found'" {
    const result = try handleQuickstart("POST /api/vms/quickstart/ HTTP/1.1");
    try std.testing.expectEqualStrings("not found", result);
}

test "handleQuickstart: unknown slug returns 'not found'" {
    const result = try handleQuickstart("POST /api/vms/quickstart/nonexistent HTTP/1.1");
    try std.testing.expectEqualStrings("not found", result);
}

test "handleQuickstart: full VM array returns 'full'" {
    const prev_count = appstate.vm_count;
    appstate.vm_count = appstate.MAX_VMS;
    defer appstate.vm_count = prev_count;
    const result = try handleQuickstart("POST /api/vms/quickstart/ubuntu2404 HTTP/1.1");
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
    try std.testing.expect(isAuthExempt(true, "/api/networks"));
    try std.testing.expect(isAuthExempt(true, "/api/catalog"));
}

test "isAuthExempt: prefix paths are exempt for GET" {
    try std.testing.expect(isAuthExempt(true, "/api/vms/0"));
    try std.testing.expect(isAuthExempt(true, "/api/vms/5/snapshots"));
    try std.testing.expect(isAuthExempt(true, "/api/vms/5/log"));
    // The framebuffer read still requires auth.
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/framebuffer"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/framebuffer?quality=50"));
    // Migrate-status read still requires auth.
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/migrate"));
    // POST /api/vms/quickstart/ creates a VM (state-changing) — it must require
    // auth (covered by the non-GET early return).
    try std.testing.expect(!isAuthExempt(false, "/api/vms/quickstart/ubuntu2404"));
    // Disk-image download streams raw guest bytes — must require auth even
    // though it lives under the otherwise-exempt /api/vms/ prefix.
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/disk2/download"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/12/disk2/download"));
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
    // These are POST routes; even probed with GET they must not be exempt
    // (only /framebuffer, /migrate, /disk2/download under /api/vms/ are the
    // explicit non-exempt GETs, the rest of /api/vms/ being read-only).
    try std.testing.expect(!isAuthExempt(true, "/api/configX"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/framebuffer"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/disk2/download"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/migrate"));
}

test "isAuthExempt: all non-GET methods are non-exempt" {
    try std.testing.expect(!isAuthExempt(false, "/"));
    try std.testing.expect(!isAuthExempt(false, "/app.js"));
    try std.testing.expect(!isAuthExempt(false, "/api/vms"));
    try std.testing.expect(!isAuthExempt(false, "/api/vms/0"));
}

test "isAuthExempt: path traversal does not bypass prefix match" {
    try std.testing.expect(isAuthExempt(true, "/api/vms/../../../etc/passwd"));
    // A traversal that ends in a non-exempt suffix must still require auth.
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/../../../../root/.ssh/disk2/download"));
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
    const body = try std.fmt.allocPrint(std.testing.allocator, "POST /api/networks HTTP/1.1\r\nHost: localhost\r\n\r\n{s}", .{json});
    defer std.testing.allocator.free(body);
    const result = try handleVnetsSave(body);
    try std.testing.expectEqualStrings("ok", result);
}

test "handleVnetsSave: empty body returns 'no body'" {
    const req = "POST /api/networks HTTP/1.1\r\nHost: localhost";
    const result = try handleVnetsSave(req);
    try std.testing.expectEqualStrings("no body", result);
}

test "handleVnetsSave: malformed JSON returns parse error" {
    const req = "POST /api/networks HTTP/1.1\r\nHost: localhost\r\n\r\n{not valid json}";
    const result = try handleVnetsSave(req);
    try std.testing.expectEqualStrings("parse error", result);
}

test "handleVnetsSave: empty JSON object returns defaults (ok)" {
    var cfg_home = try TestConfigHome.init("vnets-empty");
    defer cfg_home.deinit();

    const req = "POST /api/networks HTTP/1.1\r\nHost: localhost\r\n\r\n{}";
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

    // Power on VMs flagged host_autostart. Runs single-threaded here, before the
    // listeners/tickers spawn, so no lock is needed. Best-effort: a failure is
    // logged and the next VM is still tried. Mirrors handlePower's no-handle
    // start path. (Previously host_autostart was persisted/shown but never acted
    // on — an inert checkbox.)
    {
        var ai: usize = 0;
        while (ai < appstate.vm_count) : (ai += 1) {
            if (!shouldAutostart(&appstate.vms[ai])) continue;
            qemu.startVm(&appstate.vms[ai], std.heap.page_allocator) catch |e| {
                logOpErr("autostart", e, appstate.vms[ai].getNameSlice());
                continue;
            };
            appstate.vm_started[ai] = time(null);
            logAudit("autostart", appstate.vms[ai].getNameSlice());
        }
    }

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
            var pbuf: [128]u8 = undefined;
            logErr(std.fmt.bufPrint(&pbuf, "KV_PORT '{s}' is not a valid port number (expected 1-65535) — refusing to start", .{env}) catch "KV_PORT is not a valid port number — refusing to start");
            std.process.exit(1);
        };
        if (p == 0) {
            logErr("KV_PORT must be 1-65535 (got 0) — refusing to start");
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
        var bbuf: [160]u8 = undefined;
        logErr(std.fmt.bufPrint(&bbuf, "Failed to bind TCP port {d} (already in use, or permission denied for a privileged port) — set KV_PORT to a free port and retry", .{port}) catch "Failed to bind TCP port — refusing to start");
        std.process.exit(1);
    }
    if (c.listen(sock, 10) != 0) {
        var lbuf: [96]u8 = undefined;
        logErr(std.fmt.bufPrint(&lbuf, "Failed to listen on TCP port {d} — refusing to start", .{port}) catch "Failed to listen on TCP port");
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
        var sb: [160]u8 = undefined;
        // Include the loaded VM count and whether persistence is degraded so an
        // operator can spot a daemon that came up "healthy" but is refusing to
        // save (unreadable/newer vms.json) — otherwise that only surfaces on the
        // first failed save, long after the cause is gone from view.
        logAt(.info, std.fmt.bufPrint(&sb, "daemon started: port={d} bind={s} vms={d} persist={s}", .{ port, if (expose_all) "all" else "loopback", appstate.vm_count, if (persist.loadDegraded()) "degraded" else "ok" }) catch "daemon started");
        if (persist.loadDegraded()) logErr("persistence degraded: vms.json unreadable or written by a newer Hangar — saves are disabled until restart with a readable file");
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

    // Serve the TCP listener on the main thread via the shared acceptLoop, which
    // applies the connection cap + per-connection accounting + TCP_NODELAY. (The
    // Unix listener runs the same acceptLoop on its own thread above.) Using the
    // shared loop is essential: an inline loop that spawned serveHtml without the
    // matching active_connections increment would underflow the counter on every
    // TCP connection.
    acceptLoop(sock);
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
    const result = try handlePower("POST /api/vms/abc/power HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "handlePower: idx out of range returns 'invalid idx'" {
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    defer appstate.vm_count = prev_count;
    const result = try handlePower("POST /api/vms/0/power HTTP/1.1");
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
    const result = try handleNewVm("POST /api/vms\r\n\r\nname=test");
    try std.testing.expectEqualStrings("full", result);
}

test "handleNewVm: missing body returns 'no body'" {
    const result = try handleNewVm("POST /api/vms");
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
    const result = try handleNewVm("POST /api/vms\r\n\r\nname=evil<script>");
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
    const result = try handleNewVm("POST /api/vms\r\n\r\nname=");
    try std.testing.expectEqualStrings("invalid name", result);
}

// handleCapabilities moved to catalog.zig (tested there).

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
    const result = try handleDelete("POST /api/vms/0/delete HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "parseGuestIpv4s: extracts non-loopback IPv4s from a GA reply" {
    const sample =
        \\{"return":[{"name":"lo","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1","prefix":8}]},{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.2.15","prefix":24},{"ip-address-type":"ipv6","ip-address":"fe80::1","prefix":64}]}]}
    ;
    var out: [256]u8 = undefined;
    const ips = parseGuestIpv4s(sample, &out);
    try std.testing.expectEqualStrings("10.0.2.15", ips); // loopback + ipv6 excluded
}

test "parseGuestIpv4s: empty when no addresses" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", parseGuestIpv4s("{\"return\":[]}", &out));
}

test "parseGuestIpv4s: joins multiple IPv4s with commas" {
    const sample =
        \\[{"ip-address":"192.168.1.5"},{"ip-address":"10.1.1.2"}]
    ;
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.5,10.1.1.2", parseGuestIpv4s(sample, &out));
}

test "cleanupVmTempFiles removes name-derived temp artifacts" {
    const nm = "cleanuptestvm";
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = "/tmp/hangar-ci-cleanuptestvm.iso", .data = "x" }) catch {};
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = "/tmp/hangar-ga-cleanuptestvm.sock", .data = "x" }) catch {};
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = "/tmp/hangar-ci-ud-cleanuptestvm", .data = "x" }) catch {};
    cleanupVmTempFiles(nm);
    const gone1 = if (std.Io.Dir.cwd().access(appio.io(), "/tmp/hangar-ci-cleanuptestvm.iso", .{})) |_| false else |_| true;
    const gone2 = if (std.Io.Dir.cwd().access(appio.io(), "/tmp/hangar-ga-cleanuptestvm.sock", .{})) |_| false else |_| true;
    const gone3 = if (std.Io.Dir.cwd().access(appio.io(), "/tmp/hangar-ci-ud-cleanuptestvm", .{})) |_| false else |_| true;
    try std.testing.expect(gone1 and gone2 and gone3);
}

test "shouldAutostart: requires the flag and a disk" {
    var v = vm.VmConfig{};
    try std.testing.expect(!shouldAutostart(&v)); // default: off
    v.host_autostart = true;
    try std.testing.expect(!shouldAutostart(&v)); // flagged but no disk
    v.setDiskPath("/tmp/d.qcow2");
    try std.testing.expect(shouldAutostart(&v)); // flagged + has disk
    v.host_autostart = false;
    try std.testing.expect(!shouldAutostart(&v));
}

test "handleUndo: clamps a stale undo_idx instead of corrupting the list" {
    // Isolate the persist write to a temp dir so the test never touches the real
    // ~/.config/hangar/vms.json.
    _ = setenv("HANGAR_CONFIG_HOME", "/tmp/hangar-undo-test", 1);
    defer _ = unsetenv("HANGAR_CONFIG_HOME");

    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    const prev_undo = appstate.undo_available;
    appstate.vm_count = 2;
    appstate.vms[0] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[0].setName("a");
    appstate.vms[1] = std.mem.zeroes(vm.VmConfig);
    appstate.vms[1].setName("b");
    appstate.undo_vm = std.mem.zeroes(vm.VmConfig);
    appstate.undo_vm.setName("restored");
    appstate.undo_idx = 5; // stale: greater than the current vm_count
    appstate.undo_available = true;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.undo_available = prev_undo;
        appstate.vms_mutex.unlock();
    }

    _ = handleUndo() catch {};

    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    // Inserted at the clamped end (index 2), count grew by one, no stale slot.
    try std.testing.expectEqual(@as(usize, 3), appstate.vm_count);
    try std.testing.expectEqualStrings("restored", appstate.vms[2].getNameSlice());
}

test "handleReorder: missing from/to returns error" {
    const result = try handleReorder("POST /api/vms/reorder\r\n\r\nfrom=0");
    try std.testing.expectEqualStrings("missing from/to", result);
}

test "handleReorder: no body returns 'no body'" {
    const result = try handleReorder("POST /api/vms/reorder");
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
    const result = try handleReorder("POST /api/vms/reorder\r\n\r\nfrom=0&to=0");
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
    const result = try handleReorder("POST /api/vms/reorder\r\n\r\nfrom=0&to=1");
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
    const result = try handleSave("POST /api/vms/0 HTTP/1.1");
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
    const result = try handleSave("POST /api/vms/0 HTTP/1.1");
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
    const result = try handleSave("POST /api/vms/0 HTTP/1.1\r\n\r\niso_path=../../etc/passwd");
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
    const result = try handleSave("POST /api/vms/0 HTTP/1.1\r\n\r\nmem=2048&cpu=4");
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
    const result = try handleRename("POST /api/vms/0/rename HTTP/1.1");
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
    const result = try handleSuspend("POST /api/vms/0/suspend HTTP/1.1");
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
    const result = try handlePause("POST /api/vms/0/pause HTTP/1.1");
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
    const result = try handleResume("POST /api/vms/0/resume HTTP/1.1");
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
    const result = try handleShutdown("POST /api/vms/0/shutdown HTTP/1.1");
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
    const result = try handleReset("POST /api/vms/0/reset HTTP/1.1");
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
    const result = try handleSnapshotTake("POST /api/vms/0/snapshots HTTP/1.1");
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
    const result = handleSnapshotList("GET /api/vms/0/snapshots HTTP/1.1", &buf);
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
    const result = try handleSnapshotRevert("POST /api/vms/0/snapshots/revert HTTP/1.1");
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
    const result = try handleSnapshotDelete("POST /api/vms/0/snapshots/delete HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "handleImport: missing body returns 'no body'" {
    const result = try handleImport("POST /api/vms/import");
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
    const result = try handleCad("POST /api/vms/0/cad HTTP/1.1");
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
    const result = try handleMigrate("POST /api/vms/0/migrate HTTP/1.1");
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
    const result = try handleMigrate("POST /api/vms/0/migrate HTTP/1.1\r\n\r\ndummy=1");
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
    const result = handleMigrateStatus("GET /api/vms/0/migrate HTTP/1.1", &buf);
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
    const result = try handleMigrateCancel("POST /api/vms/0/migrate/cancel HTTP/1.1");
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
    const result = try handleClone("POST /api/vms/0/clone HTTP/1.1");
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
    const result = try handleClone("POST /api/vms/0/clone HTTP/1.1");
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

test "fuzz: handleVmLog never panics on random request-like input" {
    // handleVmLog parses an idx out of the untrusted request line and writes its
    // response straight to the connection fd, so unlike the `![]const u8` handlers
    // above it can't go through the shared idx-gated harness. Drive it over a fresh
    // socketpair per iteration (the response end is closed without draining — the
    // early-exit replies are a few dozen bytes, far below the socket buffer). With
    // the empty VM table the `idx >= vm_count` guard always fires before any
    // filesystem read, so this exercises the bad-index / parseIdx path with real
    // socket I/O and zero side effects.
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);

    var prng = std.Random.DefaultPrng.init(0x106_F1E5);
    const rnd = prng.random();
    for (0..2000) |_| {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        var buf: [160]u8 = undefined;
        for (&buf) |*b| b.* = rnd.int(u8);
        const req = buf[0..rnd.uintLessThan(usize, buf.len)];
        handleVmLog(fds[1], req) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
}

test "fuzz: handleUploadDisk multipart parser never panics on structured input" {
    // Random bytes alone die at the `POST /api/vms/<idx>` prefix check, so they
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
            "POST /api/vms/0/disk2 HTTP/1.1\r\nContent-Length: 200\r\nContent-Type: multipart/form-data; boundary={s}\r\n\r\n" ++
            "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename={s}{s}{s}\r\n\r\n" ++
            "PAYLOAD-BYTES\r\n--{s}--\r\n", .{
            bnd[0..bnd_len],
            bnd[0..bnd_len],
            if (quoted) "\"" else "",
            fname,
            if (quoted) "\"" else "",
            bnd[0..bnd_len],
        }) catch {
            handleUploadDiskStreaming(-1, "POST /api/vms/0/disk2 HTTP/1.1\r\n\r\n");
            continue;
        };

        // Corrupt a handful of random bytes to fuzz the framing.
        const flips = rnd.uintLessThan(usize, 6);
        var f: usize = 0;
        while (f < flips) : (f += 1) {
            msg[rnd.uintLessThan(usize, msg.len)] = rnd.int(u8);
        }

        handleUploadDiskStreaming(-1, msg);
    }

    // The parser path must not have mutated shared state (no write reached:
    // the empty VM table returns "invalid idx" before any file open).
    try std.testing.expectEqual(@as(usize, 0), appstate.vm_count);
}

test "requestLine: stops at CRLF and keeps method+path" {
    var out: [128]u8 = undefined;
    const line = requestLine("POST /api/vms/3/power HTTP/1.1\r\nHost: x\r\n", &out);
    try std.testing.expectEqualStrings("POST /api/vms/3/power HTTP/1.1", line);
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
    logReqErr("export failed", error.AccessDenied, "POST /api/vms/9/export\t\x01\r\nHost: x");
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
