// SPDX-License-Identifier: MIT
//! AutoProtect — scheduled automatic snapshots (VMware Workstation feature).
//!
//! Pure scheduling/naming/pruning logic, separated from the timer + qemu-img/QMP
//! IO so it can be unit-tested + fuzzed. The background ticker in `web_server.zig`
//! calls `due()` each tick; when true it takes a snapshot named by `snapName()`
//! and prunes the oldest
//! AutoProtect snapshots beyond the configured maximum (see `pruneExcess`).

const std = @import("std");

pub const PREFIX = "AutoProtect-";

/// True when an AutoProtect snapshot is due: feature enabled, a positive
/// interval, and at least `interval_min` minutes elapsed since `last_unix`.
/// `last_unix == 0` (never taken) is always due once enabled.
pub fn due(enabled: bool, interval_min: u32, last_unix: i64, now_unix: i64) bool {
    if (!enabled or interval_min == 0) return false;
    if (now_unix < last_unix) return false; // clock went backwards → wait
    // Widen to i128 so a huge (now - last) on adversarial inputs can't overflow.
    const elapsed: i128 = @as(i128, now_unix) - @as(i128, last_unix);
    return elapsed >= @as(i128, interval_min) * 60;
}

/// Format an AutoProtect snapshot name into `buf`: `AutoProtect-` + a 10-digit
/// zero-padded sequence (so lexical order == chronological order, making
/// "delete the smallest name" the same as "delete the oldest").
pub fn snapName(buf: []u8, seq: u32) []const u8 {
    return std.fmt.bufPrint(buf, PREFIX ++ "{d:0>10}", .{seq}) catch buf[0..0];
}

/// Is `name` an AutoProtect-managed snapshot?
pub fn isAutoName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, PREFIX);
}

/// How many of the existing AutoProtect snapshots must be deleted to stay at or
/// below `max` after a new one is added. `current_auto` is the count of
/// AutoProtect snapshots that currently exist (before adding the new one).
/// Returns the number of OLDEST AutoProtect snapshots the caller should delete.
pub fn pruneExcess(current_auto: usize, max: u32) usize {
    if (max == 0) return current_auto; // max 0 → keep none of the old ones
    const after_add = current_auto + 1;
    if (after_add <= max) return 0;
    return after_add - max;
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "due: respects enabled / interval / elapsed" {
    try t.expect(!due(false, 60, 0, 100000)); // disabled
    try t.expect(!due(true, 0, 0, 100000)); // zero interval
    try t.expect(due(true, 1, 0, 100000)); // never taken → due
    try t.expect(due(true, 1, 1000, 1000 + 60)); // exactly 1 min later
    try t.expect(!due(true, 1, 1000, 1000 + 59)); // 1s short
    try t.expect(!due(true, 5, 1000, 900)); // clock went backwards
    try t.expect(due(true, 60, 0, 3600)); // 60 min
}

test "snapName: prefixed + zero-padded + lexically ordered" {
    var b: [40]u8 = undefined;
    try t.expectEqualStrings("AutoProtect-0000000000", snapName(&b, 0));
    var b2: [40]u8 = undefined;
    try t.expectEqualStrings("AutoProtect-0000000042", snapName(&b2, 42));
    // Lexical order matches numeric order (key property for pruning).
    var lo: [40]u8 = undefined;
    var hi: [40]u8 = undefined;
    const a = snapName(&lo, 9);
    const c = snapName(&hi, 10);
    try t.expect(std.mem.order(u8, a, c) == .lt);
}

test "isAutoName" {
    try t.expect(isAutoName("AutoProtect-0000000001"));
    try t.expect(!isAutoName("manual-snap"));
    try t.expect(!isAutoName("AutoProtec"));
}

test "pruneExcess: keep at most max" {
    try t.expectEqual(@as(usize, 0), pruneExcess(0, 3)); // first → 1 total, ok
    try t.expectEqual(@as(usize, 0), pruneExcess(2, 3)); // 2→3, ok
    try t.expectEqual(@as(usize, 1), pruneExcess(3, 3)); // 3→4, drop 1
    try t.expectEqual(@as(usize, 3), pruneExcess(5, 3)); // 5→6, drop 3
    try t.expectEqual(@as(usize, 7), pruneExcess(7, 0)); // max 0 → drop all old
}

test "fuzz: due/pruneExcess never panic and stay sane" {
    var prng = std.Random.DefaultPrng.init(0xA070_9201);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        const en = rnd.boolean();
        const iv = rnd.int(u32);
        const last = rnd.int(i64);
        const now = rnd.int(i64);
        _ = due(en, iv, last, now); // must not panic/overflow
        const cur = rnd.uintLessThan(usize, 1000);
        const mx = rnd.uintLessThan(u32, 100);
        const p = pruneExcess(cur, mx);
        try t.expect(p <= cur + 1); // can't delete more than exist (+the new)
        if (mx > 0 and cur + 1 <= mx) try t.expect(p == 0);
    }
}

// ── Missing standalone coverage ─────────────────────────────────────

test "isAutoName: edge cases" {
    try t.expect(isAutoName("AutoProtect-0000000042"));
    try t.expect(isAutoName("AutoProtect-0000000000"));
    try t.expect(!isAutoName("AutoProtect")); // no dash+seq
    try t.expect(isAutoName("AutoProtect-")); // starts with prefix (no sequence but still matches)
    try t.expect(!isAutoName(""));
    try t.expect(!isAutoName("Something-0000000042"));
}

test "snapName: prefix + zero-padded sequence" {
    var b: [40]u8 = undefined;
    try t.expectEqualStrings("AutoProtect-0000000000", snapName(&b, 0));
    try t.expectEqualStrings("AutoProtect-0000000001", snapName(&b, 1));
    try t.expectEqualStrings("AutoProtect-4294967295", snapName(&b, 4294967295)); // max u32
}

test "snapName: buf too small returns empty" {
    var small: [10]u8 = undefined;
    const result = snapName(&small, 0);
    try t.expectEqual(@as(usize, 0), result.len);
}

test "due: large interval values" {
    try t.expect(due(true, 525600, 0, 1000000000)); // enabled, yearly interval
    try t.expect(!due(true, 525600, 1000000000, 1000000000)); // not yet due
}

test "pruneExcess: additional cases" {
    try t.expectEqual(@as(usize, 0), pruneExcess(0, 3));
    try t.expectEqual(@as(usize, 0), pruneExcess(2, 3));
    try t.expectEqual(@as(usize, 1), pruneExcess(3, 3));
    try t.expectEqual(@as(usize, 8), pruneExcess(10, 3));
    try t.expectEqual(@as(usize, 5), pruneExcess(5, 0));
    try t.expectEqual(@as(usize, 0), pruneExcess(0, 0)); // no old ones, delete none even though max is 0
}

test "due: interval zero disables" {
    try t.expect(!due(true, 0, 0, 1000000));
    try t.expect(!due(true, 0, 1000, 1000000));
}

test "fuzz: snapName/isAutoName never panic and stay bounded" {
    // snapName writes into caller buffers of any size (the buf-too-small branch
    // returns an empty slice) and isAutoName classifies untrusted snapshot tags
    // parsed out of `qemu-img snapshot -l` output. Neither had a fuzz harness.
    var prng = std.Random.DefaultPrng.init(0xA070_5EED);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        // snapName: vary the destination buffer size from far-too-small to ample
        // and feed arbitrary sequence numbers; output must fit and, when
        // non-empty, always be a valid AutoProtect name.
        var nbuf: [40]u8 = undefined;
        const cap = rnd.uintLessThan(usize, nbuf.len + 1);
        const seq = rnd.int(u32);
        const out = snapName(nbuf[0..cap], seq);
        try t.expect(out.len <= cap);
        if (out.len != 0) {
            try t.expect(isAutoName(out)); // round-trip: a produced name is "auto"
            try t.expect(std.mem.startsWith(u8, out, PREFIX));
        }

        // isAutoName: arbitrary bytes must never panic and must agree with a
        // direct prefix check.
        var rbuf: [48]u8 = undefined;
        const rlen = rnd.uintLessThan(usize, rbuf.len);
        for (rbuf[0..rlen]) |*b| b.* = rnd.int(u8);
        const name = rbuf[0..rlen];
        try t.expectEqual(std.mem.startsWith(u8, name, PREFIX), isAutoName(name));
    }
}
