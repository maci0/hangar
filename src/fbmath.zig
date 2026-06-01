//! Pure framebuffer geometry math + pixel conversion helpers.
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

/// Convert BGRA pixels to RGBA.
/// `src` contains BGRA data with `src_stride` bytes per row;
/// `dst` receives RGBA data with `dst_stride` bytes per row.
/// Each row has `width` pixels (4 bytes each).
/// Caller ensures buffers are large enough.
pub fn bgraToRgba(
    dst: []u8,
    src: []const u8,
    width: usize,
    rows: usize,
    src_stride: usize,
    dst_stride: usize,
) void {
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row = src[y * src_stride ..];
        const dst_row = dst[y * dst_stride ..];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const si = x * 4;
            const di = x * 4;
            dst_row[di + 0] = src_row[si + 2]; // R ← B
            dst_row[di + 1] = src_row[si + 1]; // G ← G
            dst_row[di + 2] = src_row[si + 0]; // B ← R
            dst_row[di + 3] = src_row[si + 3]; // A ← A
        }
    }
}

// ── fbFits tests ────────────────────────────────────────────────────

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

// ── bgraToRgba tests ────────────────────────────────────────────────

test "bgraToRgba: single pixel conversion" {
    const src = [_]u8{ 0x11, 0x22, 0x33, 0x44 }; // B=0x11, G=0x22, R=0x33, A=0x44
    var dst = [_]u8{ 0, 0, 0, 0 };
    bgraToRgba(&dst, &src, 1, 1, 4, 4);
    try std.testing.expectEqual(@as(u8, 0x33), dst[0]); // R ← B=0x11
    try std.testing.expectEqual(@as(u8, 0x22), dst[1]); // G ← G=0x22
    try std.testing.expectEqual(@as(u8, 0x11), dst[2]); // B ← R=0x33
    try std.testing.expectEqual(@as(u8, 0x44), dst[3]); // A ← A=0x44
}

test "bgraToRgba: 2x2 pixel conversion with stride" {
    // 2x2 image, src_stride=12 (2 pixels + 4 padding bytes), dst_stride=8
    const src = [_]u8{
        0x01, 0x02, 0x03, 0x04,  0x05, 0x06, 0x07, 0x08,  0, 0, 0, 0, // row 0
        0x11, 0x12, 0x13, 0x14,  0x15, 0x16, 0x17, 0x18,  0, 0, 0, 0, // row 1
    };
    var dst = [_]u8{0} ** 16;
    bgraToRgba(&dst, &src, 2, 2, 12, 8);
    // Row 0, pixel 0: B=01,G=02,R=03,A=04 → R=03,G=02,B=01,A=04
    try std.testing.expectEqual(@as(u8, 3), dst[0]);  // R ← B=1
    try std.testing.expectEqual(@as(u8, 2), dst[1]);  // G ← G=2
    try std.testing.expectEqual(@as(u8, 1), dst[2]);  // B ← R=3
    try std.testing.expectEqual(@as(u8, 4), dst[3]);  // A ← A=4
    // Row 0, pixel 1: B=05,G=06,R=07,A=08 → R=07,G=06,B=05,A=08
    try std.testing.expectEqual(@as(u8, 7), dst[4]);  // R ← B=5
    try std.testing.expectEqual(@as(u8, 6), dst[5]);  // G ← G=6
    try std.testing.expectEqual(@as(u8, 5), dst[6]);  // B ← R=7
    try std.testing.expectEqual(@as(u8, 8), dst[7]);  // A ← A=8
    // Row 1, pixel 0
    try std.testing.expectEqual(@as(u8, 0x13), dst[8]);  // R ← B=0x11
    try std.testing.expectEqual(@as(u8, 0x12), dst[9]);  // G ← G=0x12
    try std.testing.expectEqual(@as(u8, 0x11), dst[10]); // B ← R=0x13
    try std.testing.expectEqual(@as(u8, 0x14), dst[11]); // A ← A=0x14
}

test "bgraToRgba: identity round-trip (apply twice = original)" {
    const w: usize = 16;
    const h: usize = 8;
    var prng = std.Random.DefaultPrng.init(0xCAFE);
    const rnd = prng.random();
    var src: [16 * 8 * 4]u8 = undefined;
    for (&src) |*b| b.* = rnd.int(u8);
    var tmp = [_]u8{0} ** (16 * 8 * 4);
    var dst = [_]u8{0} ** (16 * 8 * 4);
    bgraToRgba(&tmp, &src, w, h, w * 4, w * 4);
    bgraToRgba(&dst, &tmp, w, h, w * 4, w * 4);
    // After two conversions, we should get the original back.
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "bgraToRgba: zero-size no-ops" {
    var dummy: [4]u8 = undefined;
    // width=0: no panic
    bgraToRgba(&dummy, &dummy, 0, 0, 4, 4);
    bgraToRgba(&dummy, &dummy, 1, 0, 4, 4);
    bgraToRgba(&dummy, &dummy, 0, 1, 4, 4);
}

test "fuzz: bgraToRgba never panics on random dimensions" {
    var prng = std.Random.DefaultPrng.init(0xDECAF);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const w = rnd.uintLessThan(usize, 64);
        const h = rnd.uintLessThan(usize, 32);
        const src_stride = w * 4 + rnd.uintLessThan(usize, 16); // stride can differ
        const dst_stride = w * 4 + rnd.uintLessThan(usize, 16);
        const src_buf_size = h * src_stride;
        const dst_buf_size = h * dst_stride;
        if (src_buf_size == 0 or dst_buf_size == 0) continue;
        const src = std.testing.allocator.alloc(u8, src_buf_size) catch continue;
        defer std.testing.allocator.free(src);
        const dst = std.testing.allocator.alloc(u8, dst_buf_size) catch continue;
        defer std.testing.allocator.free(dst);
        for (src) |*b| b.* = rnd.int(u8);
        // Must never panic.
        bgraToRgba(dst, src, w, h, src_stride, dst_stride);
    }
}
