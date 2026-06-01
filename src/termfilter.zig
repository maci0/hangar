// SPDX-License-Identifier: MIT
//! Pure terminal-output sanitizer for the serial console. The guest emits
//! arbitrary bytes over the serial socket (binary, ANSI escapes, control
//! chars); before they reach the IUP text widget they are filtered to a safe
//! printable + whitespace subset. Extracted from serial.zig (which is IUP +
//! socket + thread coupled) so this untrusted-input surface can be fuzzed
//! without a display. No IO; deterministic; operates in place.

const std = @import("std");

/// Compact `buf[0..len]` in place, keeping only TAB/CR/LF and printable ASCII
/// (0x20..0x7E). Writes a trailing NUL at the new length and returns it.
/// `buf` must have room for the NUL (len < buf.len when len == buf capacity is
/// avoided by callers sizing buf one larger). Result length is always ≤ `len`.
pub fn sanitize(buf: []u8, len: usize) usize {
    const n = @min(len, buf.len);
    var out: usize = 0;
    for (buf[0..n]) |c| {
        if (c == '\n' or c == '\r' or c == '\t' or (c >= 32 and c <= 126)) {
            buf[out] = c;
            out += 1;
        }
    }
    if (out < buf.len) buf[out] = 0;
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

fn allowed(c: u8) bool {
    return c == '\n' or c == '\r' or c == '\t' or (c >= 32 and c <= 126);
}

test "sanitize: drops control/binary, keeps printable + ws" {
    var b = "a\x00b\x1b[0mC\tD\n\xffE".*;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..b.len], &b);
    const n = sanitize(&buf, b.len);
    try t.expectEqualStrings("ab[0mC\tD\nE", buf[0..n]);
    try t.expectEqual(@as(u8, 0), buf[n]);
}

test "sanitize: all-printable unchanged" {
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    try t.expectEqual(@as(usize, 5), sanitize(&buf, 5));
    try t.expectEqualStrings("hello", buf[0..5]);
}

test "sanitize: all-binary collapses to empty" {
    var buf: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try t.expectEqual(@as(usize, 0), sanitize(&buf, 8));
    try t.expectEqual(@as(u8, 0), buf[0]);
}

test "fuzz: sanitize output is bounded and contains only allowed bytes" {
    var prng = std.Random.DefaultPrng.init(0x7E2_F11);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = rnd.int(u8);
        const n = sanitize(&buf, len);
        try t.expect(n <= len); // never grows
        for (buf[0..n]) |c| try t.expect(allowed(c)); // only safe bytes survive
        if (n < buf.len) try t.expectEqual(@as(u8, 0), buf[n]); // NUL-terminated
    }
}
