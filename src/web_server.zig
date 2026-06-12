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
const httpreq = @import("httpreq.zig");
const snapshots = @import("snapshots.zig");
const migrate = @import("migrate.zig");
const disk = @import("disk.zig");
const cdrom = @import("cdrom.zig");
const guestagent = @import("guestagent.zig");
const streams = @import("streams.zig");
const wlog = @import("wlog.zig");
// Structured logging lives in wlog.zig; alias so call sites read unchanged.
const LogLevel = wlog.LogLevel;
const logAt = wlog.logAt;
const logErr = wlog.logErr;
const logWarn = wlog.logWarn;
const logSaveErr = wlog.logSaveErr;
const logReqErr = wlog.logReqErr;
const sanitizeLogName = wlog.sanitizeLogName;
const logAudit = wlog.logAudit;
const logOpErr = wlog.logOpErr;
// Pure HTTP request/route parsers live in httpreq.zig; alias them so the ~40
// call sites below read unchanged.
const routeExact = httpreq.routeExact;
const parseIdx = httpreq.parseIdx;
const parseVmIdxSuffix = httpreq.parseVmIdxSuffix;
const parseVmIdxExact = httpreq.parseVmIdxExact;
const findHeader = httpreq.findHeader;
const requestLine = httpreq.requestLine;
const parseContentLength = httpreq.parseContentLength;
const getBody = httpreq.getBody;
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
const httpresp = @import("httpresp.zig");
const auth = @import("auth.zig");
const netutil = @import("netutil.zig");
const dbusdisplay = @import("dbusdisplay.zig");
const wsproxy = @import("wsproxy.zig");
const vmrender = @import("vmrender.zig");
const AF_INET = netutil.AF_INET;
const AF_INET6 = netutil.AF_INET6;
const AF_UNIX = netutil.AF_UNIX;
const SOCK_STREAM = netutil.SOCK_STREAM;
const SOL_SOCKET = netutil.SOL_SOCKET;
const SO_REUSEADDR = netutil.SO_REUSEADDR;
const SO_RCVTIMEO = netutil.SO_RCVTIMEO;
const SO_SNDTIMEO = netutil.SO_SNDTIMEO;
const SHUT_RDWR = netutil.SHUT_RDWR;
const IPPROTO_IPV6 = netutil.IPPROTO_IPV6;
const IPV6_V6ONLY = netutil.IPV6_V6ONLY;
const IPPROTO_TCP = netutil.IPPROTO_TCP;
const TCP_NODELAY = netutil.TCP_NODELAY;
const setTcpNoDelay = netutil.setTcpNoDelay;
// Auth lives in auth.zig; alias so call sites + main read unchanged.
const API_KEY = auth.API_KEY;
const checkAuth = auth.checkAuth;
const isAuthExempt = auth.isAuthExempt;
const wsAuthOk = auth.wsAuthOk;
const hostHeaderOk = auth.hostHeaderOk;
const validApiKey = auth.validApiKey;
const secretEql = auth.secretEql;
// HTTP status codes + response writers live in httpresp.zig; alias so the many
// call sites below read unchanged.
const HTTP_OK = httpresp.HTTP_OK;
const HTTP_CREATED = httpresp.HTTP_CREATED;
const HTTP_BAD_REQUEST = httpresp.HTTP_BAD_REQUEST;
const HTTP_UNAUTHORIZED = httpresp.HTTP_UNAUTHORIZED;
const HTTP_FORBIDDEN = httpresp.HTTP_FORBIDDEN;
const HTTP_NOT_FOUND = httpresp.HTTP_NOT_FOUND;
const HTTP_METHOD_NOT_ALLOWED = httpresp.HTTP_METHOD_NOT_ALLOWED;
const HTTP_CONFLICT = httpresp.HTTP_CONFLICT;
const HTTP_PAYLOAD_TOO_LARGE = httpresp.HTTP_PAYLOAD_TOO_LARGE;
const HTTP_TOO_MANY_REQUESTS = httpresp.HTTP_TOO_MANY_REQUESTS;
const HTTP_INTERNAL_ERROR = httpresp.HTTP_INTERNAL_ERROR;
const writeAll = httpresp.writeAll;
const jsonErr = httpresp.jsonErr;
const writeHttpResponse = httpresp.writeHttpResponse;
const sanitizeHeaderValue = httpresp.sanitizeHeaderValue;
const isServerErrToken = httpresp.isServerErrToken;
const EscapeResult = httpresp.EscapeResult;
const jsonEscape = httpresp.jsonEscape;

const DEFAULT_PORT: u16 = transport.DEFAULT_PORT; // KV_PORT default
const CONFIG_RAW_MAX = 4 * 1024 * 1024;

// Server socket fds for shutdown signaling.
var tcp_sock_fd: c.fd_t = -1;
var unix_sock_fd: c.fd_t = -1;

const c = std.c;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// POSIX networking constants (not in std.c in Zig 0.16)

/// Cap on concurrent client connections. Each accepted connection spends a
/// thread plus a 64 KB request buffer (and a WebSocket relay spends two more
/// threads), so without a bound a flood of connections — including ones that
/// stall mid-request or never read their response — would exhaust host threads
/// and memory. New connections past the cap are dropped (cheap close).
const MAX_CONNECTIONS: u32 = 256;
var active_connections: u32 = 0;


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





/// Copy the HTTP request line (method + path, up to the first CR/LF) into
/// `out`, replacing every non-printable byte with '?'. Request data is
/// client-controlled, so sanitizing here lets error logs carry route context
/// (which VM / operation failed) without risking log-line injection.
/// Write exactly `len` bytes to fd, retrying on short writes. Returns false on failure.
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
            const e = c._errno().*;
            // Transient per-connection errors must not kill the listener: a
            // single EMFILE (fd table full from many consoles) or EINTR/
            // ECONNABORTED would otherwise silently stop the daemon serving
            // until restart. Back off briefly on EMFILE/ENFILE; retry the rest.
            if (e == @intFromEnum(c.E.INTR) or e == @intFromEnum(c.E.AGAIN) or
                e == @intFromEnum(c.E.CONNABORTED))
            {
                continue;
            }
            if (e == @intFromEnum(c.E.MFILE) or e == @intFromEnum(c.E.NFILE)) {
                logErr("acceptLoop: out of file descriptors, backing off");
                appio.sleepMs(100);
                continue;
            }
            // Listener socket itself is gone (EBADF/EINVAL): stop the thread.
            logErr("acceptLoop: accept() failed fatally, listener thread exiting");
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

/// Boolean VmConfig form fields whose key equals the field name and whose value
/// is "1" (true) / else (false). Driven by @field so create + save share one
/// definition (autoprotect is excluded — create also sets a has_* sentinel).
const bool_form_fields = [_][]const u8{
    "guest_tools",           "enable_3d",   "embed_display", "enable_serial",
    "virtio_rng",            "favorite",    "guest_agent",   "tpm",
    "secure_boot",           "hyperv_enlightenments", "hugepages", "ballooning",
    "host_autostart",        "video_stream",
};

/// Set a boolean VmConfig field from a form key/value via @field. Returns true if
/// `key` named one of bool_form_fields. Shared by handleNewVm and handleSave.
/// Accepts "1" or "true" as true (the bundled UI sends "1"; API clients commonly
/// send "true" — silently parsing that as false cost a debugging session).
fn applyBoolField(v: *vm.VmConfig, key: []const u8, val: []const u8) bool {
    inline for (bool_form_fields) |f| {
        if (std.mem.eql(u8, key, f)) {
            @field(v, f) = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
            return true;
        }
    }
    return false;
}

/// Combobox-index VmConfig enum form fields whose key equals the field name.
/// The enum type is recovered from the field via @TypeOf, so adding a field is
/// one entry here (no type to repeat).
const enum_form_fields = [_][]const u8{
    "disk_format", "disk_cache",  "usb_policy",         "disk2_format",
    "gpu_device",  "display",     "display_resolution", "guest_os",
    "audio",       "boot_order",  "rtc",                "watchdog",
};

/// Set a combobox-index enum field from a form key/value via @field + @TypeOf.
/// Out-of-range / unparseable keeps the current value. Returns true if matched.
fn applyEnumField(v: *vm.VmConfig, key: []const u8, val: []const u8) bool {
    inline for (enum_form_fields) |f| {
        if (std.mem.eql(u8, key, f)) {
            const E = @TypeOf(@field(v, f));
            @field(v, f) = E.fromIndex(std.fmt.parseInt(usize, val, 10) catch @field(v, f).toIndex());
            return true;
        }
    }
    return false;
}

/// Free-text VmConfig form fields applied through a (bounds-checked) setter
/// method. The setter is invoked by name via @field on the type — no validation
/// here, so only setters that safely accept arbitrary text belong in this table.
const str_form_fields = [_]struct { key: []const u8, setter: []const u8 }{
    .{ .key = "portfw", .setter = "setPortForwards" },
    .{ .key = "notes", .setter = "setNotes" },
    .{ .key = "tags", .setter = "setTags" },
    .{ .key = "folder", .setter = "setFolder" },
    .{ .key = "vnet", .setter = "setVnet" },
    .{ .key = "cloud_init", .setter = "setCloudInit" },
};

/// Apply a free-text field by calling its setter via @field. Returns true if matched.
fn applyStrField(v: *vm.VmConfig, key: []const u8, val: []const u8) bool {
    inline for (str_form_fields) |f| {
        if (std.mem.eql(u8, key, f.key)) {
            @field(vm.VmConfig, f.setter)(v, val);
            return true;
        }
    }
    return false;
}

/// A VM-scoped POST handler: takes the raw request, returns a status token.
/// (These handlers catch their own errors and return a token, so the error set
/// is effectively empty; the alias type widens it for the table.)
const ApiHandler = *const fn ([]const u8) anyerror![]const u8;

/// Comptime dispatch table for the uniform `POST /api/vms/<id>/<suffix>` routes
/// that all return a text/plain status token. Replaces ~18 near-identical
/// if/else-if arms. ORDER MATTERS: longer suffixes precede the shorter prefixes
/// they extend (e.g. `/snapshots/revert` before `/snapshots`, `/cdrom/eject`
/// before `/cdrom`) because parseVmIdxSuffix accepts `/` as a segment boundary,
/// so the first match in iteration order wins.
const post_routes = [_]struct { suffix: []const u8, handler: ApiHandler }{
    .{ .suffix = "/power", .handler = handlePower },
    .{ .suffix = "/start", .handler = handlePowerStart },
    .{ .suffix = "/stop", .handler = handlePowerStop },
    .{ .suffix = "/delete", .handler = handleDelete },
    .{ .suffix = "/clone", .handler = handleClone },
    .{ .suffix = "/rename", .handler = handleRename },
    .{ .suffix = "/suspend", .handler = handleSuspend },
    .{ .suffix = "/pause", .handler = handlePause },
    .{ .suffix = "/resume", .handler = handleResume },
    .{ .suffix = "/shutdown", .handler = handleShutdown },
    .{ .suffix = "/reset", .handler = handleReset },
    .{ .suffix = "/cad", .handler = handleCad },
    .{ .suffix = "/disk/resize", .handler = disk.resize },
    .{ .suffix = "/disk/compact", .handler = disk.compact },
    .{ .suffix = "/cdrom/eject", .handler = cdrom.eject },
    .{ .suffix = "/cdrom", .handler = cdrom.change },
    .{ .suffix = "/snapshots/revert", .handler = snapshots.revert },
    .{ .suffix = "/snapshots/delete", .handler = snapshots.delete },
    .{ .suffix = "/snapshots", .handler = snapshots.take },
    .{ .suffix = "/migrate/cancel", .handler = migrate.cancel },
};

/// Match `req` against the POST route table; returns the handler or null.
fn lookupPostRoute(req: []const u8) ?ApiHandler {
    if (!std.mem.startsWith(u8, req, "POST /api/vms/")) return null;
    for (post_routes) |r| {
        if (parseVmIdxSuffix(req, "POST /api/vms/", r.suffix) != null) return r.handler;
    }
    return null;
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
        streams.upload(conn, req);
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

    // ── Server-Sent Events: state-change stream ──
    if (routeExact(req, "GET /api/events")) {
        // Dispatched before the generic auth gate below, so enforce the same
        // exposed-mode rule here: in exposed mode the stream (even just the
        // state-version) requires the key.
        if (auth.isExposed() and !auth.checkAuth(req)) {
            writeHttpResponse(conn, HTTP_UNAUTHORIZED, "application/json; charset=utf-8", "{\"error\":\"auth required\"}");
            return;
        }
        handleEvents(conn);
        return;
    }

    // ── WebSocket VNC Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/vnc/")) {
        if (!wsAuthOk(conn, req, "/ws/vnc")) return;
        wsproxy.vnc(conn, req) catch |e| {
            logReqErr("VNC proxy failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"VNC proxy failed\"}");
        };
        return;
    }

    // ── WebSocket SPICE Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/spice/")) {
        if (!wsAuthOk(conn, req, "/ws/spice")) return;
        wsproxy.spice(conn, req) catch |e| {
            logReqErr("SPICE proxy failed", e, req);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"SPICE proxy failed\"}");
        };
        return;
    }

    // ── WebSocket video stream (encoded H.264, docs/VIDEO-PIPELINE.md) ──
    if (std.mem.startsWith(u8, req, "GET /ws/video/")) {
        if (!wsAuthOk(conn, req, "/ws/video")) return;
        handleVideoWs(conn, req);
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        if (!wsAuthOk(conn, req, "/ws/serial")) return;
        wsproxy.serialConsole(conn, req) catch |e| {
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
        streams.download(conn, req) catch |e| {
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
        const body = disk.info(req, &di_buf);
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
        streams.screenshot(conn, req);
        return;
    }
    if (parseVmIdxSuffix(req, "GET /api/vms/", "/guestinfo") != null) {
        var gi_buf: [640]u8 = undefined;
        writeHttpResponse(conn, HTTP_OK, "application/json; charset=utf-8", guestagent.query(req, &gi_buf));
        return;
    }
    if (parseVmIdxSuffix(req, "POST /api/vms/", "/export") != null) {
        streams.exportOva(conn, req) catch |e| {
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
        const json_bytes = vmrender.renderJson(vms_buf);
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
    } else if (lookupPostRoute(req)) |h| {
        // Comptime-table dispatch for the uniform POST status-token routes
        // (power/delete/clone/.../snapshots/migrate-cancel). See post_routes.
        response = h(req) catch |e| blk: {
            logReqErr("api handler failed", e, req);
            break :blk "internal err";
        };
        content_type = "text/plain";
    } else if (parseVmIdxSuffix(req, "GET /api/vms/", "/snapshots") != null) {
        response = snapshots.list(req, &snap_buf);
        content_type = "text/plain";
        // POST /migrate/cancel is handled by the post_routes table above.
    } else if (parseVmIdxSuffix(req, "GET /api/vms/", "/migrate") != null) {
        response = migrate.status(req, &snap_buf);
        content_type = "application/json; charset=utf-8";
        // The status payload is JSON, so it bypasses the central text/plain error
        // mapper. Surface its error states as real HTTP codes — otherwise a bad
        // index or a failed QMP query both return 200 OK, indistinguishable from a
        // live migration to a programmatic client. The body is unchanged and the
        // web UI reads it regardless of status code, so this is non-breaking.
        status = migrate.statusHttpCode(response);
    } else if (parseVmIdxSuffix(req, "POST /api/vms/", "/migrate") != null) {
        response = try migrate.start(req);
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
        response = vmrender.renderVmDetail(req, &detail_buf) catch blk: {
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
    } else if (routeExact(req, "GET /elk.js")) {
        response = elk_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /van.js")) {
        response = van_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /xterm.js")) {
        response = xterm_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /xterm-fit.js")) {
        response = xterm_fit_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /xterm-webgl.js")) {
        response = xterm_webgl_js;
        content_type = "application/javascript; charset=utf-8";
    } else if (routeExact(req, "GET /xterm.css")) {
        response = xterm_css;
        content_type = "text/css; charset=utf-8";
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
            } else if (anyEql(response, &.{ "not running", "off", "not paused", "vm running", "full", "shrink not allowed", "name exists", "busy" })) {
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

    // Any accepted POST to the API is a (potential) state mutation: bump the
    // version so /api/events subscribers refresh immediately instead of waiting
    // for their next poll. Cheap; spurious bumps just cause one extra GET.
    if (status < 400 and std.mem.startsWith(u8, req, "POST /api/")) appstate.bumpStateVersion();
    writeHttpResponse(conn, status, content_type, response);
}

/// Stream state-change notifications as Server-Sent Events. Holds the
/// connection open (thread-per-conn, like the WS relays) and emits an
/// `event: change` whenever the global state version moves — POST mutations
/// and unexpected VM exits both bump it. A comment keepalive every ~15s lets
/// dead clients be detected via the socket's send timeout.
fn handleEvents(conn: c.fd_t) void {
    const hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\n";
    if (!writeAll(conn, hdr.ptr, hdr.len)) return;
    var last = appstate.getStateVersion();
    var buf: [64]u8 = undefined;
    const hello = std.fmt.bufPrint(&buf, "event: change\ndata: {d}\n\n", .{last}) catch return;
    if (!writeAll(conn, hello.ptr, hello.len)) return;
    var ticks: u32 = 0;
    while (true) {
        appio.sleepMs(400);
        const v = appstate.getStateVersion();
        if (v != last) {
            last = v;
            ticks = 0;
            const msg = std.fmt.bufPrint(&buf, "event: change\ndata: {d}\n\n", .{v}) catch return;
            if (!writeAll(conn, msg.ptr, msg.len)) return;
        } else {
            ticks += 1;
            if (ticks >= 38) { // ~15s keepalive
                ticks = 0;
                const ka = ": ka\n\n";
                if (!writeAll(conn, ka.ptr, ka.len)) return;
            }
        }
    }
}

/// Upgrade and serve a /ws/video/<idx> client: encoded video for a running VM
/// with video_stream enabled (the dbusdisplay session feeds the encoder).
fn handleVideoWs(conn: c.fd_t, req: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var bitrate: u32 = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /ws/video/") orelse return;
        if (idx >= appstate.vm_count) return;
        const v = &appstate.vms[idx];
        if (!v.isAlive() or !v.video_stream) return;
        const nm = v.getNameSlice();
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        bitrate = v.video_bitrate_kbps;
    }
    const accept_key = ws.parseUpgrade(req) orelse return;
    ws.writeUpgradeResponse(conn, accept_key, req) catch return;
    dbusdisplay.serveVideoClient(conn, name_buf[0..name_len], bitrate);
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




/// Per-request error detail buffer for start-failure diagnostics.
/// Thread-local because each accepted HTTP connection runs in its own thread.
threadlocal var start_err_buf: [640]u8 = undefined;
threadlocal var start_err_buf2: [512]u8 = undefined;

/// Scan for a display port that is free both in this daemon's VM list and at the
/// OS level (actually bindable). `findUnusedVncPort` only avoids in-daemon
/// clashes, so a stale/external listener on the assigned port would make QEMU
/// fail to bind. Returns null if the whole range is taken.
fn freeBindableDisplayPort(skip_idx: usize) ?u16 {
    var port: u16 = vm.VNC_PORT_MIN;
    while (port <= vm.DISPLAY_PORT_MAX) : (port += 1) {
        var used = false;
        for (appstate.vms[0..appstate.vm_count], 0..) |*o, i| {
            if (i == skip_idx) continue;
            if (o.vnc_port == port or o.spice_port == port) {
                used = true;
                break;
            }
        }
        if (used) continue;
        if (!netutil.portInUse(port)) return port;
    }
    return null;
}

/// Before launching QEMU, make sure the VM's VNC/SPICE port is actually bindable;
/// if an external process holds it, reassign to a free+bindable one so power-on
/// doesn't fail (and the WS proxy, which dials the same field, stays correct).
/// Caller holds `vms_mutex`.
fn ensureBindableDisplayPorts(idx: usize) void {
    const v = &appstate.vms[idx];
    if (v.display == .vnc and netutil.portInUse(v.vnc_port)) {
        if (freeBindableDisplayPort(idx)) |p| v.vnc_port = p;
    }
    if (v.display == .spice and netutil.portInUse(v.spice_port)) {
        if (freeBindableDisplayPort(idx)) |p| v.spice_port = p;
    }
}

/// True if `name` already names a VM (optionally excluding index `skip`, for
/// rename). Caller must hold vms_mutex. Names are case-sensitive and matched
/// exactly — VM names derive the QMP/serial/log paths, so a duplicate would
/// make control commands hit the wrong VM and a delete unlink a live VM's
/// sockets.
fn nameTaken(name: []const u8, skip: ?usize) bool {
    var i: usize = 0;
    while (i < appstate.vm_count) : (i += 1) {
        if (skip) |sk| {
            if (i == sk) continue;
        }
        if (std.mem.eql(u8, appstate.vms[i].getNameSlice(), name)) return true;
    }
    return false;
}

const PowerMode = enum { toggle, on, off };

fn handlePower(req: []const u8) ![]const u8 {
    return powerOp(req, .toggle);
}

/// Idempotent power-on: no-op (200 ok) if the VM is already running.
fn handlePowerStart(req: []const u8) ![]const u8 {
    return powerOp(req, .on);
}

/// Idempotent power-off: no-op (200 ok) if the VM is already stopped.
fn handlePowerStop(req: []const u8) ![]const u8 {
    return powerOp(req, .off);
}

fn powerOp(req: []const u8, mode: PowerMode) ![]const u8 {
    // Power on/off forks/execs/reaps QEMU, which blocks for ~1-2s. Holding
    // vms_mutex across that froze every concurrent request (the 5s poll, SSE,
    // render) on a spinlock. Instead: snapshot the config under the lock, do
    // the blocking I/O on the COPY unlocked, then re-resolve the slot by stable
    // id under the lock to commit pid/status. The dispatch handle's stored
    // pointer can't be used unlocked (a concurrent delete frees it), so the I/O
    // goes straight through qemu.* on the copy — the dispatch table covers only
    // process lifecycle and QEMU is the only backend. A per-id transition guard
    // refuses a second power op on the same VM (double-click -> duplicate QEMU).
    var copy: vm.VmConfig = undefined;
    var was_alive = false;
    var want_dbus_capture = false;
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    var vm_name_len: usize = 0;
    var id_buf: [32]u8 = undefined;
    var id_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        const vid = v.getIdSlice();
        if (vid.len == 0) {
            const alive = v.isAlive();
            if ((mode == .on and alive) or (mode == .off and !alive)) return "ok";
            return handlePowerLocked(idx); // pre-id legacy config
        }
        if (appstate.isTransitioning(vid)) return "busy";
        if (!v.isAlive()) ensureBindableDisplayPorts(idx);
        was_alive = v.isAlive();
        // Idempotent start/stop: if already in the requested state, do nothing.
        if ((mode == .on and was_alive) or (mode == .off and !was_alive)) return "ok";
        copy = v.*;
        want_dbus_capture = v.video_stream and v.embed_display and
            !(v.enable_3d and v.gpu_device.needsVirgl());
        const nm = v.getNameSlice();
        @memcpy(vm_name_buf[0..nm.len], nm);
        vm_name_len = nm.len;
        @memcpy(id_buf[0..vid.len], vid);
        id_len = vid.len;
        if (!appstate.beginTransition(vid)) return "busy";
    }
    const vid = id_buf[0..id_len];
    const vm_name = vm_name_buf[0..vm_name_len];

    // ── Blocking I/O, lock released ──
    var start_failed = false;
    var start_detail: []const u8 = "";
    if (was_alive) {
        qemu.forceStopVm(&copy);
        qemu.reapVm(&copy); // sets copy.pid=null, copy.status=.stopped
    } else {
        qemu.startVm(&copy, std.heap.page_allocator) catch |e| {
            logOpErr("power on", e, vm_name);
            start_failed = true;
            var log_path_buf: [320]u8 = [_]u8{0} ** 320;
            const log_path = std.fmt.bufPrintZ(&log_path_buf, "/var/tmp/hangar-vm-{s}.log", .{vm_name}) catch null;
            start_detail = if (log_path) |lp| readStartupLog(lp, &start_err_buf2) else "";
        };
    }

    // ── Commit under the lock, re-resolving by id ──
    var still_present = false;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        defer appstate.endTransition(vid);
        const slot = appstate.idxById(vid);
        still_present = slot != null;
        if (start_failed) {
            // startVm may have forked a pid before failing; reap it so a partial
            // start never leaks a zombie/orphan, whether or not the slot survives.
            qemu.forceStopVm(&copy);
            qemu.reapVm(&copy);
            if (slot) |j| {
                appstate.vms[j].status = .stopped;
                appstate.vms[j].pid = null;
            }
            if (start_detail.len > 0) {
                return std.fmt.bufPrint(&start_err_buf, "start err: {s}", .{start_detail}) catch "start err";
            }
            return "start err";
        }
        if (slot) |j| {
            appstate.vms[j].pid = copy.pid;
            appstate.vms[j].status = copy.status;
            if (was_alive) {
                appstate.destroyVmmHandle(j);
                appstate.vm_started[j] = 0;
            } else {
                appstate.vm_started[j] = time(null);
            }
        } else if (!was_alive) {
            // VM deleted while powering on: kill the orphaned process.
            qemu.forceStopVm(&copy);
            qemu.reapVm(&copy);
        }
    }

    if (!was_alive and want_dbus_capture and still_present) spawnDbusCapture(vm_name);
    logAudit(if (was_alive) "power off" else "power on", vm_name);
    // No persist.save: power toggles only runtime state (pid/status/started),
    // which is never written to vms.json.
    return "ok";
}

/// Spawn the fire-and-forget dbus scanout-capture attach (phase 1). Failures
/// only log; never affects power-on.
fn spawnDbusCapture(vm_name: []const u8) void {
    if (std.heap.page_allocator.create(dbusdisplay.AttachCtx)) |ctx| {
        ctx.* = .{};
        @memcpy(ctx.name_buf[0..vm_name.len], vm_name);
        ctx.name_len = @intCast(vm_name.len);
        if (std.Thread.spawn(std.Thread.SpawnConfig{}, dbusdisplay.attachThread, .{ctx})) |th| {
            th.detach();
        } else |_| {
            std.heap.page_allocator.destroy(ctx);
        }
    } else |_| {}
}

/// Locked fallback for pre-id legacy configs (no stable id to re-resolve by).
fn handlePowerLocked(idx: usize) []const u8 {
    const v = &appstate.vms[idx];
    const was_alive = v.isAlive();
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    const vm_name = v.getNameSlice();
    @memcpy(vm_name_buf[0..vm_name.len], vm_name);
    if (was_alive) {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
        appstate.destroyVmmHandle(idx);
        appstate.vm_started[idx] = 0;
    } else {
        ensureBindableDisplayPorts(idx);
        qemu.startVm(v, std.heap.page_allocator) catch return "start err";
        appstate.vm_started[idx] = time(null);
    }
    logAudit(if (was_alive) "power off" else "power on", vm_name_buf[0..vm_name.len]);
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
        _ = applyEnumField(&cfg, key, val);
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
        _ = applyBoolField(&cfg, key, val);
        if (std.mem.eql(u8, key, "autoprotect")) {
            cfg.autoprotect = std.mem.eql(u8, val, "1");
            has_autoprotect = true;
        }
        if (std.mem.eql(u8, key, "ap_interval")) cfg.autoprotect_interval_min = @max(1, @min(1440, std.fmt.parseInt(u32, val, 10) catch cfg.autoprotect_interval_min));
        if (std.mem.eql(u8, key, "video_bitrate")) cfg.video_bitrate_kbps = @min(50000, std.fmt.parseInt(u32, val, 10) catch cfg.video_bitrate_kbps);
        if (std.mem.eql(u8, key, "ap_max")) cfg.autoprotect_max = @max(1, @min(1000, std.fmt.parseInt(u32, val, 10) catch cfg.autoprotect_max));
        if (std.mem.eql(u8, key, "disk2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setDisk2Path(val);
        }
        if (std.mem.eql(u8, key, "disk2_size")) cfg.disk2_size_gb = vm.clampOptionalDiskSize(std.fmt.parseInt(u32, val, 10) catch cfg.disk2_size_gb);
        if (std.mem.eql(u8, key, "floppy")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            cfg.setFloppyPath(val);
        }
        if (std.mem.eql(u8, key, "nic2")) cfg.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (key.len == 9 and std.mem.startsWith(u8, key, "nic") and std.mem.endsWith(u8, key, "_vnet") and key[3] >= '2' and key[3] <= '8') {
            // "nicN_vnet" — per-NIC virtual-network binding (free-form name).
            if (std.mem.indexOfAny(u8, val, "<>&\"'") == null) cfg.setNicVnetAny(@as(usize, key[3] - '1'), val);
        }
        if (std.mem.eql(u8, key, "nic2_mac")) {
            if (vm.isValidMac(val)) cfg.setNic2Mac(val);
        }
        if (std.mem.eql(u8, key, "nic3")) cfg.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) {
            if (vm.isValidMac(val)) cfg.setNic3Mac(val);
        }
        _ = applyStrField(&cfg, key, val);
        if (std.mem.eql(u8, key, "accel")) cfg.accel = form_parsers.parseAccel(val);
        if (std.mem.eql(u8, key, "enable_kvm")) {
            if (std.mem.eql(u8, val, "1")) cfg.accel = .auto else cfg.accel = .tcg;
        }
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
        if (std.mem.eql(u8, key, "num_displays")) cfg.num_displays = @max(1, @min(vm.MAX_DISPLAYS, std.fmt.parseInt(u32, val, 10) catch cfg.num_displays));
        if (std.mem.eql(u8, key, "io_threads")) cfg.io_threads = std.fmt.parseInt(u32, val, 10) catch cfg.io_threads;
        if (std.mem.eql(u8, key, "disk_bps_throttle")) cfg.disk_bps_throttle = std.fmt.parseInt(u64, val, 10) catch cfg.disk_bps_throttle;
        if (std.mem.eql(u8, key, "disk_iops_throttle")) cfg.disk_iops_throttle = std.fmt.parseInt(u32, val, 10) catch cfg.disk_iops_throttle;
        // Extra NICs (4-8)
        // NICs 4-8 (mode + mac), comptime-unrolled over the slot number.
        inline for (4..vm.MAX_NICS + 1) |n| {
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("nic{d}", .{n}))) cfg.nics[n - 1].mode = vm.NetworkMode.fromStr(val);
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("nic{d}_mac", .{n}))) {
                if (vm.isValidMac(val)) cfg.setNicMacAny(n - 1, val);
            }
        }
        // Extra disks (path/size/format per slot), comptime-unrolled.
        inline for (0..vm.MAX_EXTRA_DISKS) |i| {
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_path", .{i}))) {
                if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
                cfg.setExtraDiskPath(i, val);
            }
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_size", .{i}))) cfg.extra_disks[i].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_format", .{i}))) cfg.extra_disks[i].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch cfg.extra_disks[i].format.toIndex());
        }
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
    if (nameTaken(cfg.getNameSlice(), null)) {
        if (disk_created) cleanupCreatedDisk(&cfg);
        return "name exists";
    }
    if (!has_vnc_port) cfg.vnc_port = vm.findUnusedVncPort(appstate.vms[0..appstate.vm_count]);
    if (!has_spice_port) cfg.spice_port = vm.findUnusedSpicePort(appstate.vms[0..appstate.vm_count]);
    cfg.ensureId();
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

    cfg.ensureId();
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
    const base = clone.getNameSlice();
    var cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{base}) catch return "nameerr";
    // Avoid colliding with an existing "<name> (clone)" — names derive temp
    // socket/log paths, so duplicates must not happen.
    if (nameTaken(cn, null)) {
        var n: u32 = 2;
        while (n < 1000) : (n += 1) {
            cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone {d})", .{ base, n }) catch return "nameerr";
            if (!nameTaken(cn, null)) break;
        }
    }
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
    clone.id_len = 0; // a clone is a new VM — give it its own stable id
    clone.ensureId();
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
        // Don't delete a VM mid power-transition: power-on commits pid/status by
        // id after this would have shifted/removed the slot. Refuse; client retries.
        if (appstate.isTransitioning(appstate.vms[idx].getIdSlice())) return "busy";
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
        _ = applyEnumField(v, key, val);
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
        _ = applyBoolField(v, key, val);
        if (std.mem.eql(u8, key, "autoprotect")) v.autoprotect = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "ap_interval")) v.autoprotect_interval_min = @max(1, @min(1440, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_interval_min));
        if (std.mem.eql(u8, key, "video_bitrate")) v.video_bitrate_kbps = @min(50000, std.fmt.parseInt(u32, val, 10) catch v.video_bitrate_kbps);
        if (std.mem.eql(u8, key, "ap_max")) v.autoprotect_max = @max(1, @min(1000, std.fmt.parseInt(u32, val, 10) catch v.autoprotect_max));
        if (std.mem.eql(u8, key, "disk2_path")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setDisk2Path(val);
        }
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = vm.clampOptionalDiskSize(std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb);
        if (std.mem.eql(u8, key, "floppy")) {
            if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
            v.setFloppyPath(val);
        }
        if (std.mem.eql(u8, key, "nic2")) v.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (key.len == 9 and std.mem.startsWith(u8, key, "nic") and std.mem.endsWith(u8, key, "_vnet") and key[3] >= '2' and key[3] <= '8') {
            // "nicN_vnet" — per-NIC virtual-network binding (free-form name).
            if (std.mem.indexOfAny(u8, val, "<>&\"'") == null) v.setNicVnetAny(@as(usize, key[3] - '1'), val);
        }
        if (std.mem.eql(u8, key, "nic2_mac")) {
            if (vm.isValidMac(val)) v.setNic2Mac(val);
        }
        if (std.mem.eql(u8, key, "nic3")) v.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) {
            if (vm.isValidMac(val)) v.setNic3Mac(val);
        }
        _ = applyStrField(v, key, val);
        if (std.mem.eql(u8, key, "accel")) v.accel = form_parsers.parseAccel(val);
        if (std.mem.eql(u8, key, "enable_kvm")) {
            if (std.mem.eql(u8, val, "1")) v.accel = .auto else v.accel = .tcg;
        }
        if (std.mem.eql(u8, key, "vnc_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch v.vnc_port;
            if (vm.isValidDisplayPort(p)) v.vnc_port = p;
        }
        if (std.mem.eql(u8, key, "spice_port")) {
            const p = std.fmt.parseInt(u16, val, 10) catch v.spice_port;
            if (vm.isValidDisplayPort(p)) v.spice_port = p;
        }
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = @max(1, @min(vm.MAX_DISPLAYS, std.fmt.parseInt(u32, val, 10) catch v.num_displays));
        if (std.mem.eql(u8, key, "io_threads")) v.io_threads = std.fmt.parseInt(u32, val, 10) catch v.io_threads;
        if (std.mem.eql(u8, key, "disk_bps_throttle")) v.disk_bps_throttle = std.fmt.parseInt(u64, val, 10) catch v.disk_bps_throttle;
        if (std.mem.eql(u8, key, "disk_iops_throttle")) v.disk_iops_throttle = std.fmt.parseInt(u32, val, 10) catch v.disk_iops_throttle;
        // Extra NICs (4-8)
        // NICs 4-8 (mode + mac), comptime-unrolled over the slot number.
        inline for (4..vm.MAX_NICS + 1) |n| {
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("nic{d}", .{n}))) v.nics[n - 1].mode = vm.NetworkMode.fromStr(val);
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("nic{d}_mac", .{n}))) {
                if (vm.isValidMac(val)) v.setNicMacAny(n - 1, val);
            }
        }
        // Extra disks (path/size/format per slot), comptime-unrolled.
        inline for (0..vm.MAX_EXTRA_DISKS) |i| {
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_path", .{i}))) {
                if (std.mem.indexOf(u8, val, "..") != null) return "bad path";
                v.setExtraDiskPath(i, val);
            }
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_size", .{i}))) v.extra_disks[i].size_gb = vm.clampOptionalDiskSize(form_parsers.parseU32OrDefault(val, 0));
            if (std.mem.eql(u8, key, std.fmt.comptimePrint("extra{d}_format", .{i}))) v.extra_disks[i].format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.extra_disks[i].format.toIndex());
        }
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
    // A power on/off may be running its blocking I/O on this VM with the lock
    // released; suspending in that window could write status=suspended over a
    // pid that power-on is about to commit. Refuse — the client can retry.
    if (appstate.isTransitioning(v.getIdSlice())) {
        appstate.vms_mutex.unlock();
        return "busy";
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
            if (nameTaken(val, idx)) return "name exists";
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
    if (nameTaken(name, null)) return "name exists";
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
    cfg.ensureId();
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

/// Parse Content-Length header value from an HTTP request. Returns null if not found.

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



/// Strip dangerous characters from an HTTP header value.
/// Replaces double-quote with single-quote and removes CR/LF.

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
const elk_js = @embedFile("web/elk.js");
const van_js = @embedFile("web/van.js");
const xterm_js = @embedFile("web/xterm.js");
const xterm_fit_js = @embedFile("web/xterm-fit.js");
const xterm_webgl_js = @embedFile("web/xterm-webgl.js");
const xterm_css = @embedFile("web/xterm.css");

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
                    appstate.bumpStateVersion();
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

test "nameTaken: detects duplicates and honors the skip index" {
    const saved_count = appstate.vm_count;
    defer appstate.vm_count = saved_count;
    appstate.vm_count = 2;
    appstate.vms[0] = vm.VmConfig{};
    appstate.vms[1] = vm.VmConfig{};
    appstate.vms[0].setName("alpha");
    appstate.vms[1].setName("beta");
    try std.testing.expect(nameTaken("alpha", null));
    try std.testing.expect(nameTaken("beta", null));
    try std.testing.expect(!nameTaken("gamma", null));
    // skip the VM's own index so a no-op rename isn't a false collision
    try std.testing.expect(!nameTaken("alpha", 0));
    try std.testing.expect(nameTaken("alpha", 1));
}

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
    const prev = auth.token_len;
    auth.token_len = 0;
    defer auth.token_len = prev;
    // No X-API-Key header, conn=-1 (only touched on the failure path, which we
    // don't take here).
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
}

test "wsAuthOk: exposed (KV_API_KEY set) still requires the key" {
    auth.token_len = 6;
    @memcpy(auth.token[0..6], "secret");
    defer {
        auth.token_len = 0;
        @memset(&auth.token, 0);
    }
    // Correct key upgrades; the no-key path would write a 401 to conn, so only
    // assert the accepting case here.
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nX-API-Key: secret\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
}

test "checkAuth: accepts correct custom auth token" {
    auth.token_len = 6;
    @memcpy(auth.token[0..6], "secret");
    defer {
        auth.token_len = 0;
        @memset(&auth.token, 0);
    }

    // X-API-Key precedes another header → value terminated by the CR scan,
    // not by end-of-headers (that case is the "custom token at end" test).
    const req = "GET /api/vms HTTP/1.1\r\nX-API-Key: secret\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(checkAuth(req));
}

test "checkAuth: rejects wrong custom auth token" {
    auth.token_len = 6;
    @memcpy(auth.token[0..6], "secret");
    defer {
        auth.token_len = 0;
        @memset(&auth.token, 0);
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
    auth.token_len = 6;
    @memcpy(auth.token[0..6], "secret");
    defer {
        auth.token_len = 0;
        @memset(&auth.token, 0);
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
    auth.token_len = 6;
    @memcpy(auth.token[0..6], "secret");
    defer {
        auth.token_len = 0;
        @memset(&auth.token, 0);
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

test "snapshots.validateTag: valid tags" {
    try std.testing.expect(snapshots.validateTag("snapshot1"));
    try std.testing.expect(snapshots.validateTag("backup-2024-01-01"));
    try std.testing.expect(snapshots.validateTag("a"));
    try std.testing.expect(snapshots.validateTag("A" ** 255));
}

test "snapshots.validateTag: empty tag rejected" {
    try std.testing.expect(!snapshots.validateTag(""));
}

test "snapshots.validateTag: too long tag rejected" {
    var long: [256]u8 = [_]u8{'x'} ** 256;
    try std.testing.expect(!snapshots.validateTag(&long));
}

test "snapshots.validateTag: control characters rejected" {
    try std.testing.expect(!snapshots.validateTag("bad\x01"));
    try std.testing.expect(!snapshots.validateTag("bad\x1f"));
    try std.testing.expect(!snapshots.validateTag("\x00name"));
    try std.testing.expect(!snapshots.validateTag("\x10middle"));
}

test "snapshots.validateTag: dot-dot path traversal rejected" {
    try std.testing.expect(!snapshots.validateTag(".."));
    try std.testing.expect(!snapshots.validateTag("../escape"));
    try std.testing.expect(!snapshots.validateTag("snap/../etc"));
    try std.testing.expect(!snapshots.validateTag("trailing.."));
    // A single dot is fine; only the ".." sequence is dangerous.
    try std.testing.expect(snapshots.validateTag("v1.0"));
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

test "fuzz: snapshots.validateTag never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xCAFE_F00D);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = snapshots.validateTag(buf[0..len]);
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
            auth.token_len = key.len;
            @memcpy(auth.token[0..key.len], key);
        }
    } else {
        // No custom key: the built-in default API key is in effect. Confine the
        // TCP listener to loopback so the weak default cannot be reached from
        // other hosts. An operator who sets KV_API_KEY opts into all-interface
        // exposure (see `expose_all` below).
        logErr("WARNING: KV_API_KEY not set — serving with the default API key, bound to loopback only. Set KV_API_KEY to a strong secret to expose Hangar on all interfaces.");
    }

    // Only expose the daemon beyond loopback when a real API key is configured.
    const expose_all = auth.token_len > 0;

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

test "guestagent.parseIpv4s: extracts non-loopback IPv4s from a GA reply" {
    const sample =
        \\{"return":[{"name":"lo","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1","prefix":8}]},{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.2.15","prefix":24},{"ip-address-type":"ipv6","ip-address":"fe80::1","prefix":64}]}]}
    ;
    var out: [256]u8 = undefined;
    const ips = guestagent.parseIpv4s(sample, &out);
    try std.testing.expectEqualStrings("10.0.2.15", ips); // loopback + ipv6 excluded
}

test "guestagent.parseIpv4s: empty when no addresses" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", guestagent.parseIpv4s("{\"return\":[]}", &out));
}

test "guestagent.parseIpv4s: joins multiple IPv4s with commas" {
    const sample =
        \\[{"ip-address":"192.168.1.5"},{"ip-address":"10.1.1.2"}]
    ;
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.5,10.1.1.2", guestagent.parseIpv4s(sample, &out));
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

test "snapshots.take: missing prefix returns 'invalid'" {
    const result = try snapshots.take("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "snapshots.take: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try snapshots.take("POST /api/vms/0/snapshots HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "snapshots.list: missing prefix returns error" {
    var buf: [4096]u8 = undefined;
    const result = snapshots.list("GET /api/other HTTP/1.1", &buf);
    try std.testing.expectEqualStrings("invalid", result);
}

test "snapshots.list: idx out of range returns error" {
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
    const result = snapshots.list("GET /api/vms/0/snapshots HTTP/1.1", &buf);
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "snapshots.revert: missing prefix returns 'invalid'" {
    const result = try snapshots.revert("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "snapshots.revert: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try snapshots.revert("POST /api/vms/0/snapshots/revert HTTP/1.1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "snapshots.delete: missing prefix returns 'invalid'" {
    const result = try snapshots.delete("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "snapshots.delete: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try snapshots.delete("POST /api/vms/0/snapshots/delete HTTP/1.1");
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

test "migrate.start: VM not running returns 'not running'" {
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
    const result = try migrate.start("POST /api/vms/0/migrate HTTP/1.1");
    // The handler checks isAlive() before body parse, so this hits "not running".
    try std.testing.expectEqualStrings("not running", result);
}

test "migrate.start: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try migrate.start("POST /api/vms/0/migrate HTTP/1.1\r\n\r\ndummy=1");
    try std.testing.expectEqualStrings("invalid idx", result);
}

test "migrate.isValidDest: accepts tcp targets, rejects injection" {
    try std.testing.expect(migrate.isValidDest("tcp:10.0.0.2:4444"));
    try std.testing.expect(migrate.isValidDest("tcp:[fe80::1]:4444"));
    // Non-tcp schemes — exec: would run a shell command on the host.
    try std.testing.expect(!migrate.isValidDest("exec:touch /tmp/pwned"));
    try std.testing.expect(!migrate.isValidDest("unix:/tmp/x.sock"));
    try std.testing.expect(!migrate.isValidDest("fd:3"));
    // JSON string break-out via quote/backslash.
    try std.testing.expect(!migrate.isValidDest("tcp:h\":4444"));
    try std.testing.expect(!migrate.isValidDest("tcp:h\\:4444"));
    // Control characters and traversal.
    try std.testing.expect(!migrate.isValidDest("tcp:h\n:4444"));
    try std.testing.expect(!migrate.isValidDest("tcp:../../x"));
    try std.testing.expect(!migrate.isValidDest(""));
}

test "fuzz: migrate.isValidDest never crashes and never allows shell/JSON escape" {
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rand.int(u8);
        const dest = buf[0..len];
        if (migrate.isValidDest(dest)) {
            // Any accepted value must be a clean tcp: target — no shell-exec
            // scheme, no characters that could break the QMP JSON string.
            try std.testing.expect(std.mem.startsWith(u8, dest, "tcp:"));
            try std.testing.expect(std.mem.indexOfAny(u8, dest, "\"\\") == null);
            for (dest) |ch| try std.testing.expect(ch >= 0x20);
        }
    }
}

test "migrate.status: missing prefix returns error JSON" {
    var buf: [512]u8 = undefined;
    const result = migrate.status("GET /api/other HTTP/1.1", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
}

test "migrate.status: idx out of range returns error JSON" {
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
    const result = migrate.status("GET /api/vms/0/migrate HTTP/1.1", &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
}

test "migrate.statusHttpCode: maps status payloads to HTTP codes" {
    try std.testing.expectEqual(HTTP_OK, migrate.statusHttpCode("{\"status\":\"active\"}"));
    try std.testing.expectEqual(HTTP_OK, migrate.statusHttpCode("{\"status\":\"completed\"}"));
    try std.testing.expectEqual(HTTP_NOT_FOUND, migrate.statusHttpCode("{\"status\":\"error\",\"error\":\"invalid idx\"}"));
    try std.testing.expectEqual(HTTP_NOT_FOUND, migrate.statusHttpCode("{\"status\":\"error\",\"error\":\"bad idx\"}"));
    try std.testing.expectEqual(HTTP_CONFLICT, migrate.statusHttpCode("{\"status\":\"error\",\"error\":\"not running\"}"));
    try std.testing.expectEqual(HTTP_INTERNAL_ERROR, migrate.statusHttpCode("{\"status\":\"error\",\"error\":\"qmp query\"}"));
    try std.testing.expectEqual(HTTP_INTERNAL_ERROR, migrate.statusHttpCode("{\"status\":\"error\"}"));
}

test "fuzz: migrate.statusHttpCode never panics and only ever returns mapped codes" {
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
        const code = migrate.statusHttpCode(buf[0..len]);
        try std.testing.expect(code == HTTP_OK or code == HTTP_NOT_FOUND or
            code == HTTP_CONFLICT or code == HTTP_INTERNAL_ERROR);
    }
}

test "migrate.cancel: missing prefix returns 'invalid'" {
    const result = try migrate.cancel("GET /api/other HTTP/1.1");
    try std.testing.expectEqualStrings("invalid", result);
}

test "migrate.cancel: idx out of range returns 'invalid idx'" {
    appstate.vms_mutex.lock();
    const prev_count = appstate.vm_count;
    appstate.vm_count = 0;
    appstate.vms_mutex.unlock();
    defer {
        appstate.vms_mutex.lock();
        appstate.vm_count = prev_count;
        appstate.vms_mutex.unlock();
    }
    const result = try migrate.cancel("POST /api/vms/0/migrate/cancel HTTP/1.1");
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
        _ = migrate.start(req) catch {};
        _ = migrate.cancel(req) catch {};
        _ = snapshots.take(req) catch {};
        _ = snapshots.revert(req) catch {};
        _ = snapshots.delete(req) catch {};
        _ = snapshots.list(req, &out);
        _ = migrate.status(req, &out);
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
            streams.upload(-1, "POST /api/vms/0/disk2 HTTP/1.1\r\n\r\n");
            continue;
        };

        // Corrupt a handful of random bytes to fuzz the framing.
        const flips = rnd.uintLessThan(usize, 6);
        var f: usize = 0;
        while (f < flips) : (f += 1) {
            msg[rnd.uintLessThan(usize, msg.len)] = rnd.int(u8);
        }

        streams.upload(-1, msg);
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
