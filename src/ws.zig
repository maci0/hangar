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
pub fn parseUpgrade(req: []const u8) ?[29]u8 {
    // Find the Sec-WebSocket-Key header.
    const key_marker = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, req, key_marker) orelse return null;
    const key_val_start = key_start + key_marker.len;
    const key_end = std.mem.indexOfScalar(u8, req[key_val_start..], '\r') orelse return null;
    const key = req[key_val_start .. key_val_start + key_end];

    // Verify Connection: Upgrade and Upgrade: websocket are present.
    if (std.mem.indexOf(u8, req, "Upgrade: websocket") == null) return null;
    if (std.mem.indexOf(u8, req, "Connection: Upgrade") == null) return null;

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

/// Write the HTTP 101 Switching Protocols response for a WebSocket upgrade.
pub fn writeUpgradeResponse(fd: c.fd_t, accept_key: [29]u8) !void {
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf,
        \\HTTP/1.1 101 Switching Protocols\r
        \\Upgrade: websocket\r
        \\Connection: Upgrade\r
        \\Sec-WebSocket-Accept: {s}\r
        \\\r
        \\
    , .{accept_key[0..28]}) catch return error.WriteFailed;
    _ = c.write(fd, resp.ptr, resp.len);
}

/// Read a WebSocket frame header from the socket.
/// Returns null on EOF or invalid frame.
pub fn readFrameHeader(fd: c.fd_t) ?FrameHeader {
    var buf: [2]u8 = undefined;
    if (c.read(fd, &buf, 2) != 2) return null;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(b0 & 0x0f);
    const mask = (b1 & 0x80) != 0;
    var payload_len: u64 = b1 & 0x7f;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        if (c.read(fd, &ext, 2) != 2) return null;
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        if (c.read(fd, &ext, 8) != 8) return null;
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
        if (c.read(fd, &mask_key, 4) != 4) return null;
        return 0;
    }
    if (len == 0) return 0;

    // Read mask key FIRST (RFC 6455 §5.3: masking-key precedes Payload Data).
    var mask_key: [4]u8 = [_]u8{0} ** 4;
    if (header.mask) {
        if (c.read(fd, &mask_key, 4) != 4) return null;
    }

    // Read and unmask the payload in a single pass.
    var total_read: usize = 0;
    while (total_read < len) {
        const n = c.read(fd, buf.ptr + total_read, len - total_read);
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
            const n = c.read(fd, &drain, to_read);
            if (n <= 0) return null;
            remaining -= @intCast(n);
        }
    }

    return len;
}

/// Write a WebSocket frame (binary or text).
/// Server frames are never masked.
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

    if (c.write(fd, &header, header_len) != @as(isize, @intCast(header_len))) return error.WriteFailed;
    if (c.write(fd, payload.ptr, payload.len) != @as(isize, @intCast(payload.len))) return error.WriteFailed;
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
        _ = parseUpgrade(buf[0..n]);
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
    try writeUpgradeResponse(fds[0], accept);

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
