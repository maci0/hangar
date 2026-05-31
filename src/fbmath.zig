//! Pure framebuffer geometry math.
//!
//! Split out of `display.zig` so it can be fuzzed without pulling in IUP.
//! Remote VNC/SPICE servers report the framebuffer width/height, so these are
//! untrusted `c_int` values — `fw * fh` must not overflow `i32` before the
//! size check (a forged/huge guest video mode otherwise crashes the UI).

const std = @import("std");

/// Returns the pixel count `fw*fh` if a 4-byte-per-pixel framebuffer of those
/// dimensions fits in `cap` bytes; otherwise `null` (non-positive, overflowing,
/// or too large). The multiply is done in `u64` so `i32` math can't overflow.
pub fn fbFits(fw: c_int, fh: c_int, cap: usize) ?usize {
    if (fw <= 0 or fh <= 0) return null;
    const px = @as(u64, @intCast(fw)) * @as(u64, @intCast(fh));
    if (px > @as(u64, std.math.maxInt(usize) / 4)) return null; // px*4 would overflow usize
    if (px * 4 > cap) return null;
    return @intCast(px);
}

test "fbFits: rejects non-positive dimensions" {
    try std.testing.expectEqual(@as(?usize, null), fbFits(0, 100, 1 << 30));
    try std.testing.expectEqual(@as(?usize, null), fbFits(100, 0, 1 << 30));
    try std.testing.expectEqual(@as(?usize, null), fbFits(-1, -1, 1 << 30));
}

test "fbFits: accepts normal dimensions" {
    try std.testing.expectEqual(@as(?usize, 1920 * 1080), fbFits(1920, 1080, 3840 * 2160 * 4));
}

test "fbFits: rejects dimensions that exceed the cap" {
    try std.testing.expectEqual(@as(?usize, null), fbFits(3840, 2161, 3840 * 2160 * 4));
}

test "fbFits: huge dimensions that overflow i32 do not crash" {
    // 50000*50000 = 2.5e9 > i32 max — the old `fw*fh` (c_int) panicked here.
    try std.testing.expectEqual(@as(?usize, null), fbFits(50000, 50000, 3840 * 2160 * 4));
    try std.testing.expectEqual(@as(?usize, null), fbFits(std.math.maxInt(c_int), std.math.maxInt(c_int), 3840 * 2160 * 4));
}

test "fuzz: fbFits never overflows and honors the cap" {
    const cap: usize = 3840 * 2160 * 4;
    var prng = std.Random.DefaultPrng.init(0xF00D_F00D);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 10000) : (iter += 1) {
        // Bias toward i32 extremes plus fully random values.
        const fw: c_int = if (rnd.boolean()) rnd.int(c_int) else @intCast(rnd.uintLessThan(u32, 100000));
        const fh: c_int = if (rnd.boolean()) rnd.int(c_int) else @intCast(rnd.uintLessThan(u32, 100000));
        if (fbFits(fw, fh, cap)) |n| {
            // When accepted, the framebuffer must genuinely fit.
            try std.testing.expect(n * 4 <= cap);
            try std.testing.expect(fw > 0 and fh > 0);
        }
    }
}
