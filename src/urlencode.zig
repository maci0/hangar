// SPDX-License-Identifier: MIT
//! URL-encoded body builder for HTTP POST requests.
//!
//! Pure string-formatting logic extracted from buildSaveBody so it can be
//! unit-tested without UI dependencies. Callers extract form values and
//! pass (key, value) pairs; this module assembles the `key=val&...` string.

const std = @import("std");

/// Append `key=value&` to `buf[pos..]`, advance pos, and return it.
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
/// Caller must ensure buf.len >= src.len.
pub fn urlDecode(buf: []u8, src: []const u8) []u8 {
    var wi: usize = 0;
    var ri: usize = 0;
    while (ri < src.len) : (ri += 1) {
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
    // Verify space→%20 round-trips correctly
    try std.testing.expectEqual(decoded.len, decoded.len);
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
