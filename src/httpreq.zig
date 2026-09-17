//! Pure HTTP request-line / header / route parsing helpers shared by the daemon.
//! Leaf module (std only) so handlers and any future split-out handler modules
//! can use these without depending on web_server.zig. web_server aliases each of
//! these so existing call sites read unchanged.

const std = @import("std");

/// True if `req` starts with `prefix` and the next byte ends the path (space or
/// `?`): i.e. an exact route match, not a longer path that merely shares the
/// prefix.
pub fn routeExact(req: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, req, prefix)) return false;
    if (req.len <= prefix.len) return false;
    const delim = req[prefix.len];
    return delim == ' ' or delim == '?';
}

/// Parse the integer immediately after `prefix` in `req`, terminated by space,
/// `/`, or `?`. Returns null if the prefix is absent or no terminator follows.
pub fn parseIdx(req: []const u8, prefix: []const u8) ?usize {
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
/// `GET /api/vms/0/disk2/download`. Returns null on mismatch: safer than a
/// substring search which might match ambiguous segments.
pub fn parseVmIdxSuffix(req: []const u8, prefix: []const u8, suffix: []const u8) ?usize {
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
/// E.g. matches `GET /api/vms/12 HTTP/1.1` (and `?query`) but returns null for
/// `GET /api/vms/12/log`, that has an action suffix and must be routed by
/// `parseVmIdxSuffix`. Returns the index only when the char after the digits is
/// a space, `?`, or end of input.
pub fn parseVmIdxExact(req: []const u8, prefix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    var end: usize = rest.len;
    for ([_]u8{ ' ', '/', '?' }) |term| {
        if (std.mem.indexOfScalar(u8, rest, term)) |i| {
            if (i < end) end = i;
        }
    }
    if (end == 0) return null;
    // A '/' terminator means a trailing segment → an action route, not an item.
    if (end < rest.len and rest[end] == '/') return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

/// Find a header value by (case-insensitive) name in the header block. `name`
/// must include the trailing `": "`. Returns the value up to CRLF, or null.
pub fn findHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    const headers = raw[0 .. std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len];
    var pos: usize = 0;
    while (pos < headers.len) {
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

/// Copy the request line (up to CRLF) into `out`, replacing control bytes with
/// `?`, for safe logging. Returns the written slice.
pub fn requestLine(req: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (req) |ch| {
        if (ch == '\r' or ch == '\n' or n >= out.len) break;
        out[n] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
        n += 1;
    }
    return out[0..n];
}

/// Parse the Content-Length header value (case-insensitive), or null.
pub fn parseContentLength(raw: []const u8) ?usize {
    const req = if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |end| raw[0 .. end + 2] else raw;
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
                return std.fmt.parseInt(usize, line[cl.len..], 10) catch null;
            }
        } else break;
    }
    return null;
}

/// The request body (bytes after the CRLFCRLF header terminator), or null.
pub fn getBody(req: []const u8) ?[]const u8 {
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return null;
    return req[body_start + 4 ..];
}

// ── Tests ───────────────────────────────────────────────────────────

test "fuzz: httpreq parsers never panic on random request bytes" {
    var prng = std.Random.DefaultPrng.init(0x4777_9001);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    var out: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        const req = buf[0..len];
        _ = parseIdx(req, "POST /api/vms/");
        _ = parseVmIdxSuffix(req, "GET /ws/vnc/", "");
        _ = findHeader(req, "Content-Length: ");
        if (parseContentLength(req)) |cl| std.debug.assert(cl <= std.math.maxInt(usize));
        if (getBody(req)) |b| std.debug.assert(b.len <= req.len);
        const line = requestLine(req, &out);
        std.debug.assert(line.len <= out.len);
    }
}

test "httpreq: parseIdx + suffix/exact routing" {
    try std.testing.expectEqual(@as(?usize, 12), parseIdx("POST /api/vms/12/power HTTP/1.1", "POST /api/vms/"));
    try std.testing.expectEqual(@as(?usize, 0), parseVmIdxSuffix("GET /api/vms/0/log HTTP/1.1", "GET /api/vms/", "/log"));
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxSuffix("GET /api/vms/0/logs HTTP/1.1", "GET /api/vms/", "/log"));
    try std.testing.expectEqual(@as(?usize, 7), parseVmIdxExact("GET /api/vms/7 HTTP/1.1", "GET /api/vms/"));
    try std.testing.expectEqual(@as(?usize, null), parseVmIdxExact("GET /api/vms/7/log HTTP/1.1", "GET /api/vms/"));
}

test "httpreq: findHeader + parseContentLength are case-insensitive" {
    const req = "POST /x HTTP/1.1\r\nContent-Length: 42\r\nX-API-Key: secret\r\n\r\nbody";
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength(req));
    try std.testing.expectEqualStrings("secret", findHeader(req, "x-api-key: ").?);
    try std.testing.expectEqualStrings("body", getBody(req).?);
}

test "httpreq: header lookup stops before the body" {
    const req = "POST /x HTTP/1.1\r\nHost: localhost\r\n\r\nContent-Length: 42\r\n";
    try std.testing.expect(parseContentLength(req) == null);
    try std.testing.expect(findHeader(req, "Content-Length: ") == null);
    try std.testing.expectEqualStrings("localhost", findHeader(req, "Host: ").?);
}

test "httpreq: header values take precedence over body text" {
    const req = "POST /x HTTP/1.1\r\nContent-Length: 20\r\n\r\nContent-Length: 42\r\n";
    try std.testing.expectEqual(@as(?usize, 20), parseContentLength(req));
    try std.testing.expectEqualStrings("20", findHeader(req, "Content-Length: ").?);
}

test "httpreq: requestLine sanitizes control bytes" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("GET /x", requestLine("GET /x\r\nHost: y", &out));
}
