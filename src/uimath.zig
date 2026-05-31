//! Pure UI geometry / formatting helpers, extracted from the IUP-coupled
//! modules (display.zig, dialogs.zig, serial.zig) so they can be unit-tested
//! and fuzzed without IupOpen / a display / a socket. Same rationale as
//! `fbmath.zig`. No imports beyond `std`; deterministic; no IO.

const std = @import("std");

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

/// Top of the memory-bar scale (MB). Shared with dialogs.zig.
pub const MEM_BAR_MAX_MB: i64 = 32768;

/// Map a memory value (MB) to an x pixel on a bar `w` px wide. Clamps the
/// value to `[0, MEM_BAR_MAX_MB]`; result is in `[0, w]`.
pub fn memToX(mb: i64, w: i32) i32 {
    const clamped = std.math.clamp(mb, 0, MEM_BAR_MAX_MB);
    const frac = @as(f64, @floatFromInt(clamped)) / @as(f64, @floatFromInt(MEM_BAR_MAX_MB));
    return @intFromFloat(frac * @as(f64, @floatFromInt(w)));
}

// ── Serial console socket path builder ───────────────────────────────

/// Build `/tmp/kvmgui-serial-<vm_name>.sock` into `buf`, NUL-terminating it.
/// Returns the byte length (excluding NUL), or null if it would not fit in
/// `buf` (caller keeps its previous value). Pure: no filesystem access.
pub fn serialSocketPath(buf: []u8, vm_name: []const u8) ?usize {
    const prefix = "/tmp/kvmgui-serial-";
    const suffix = ".sock";
    const total = prefix.len + vm_name.len + suffix.len;
    if (total + 1 > buf.len) return null; // +1 for NUL
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..vm_name.len], vm_name);
    @memcpy(buf[prefix.len + vm_name.len ..][0..suffix.len], suffix);
    buf[total] = 0;
    return total;
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

test "serialSocketPath: builds and NUL-terminates" {
    var buf: [256]u8 = undefined;
    const n = serialSocketPath(&buf, "myvm").?;
    try t.expectEqualStrings("/tmp/kvmgui-serial-myvm.sock", buf[0..n]);
    try t.expectEqual(@as(u8, 0), buf[n]);
}

test "serialSocketPath: rejects names that overflow the buffer" {
    var small: [16]u8 = undefined;
    try t.expect(serialSocketPath(&small, "anything") == null);
    var buf: [256]u8 = undefined;
    const huge = "x" ** 300;
    try t.expect(serialSocketPath(&buf, huge) == null);
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

test "fuzz: serialSocketPath never overflows and round-trips length" {
    var prng = std.Random.DefaultPrng.init(0x5E71A1FF);
    const rnd = prng.random();
    var name: [400]u8 = undefined;
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 6000) : (i += 1) {
        const len = rnd.uintLessThan(usize, name.len);
        for (name[0..len]) |*c| c.* = rnd.intRangeAtMost(u8, 'a', 'z');
        if (serialSocketPath(&buf, name[0..len])) |n| {
            try t.expect(n < buf.len);
            try t.expectEqual(@as(u8, 0), buf[n]);
            try t.expectEqualStrings("/tmp/kvmgui-serial-", buf[0..19]);
        }
    }
}
