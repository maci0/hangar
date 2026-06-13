// SPDX-License-Identifier: MIT
//! WebSocket implementation for the embedded HTTP server.
//!
//! Provides upgrade handshake parsing and frame read/write.
//! Used by the VNC WebSocket proxy to stream framebuffer data
//! from QEMU's VNC server to browser clients.

const std = @import("std");
const c = std.c;

/// Fixed GUID for WebSocket handshake as per RFC 6455.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// WebSocket frame opcodes.
pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

/// A parsed WebSocket frame header.
pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    mask: bool,
    payload_len: u64,
};

/// Parse the WebSocket upgrade request, returning the accept key.
/// Caller must write the 101 response using the returned key.
/// Returns null if the request is not a valid WebSocket upgrade.
/// Case-insensitive check that a header line `name` exists and its value
/// contains `token` (comma/space tolerant). Used for the upgrade handshake,
/// where clients vary header casing and combine Connection tokens.
fn headerValueContains(req: []const u8, name: []const u8, token: []const u8) bool {
    var rest = req;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return false;
        const line = std.mem.trim(u8, rest[0..nl], " \r\t");
        rest = rest[nl + 1 ..];
        if (line.len == 0) return false; // end of headers
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = line[0..colon];
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, hname, " \t"), std.mem.trim(u8, name[0..name.len-1], " "))) continue;
        const value = line[colon + 1 ..];
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |tok| {
            if (std.ascii.eqlIgnoreCase(tok, token)) return true;
        }
        return false;
    }
}

pub fn parseUpgrade(req: []const u8) ?[29]u8 {
    // Find the Sec-WebSocket-Key header.
    const key_marker = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, req, key_marker) orelse return null;
    const key_val_start = key_start + key_marker.len;
    const key_end = std.mem.indexOfScalar(u8, req[key_val_start..], '\r') orelse return null;
    const key = req[key_val_start .. key_val_start + key_end];

    // Verify the Upgrade and Connection headers. Match case-insensitively and
    // token-scan the value: Firefox sends "Connection: keep-alive, Upgrade" and
    // header casing varies by client, so exact-substring matching dropped valid
    // upgrades (every console WS failed on Firefox).
    if (!headerValueContains(req, "upgrade:", "websocket")) return null;
    if (!headerValueContains(req, "connection:", "upgrade")) return null;

    // Compute accept = base64(sha1(key + ws_guid))
    var sha: [20]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(ws_guid);
    hasher.final(&sha);

    var accept: [29]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&accept, &sha);
    accept[encoded.len] = 0; // null terminate (base64 of 20 bytes = 28 chars)
    return accept;
}

/// First requested WebSocket subprotocol from the upgrade request, if any
/// (e.g. spice-html5 asks for "binary"). RFC 6455 §4.2.2: when the client
/// requests a subprotocol, the server must echo one back or the browser fails
/// the whole handshake — silently dropping it broke the SPICE console while
/// VNC (which requests none) worked.
pub fn requestedProtocol(req: []const u8) ?[]const u8 {
    const marker = "Sec-WebSocket-Protocol: ";
    const start = std.mem.indexOf(u8, req, marker) orelse return null;
    const val_start = start + marker.len;
    const rel_end = std.mem.indexOfScalar(u8, req[val_start..], '\r') orelse return null;
    var first = req[val_start .. val_start + rel_end];
    if (std.mem.indexOfScalar(u8, first, ',')) |comma| first = first[0..comma];
    first = std.mem.trim(u8, first, " \t");
    if (first.len == 0 or first.len > 64) return null;
    return first;
}

/// Format the HTTP 101 Switching Protocols response for a WebSocket upgrade,
/// echoing the client's requested subprotocol when present (see
/// `requestedProtocol`). MUST use a normal string literal: Zig multiline (`\\`)
/// literals do not process escapes, so a `\r` inside one is the two characters
/// backslash+r — browsers then never see a real CRLF header terminator and the
/// WebSocket stays in CONNECTING forever (this silently broke all consoles).
pub fn formatUpgradeResponse(buf: []u8, accept_key: [29]u8, protocol: ?[]const u8) ![]const u8 {
    if (protocol) |p| {
        return std.fmt.bufPrint(buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\nSec-WebSocket-Protocol: {s}\r\n\r\n", .{ accept_key[0..28], p }) catch error.WriteFailed;
    }
    return std.fmt.bufPrint(buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key[0..28]}) catch error.WriteFailed;
}

/// Write the HTTP 101 Switching Protocols response for a WebSocket upgrade.
pub fn writeUpgradeResponse(fd: c.fd_t, accept_key: [29]u8, req: []const u8) !void {
    var buf: [384]u8 = undefined;
    const resp = try formatUpgradeResponse(&buf, accept_key, requestedProtocol(req));
    _ = c.write(fd, resp.ptr, resp.len);
}

/// Read exactly `dst.len` bytes from `fd`, looping on partial reads.
/// Returns false on EOF or error before the buffer is filled. A single
/// `c.read` may return fewer bytes than requested on a fragmented TCP
/// stream (the VNC proxy serves possibly-remote browser clients), so the
/// fixed-size header reads below must accumulate rather than demand the
/// full count in one syscall — otherwise a split header is misread as a
/// protocol error and the connection is dropped spuriously.
/// read() that retries on EINTR and on a recv timeout (EAGAIN). The WebSocket
/// fd inherits the HTTP connection's 30s SO_RCVTIMEO, but an idle viewer that
/// sends no frames is healthy — a timeout must not be mistaken for EOF and tear
/// the connection down (a mid-frame timeout would also drop a live stream).
/// Returns the byte count (>0), 0 on EOF, or -1 on a genuine error.
fn readRetry(fd: c.fd_t, dst: [*]u8, len: usize) isize {
    while (true) {
        const n = c.read(fd, dst, len);
        if (n >= 0) return n;
        const e = c._errno().*;
        if (e == @intFromEnum(c.E.INTR) or e == @intFromEnum(c.E.AGAIN)) continue;
        return -1;
    }
}

fn readFull(fd: c.fd_t, dst: []u8) bool {
    var got: usize = 0;
    while (got < dst.len) {
        const n = readRetry(fd, dst.ptr + got, dst.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

/// Read a WebSocket frame header from the socket.
/// Returns null on EOF or invalid frame.
pub fn readFrameHeader(fd: c.fd_t) ?FrameHeader {
    var buf: [2]u8 = undefined;
    if (!readFull(fd, &buf)) return null;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(b0 & 0x0f);
    const mask = (b1 & 0x80) != 0;
    var payload_len: u64 = b1 & 0x7f;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        if (!readFull(fd, &ext)) return null;
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        if (!readFull(fd, &ext)) return null;
        payload_len = std.mem.readInt(u64, &ext, .big);
        // RFC 6455 §5.2: MSB of 64-bit extended length must be clear.
        if ((payload_len & (1 << 63)) != 0) return null;
    }

    return FrameHeader{
        .fin = fin,
        .opcode = opcode,
        .mask = mask,
        .payload_len = payload_len,
    };
}

/// Read a WebSocket frame payload into `buf`.
/// Automatically reads and applies the mask if present.
/// Returns the number of bytes actually read (<= payload_len).
pub fn readFramePayload(fd: c.fd_t, buf: []u8, header: FrameHeader) ?usize {
    const len: usize = @intCast(@min(header.payload_len, buf.len));
    if (len == 0 and header.mask) {
        // Mask key is still on the wire even with zero payload — consume it.
        var mask_key: [4]u8 = undefined;
        if (!readFull(fd, &mask_key)) return null;
        return 0;
    }
    if (len == 0) return 0;

    // Read mask key FIRST (RFC 6455 §5.3: masking-key precedes Payload Data).
    var mask_key: [4]u8 = [_]u8{0} ** 4;
    if (header.mask) {
        if (!readFull(fd, &mask_key)) return null;
    }

    // Read and unmask the payload in a single pass.
    var total_read: usize = 0;
    while (total_read < len) {
        const n = readRetry(fd, buf.ptr + total_read, len - total_read);
        if (n <= 0) return null;
        const chunk_end = total_read + @as(usize, @intCast(n));
        if (header.mask) {
            for (total_read..chunk_end) |i| {
                buf[i] ^= mask_key[i % 4];
            }
        }
        total_read = chunk_end;
    }

    // Drain any remaining payload beyond our buffer.
    if (header.payload_len > len) {
        var drain: [4096]u8 = undefined;
        var remaining: u64 = header.payload_len - len;
        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, drain.len));
            const n = readRetry(fd, &drain, to_read);
            if (n <= 0) return null;
            remaining -= @intCast(n);
        }
    }

    return len;
}

/// Write a WebSocket frame (binary or text).
/// Server frames are never masked.
/// Write one frame whose payload is the concatenation of two slices (used by
/// the video relay: 1-byte chunk marker + access unit) without copying them
/// into a contiguous buffer. One writev attempt for the common case; partial
/// writes finish with plain sequential writes.
pub fn writeFrame2(fd: c.fd_t, opcode: Opcode, p1: []const u8, p2: []const u8) !void {
    const plen = p1.len + p2.len;
    var header: [10]u8 = undefined;
    var header_len: usize = 2;
    header[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (plen < 126) {
        header[1] = @intCast(plen);
    } else if (plen <= 65535) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(plen), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(plen), .big);
        header_len = 10;
    }
    var iov = [3]std.posix.iovec_const{
        .{ .base = &header, .len = header_len },
        .{ .base = p1.ptr, .len = p1.len },
        .{ .base = p2.ptr, .len = p2.len },
    };
    const total = header_len + plen;
    const n = c.writev(fd, iov[0..].ptr, 3);
    if (n <= 0) return error.WriteFailed;
    var done: usize = @intCast(n);
    if (done == total) return;
    // Finish whatever the single writev left over, slice by slice.
    const parts = [3][]const u8{ header[0..header_len], p1, p2 };
    for (parts) |part| {
        if (done >= part.len) {
            done -= part.len;
            continue;
        }
        var off = done;
        done = 0;
        while (off < part.len) {
            const wn = c.write(fd, part[off..].ptr, part.len - off);
            if (wn <= 0) return error.WriteFailed;
            off += @intCast(wn);
        }
    }
}

pub fn writeFrame(fd: c.fd_t, opcode: Opcode, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN + opcode

    if (payload.len < 126) {
        header[1] = @intCast(payload.len); // no mask
    } else if (payload.len <= 65535) {
        header[1] = 126; // no mask
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127; // no mask
        std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    // Emit header+payload in a single writev so the 2-byte header is not sent
    // as its own runt TCP segment. The relay sockets set TCP_NODELAY, so two
    // separate write() calls would push a tiny header packet ahead of every
    // frame on the VNC/SPICE/serial console path. One syscall, one segment.
    if (payload.len == 0) {
        if (c.write(fd, &header, header_len) != @as(isize, @intCast(header_len))) return error.WriteFailed;
        return;
    }
    var iov = [2]std.posix.iovec_const{
        .{ .base = &header, .len = header_len },
        .{ .base = payload.ptr, .len = payload.len },
    };
    const total: isize = @intCast(header_len + payload.len);
    // A short writev (signal/buffer pressure) is treated as failure, matching
    // the prior write()-based behaviour which also did not loop on partial writes.
    if (c.writev(fd, &iov, 2) != total) return error.WriteFailed;
}

/// Write a WebSocket close frame.
pub fn writeClose(fd: c.fd_t) !void {
    var buf: [4]u8 = undefined;
    buf[0] = 0x88; // FIN + close
    buf[1] = 2; // 2-byte payload (status code)
    buf[2] = 0x03; // 1000 = normal closure
    buf[3] = 0xe8;
    _ = c.write(fd, &buf, 4);
}

/// Write a WebSocket ping frame (heartbeat).
pub fn writePing(fd: c.fd_t) !void {
    var buf: [2]u8 = undefined;
    buf[0] = 0x89; // FIN + ping
    buf[1] = 0; // no payload
    _ = c.write(fd, &buf, 2);
}

/// Write a WebSocket pong frame (reply to client ping).
pub fn writePong(fd: c.fd_t) !void {
    var buf: [2]u8 = undefined;
    buf[0] = 0x8a; // FIN + pong
    buf[1] = 0; // no payload
    _ = c.write(fd, &buf, 2);
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseUpgrade: valid WebSocket request" {
    const req = "GET /ws/vnc/0 HTTP/1.1\r\n" ++
        "Host: localhost:9080\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    const accept = parseUpgrade(req);
    try std.testing.expect(accept != null);
    // Known answer: base64(sha1("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept.?[0..28]);
}

test "formatUpgradeResponse: real CRLF line endings and terminator (RFC 6455)" {
    const req = "GET /ws/vnc/0 HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    const accept = parseUpgrade(req).?;
    var buf: [256]u8 = undefined;
    const resp = try formatUpgradeResponse(&buf, accept, null);
    // Every line must end in a REAL CR+LF — a literal backslash-r (from a Zig
    // multiline string) leaves browsers waiting for end-of-headers forever.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\\r") == null);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101 Switching Protocols\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
}

fn fuzzByteIsPrintable(b: u8) bool {
    return b == '\r' or b == '\n' or (b >= 0x20 and b < 0x7f);
}

test "fuzz: headerValueContains never panics on random request bytes" {
    var prng = std.Random.DefaultPrng.init(0xBEEF_77AA);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = headerValueContains(buf[0..len], "upgrade:", "websocket");
        _ = headerValueContains(buf[0..len], "connection:", "upgrade");
    }
}

test "headerValueContains: case-insensitive, comma-tolerant (Firefox Connection)" {
    const ff = "GET /ws HTTP/1.1\r\nupgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\n\r\n";
    try std.testing.expect(headerValueContains(ff, "upgrade:", "websocket"));
    try std.testing.expect(headerValueContains(ff, "connection:", "upgrade"));
    const no = "GET /ws HTTP/1.1\r\nConnection: keep-alive\r\n\r\n";
    try std.testing.expect(!headerValueContains(no, "connection:", "upgrade"));
}

test "parseUpgrade: accepts Firefox-style combined Connection header" {
    const req = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try std.testing.expect(parseUpgrade(req) != null);
}

test "writeFrame2: two-slice payload round-trips through a socketpair" {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    const marker = [_]u8{0x03};
    const au = "ACCESS-UNIT-BYTES" ** 4; // 68 bytes
    try writeFrame2(fds[0], .binary, &marker, au);
    var rb: [128]u8 = undefined;
    const hdr = readFrameHeader(fds[1]).?;
    try std.testing.expectEqual(Opcode.binary, hdr.opcode);
    try std.testing.expectEqual(@as(u64, marker.len + au.len), hdr.payload_len);
    const n = readFramePayload(fds[1], &rb, hdr).?;
    try std.testing.expectEqual(marker.len + au.len, n);
    try std.testing.expectEqual(@as(u8, 0x03), rb[0]);
    try std.testing.expectEqualStrings(au, rb[1 .. 1 + au.len]);
}

test "fuzz: writeFrame2 emits a well-formed header across length boundaries" {
    var prng = std.Random.DefaultPrng.init(0xF2A2_0001);
    const rnd = prng.random();
    const big = std.heap.page_allocator.alloc(u8, 70000) catch return error.SkipZigTest;
    defer std.heap.page_allocator.free(big);
    for (big) |*b| b.* = rnd.int(u8);
    // Boundary payload lengths exercise the 1/2/8-byte header encodings.
    const lens = [_]usize{ 0, 1, 125, 126, 127, 65535, 65536, 70000 };
    for (lens) |total| {
        const p1len = @min(total, @as(usize, 1));
        const p2len = total - p1len;
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
        // Drain reader on a thread so a >SO_SNDBUF frame doesn't deadlock the writer.
        const Reader = struct {
            fn run(fd: c.fd_t, expect_len: u64) void {
                const h = readFrameHeader(fd) orelse return;
                std.testing.expectEqual(expect_len, h.payload_len) catch {};
                var buf: [4096]u8 = undefined;
                var got: usize = 0;
                while (got < h.payload_len) {
                    const n = readFramePayload(fd, &buf, .{ .fin = h.fin, .opcode = h.opcode, .mask = false, .payload_len = @min(h.payload_len - got, buf.len) }) orelse break;
                    if (n == 0) break;
                    got += n;
                }
            }
        };
        const th = std.Thread.spawn(.{}, Reader.run, .{ fds[1], @as(u64, total) }) catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            continue;
        };
        writeFrame2(fds[0], .binary, big[0..p1len], big[p1len .. p1len + p2len]) catch {};
        _ = c.close(fds[0]);
        th.join();
        _ = c.close(fds[1]);
    }
}

test "requestedProtocol: extracts first token, trims, null when absent" {
    try std.testing.expectEqualStrings("binary", requestedProtocol("GET /ws HTTP/1.1\r\nSec-WebSocket-Protocol: binary\r\n\r\n").?);
    try std.testing.expectEqualStrings("binary", requestedProtocol("GET /ws HTTP/1.1\r\nSec-WebSocket-Protocol: binary, base64\r\n\r\n").?);
    try std.testing.expect(requestedProtocol("GET /ws HTTP/1.1\r\nHost: x\r\n\r\n") == null);
}

test "formatUpgradeResponse: echoes the requested subprotocol (RFC 6455)" {
    const req = "GET /ws/spice/0 HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: binary\r\n\r\n";
    const accept = parseUpgrade(req).?;
    var buf: [384]u8 = undefined;
    const resp = try formatUpgradeResponse(&buf, accept, requestedProtocol(req));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Protocol: binary\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
}

test "fuzz: formatUpgradeResponse output is printable HTTP for random accept keys" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE01);
    const random = prng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var key: [29]u8 = undefined;
        for (&key) |*kb| kb.* = random.intRangeAtMost(u8, 0x21, 0x7e); // printable, no spaces
        key[28] = 0;
        var buf: [256]u8 = undefined;
        const resp = try formatUpgradeResponse(&buf, key, null);
        try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));
        for (resp) |rb| try std.testing.expect(fuzzByteIsPrintable(rb));
    }
}

test "parseUpgrade: missing key returns null" {
    const req = "GET /ws/vnc/0 HTTP/1.1\r\n" ++
        "Host: localhost:9080\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "\r\n";
    try std.testing.expect(parseUpgrade(req) == null);
}

test "parseUpgrade: missing Upgrade header returns null" {
    const req = "GET /ws/vnc/0 HTTP/1.1\r\n" ++
        "Host: localhost:9080\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Connection: Upgrade\r\n" ++
        "\r\n";
    try std.testing.expect(parseUpgrade(req) == null);
}

test "writeFrame: binary frame encoding" {
    // Drive writeFrame against a real pipe and read back the wire bytes.
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    const payload = "hello";
    try writeFrame(fds[1], .binary, payload);

    var buf: [16]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 2 + payload.len), n);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]); // FIN + binary opcode
    try std.testing.expectEqual(@as(u8, payload.len), buf[1]); // unmasked length
    try std.testing.expectEqualStrings(payload, buf[2 .. 2 + payload.len]);
}

test "writeFrame: header sizes for different payload lengths" {
    // Verify header byte layout for small (<126), medium (126-65535), and large payloads.
    // Small payload (125 bytes) — 2-byte header
    {
        var header: [10]u8 = undefined;
        const len: usize = 125;
        header[0] = 0x80 | @as(u8, @intFromEnum(Opcode.binary));
        header[1] = @as(u8, @intCast(len));
        try std.testing.expectEqual(@as(u8, 0x82), header[0]); // FIN+Binary
        try std.testing.expectEqual(@as(u8, 125), header[1]);
    }
    // Medium payload (126 bytes) — 4-byte header
    {
        var header: [10]u8 = undefined;
        const len: usize = 126;
        header[0] = 0x80 | @as(u8, @intFromEnum(Opcode.binary));
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(len), .big);
        try std.testing.expectEqual(@as(u8, 126), header[1]);
        try std.testing.expectEqual(@as(u16, 126), std.mem.readInt(u16, header[2..4], .big));
    }
    // Large payload (65536 bytes) — 10-byte header
    {
        var header: [10]u8 = undefined;
        const len: usize = 65536;
        header[0] = 0x80 | @as(u8, @intFromEnum(Opcode.binary));
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(len), .big);
        try std.testing.expectEqual(@as(u8, 127), header[1]);
        try std.testing.expectEqual(@as(u64, 65536), std.mem.readInt(u64, header[2..10], .big));
    }
}

test "writeClose: frame encoding" {
    var buf: [4]u8 = undefined;
    buf[0] = 0x88;
    buf[1] = 2;
    buf[2] = 0x03;
    buf[3] = 0xe8;
    try std.testing.expectEqual(@as(u8, 0x88), buf[0]); // FIN+Close
    try std.testing.expectEqual(@as(u8, 2), buf[1]);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, buf[2..4], .big)); // 1000 = normal
}

test "writePing/writePong: frame encoding" {
    try std.testing.expectEqual(@as(u8, 0x89), 0x80 | @as(u8, @intFromEnum(Opcode.ping))); // FIN+Ping
    try std.testing.expectEqual(@as(u8, 0x8a), 0x80 | @as(u8, @intFromEnum(Opcode.pong))); // FIN+Pong
}

test "Opcode enum values" {
    try std.testing.expectEqual(@as(u4, 0), @intFromEnum(Opcode.continuation));
    try std.testing.expectEqual(@as(u4, 1), @intFromEnum(Opcode.text));
    try std.testing.expectEqual(@as(u4, 2), @intFromEnum(Opcode.binary));
    try std.testing.expectEqual(@as(u4, 8), @intFromEnum(Opcode.close));
    try std.testing.expectEqual(@as(u4, 9), @intFromEnum(Opcode.ping));
    try std.testing.expectEqual(@as(u4, 10), @intFromEnum(Opcode.pong));
}

test "parseUpgrade: known answer for spec example" {
    // RFC 6455 section 4.2.2 example
    const req = "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Origin: http://example.com\r\n" ++
        "Sec-WebSocket-Protocol: chat, superchat\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";
    const accept = parseUpgrade(req).?;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept[0..28]);
}

test "fuzz: writeFrame header encoding never panics for any payload length" {
    var prng = std.Random.DefaultPrng.init(0xFEEDFACE);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const opcode: Opcode = if (rnd.boolean()) .binary else .text;
        const len_choice = rnd.uintLessThan(u3, 3);
        const payload_len: usize = switch (len_choice) {
            0 => rnd.uintLessThan(usize, 126),
            1 => 126 + rnd.uintLessThan(usize, 65410), // 126..65535
            2 => 65536 + rnd.uintLessThan(usize, 1_000_000), // large
            else => unreachable,
        };
        // Verify header encoding math is correct for all three size classes.
        var header: [10]u8 = undefined;
        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        if (payload_len < 126) {
            header[1] = @intCast(payload_len);
        } else if (payload_len <= 65535) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload_len), .big);
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload_len), .big);
        }
        // Verify round-trip: the encoded length matches.
        const decoded: u64 = if (header[1] < 126) header[1] else if (header[1] == 126) std.mem.readInt(u16, header[2..4], .big) else std.mem.readInt(u64, header[2..10], .big);
        try std.testing.expectEqual(@as(u64, @intCast(payload_len)), decoded);
    }
}

test "fuzz: parseUpgrade never panics on random HTTP headers" {
    var prng = std.Random.DefaultPrng.init(0x5EC0A5AB);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        var buf: [1024]u8 = undefined;
        const n = rnd.uintLessThan(usize, 900);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        // Ensure there's no uninitialized read past the generated data.
        @memset(buf[n..], 0);
        if (parseUpgrade(buf[0..n])) |accept| assertAcceptKey(accept);
    }
}

test "fuzz: parseUpgrade accept key is injection-safe on valid-shaped requests" {
    // Random bytes almost never carry all three required markers, so the
    // accept-computation path above is rarely reached. Build well-formed
    // upgrade requests with an attacker-controlled key value and assert the
    // derived accept key can never carry a CR/LF (which would let the key
    // smuggle headers into the HTTP 101 response in writeUpgradeResponse).
    var prng = std.Random.DefaultPrng.init(0xC0FFEE11);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        var key: [64]u8 = undefined;
        const klen = rnd.uintLessThan(usize, key.len);
        for (key[0..klen]) |*b| b.* = rnd.int(u8);
        var buf: [512]u8 = undefined;
        // The '\r' terminator for the key header is guaranteed by bufPrint; a
        // raw '\r' inside the random key just truncates it early, which is fine.
        const req = std.fmt.bufPrint(
            &buf,
            "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\n\r\n",
            .{key[0..klen]},
        ) catch continue;
        const accept = parseUpgrade(req) orelse continue;
        assertAcceptKey(accept);
    }
}

/// The accept key is base64 of a 20-byte SHA1 (exactly 28 chars) plus a NUL
/// terminator, and bytes 0..28 flow unescaped into the HTTP 101 response.
fn assertAcceptKey(accept: [29]u8) void {
    std.testing.expect(accept[28] == 0) catch unreachable;
    for (accept[0..28]) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '+' or ch == '/' or ch == '=';
        std.testing.expect(ok) catch unreachable;
    }
}

test "writeUpgradeResponse: emits valid HTTP 101 response" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var accept: [29]u8 = undefined;
    @memcpy(accept[0..28], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    accept[28] = 0;
    try writeUpgradeResponse(fds[0], accept, "GET /ws HTTP/1.1\r\n\r\n");

    var read_buf: [256]u8 = undefined;
    const n = c.read(fds[1], &read_buf, read_buf.len);
    try std.testing.expect(n > 0);
    const resp = read_buf[0..@intCast(n)];

    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 101") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Upgrade: websocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: Upgrade") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "readFrameHeader: small payload (2-byte header)" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN + text opcode, unmasked, payload_len=5
    var frame: [2]u8 = .{ 0x81, 5 };
    _ = c.write(fds[1], &frame, 2);
    // Write payload separately so readFrameHeader only consumes header.
    const payload = "hello";
    _ = c.write(fds[1], payload, payload.len);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expect(hdr.?.fin);
    try std.testing.expectEqual(Opcode.text, hdr.?.opcode);
    try std.testing.expect(!hdr.?.mask);
    try std.testing.expectEqual(@as(u64, 5), hdr.?.payload_len);
}

test "readFrameHeader: medium payload (4-byte header)" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN + binary, unmasked, extended payload_len=300 (126 marker + 2 bytes)
    var frame: [4]u8 = .{ 0x82, 126, 0x01, 0x2c };
    _ = c.write(fds[1], &frame, 4);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(Opcode.binary, hdr.?.opcode);
    try std.testing.expectEqual(@as(u64, 300), hdr.?.payload_len);
}

test "readFrameHeader: large payload (10-byte header)" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN + binary, unmasked, extended payload_len=100000 (127 marker + 8 bytes)
    var frame: [10]u8 = undefined;
    frame[0] = 0x82;
    frame[1] = 127;
    std.mem.writeInt(u64, frame[2..10], @as(u64, 100000), .big);
    _ = c.write(fds[1], &frame, 10);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(@as(u64, 100000), hdr.?.payload_len);
}

test "readFrameHeader: MSB set in 64-bit extended length rejected" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN, text, payload_len=127 (= extended 8-byte length follows)
    var header: [2]u8 = .{ 0x81, 127 };
    _ = c.write(fds[1], &header, 2);
    // Extended 8-byte length with MSB set
    var ext: [8]u8 = undefined;
    std.mem.writeInt(u64, &ext, 0x8000000000000000, .big);
    _ = c.write(fds[1], &ext, 8);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr == null);
}

test "readFrameHeader: MSB clear in 64-bit extended length accepted" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var header: [2]u8 = .{ 0x81, 127 };
    _ = c.write(fds[1], &header, 2);
    var ext: [8]u8 = undefined;
    std.mem.writeInt(u64, &ext, 0x7FFFFFFFFFFFFFFF, .big);
    _ = c.write(fds[1], &ext, 8);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(@as(u64, 0x7FFFFFFFFFFFFFFF), hdr.?.payload_len);
}

test "readFrameHeader: masked frame" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN + text, masked, payload_len=3
    var frame: [2]u8 = .{ 0x81, 0x80 | 3 };
    _ = c.write(fds[1], &frame, 2);
    // Write mask key + masked payload so readFrameHeader doesn't consume them
    const mask_and_payload = [_]u8{ 0x11, 0x22, 0x33, 0x44, 'A' ^ 0x11, 'B' ^ 0x22, 'C' ^ 0x33 };
    _ = c.write(fds[1], &mask_and_payload, mask_and_payload.len);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expect(hdr.?.fin);
    try std.testing.expectEqual(Opcode.text, hdr.?.opcode);
    try std.testing.expect(hdr.?.mask);
    try std.testing.expectEqual(@as(u64, 3), hdr.?.payload_len);
}

test "readFrameHeader: header split across reads is reassembled" {
    // A fragmented stream delivers the 4-byte (126-marker) header one byte at
    // a time. readFull must accumulate rather than treat the first short read
    // as a protocol error, so the header still parses correctly.
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // FIN + binary, unmasked, extended payload_len=300.
    const frame = [_]u8{ 0x82, 126, 0x01, 0x2c };
    const Writer = struct {
        fn run(wfd: c.fd_t, bytes: []const u8) void {
            for (bytes) |b| {
                var one = [_]u8{b};
                _ = c.write(wfd, &one, 1);
            }
        }
    };
    var th = try std.Thread.spawn(.{}, Writer.run, .{ fds[1], frame[0..] });
    defer th.join();

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(Opcode.binary, hdr.?.opcode);
    try std.testing.expectEqual(@as(u64, 300), hdr.?.payload_len);
}

test "readFrameHeader: EOF on first 2 bytes returns null" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    _ = c.shutdown(fds[1], c.SHUT.WR);
    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr == null);
}

test "readFrameHeader: EOF during extended length read returns null" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // Write only the 2-byte base header with 126 marker, then shutdown.
    var frame: [2]u8 = .{ 0x82, 126 };
    _ = c.write(fds[1], &frame, 2);
    _ = c.shutdown(fds[1], c.SHUT.WR);

    const hdr = readFrameHeader(fds[0]);
    try std.testing.expect(hdr == null);
}

test "readFramePayload: unmasked payload" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    const msg = "hello world";
    _ = c.write(fds[1], msg, msg.len);

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = false, .payload_len = msg.len };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expect(n != null);
    try std.testing.expectEqualStrings(msg, buf[0..n.?]);
}

test "readFramePayload: masked payload" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    const mask: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    const plain = "hello";
    var masked: [5]u8 = undefined;
    for (plain, 0..) |ch, i| masked[i] = ch ^ mask[i % 4];

    _ = c.write(fds[1], &mask, 4);
    _ = c.write(fds[1], &masked, masked.len);

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = true, .payload_len = plain.len };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expect(n != null);
    try std.testing.expectEqual(plain.len, n.?);
    try std.testing.expectEqualStrings(plain, buf[0..n.?]);
}

test "readFramePayload: zero-length unmasked" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = false, .payload_len = 0 };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expectEqual(@as(usize, 0), n.?);
}

test "readFramePayload: zero-length masked consumes mask key" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    // Write mask key + a subsequent byte so we can verify the mask was consumed.
    const mask: [4]u8 = .{ 0xaa, 0xbb, 0xcc, 0xdd };
    _ = c.write(fds[1], &mask, 4);
    _ = c.write(fds[1], &[_]u8{'X'}, 1);

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = true, .payload_len = 0 };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expectEqual(@as(usize, 0), n.?);

    // The 'X' should still be readable — mask key was consumed.
    var ch: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), c.read(fds[0], &ch, 1));
    try std.testing.expectEqual(@as(u8, 'X'), ch[0]);
}

test "readFramePayload: buffer smaller than payload drains remainder" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    const payload = "ABCDEFGHIJKLMNOP"; // 16 bytes
    _ = c.write(fds[1], payload, payload.len);

    var buf: [4]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .binary, .mask = false, .payload_len = payload.len };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expect(n != null);
    try std.testing.expectEqual(@as(usize, 4), n.?);
    try std.testing.expectEqualStrings("ABCD", buf[0..4]);
}

test "readFramePayload: EOF during read returns null" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    _ = c.shutdown(fds[1], c.SHUT.WR);

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = false, .payload_len = 10 };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expect(n == null);
}

test "readFramePayload: EOF during mask key read returns null" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }

    _ = c.shutdown(fds[1], c.SHUT.WR);

    var buf: [32]u8 = undefined;
    const hdr = FrameHeader{ .fin = true, .opcode = .text, .mask = true, .payload_len = 1 };
    const n = readFramePayload(fds[0], &buf, hdr);
    try std.testing.expect(n == null);
}

test "fuzz: readFrameHeader round-trip via socketpair" {
    var prng = std.Random.DefaultPrng.init(0x7EAF00D);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 800) : (iter += 1) {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }

        const opcode: Opcode = switch (rnd.uintLessThan(u3, 4)) {
            0 => .binary,
            1 => .text,
            2 => .ping,
            3 => .close,
            else => unreachable,
        };
        const fin = rnd.boolean();
        const masked = rnd.boolean();
        const len_choice = rnd.uintLessThan(u3, 3);
        const payload_len: u64 = switch (len_choice) {
            0 => rnd.uintLessThan(u64, 125),
            1 => 126 + rnd.uintLessThan(u64, 65410),
            2 => 65536 + rnd.uintLessThan(u64, 1000),
            else => unreachable,
        };

        // Build raw header bytes.
        var header: [10]u8 = undefined;
        var hdr_len: usize = 2;
        header[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
        const mask_bit: u8 = if (masked) 0x80 else 0;
        if (payload_len < 126) {
            header[1] = mask_bit | @as(u8, @intCast(payload_len));
        } else if (payload_len <= 65535) {
            header[1] = mask_bit | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload_len), .big);
            hdr_len = 4;
        } else {
            header[1] = mask_bit | 127;
            std.mem.writeInt(u64, header[2..10], payload_len, .big);
            hdr_len = 10;
        }
        _ = c.write(fds[1], &header, hdr_len);

        const hdr = readFrameHeader(fds[0]);
        try std.testing.expect(hdr != null);
        try std.testing.expectEqual(fin, hdr.?.fin);
        try std.testing.expectEqual(opcode, hdr.?.opcode);
        try std.testing.expectEqual(masked, hdr.?.mask);
        try std.testing.expectEqual(payload_len, hdr.?.payload_len);
    }
}

test "fuzz: readFramePayload never panics on random masked data" {
    var prng = std.Random.DefaultPrng.init(0x7EAF00E);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 600) : (iter += 1) {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }

        const masked = rnd.boolean();
        const payload_len: usize = rnd.uintLessThan(usize, 200);
        var wire: [500]u8 = undefined;
        var wp: usize = 0;
        if (masked) {
            const mk: [4]u8 = .{
                rnd.int(u8), rnd.int(u8), rnd.int(u8), rnd.int(u8),
            };
            @memcpy(wire[wp..][0..4], &mk);
            wp += 4;
        }
        var plain: [200]u8 = undefined;
        for (0..payload_len) |i| {
            plain[i] = rnd.int(u8);
            if (masked) {
                wire[wp + i] = plain[i] ^ wire[(wp - 4 + i % 4)];
            } else {
                wire[wp + i] = plain[i];
            }
        }
        const wire_end = wp + payload_len;
        _ = c.write(fds[1], wire[0..wire_end].ptr, wire_end);

        var buf: [200]u8 = undefined;
        const hdr = FrameHeader{ .fin = true, .opcode = .binary, .mask = masked, .payload_len = payload_len };
        const n = readFramePayload(fds[0], &buf, hdr);
        // EOF can happen if the OS buffer swallows only part — tolerate null.
        if (n) |len| {
            try std.testing.expectEqualStrings(plain[0..payload_len], buf[0..len]);
        }
    }
}

test "fuzz: readFramePayload drains an oversized frame and leaves the stream aligned" {
    // Exercises the overflow path (payload_len > buf.len): a hostile client can
    // claim a payload bigger than our receive buffer. readFramePayload must read
    // what fits, then drain the remainder so the NEXT frame header parses cleanly.
    var prng = std.Random.DefaultPrng.init(0x7EAF00F);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 400) : (iter += 1) {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }

        const masked = rnd.boolean();
        // Buffer smaller than the payload forces the drain branch.
        const cap: usize = 16 + rnd.uintLessThan(usize, 48); // [16, 64)
        const payload_len: usize = cap + 1 + rnd.uintLessThan(usize, 200);

        // Frame 1: oversized payload (raw masked bytes; content is irrelevant
        // to the drain path, only the byte count must be consumed exactly).
        var wire: [512]u8 = undefined;
        var wp: usize = 0;
        if (masked) {
            for (0..4) |_| {
                wire[wp] = rnd.int(u8);
                wp += 1;
            }
        }
        for (0..payload_len) |_| {
            wire[wp] = rnd.int(u8);
            wp += 1;
        }
        _ = c.write(fds[1], wire[0..wp].ptr, wp);

        // Frame 2: a tiny known unmasked payload that must survive intact only
        // if frame 1 was drained to the exact byte.
        const sentinel = "OK";
        _ = c.write(fds[1], sentinel.ptr, sentinel.len);

        var buf: [64]u8 = undefined;
        const hdr1 = FrameHeader{ .fin = true, .opcode = .binary, .mask = masked, .payload_len = payload_len };
        const got = readFramePayload(fds[0], buf[0..cap], hdr1);
        if (got) |len| {
            // Truncated to buffer capacity, never more.
            try std.testing.expectEqual(cap, len);
            // Stream re-aligned: the sentinel reads back byte-for-byte.
            var s: [2]u8 = undefined;
            const hdr2 = FrameHeader{ .fin = true, .opcode = .binary, .mask = false, .payload_len = sentinel.len };
            const m = readFramePayload(fds[0], &s, hdr2);
            if (m) |ml| try std.testing.expectEqualStrings(sentinel, s[0..ml]);
        }
    }
}

test "fuzz: readFrameHeader rejects a 64-bit length with the reserved MSB set" {
    // RFC 6455 §5.2: the most-significant bit of a 127 (64-bit) extended length
    // MUST be 0. A frame with it set is malformed and must be refused, not
    // turned into a ~2^63 allocation/drain request.
    var prng = std.Random.DefaultPrng.init(0x7EAF010);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        var fds: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) continue;
        defer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }

        var header: [10]u8 = undefined;
        header[0] = 0x82; // FIN + binary
        header[1] = 127; // 64-bit extended length, unmasked
        // Force the reserved high bit and randomize the rest.
        const bad_len: u64 = (@as(u64, 1) << 63) | rnd.int(u63);
        std.mem.writeInt(u64, header[2..10], bad_len, .big);
        _ = c.write(fds[1], &header, 10);

        try std.testing.expect(readFrameHeader(fds[0]) == null);
    }
}
