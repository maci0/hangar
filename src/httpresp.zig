//! HTTP status codes + response writing for the daemon. One header block is
//! assembled and written with the body in two syscalls, carrying the fixed
//! security headers (nosniff / DENY / CSP) and per-content-type caching policy.
//! Leaf module (std only) so handlers and split-out handler modules share it.

const std = @import("std");
const c = std.c;

pub const HTTP_OK: u16 = 200;
pub const HTTP_CREATED: u16 = 201;
pub const HTTP_BAD_REQUEST: u16 = 400;
pub const HTTP_UNAUTHORIZED: u16 = 401;
pub const HTTP_FORBIDDEN: u16 = 403;
pub const HTTP_NOT_FOUND: u16 = 404;
pub const HTTP_METHOD_NOT_ALLOWED: u16 = 405;
pub const HTTP_CONFLICT: u16 = 409;
pub const HTTP_PAYLOAD_TOO_LARGE: u16 = 413;
pub const HTTP_TOO_MANY_REQUESTS: u16 = 429;
pub const HTTP_INTERNAL_ERROR: u16 = 500;
pub const HTTP_SERVICE_UNAVAILABLE: u16 = 503;

/// Write exactly `len` bytes to fd, retrying on short writes. Returns false on failure.
pub fn writeAll(conn: c.fd_t, buf: [*]const u8, len: usize) bool {
    var written: usize = 0;
    while (written < len) {
        const n = c.write(conn, buf + written, len - written);
        if (n <= 0) return false;
        written += @intCast(n);
    }
    return true;
}

/// Format an error message as a JSON object: {"error":"<msg>"}. Returns a slice
/// of `buf` (needs msg.len + 12 bytes); falls back to a static string on overflow.
pub fn jsonErr(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"internal\"}";
}

/// Result of `jsonEscape`: the escaped slice + whether output was truncated to
/// fit the buffer (callers that must not emit broken JSON check this).
pub const EscapeResult = struct {
    escaped: []const u8,
    truncated: bool,
};

/// Escape a string for safe inclusion in a JSON string value. Escapes `"` `\`
/// `\n` `\r` `\t` and control chars (→ `\u00XX`). Writes into `buf`; sets
/// `truncated` if `buf` was too small (output stops at the last whole escape).
pub fn jsonEscape(buf: []u8, s: []const u8) EscapeResult {
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
                // Control character → \u00XX
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

/// True if a handler status token denotes a server-side fault (→ HTTP 500)
/// rather than a client mistake (→ 400). The central dispatch error mapper and
/// the upload error reply both classify tokens through this one list.
pub fn isServerErrToken(response: []const u8) bool {
    if (std.mem.startsWith(u8, response, "start err")) return true; // incl. "start err: <detail>"
    const tokens = [_][]const u8{
        "apply err",  "bd err",      "cad err",     "cancel err",
        "create err", "delete err",  "linkerr",     "migrate err",
        "nameerr",    "path err",    "qmp err",     "sock err",
        "write err",  "change err",  "eject err",   "resize err",
        "upload err", "save failed", "compact err", "internal err",
    };
    for (tokens) |t| {
        if (std.mem.eql(u8, response, t)) return true;
    }
    return false;
}

/// Sanitize a value for safe inclusion in a response header: drop CR/LF (header
/// injection) and turn `"` into `'` (so it can't break a quoted parameter like
/// Content-Disposition filename="..."). Returns a slice of `buf`.
pub fn sanitizeHeaderValue(buf: []u8, s: []const u8) []const u8 {
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

/// Write a full HTTP/1.1 response (status line + security headers + content-type
/// + caching policy + body) to the connection in two writes.
pub fn writeHttpResponse(conn: c.fd_t, status: u16, ct: []const u8, body: []const u8) void {
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
        HTTP_SERVICE_UNAVAILABLE => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };
    // Assemble the full header block in one buffer so the response costs two
    // write() syscalls (headers + body) instead of ~11 small writes. The header
    // set is well under 1 KiB even with the CSP string.
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
        // Dynamic responses (API JSON, errors) carry auth-gated VM state, disk
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

// ── Tests ───────────────────────────────────────────────────────────

test "httpresp: jsonErr wraps the message" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"error\":\"nope\"}", jsonErr(&buf, "nope"));
}

test "httpresp: jsonEscape escapes quotes/backslash/control, flags truncation" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\\\"b", jsonEscape(&buf, "a\"b").escaped);
    try std.testing.expectEqualStrings("\\n\\t\\\\", jsonEscape(&buf, "\n\t\\").escaped);
    try std.testing.expectEqualStrings("\\u0000", jsonEscape(&buf, "\x00").escaped);
    var tiny: [1]u8 = undefined;
    try std.testing.expect(jsonEscape(&tiny, "\"x").truncated);
}

test "fuzz: sanitizeHeaderValue never leaks CR/LF/quote and stays within buf" {
    // Header-injection (CWE-113) boundary: VM names / filenames flow into
    // response headers (Content-Disposition). The output must never carry a
    // bare CR, LF, or `"` no matter the input, and must fit the caller buffer.
    var prng = std.Random.DefaultPrng.init(0xDEADBE12);
    const rnd = prng.random();
    var in_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const in_len = rnd.uintLessThan(usize, in_buf.len + 1);
        for (in_buf[0..in_len]) |*b| b.* = rnd.int(u8);
        // Vary the output capacity to exercise the truncation cutoff.
        const out_cap = rnd.uintLessThan(usize, out_buf.len + 1);
        const out = sanitizeHeaderValue(out_buf[0..out_cap], in_buf[0..in_len]);
        try std.testing.expect(out.len <= out_cap);
        for (out) |ch| {
            try std.testing.expect(ch != '\r' and ch != '\n' and ch != '"');
        }
    }
}

test "fuzz: isServerErrToken never panics on random response bytes" {
    var prng = std.Random.DefaultPrng.init(0x500_E12);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = isServerErrToken(buf[0..len]);
    }
}
