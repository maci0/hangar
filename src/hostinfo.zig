// SPDX-License-Identifier: MIT
//! Physical host capacity (CPU core count + total RAM) for the dashboard's
//! capacity-planning view: VM-allocated totals are only meaningful next to what
//! the host actually has. Linux-only. Both values are invariant at runtime
//! (no CPU/RAM hotplug handling), so they are resolved once and cached; the
//! dashboard polls this endpoint alongside the VM list.

const std = @import("std");

/// Resolved-once caches; 0 means "not yet resolved" (or last attempt failed,
/// in which case we retry rather than pinning the failure).
var cpu_cache: u32 = 0;
var ram_cache: u32 = 0;

/// Number of online CPUs the host exposes, or 0 if it can't be determined.
pub fn cpuCount() u32 {
    const cached = @atomicLoad(u32, &cpu_cache, .acquire);
    if (cached != 0) return cached;
    const n = std.Thread.getCpuCount() catch return 0;
    if (n != 0) {
        const v: u32 = @intCast(@min(n, std.math.maxInt(u32)));
        @atomicStore(u32, &cpu_cache, v, .release);
        return v;
    }
    return 0;
}

/// Total physical RAM in MiB parsed from /proc/meminfo, or 0 on any failure.
pub fn totalRamMb() u32 {
    const cached = @atomicLoad(u32, &ram_cache, .acquire);
    if (cached != 0) return cached;
    var buf: [4096]u8 = undefined;
    const fd = std.c.open("/proc/meminfo", .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;
    const mb = parseMemTotalMb(buf[0..@intCast(n)]);
    if (mb != 0) @atomicStore(u32, &ram_cache, mb, .release);
    return mb;
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

test "hostinfo: cached capacity stays stable across calls" {
    // Second call must hit the cache and return the identical value.
    try t.expectEqual(cpuCount(), cpuCount());
    try t.expectEqual(totalRamMb(), totalRamMb());
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
