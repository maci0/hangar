// SPDX-License-Identifier: MIT
//! Pure UI geometry / formatting helpers for the web frontend and
//! display rendering. Deterministic; no IO.

const std = @import("std");

// ── Toolbar: dynamic button sizing ───────────────────────────────────

/// Scale a set of reference button widths for a target window width.
/// Reference width is 1200; scale is clamped to [0.5, 2.0]; min width is 30.
pub fn scaleToolbarWidths(comptime N: usize, ref_w: [N]i32, ww: i32) [N]i32 {
    const REF_WIDTH: i32 = 1200;
    const scale: f64 = @max(0.5, @min(2.0, @as(f64, @floatFromInt(ww)) / @as(f64, @floatFromInt(REF_WIDTH))));
    var out: [N]i32 = undefined;
    for (ref_w, 0..) |bw, i| {
        out[i] = @max(30, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(bw)) * scale))));
    }
    return out;
}

/// Compute the gap between toolbar buttons for a given window width.
/// `scaled_w` has the (possibly scaled) button widths; `n_buttons` is the total count.
pub fn computeToolbarGap(ww: i32, scaled_w: []const i32, n_buttons: usize) i32 {
    // With 0 or 1 buttons there are no inter-button gaps; avoid /0.
    if (n_buttons <= 1) return 3;
    var tw: i32 = 0;
    for (scaled_w) |w| tw += w;
    return @max(3, @divTrunc(ww - 10 - tw, @as(i32, @intCast(n_buttons - 1))));
}

// ── Display: widget-space → framebuffer-space click mapping ──────────

/// Map a click at widget pixel `(x,y)` (widget size `w`×`h`) to framebuffer
/// coordinates for a framebuffer `fw`×`fh` drawn aspect-fit (letterboxed)
/// centered in the widget. Returns null for a degenerate framebuffer.
/// Result is always clamped into `[0,fw-1]`×`[0,fh-1]`.
pub fn mapCoords(w: c_int, h: c_int, fw: c_int, fh: c_int, x: c_int, y: c_int) ?[2]c_int {
    if (fw <= 0 or fh <= 0) return null;

    const scale = @min(
        @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(fw)),
        @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(fh)),
    );
    if (scale <= 0.0) return null;

    const off_x = @divTrunc(w - @as(c_int, @intFromFloat(@as(f64, @floatFromInt(fw)) * scale)), 2);
    const off_y = @divTrunc(h - @as(c_int, @intFromFloat(@as(f64, @floatFromInt(fh)) * scale)), 2);

    const vx_raw = @as(c_int, @intFromFloat(@as(f64, @floatFromInt(x - off_x)) / scale));
    const vy_raw = @as(c_int, @intFromFloat(@as(f64, @floatFromInt(y - off_y)) / scale));

    return .{
        std.math.clamp(vx_raw, 0, fw - 1),
        std.math.clamp(vy_raw, 0, fh - 1),
    };
}

// ── Memory guidance bar: MB → x pixel ────────────────────────────────

/// Top of the memory-bar scale (MB).
pub const MEM_BAR_MAX_MB: i64 = 32768;

/// Map a memory value (MB) to an x pixel on a bar `w` px wide. Clamps the
/// value to `[0, MEM_BAR_MAX_MB]`; result is in `[0, w]`.
pub fn memToX(mb: i64, w: i32) i32 {
    const clamped = std.math.clamp(mb, 0, MEM_BAR_MAX_MB);
    const frac = @as(f64, @floatFromInt(clamped)) / @as(f64, @floatFromInt(MEM_BAR_MAX_MB));
    return @intFromFloat(frac * @as(f64, @floatFromInt(w)));
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "mapCoords: 1:1 maps identically" {
    const r = mapCoords(800, 600, 800, 600, 100, 50).?;
    try t.expectEqual(@as(c_int, 100), r[0]);
    try t.expectEqual(@as(c_int, 50), r[1]);
}

test "mapCoords: 2x scale halves coordinates" {
    // fb 400x300 shown in 800x600 (scale 2, no letterbox).
    const r = mapCoords(800, 600, 400, 300, 400, 300).?;
    try t.expectEqual(@as(c_int, 200), r[0]);
    try t.expectEqual(@as(c_int, 150), r[1]);
}

test "mapCoords: degenerate framebuffer returns null" {
    try t.expect(mapCoords(800, 600, 0, 600, 1, 1) == null);
    try t.expect(mapCoords(800, 600, 800, -5, 1, 1) == null);
}

test "mapCoords: result always clamped in-bounds" {
    // Click far outside maps to a clamped edge, never out of range.
    const r = mapCoords(800, 600, 320, 240, 10000, 10000).?;
    try t.expect(r[0] >= 0 and r[0] < 320);
    try t.expect(r[1] >= 0 and r[1] < 240);
}

test "memToX: endpoints and clamping" {
    try t.expectEqual(@as(i32, 0), memToX(0, 200));
    try t.expectEqual(@as(i32, 200), memToX(MEM_BAR_MAX_MB, 200));
    try t.expectEqual(@as(i32, 200), memToX(MEM_BAR_MAX_MB * 4, 200)); // over-max clamps
    try t.expectEqual(@as(i32, 0), memToX(-999, 200)); // negative clamps
    try t.expectEqual(@as(i32, 0), memToX(2048, 0)); // zero-width bar
    const mid = memToX(MEM_BAR_MAX_MB / 2, 200);
    try t.expect(mid >= 99 and mid <= 101);
}

test "fuzz: mapCoords never panics, returns in-bounds or null" {
    var prng = std.Random.DefaultPrng.init(0xC0014A7E);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        const w = rnd.intRangeAtMost(c_int, -10, 4096);
        const h = rnd.intRangeAtMost(c_int, -10, 4096);
        const fw = rnd.intRangeAtMost(c_int, -10, 4096);
        const fh = rnd.intRangeAtMost(c_int, -10, 4096);
        const x = rnd.intRangeAtMost(c_int, -5000, 5000);
        const y = rnd.intRangeAtMost(c_int, -5000, 5000);
        if (mapCoords(w, h, fw, fh, x, y)) |r| {
            try t.expect(r[0] >= 0 and r[0] < fw);
            try t.expect(r[1] >= 0 and r[1] < fh);
        }
    }
}

test "fuzz: memToX always within [0, w] for non-negative w" {
    var prng = std.Random.DefaultPrng.init(0x3EE17E55);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        const w = rnd.intRangeAtMost(i32, 0, 4096);
        const mb = rnd.intRangeAtMost(i64, -1_000_000, 1_000_000);
        const x = memToX(mb, w);
        try t.expect(x >= 0 and x <= w);
    }
}

// ── Toolbar math tests ───────────────────────────────────────────────

test "scaleToolbarWidths: reference width 1200 produces no scaling" {
    const ref = [_]i32{ 80, 70, 55 };
    const got = scaleToolbarWidths(3, ref, 1200);
    for (ref, 0..) |expected, i| {
        try t.expectEqual(expected, got[i]);
    }
}

test "scaleToolbarWidths: 2400-wide window doubles widths" {
    const ref = [_]i32{ 80, 70, 55 };
    const got = scaleToolbarWidths(3, ref, 2400);
    try t.expectEqual(@as(i32, 160), got[0]);
    try t.expectEqual(@as(i32, 140), got[1]);
    try t.expectEqual(@as(i32, 110), got[2]);
}

test "scaleToolbarWidths: 600-wide window halves widths with floor" {
    const ref = [_]i32{ 80, 70, 55 };
    const got = scaleToolbarWidths(3, ref, 600);
    try t.expectEqual(@as(i32, 40), got[0]);
    try t.expectEqual(@as(i32, 35), got[1]);
    try t.expectEqual(@as(i32, 30), got[2]); // 27.5 → max(30, 28) = 30
}

test "scaleToolbarWidths: min width of 30 is enforced" {
    const ref = [_]i32{ 30, 20, 10 };
    const got = scaleToolbarWidths(3, ref, 300);
    try t.expect(got[0] >= 30);
    try t.expect(got[1] >= 30);
    try t.expect(got[2] >= 30);
}

test "scaleToolbarWidths: scale clamped to 2.0 max" {
    const ref = [_]i32{55};
    const got = scaleToolbarWidths(1, ref, 10000);
    try t.expectEqual(@as(i32, 110), got[0]); // 55 * 2.0 = 110
}

test "computeToolbarGap: even distribution" {
    const scaled = [_]i32{80} ** 15;
    const gap = computeToolbarGap(1200, &scaled, 15);
    try t.expectEqual(@as(i32, 3), gap);
}

test "computeToolbarGap: wider window increases gap" {
    const scaled = [_]i32{80} ** 15;
    const gap = computeToolbarGap(2400, &scaled, 15);
    try t.expectEqual(@as(i32, 85), gap);
}

test "computeToolbarGap: 0 or 1 button does not divide by zero" {
    const scaled = [_]i32{80};
    try t.expectEqual(@as(i32, 3), computeToolbarGap(1200, &scaled, 1));
    try t.expectEqual(@as(i32, 3), computeToolbarGap(1200, scaled[0..0], 0));
}

test "computeToolbarGap: gap at least 3" {
    const scaled = [_]i32{400} ** 15;
    const gap = computeToolbarGap(1200, &scaled, 15);
    try t.expectEqual(@as(i32, 3), gap);
}

test "scaleToolbarWidths + computeToolbarGap: full layout fits window" {
    const ref = [_]i32{ 80, 80, 80, 80, 80, 80, 80, 80, 75, 70, 75, 80, 70, 55, 55 };
    const scaled = scaleToolbarWidths(15, ref, 1200);
    const gap = computeToolbarGap(1200, &scaled, 15);
    var total: i32 = 10;
    for (scaled) |w| total += w;
    total += gap * @as(i32, @intCast(15 - 1));
    try t.expect(total <= 1200);
    try t.expect(total >= 1200 - gap);
}
