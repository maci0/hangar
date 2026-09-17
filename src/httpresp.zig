//! HTTP status codes + response writing for the daemon. One header block is
//! assembled and written with the body in two syscalls, carrying the fixed
//! security headers (nosniff / DENY / CSP) and per-content-type caching policy.
//! Leaf module (std only) so handlers and split-out handler modules share it.

const std = @import("std");
const c = std.c;
const wlog = @import("wlog.zig");
const sync = @import("sync.zig");

var etag_mutex = sync.SpinMutex{};

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

/// Format an error message as a JSON object: {"error":"<msg>"}. The message is
/// JSON-escaped (quotes, backslash, control bytes) so a status token carrying
/// one can never produce an invalid response body. The envelope wraps the
/// escape scratch in `buf`; a message that cannot fit (or a buffer too small
/// for the envelope itself) falls back to the static `{"error":"internal"}`.
pub fn jsonErr(buf: []u8, msg: []const u8) []const u8 {
    const prefix = "{\"error\":\"";
    const suffix = "\"}";
    if (buf.len < prefix.len + suffix.len) return "{\"error\":\"internal\"}";
    const esc = jsonEscape(buf[prefix.len .. buf.len - suffix.len], msg);
    if (esc.truncated) return "{\"error\":\"internal\"}";
    const end = prefix.len + esc.escaped.len;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[end..][0..suffix.len], suffix);
    return buf[0 .. end + suffix.len];
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

/// Write a static asset guarded by a strong content hash: the ETag is
/// `"<8-byte sha256, hex>"`, computed lazily on first use and cached for the
/// process lifetime (embedded bytes never change). A request whose
/// `If-None-Match` carries exactly that tag gets a header-only 304, so an
/// unchanged asset costs ~100 header bytes instead of a full re-download.
pub fn writeHttpAssetResponse(
    conn: c.fd_t,
    status: u16,
    ct: []const u8,
    body: []const u8,
    etag_storage: *?[]const u8,
    req: []const u8,
) void {
    etag_mutex.lock();
    if (etag_storage.* == null) {
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &hash_bytes, .{});
        const hex_digits = "0123456789abcdef";
        var tag_buf: [18]u8 = undefined;
        tag_buf[0] = '"';
        for (hash_bytes[0..8], 0..) |b, i| {
            tag_buf[1 + i * 2] = hex_digits[b >> 4];
            tag_buf[2 + i * 2] = hex_digits[b & 0x0F];
        }
        tag_buf[17] = '"';
        etag_storage.* = std.heap.page_allocator.dupe(u8, &tag_buf) catch null;
    }
    const etag = etag_storage.*;
    etag_mutex.unlock();
    if (etag) |tag| {
        if (etagMatches(req, tag)) {
            write304Response(conn, tag);
            return;
        }
    }
    writeHttpResponseTagged(conn, status, ct, body, etag);
}

/// True when the request's `If-None-Match` header carries the exact tag.
/// Strong comparison (RFC 9110 §8.8.3): byte equality, no weak-star handling.
fn etagMatches(req: []const u8, tag: []const u8) bool {
    const needle = "If-None-Match: ";
    const idx = std.mem.indexOf(u8, req, needle) orelse return false;
    const rest = req[idx + needle.len ..];
    const end = std.mem.indexOf(u8, rest, "\r\n") orelse rest.len;
    return std.mem.eql(u8, std.mem.trim(u8, rest[0..end], " "), tag);
}

/// Emit a 304 with the validators a conditional asset request expects.
fn write304Response(conn: c.fd_t, tag: []const u8) void {
    var hbuf: [512]u8 = undefined;
    var id_buf: [48]u8 = undefined;
    const id_header = if (wlog.requestId() != 0)
        std.fmt.bufPrint(&id_buf, "X-Request-ID: {d}\r\n", .{wlog.requestId()}) catch unreachable
    else
        "";
    const head = std.fmt.bufPrint(
        &hbuf,
        "HTTP/1.1 304 Not Modified\r\n{s}ETag: {s}\r\nCache-Control: public, no-cache\r\nConnection: close\r\n\r\n",
        .{ id_header, tag },
    ) catch "HTTP/1.1 304 Not Modified\r\nConnection: close\r\n\r\n";
    wlog.logResponse(304, writeAll(conn, head.ptr, head.len));
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
    writeHttpResponseTagged(conn, status, ct, body, null);
}

/// writeHttpResponse plus a strong ETag for immutable embedded assets. `etag`
/// (a quoted token, e.g. `"1a2b…"`) adds an `ETag` header; everything else is
/// identical to `writeHttpResponse`, including logging the wire status.
pub fn writeHttpResponseTagged(conn: c.fd_t, status: u16, ct: []const u8, body: []const u8, etag: ?[]const u8) void {
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
    // set is well under 1 KiB even with the CSP string and an ETag.
    var hbuf: [1152]u8 = undefined;
    var hlen: usize = 0;
    const append = struct {
        fn add(b: []u8, n: *usize, s: []const u8) void {
            if (n.* + s.len > b.len) return; // header set is bounded; never trips
            @memcpy(b[n.*..][0..s.len], s);
            n.* += s.len;
        }
    }.add;

    append(&hbuf, &hlen, status_line);
    if (wlog.requestId() != 0) {
        var id_buf: [48]u8 = undefined;
        append(&hbuf, &hlen, std.fmt.bufPrint(&id_buf, "X-Request-ID: {d}\r\n", .{wlog.requestId()}) catch unreachable);
    }
    append(&hbuf, &hlen, "X-Content-Type-Options: nosniff\r\n");
    append(&hbuf, &hlen, "X-Frame-Options: DENY\r\n");
    if (etag) |tag| {
        append(&hbuf, &hlen, "ETag: ");
        append(&hbuf, &hlen, tag);
        append(&hbuf, &hlen, "\r\n");
    }
    append(&hbuf, &hlen, "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'none'; form-action 'self'; base-uri 'self'\r\n");
    append(&hbuf, &hlen, "Content-Type: ");
    append(&hbuf, &hlen, ct);
    append(&hbuf, &hlen, "\r\nServer: hangar");
    if (std.mem.indexOf(u8, ct, "text/css") != null or std.mem.indexOf(u8, ct, "application/javascript") != null or std.mem.indexOf(u8, ct, "image/svg+xml") != null) {
        append(&hbuf, &hlen, "\r\nCache-Control: public, no-cache");
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

    const sent = writeAll(conn, hbuf[0..hlen].ptr, hlen) and writeAll(conn, body.ptr, body.len);
    const wire_status = std.fmt.parseInt(u16, status_line[9..12], 10) catch unreachable;
    wlog.logResponse(wire_status, sent);
}

// ── Tests ───────────────────────────────────────────────────────────

test "httpresp: jsonErr wraps the message" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"error\":\"nope\"}", jsonErr(&buf, "nope"));
}

test "httpresp: jsonErr escapes message characters" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"error\":\"quote \\\" slash \\\\ newline \\n control \\u0001\"}", jsonErr(&buf, "quote \" slash \\ newline \n control \x01"));
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

test "fuzz: jsonErr output is always valid JSON for arbitrary tokens" {
    // Error messages can carry untrusted detail (QEMU log text, paths). The
    // envelope must stay parseable JSON no matter what bytes flow through it.
    var prng = std.Random.DefaultPrng.init(0x4A50_E12);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        const out = jsonErr(buf[0..len], buf[0..len]);
        try std.testing.expect(std.mem.startsWith(u8, out, "{\"error\":\""));
        try std.testing.expect(std.mem.endsWith(u8, out, "\"}"));
        for (out, 0..) |ch, j| {
            if (j < 10 or j + 2 >= out.len) continue; // envelope quotes checked above
            try std.testing.expect(ch != '"');
            try std.testing.expect(ch >= 0x20);
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

/// Drain a pipe to EOF and return what was read. The caller closes the write
/// end (after the handler returns) and the read end.
fn drainPipe(drain_fd: c.fd_t, out: []u8) ![]u8 {
    var total: usize = 0;
    while (total < out.len) {
        const n = c.read(drain_fd, out.ptr + total, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return out[0..total];
}

test "httpresp: writeHttpAssetResponse serves 200 with ETag, then 304 on If-None-Match" {
    const body = "body-bytes-for-etag-test";
    var etag_storage: ?[]const u8 = null;

    // First request: full 200 response carrying the strong ETag.
    var fds1: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds1));
    const req1 = "GET /app.js HTTP/1.1\r\nHost: localhost\r\n\r\n";
    writeHttpAssetResponse(fds1[1], HTTP_OK, "application/javascript; charset=utf-8", body, &etag_storage, req1);
    try std.testing.expect(etag_storage != null);
    var resp_buf: [4096]u8 = undefined;
    _ = c.close(fds1[1]);
    const resp1 = try drainPipe(fds1[0], &resp_buf);
    _ = c.close(fds1[0]);
    const tag = etag_storage.?;
    try std.testing.expect(tag.len > 2 and tag[0] == '"' and tag[tag.len - 1] == '"');
    try std.testing.expect(std.mem.startsWith(u8, resp1, "HTTP/1.1 200 OK\r\n"));
    const hdr_tag = std.mem.indexOf(u8, resp1, "ETag: ") orelse return error.MissingEtag;
    try std.testing.expect(std.mem.startsWith(u8, resp1[hdr_tag + 6 ..], tag));
    try std.testing.expect(std.mem.endsWith(u8, resp1, body));
    try std.testing.expect(std.mem.indexOf(u8, resp1, "Cache-Control: public, no-cache\r\n") != null);

    // Second request holding the same tag: header-only 304, no body bytes.
    var fds2: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds2));
    var req_buf: [256]u8 = undefined;
    const req2 = try std.fmt.bufPrint(&req_buf, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: {s}\r\n\r\n", .{tag});
    wlog.beginRequest(req2);
    defer wlog.endRequest();
    var id_buf: [48]u8 = undefined;
    const id_header = try std.fmt.bufPrint(&id_buf, "X-Request-ID: {d}\r\n", .{wlog.requestId()});
    writeHttpAssetResponse(fds2[1], HTTP_OK, "application/javascript; charset=utf-8", body, &etag_storage, req2);
    _ = c.close(fds2[1]);
    const resp2 = try drainPipe(fds2[0], &resp_buf);
    _ = c.close(fds2[0]);
    try std.testing.expect(std.mem.startsWith(u8, resp2, "HTTP/1.1 304 Not Modified\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp2, id_header) != null);
    try std.testing.expect(std.mem.indexOf(u8, resp2, body) == null);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "Cache-Control: public, no-cache\r\n") != null);

    // Stale or malformed validators must fall through to the full response.
    var fds3: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds3));
    const req3 = "GET /app.js HTTP/1.1\r\nIf-None-Match: \"stale\"\r\n\r\n";
    writeHttpAssetResponse(fds3[1], HTTP_OK, "application/javascript; charset=utf-8", body, &etag_storage, req3);
    _ = c.close(fds3[1]);
    const resp3 = try drainPipe(fds3[0], &resp_buf);
    _ = c.close(fds3[0]);
    try std.testing.expect(std.mem.startsWith(u8, resp3, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, resp3, body));

    if (etag_storage) |allocated| std.heap.page_allocator.free(allocated);
}

test "httpresp: failed conditional asset send logs correlated wire outcome" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    const saved_log_fd = wlog.log_fd;
    wlog.log_fd = fds[1];
    defer wlog.log_fd = saved_log_fd;

    const req = "GET /app.js HTTP/1.1\r\nIf-None-Match: \"cached\"\r\n\r\n";
    wlog.beginRequest(req);
    defer wlog.endRequest();
    var id_buf: [48]u8 = undefined;
    const correlation = try std.fmt.bufPrint(&id_buf, "request_id={d} ", .{wlog.requestId()});
    var etag: ?[]const u8 = "\"cached\"";
    writeHttpAssetResponse(-1, HTTP_OK, "application/javascript", "body", &etag, req);
    _ = c.close(fds[1]);
    wlog.log_fd = -1;

    var buf: [1024]u8 = undefined;
    const line = try drainPipe(fds[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "hangar warn: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, correlation) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "http_response status=304 duration_ms=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "sent=false request=[GET /app.js HTTP/1.1]") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}
