// SPDX-License-Identifier: MIT
//! Physical host capacity (CPU core count + total RAM) for the dashboard's
//! capacity-planning view: VM-allocated totals are only meaningful next to what
//! the host actually has. Linux-only; read once per request (cheap).

const std = @import("std");

/// Number of online CPUs the host exposes, or 0 if it can't be determined.
pub fn cpuCount() u32 {
    const n = std.Thread.getCpuCount() catch return 0;
    return @intCast(@min(n, std.math.maxInt(u32)));
}

/// Total physical RAM in MiB parsed from /proc/meminfo, or 0 on any failure.
pub fn totalRamMb() u32 {
    var buf: [4096]u8 = undefined;
    const fd = std.c.open("/proc/meminfo", .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    return parseMemTotalMb(buf[0..@intCast(n)]);
}

/// Parse the "MemTotal:    N kB" line of /proc/meminfo into MiB. Pure so it is
/// unit/fuzz testable against captured (and adversarial) meminfo content.
pub fn parseMemTotalMb(text: []const u8) u32 {
    const key = "MemTotal:";
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var i = at + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') i += 1;
    if (i == start) return 0;
    const kb = std.fmt.parseInt(u64, text[start..i], 10) catch return 0;
    return @intCast(@min(kb / 1024, std.math.maxInt(u32)));
}

/// Host capacity as JSON into `buf`: physical cores + total RAM (MiB).
pub fn hostJson(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"cpu_cores\":{d},\"ram_mb\":{d}}}", .{ cpuCount(), totalRamMb() }) catch "{}";
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "hostinfo: parseMemTotalMb extracts MiB from a meminfo sample" {
    const sample = "MemTotal:       16384000 kB\nMemFree:         8000000 kB\n";
    try t.expectEqual(@as(u32, 16000), parseMemTotalMb(sample)); // 16384000/1024
}

test "hostinfo: parseMemTotalMb returns 0 on absent/garbage" {
    try t.expectEqual(@as(u32, 0), parseMemTotalMb("MemFree: 100 kB\n"));
    try t.expectEqual(@as(u32, 0), parseMemTotalMb("MemTotal:\n"));
    try t.expectEqual(@as(u32, 0), parseMemTotalMb(""));
    try t.expectEqual(@as(u32, 0), parseMemTotalMb("MemTotal:    notanumber kB"));
}

test "hostinfo: cpuCount is positive on a real host" {
    try t.expect(cpuCount() > 0);
}

test "fuzz: parseMemTotalMb never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x4057_0001);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = parseMemTotalMb(buf[0..len]);
    }
}

test "hostinfo: hostJson is well-formed" {
    var buf: [128]u8 = undefined;
    const j = hostJson(&buf);
    try t.expect(std.mem.indexOf(u8, j, "\"cpu_cores\":") != null);
    try t.expect(std.mem.indexOf(u8, j, "\"ram_mb\":") != null);
}
