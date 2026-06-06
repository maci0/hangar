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

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "appio: io() returns a usable instance and caches it" {
    const a = io();
    const b = io(); // second call must hit the cached instance, not re-init
    try testing.expect(ready);
    try testing.expect(std.meta.eql(a, b)); // same cached Io, not a fresh instance
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
