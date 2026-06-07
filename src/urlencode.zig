// SPDX-License-Identifier: MIT
//! URL-encoded body builder and percent-decoder for HTTP requests.
//!
//! Pure string logic with no UI dependencies, so it can be unit-tested in
//! isolation. Callers extract form values and pass (key, value) pairs;
//! `buildBody`/`appendPair` assemble the `key=val&...` string, and `urlDecode`
//! reverses percent-encoding on incoming values.

const std = @import("std");

/// Append `key=value&` to `buf[pos..]` and advance `pos.*` past it.
/// Returns error.NoSpaceLeft if the buffer is too small.
pub fn appendPair(buf: []u8, pos: *usize, key: []const u8, value: []const u8) !void {
    if (pos.* + key.len + 1 + value.len + 1 > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos.*..][0..key.len], key);
    var p = pos.* + key.len;
    buf[p] = '=';
    p += 1;
    @memcpy(buf[p..][0..value.len], value);
    p += value.len;
    buf[p] = '&';
    p += 1;
    pos.* = p;
}

/// URL-decode a percent-encoded string into `buf`. Returns the decoded slice
/// (always <= src.len). Converts %XX→byte and '+'→' '.
/// Output is bounded to `buf.len`: if `src` decodes to more bytes than the
/// buffer holds, decoding stops at capacity rather than writing past the end.
/// This keeps a too-small caller buffer from becoming a stack buffer overflow
/// (CWE-787) when `src` is attacker-controlled request data.
pub fn urlDecode(buf: []u8, src: []const u8) []u8 {
    var wi: usize = 0;
    var ri: usize = 0;
    while (ri < src.len) : (ri += 1) {
        if (wi >= buf.len) break;
        if (src[ri] == '%' and ri + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[ri + 1], 16) catch {
                buf[wi] = '%';
                wi += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(src[ri + 2], 16) catch {
                buf[wi] = '%';
                wi += 1;
                continue;
            };
            buf[wi] = (hi << 4) | lo;
            wi += 1;
            ri += 2;
        } else if (src[ri] == '+') {
            buf[wi] = ' ';
            wi += 1;
        } else {
            buf[wi] = src[ri];
            wi += 1;
        }
    }
    return buf[0..wi];
}

/// Percent-encode `src` into `buf` per RFC 3986: the unreserved set
/// (`A-Z a-z 0-9 - _ . ~`) passes through unchanged, every other byte becomes
/// `%XX` with uppercase hex. This mirrors JavaScript's `encodeURIComponent`
/// closely enough that the daemon's `urlDecode` round-trips the result, so a
/// form value containing `&`, `=`, `%`, `+`, or a space survives transport
/// intact instead of being split or mis-decoded server-side. Returns the
/// encoded slice, or `error.NoSpaceLeft` when `buf` is too small (callers must
/// not silently truncate an encoded value — that would corrupt it).
pub fn percentEncode(buf: []u8, src: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var w: usize = 0;
    for (src) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            if (w + 1 > buf.len) return error.NoSpaceLeft;
            buf[w] = ch;
            w += 1;
        } else {
            if (w + 3 > buf.len) return error.NoSpaceLeft;
            buf[w] = '%';
            buf[w + 1] = hex[ch >> 4];
            buf[w + 2] = hex[ch & 0x0F];
            w += 3;
        }
    }
    return buf[0..w];
}

/// Build a `key=value&...` body string from a slice of (key, value) pairs.
/// Returns a suffix slice of `buf` containing the encoded body.
pub fn buildBody(buf: []u8, pairs: []const [2][]const u8) ![]const u8 {
    var pos: usize = 0;
    for (pairs) |pair| {
        try appendPair(buf, &pos, pair[0], pair[1]);
    }
    return buf[0..pos];
}

// ── Tests ───────────────────────────────────────────────────────────

test "appendPair: single key-value" {
    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    try appendPair(&buf, &pos, "name", "test-vm");
    try std.testing.expectEqualStrings("name=test-vm&", buf[0..pos]);
    try std.testing.expectEqual(@as(usize, 13), pos);
}

test "appendPair: multiple pairs" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    try appendPair(&buf, &pos, "name", "ubuntu");
    try appendPair(&buf, &pos, "mem", "4096");
    try appendPair(&buf, &pos, "cpu", "4");
    try std.testing.expectEqualStrings("name=ubuntu&mem=4096&cpu=4&", buf[0..pos]);
}

test "appendPair: empty value" {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    try appendPair(&buf, &pos, "notes", "");
    try std.testing.expectEqualStrings("notes=&", buf[0..pos]);
}

test "appendPair: buffer full" {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expectError(error.NoSpaceLeft, appendPair(&buf, &pos, "key", "value"));
}

test "appendPair: exact fit" {
    var buf: [9]u8 = undefined;
    var pos: usize = 0;
    try appendPair(&buf, &pos, "k", "v");
    try std.testing.expectEqualStrings("k=v&", buf[0..pos]);
}

test "buildBody: empty pairs" {
    var buf: [16]u8 = undefined;
    const result = try buildBody(&buf, &.{});
    try std.testing.expectEqualStrings("", result);
}

test "buildBody: typical save body" {
    var buf: [256]u8 = undefined;
    const result = try buildBody(&buf, &.{
        .{ "name", "test" },
        .{ "mem", "2048" },
        .{ "cpu", "2" },
        .{ "guest_tools", "1" },
        .{ "autoprotect", "0" },
    });
    try std.testing.expectEqualStrings("name=test&mem=2048&cpu=2&guest_tools=1&autoprotect=0&", result);
}

test "buildBody: special characters in value pass through" {
    var buf: [128]u8 = undefined;
    const result = try buildBody(&buf, &.{
        .{ "path", "/home/user/vm disk.qcow2" },
        .{ "mac", "00:11:22:33:44:55" },
    });
    try std.testing.expectEqualStrings("path=/home/user/vm disk.qcow2&mac=00:11:22:33:44:55&", result);
}

test "fuzz: buildBody never panics on random key-value pairs" {
    var prng = std.Random.DefaultPrng.init(0xB1_CE);
    const rnd = prng.random();
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    var out_buf: [2048]u8 = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const n_pairs = rnd.uintLessThan(usize, 50);
        var pos: usize = 0;
        for (0..n_pairs) |_| {
            for (&key_buf) |*c| c.* = rnd.int(u8);
            for (&val_buf) |*c| c.* = rnd.int(u8);
            _ = appendPair(&out_buf, &pos, &key_buf, &val_buf) catch break;
        }
    }
}

test "percentEncode: unreserved characters pass through" {
    var buf: [64]u8 = undefined;
    const result = try percentEncode(&buf, "Abc-123_x.y~z");
    try std.testing.expectEqualStrings("Abc-123_x.y~z", result);
}

test "percentEncode: reserved characters and space are escaped" {
    var buf: [64]u8 = undefined;
    const result = try percentEncode(&buf, "a b&c=d%e+f");
    try std.testing.expectEqualStrings("a%20b%26c%3Dd%25e%2Bf", result);
}

test "percentEncode: empty string" {
    var buf: [4]u8 = undefined;
    const result = try percentEncode(&buf, "");
    try std.testing.expectEqualStrings("", result);
}

test "percentEncode: NoSpaceLeft when buffer too small" {
    var buf: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, percentEncode(&buf, "&&"));
}

test "percentEncode: round-trips through urlDecode" {
    var enc_buf: [256]u8 = undefined;
    var dec_buf: [256]u8 = undefined;
    const original = "my vm & co + 50% /path";
    const encoded = try percentEncode(&enc_buf, original);
    const decoded = urlDecode(&dec_buf, encoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "fuzz: percentEncode round-trips and never panics" {
    var prng = std.Random.DefaultPrng.init(0xE0_DE);
    const rnd = prng.random();
    var input: [128]u8 = undefined;
    var enc_buf: [512]u8 = undefined;
    var dec_buf: [512]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len);
        for (input[0..len]) |*c| c.* = rnd.int(u8);
        const encoded = percentEncode(&enc_buf, input[0..len]) catch continue;
        const decoded = urlDecode(&dec_buf, encoded);
        try std.testing.expectEqualSlices(u8, input[0..len], decoded);
    }
}

test "urlDecode: plain string passes through" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "hello world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode: percent-encoded space" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "hello%20world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode: plus to space" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "hello+world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "urlDecode: mixed encoding" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "foo%20bar+baz");
    try std.testing.expectEqualStrings("foo bar baz", result);
}

test "urlDecode: special characters" {
    var buf: [64]u8 = undefined;
    const result = urlDecode(&buf, "%2Ftmp%2Fdisk%2Eimg");
    try std.testing.expectEqualStrings("/tmp/disk.img", result);
}

test "urlDecode: empty string" {
    var buf: [8]u8 = undefined;
    const result = urlDecode(&buf, "");
    try std.testing.expectEqualStrings("", result);
}

test "urlDecode: invalid percent sequence kept as-is" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "foo%XXbar");
    try std.testing.expectEqualStrings("foo%XXbar", result);
}

test "urlDecode: truncated percent at end" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "foo%2");
    try std.testing.expectEqualStrings("foo%2", result);
}

test "urlDecode: truncated percent at end of buffer" {
    var buf: [32]u8 = undefined;
    const result = urlDecode(&buf, "foo%");
    try std.testing.expectEqualStrings("foo%", result);
}

test "urlDecode: all printable ascii round-trip" {
    var buf: [128]u8 = undefined;
    var enc_buf: [512]u8 = undefined;
    // Encode all printable chars that are special in URLs
    var ei: usize = 0;
    for (0..128) |c| {
        if (c == ' ') {
            @memcpy(enc_buf[ei..][0..3], "%20");
            ei += 3;
        } else if (c == '%') {
            @memcpy(enc_buf[ei..][0..3], "%25");
            ei += 3;
        } else if (c == '+') {
            @memcpy(enc_buf[ei..][0..3], "%2B");
            ei += 3;
        } else {
            enc_buf[ei] = @intCast(c);
            ei += 1;
        }
    }
    const encoded = enc_buf[0..ei];
    const decoded = urlDecode(&buf, encoded);
    // Decoding must reproduce every original byte (0..127) exactly: the
    // %-escaped space/%/+ collapse back and all literals pass through.
    var expected: [128]u8 = undefined;
    for (0..128) |c| expected[c] = @intCast(c);
    try std.testing.expectEqualSlices(u8, &expected, decoded);
}

test "urlDecode: output bounded to buffer, no overflow on oversized input" {
    // Src far larger than the destination buffer must not write past `buf`.
    // Surround a small buffer with canaries and confirm they survive.
    var guard_front: [8]u8 = [_]u8{0xAA} ** 8;
    var buf: [8]u8 = undefined;
    var guard_back: [8]u8 = [_]u8{0xBB} ** 8;
    var input: [256]u8 = [_]u8{'a'} ** 256;
    const result = urlDecode(&buf, &input);
    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xAA} ** 8), &guard_front);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xBB} ** 8), &guard_back);
}

test "fuzz: urlDecode never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xDE_C0);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var input: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        for (&input) |*c| c.* = rnd.int(u8);
        _ = urlDecode(&buf, &input);
    }
}

test "fuzz: urlDecode never overflows an undersized buffer" {
    // Buffer is smaller than the input, the exact condition the request
    // handlers hit on oversized form values. Output must stay within `buf`.
    var prng = std.Random.DefaultPrng.init(0x0F_F1);
    const rnd = prng.random();
    var buf: [16]u8 = undefined;
    var input: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len);
        for (input[0..len]) |*c| c.* = rnd.int(u8);
        const out = urlDecode(&buf, input[0..len]);
        try std.testing.expect(out.len <= buf.len);
    }
}
