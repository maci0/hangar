// SPDX-License-Identifier: MIT
//! Process-wide `std.Io` instance and small timing helpers.
//!
//! Zig 0.16 routes filesystem, process, and networking calls through the
//! `std.Io` interface, which must be threaded through every call. Hangar's web
//! server and its background tickers all run synchronous blocking I/O, so we
//! keep a single lazily-initialised threaded `Io` and hand it out on demand
//! rather than plumbing it through every function.

const std = @import("std");
const sync = @import("sync.zig");

var instance: std.Io.Threaded = undefined;
var ready: bool = false;
var ready_mutex: sync.SpinMutex = .{};

/// Return the shared `Io`. Lazily initialised on first use.
///
/// Thread-safe: request handlers and background tickers may call this after
/// the web server has spawned worker threads.
pub fn io() std.Io {
    if (!@atomicLoad(bool, &ready, .acquire)) {
        ready_mutex.lock();
        defer ready_mutex.unlock();
        if (!ready) {
            instance = std.Io.Threaded.init(std.heap.c_allocator, .{});
            @atomicStore(bool, &ready, true, .release);
        }
    }
    return instance.io();
}

/// Look up an environment variable. Replaces `std.posix.getenv`, removed in
/// 0.16. Backed by libc `getenv` (libc is always linked).
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.span(val);
}

/// Sleep for `ms` milliseconds. Replaces `std.Thread.sleep`, which 0.16
/// moved behind the `Io` interface.
pub fn sleepMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (std.c.nanosleep(&req, &req) != 0) {
        // Interrupted by a signal — resume with the remaining time.
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) break;
    }
}

/// Seconds since an arbitrary fixed point, from CLOCK.MONOTONIC. Immune to
/// wall-clock steps (NTP corrections, manual changes): use for elapsed-time
/// measurement and uptime; never compare across processes or machines.
pub fn monoSecs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @intCast(@max(0, ts.sec));
}

/// Write `data` to `file_path` atomically: stage into a temp file, fsync, then
/// rename over the destination so a crash never leaves a half-written file.
///
/// The file is created owner-only (`0o600`). Hangar's persisted state
/// (`vms.json`, `networks.json`) records VM names, disk/ISO paths and NIC MAC
/// addresses; on a shared host the default `0o644` would let any local user
/// read another user's VM inventory, so we restrict it at the single write
/// funnel rather than relying on the caller's umask.
///
/// Propagates the real error (NoSpaceLeft, AccessDenied, ...) rather than
/// masking it as a generic WriteFailed, so the actual cause reaches callers
/// (they typically log `@errorName(e)`).
pub fn writeFileAtomic(file_path: []const u8, data: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io(), file_path, .{
        .replace = true,
        .permissions = .fromMode(0o600),
    });
    defer af.deinit(io());

    try af.file.writeStreamingAll(io(), data);
    try af.file.sync(io());
    try af.replace(io());
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "appio: io() returns a usable instance and caches it" {
    const a = io();
    const b = io(); // second call must hit the cached instance, not re-init
    try testing.expect(ready);
    try testing.expect(std.meta.eql(a, b)); // same cached Io, not a fresh instance
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "appio: monoSecs never goes backwards" {
    const a = monoSecs();
    sleepMs(15);
    const b = monoSecs();
    try testing.expect(b >= a);
}

test "appio fuzz: monoSecs stays monotonic across rapid reads" {
    var prev = monoSecs();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const now = monoSecs();
        try testing.expect(now >= prev);
        prev = now;
    }
}

test "appio: getenv known + unknown" {
    _ = setenv("Hangar_TEST_VAR", "hello123", 1);
    try testing.expectEqualStrings("hello123", getenv("Hangar_TEST_VAR").?);
    try testing.expect(getenv("Hangar_DEFINITELY_UNSET_XYZ_42") == null);
}

test "appio: sleepMs waits at least the requested time" {
    var t0: std.c.timespec = undefined;
    var t1: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t0);
    sleepMs(25);
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t1);
    const elapsed_ms = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, std.time.ns_per_ms);
    try testing.expect(elapsed_ms >= 20); // requested 25, allow scheduler slack
}

test "appio fuzz: getenv never panics on random names" {
    var prng = std.Random.DefaultPrng.init(0xA7010A70);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const n = rnd.uintLessThan(usize, 128);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        if (n < buf.len) buf[n] = 0;
        _ = getenv(@ptrCast(&buf));
    }
}

test "appio fuzz: sleepMs tolerates random small durations" {
    var prng = std.Random.DefaultPrng.init(0xA7010A71);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const ms = rnd.uintLessThan(u64, 10);
        sleepMs(ms);
    }
}

test "appio: writeFileAtomic round-trips and overwrites" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-appio-atomic-{d}.txt", .{std.c.getpid()});
    defer _ = std.Io.Dir.cwd().deleteFile(io(), path) catch {};

    try writeFileAtomic(path, "first");
    const first = try std.Io.Dir.cwd().readFileAlloc(io(), path, testing.allocator, .limited(64));
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first", first);

    // A second write must atomically replace the prior contents.
    try writeFileAtomic(path, "second-longer");
    const second = try std.Io.Dir.cwd().readFileAlloc(io(), path, testing.allocator, .limited(64));
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("second-longer", second);
}

test "appio: writeFileAtomic creates owner-only (0o600) files" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-appio-atomic-mode-{d}.txt", .{std.c.getpid()});
    defer _ = std.Io.Dir.cwd().deleteFile(io(), path) catch {};

    try writeFileAtomic(path, "secret-ish config");

    // Stat the resulting file; persisted state must not be world/group readable.
    var f = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer f.close(io());
    const st = try f.stat(io());
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "appio fuzz: writeFileAtomic never panics on random byte payloads" {
    var prng = std.Random.DefaultPrng.init(0xA7010A72);
    const rnd = prng.random();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-appio-atomic-fuzz-{d}.txt", .{std.c.getpid()});
    defer _ = std.Io.Dir.cwd().deleteFile(io(), path) catch {};
    var data: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const n = rnd.uintLessThan(usize, data.len + 1);
        for (data[0..n]) |*b| b.* = rnd.int(u8);
        try writeFileAtomic(path, data[0..n]);
        const got = try std.Io.Dir.cwd().readFileAlloc(io(), path, testing.allocator, .limited(512));
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, data[0..n], got);
    }
}
