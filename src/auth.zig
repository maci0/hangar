//! API authentication + origin gating for the daemon. Holds the configured
//! `KV_API_KEY` token (empty = loopback mode, built-in default key) and the
//! checks that gate every request: constant-time key comparison, the GET-exempt
//! allowlist, the loopback Host allowlist (anti-DNS-rebinding), and the
//! WebSocket-upgrade gate.

const std = @import("std");
const c = std.c;
const transport = @import("transport.zig");
const httpreq = @import("httpreq.zig");
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");

/// Built-in X-API-Key default (loopback-only; treated as "unset" for exposure).
pub const API_KEY: []const u8 = transport.DEFAULT_API_KEY;

/// The configured custom key. `token_len == 0` means loopback mode (no custom
/// key set): the daemon binds loopback only and accepts the built-in default.
/// Written once at startup from KV_API_KEY (and by tests).
pub var token: [64]u8 = [_]u8{0} ** 64;
pub var token_len: usize = 0;

/// True when a custom key is configured (daemon intentionally exposed).
pub fn isExposed() bool {
    return token_len > 0;
}

/// Validate a `KV_API_KEY` value: 1-64 bytes of printable ASCII (no control
/// chars, no spaces). Rejecting whitespace/control bytes fails fast on the
/// common footgun of a trailing newline from `export KV_API_KEY=$(cat keyfile)`.
pub fn validApiKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Length-checked, constant-time byte-slice equality. The comparison must not
/// early-exit on the first differing byte: it runs on the network-exposed
/// daemon, where a short-circuit would leak the secret via response timing.
pub fn secretEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Validate the request's `Host` header against the loopback allowlist. Only
/// enforced in loopback mode (no custom key); closes a DNS-rebinding hole
/// (CWE-350/1385). When a key is set, the secret — not the origin — is the
/// control, so the check is skipped.
pub fn hostHeaderOk(req: []const u8) bool {
    if (token_len > 0) return true; // exposed mode: secret key gates access
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse req.len;
    const host = httpreq.findHeader(req[0..hdr_end], "Host: ") orelse return false;
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

/// True if the request carries a valid `X-API-Key` (custom token if set, else
/// the built-in default).
pub fn checkAuth(req: []const u8) bool {
    const hdr_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return false;
    const headers = req[0..hdr_end];
    const provided = httpreq.findHeader(headers, "X-API-Key: ") orelse return false;
    const expected = if (token_len > 0) token[0..token_len] else API_KEY;
    return secretEql(provided, expected);
}

/// True if a GET endpoint is exempt from auth (static assets + read-only,
/// non-sensitive API reads). Sensitive reads (disk download, framebuffer,
/// screenshot, guestinfo, migrate status) are never exempt.
pub fn isAuthExempt(method_get: bool, path: []const u8) bool {
    if (!method_get) return false; // only GET endpoints are exempt
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.eql(u8, path, "/app.js")) return true;
    if (std.mem.eql(u8, path, "/novnc.js")) return true;
    if (std.mem.eql(u8, path, "/spice.js")) return true;
    if (std.mem.eql(u8, path, "/elk.js")) return true;
    if (std.mem.eql(u8, path, "/van.js")) return true;
    if (std.mem.eql(u8, path, "/app.css")) return true;
    if (std.mem.startsWith(u8, path, "/favicon")) return true;
    if (std.mem.eql(u8, path, "/api/vms")) return true;
    if (std.mem.eql(u8, path, "/api/capabilities")) return true;
    if (std.mem.eql(u8, path, "/api/health")) return true;
    if (std.mem.eql(u8, path, "/api/events")) return true;
    if (std.mem.eql(u8, path, "/api/config")) return true;
    if (std.mem.eql(u8, path, "/api/catalog")) return true;
    if (std.mem.eql(u8, path, "/api/networks")) return true;
    if (std.mem.startsWith(u8, path, "/api/vms/")) {
        const p = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
        if (std.mem.endsWith(u8, p, "/disk2/download")) return false;
        if (std.mem.endsWith(u8, p, "/framebuffer")) return false;
        if (std.mem.endsWith(u8, p, "/migrate")) return false;
        if (std.mem.endsWith(u8, p, "/screenshot")) return false;
        if (std.mem.endsWith(u8, p, "/guestinfo")) return false;
        return true; // detail, /log, /snapshots are read-only and exempt
    }
    return false;
}

/// Auth-gate a WebSocket route. On failure logs the rejected `route`, writes a
/// 401, and returns false. In loopback mode the upgrade is allowed without a key
/// (browsers can't set headers on a WS handshake; the Host allowlist already
/// gates origin).
pub fn wsAuthOk(conn: c.fd_t, req: []const u8, route: []const u8) bool {
    if (token_len == 0) return true;
    if (checkAuth(req)) return true;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "auth rejected: GET {s}", .{route}) catch "auth rejected: GET /ws";
    wlog.logWarn(msg);
    httpresp.writeHttpResponse(conn, httpresp.HTTP_UNAUTHORIZED, "application/json; charset=utf-8", "{\"error\":\"auth required\"}");
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────

test "auth: validApiKey bounds + character class" {
    try std.testing.expect(validApiKey("hangar"));
    try std.testing.expect(validApiKey("S3cr3t-Key_With.Symbols!~"));
    try std.testing.expect(validApiKey("x" ** 64));
    try std.testing.expect(!validApiKey(""));
    try std.testing.expect(!validApiKey("x" ** 65));
    try std.testing.expect(!validApiKey("secret\n"));
    try std.testing.expect(!validApiKey("two words"));
}

test "auth: secretEql is length-checked equality" {
    try std.testing.expect(secretEql("abc", "abc"));
    try std.testing.expect(!secretEql("abc", "abd"));
    try std.testing.expect(!secretEql("abc", "ab"));
}

test "auth: isAuthExempt — static + safe reads exempt, sensitive not" {
    try std.testing.expect(isAuthExempt(true, "/"));
    try std.testing.expect(isAuthExempt(true, "/api/vms"));
    try std.testing.expect(isAuthExempt(true, "/api/events"));
    try std.testing.expect(isAuthExempt(true, "/api/vms/0/log"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/disk2/download"));
    try std.testing.expect(!isAuthExempt(true, "/api/vms/0/screenshot"));
    try std.testing.expect(!isAuthExempt(false, "/api/vms")); // POST never exempt
}

test "auth: wsAuthOk allows keyless upgrade in loopback, requires key when set" {
    const prev = token_len;
    token_len = 0;
    defer token_len = prev;
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
    token_len = 6;
    @memcpy(token[0..6], "secret");
    defer {
        token_len = 0;
        @memset(&token, 0);
    }
    try std.testing.expect(!wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
    try std.testing.expect(wsAuthOk(-1, "GET /ws/vnc/0 HTTP/1.1\r\nX-API-Key: secret\r\nHost: localhost\r\n\r\n", "/ws/vnc"));
}
