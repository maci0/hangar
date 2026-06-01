// SPDX-License-Identifier: MIT
//! Small synchronisation primitives.
//!
//! Zig 0.16 removed `std.Thread.Mutex`; the blocking mutex now lives at
//! `std.Io.Mutex` and requires an `Io` instance threaded through every
//! lock/unlock. The framebuffer and serial-buffer critical sections here are
//! tiny memcpys, so a spin lock built on the io-free `std.atomic.Mutex` is
//! sufficient and keeps the call sites unchanged.

const std = @import("std");

pub const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "SpinMutex: lock then unlock is re-acquirable (single thread)" {
    var m = SpinMutex{};
    m.lock();
    m.unlock();
    m.lock(); // would spin forever if unlock failed to release
    m.unlock();
}

test "SpinMutex: mutual exclusion under contention keeps a counter exact" {
    var m = SpinMutex{};
    var counter: u64 = 0;
    const N = 4;
    const ITERS = 20_000;

    const Worker = struct {
        fn run(mx: *SpinMutex, c: *u64) void {
            var i: usize = 0;
            while (i < ITERS) : (i += 1) {
                mx.lock();
                // Non-atomic RMW — only correct if the lock truly serializes.
                c.* += 1;
                mx.unlock();
            }
        }
    };

    var threads: [N]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &counter });
    for (threads) |th| th.join();

    try std.testing.expectEqual(@as(u64, N * ITERS), counter);
}

test "SpinMutex: rapid lock/unlock cycle is stable" {
    var m = SpinMutex{};
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        m.lock();
        m.unlock();
    }
}

test "SpinMutex: tryLock-acquire-release pattern" {
    var m = SpinMutex{};
    // First lock via tryLock
    try std.testing.expect(m.inner.tryLock());
    // Second tryLock should fail (already locked)
    try std.testing.expect(!m.inner.tryLock());
    m.unlock();
    // Now it should succeed again
    try std.testing.expect(m.inner.tryLock());
    m.unlock();
}

test "fuzz: SpinMutex under random thread scheduling" {
    var m = SpinMutex{};
    var counter: u64 = 0;
    const N = 6;
    const ITERS = 5000;

    const Worker = struct {
        fn run(mx: *SpinMutex, c: *u64) void {
            var i: usize = 0;
            while (i < ITERS) : (i += 1) {
                mx.lock();
                const v = c.*;
                std.atomic.spinLoopHint(); // encourage interleaving
                c.* = v + 1;
                mx.unlock();
            }
        }
    };

    var threads: [N]std.Thread = undefined;
    for (&threads) |*th| th.* = std.Thread.spawn(.{}, Worker.run, .{ &m, &counter }) catch unreachable;
    for (threads) |th| th.join();

    try std.testing.expectEqual(@as(u64, N * ITERS), counter);
}
