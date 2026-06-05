// SPDX-License-Identifier: MIT
//! Pure ring-buffer append for the serial console.
//!
//! The serial reader thread feeds this guest-controlled byte chunks of
//! arbitrary size; it must never write out of bounds and must always keep
//! the most recent bytes when the buffer overflows.

const std = @import("std");

/// Append `chunk` to a ring buffer `buf` that currently holds `len` valid
/// bytes (`buf[0..len]`). On overflow, oldest bytes are dropped so the most
/// recent `buf.len` bytes are retained. Returns the new valid length
/// (always `<= buf.len`).
pub fn append(buf: []u8, len: usize, chunk: []const u8) usize {
    const cap = buf.len;
    const n = chunk.len;
    if (n == 0) return @min(len, cap);

    const cur = @min(len, cap);
    const space = cap - cur;
    if (n <= space) {
        @memcpy(buf[cur..][0..n], chunk);
        return cur + n;
    }

    // Not enough room. Keep only the most recent `cap` bytes overall.
    if (n >= cap) {
        // The chunk alone fills (or overfills) the buffer — keep its tail.
        @memcpy(buf[0..cap], chunk[n - cap ..]);
        return cap;
    }

    // Drop the oldest `shift` existing bytes, then append the whole chunk.
    const shift = n - space; // 0 < shift <= cur, since n < cap
    std.mem.copyForwards(u8, buf[0 .. cur - shift], buf[shift..cur]);
    const new_len = cur - shift;
    @memcpy(buf[new_len..][0..n], chunk);
    return new_len + n;
}

test "append: fits without overflow" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    len = append(&buf, len, "abc");
    try std.testing.expectEqual(@as(usize, 3), len);
    len = append(&buf, len, "de");
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, "abcde", buf[0..len]);
}

test "append: overflow keeps the most recent bytes" {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    len = append(&buf, len, "12345678"); // exactly fills
    len = append(&buf, len, "ABC"); // pushes out "123"
    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqualSlices(u8, "45678ABC", buf[0..len]);
}

test "append: chunk larger than buffer keeps its tail" {
    var buf: [4]u8 = undefined;
    const len = append(&buf, 0, "abcdefgh");
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqualSlices(u8, "efgh", buf[0..len]);
}

test "fuzz: append never overflows and preserves the recent tail" {
    var prng = std.Random.DefaultPrng.init(0x9E37_79B9);
    const rnd = prng.random();

    // A reference stream of everything appended, to check the tail invariant.
    var ref: [70000]u8 = undefined;
    var ref_len: usize = 0;

    var ring: [4096]u8 = undefined;
    var len: usize = 0;
    var chunk: [5000]u8 = undefined;

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const cn = rnd.uintLessThan(usize, chunk.len + 1);
        for (chunk[0..cn]) |*b| b.* = rnd.int(u8);

        // If the reference can't hold this chunk, restart BOTH from empty so
        // the ring and the reference stay in sync (a common fresh start keeps
        // `ref_len >= len` invariant valid).
        if (ref_len + cn > ref.len) {
            len = 0;
            ref_len = 0;
        }

        len = append(&ring, len, chunk[0..cn]);
        try std.testing.expect(len <= ring.len);

        @memcpy(ref[ref_len..][0..cn], chunk[0..cn]);
        ref_len += cn;

        // The ring must equal the last `len` bytes of the reference stream.
        try std.testing.expect(ref_len >= len);
        try std.testing.expectEqualSlices(u8, ref[ref_len - len .. ref_len], ring[0..len]);
    }
}

test "append: empty chunk is no-op" {
    var buf: [8]u8 = undefined;
    var len: usize = 3;
    @memcpy(buf[0..3], "ABC");
    len = append(&buf, len, "");
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqualSlices(u8, "ABC", buf[0..len]);
}

test "append: zero-length buffer" {
    var buf: [0]u8 = undefined;
    const len = append(&buf, 0, "hello");
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "append: chunk exactly equals available space" {
    var buf: [6]u8 = undefined;
    var len: usize = 0;
    len = append(&buf, len, "123");
    len = append(&buf, len, "456"); // exactly fills remaining 3
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqualSlices(u8, "123456", buf[0..len]);
}

test "append: gradual overflow shifts correctly" {
    var buf: [5]u8 = undefined;
    var len: usize = 0;
    len = append(&buf, len, "abcde"); // exactly fills
    try std.testing.expectEqual(@as(usize, 5), len);
    len = append(&buf, len, "f"); // pushes out 'a'
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, "bcdef", buf[0..len]);
    len = append(&buf, len, "gh"); // pushes out 'b','c'
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, "defgh", buf[0..len]);
}

test "fuzz: append random sequences maintain length invariant" {
    var prng = std.Random.DefaultPrng.init(0xB00B_1234);
    const rnd = prng.random();
    var ring: [63]u8 = undefined; // odd size, not power of 2
    var len: usize = 0;
    var chunk: [100]u8 = undefined;
    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        const cn = rnd.uintLessThan(usize, chunk.len + 1);
        for (chunk[0..cn]) |*b| b.* = rnd.int(u8);
        len = append(&ring, len, chunk[0..cn]);
        try std.testing.expect(len <= ring.len);
        if (len > 0) try std.testing.expect(len <= ring.len);
    }
}
