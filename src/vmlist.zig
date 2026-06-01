// SPDX-License-Identifier: MIT
//! Pure VM list indexing helpers.
//!
//! Extracted from `appstate.zig` so the browser line→VM-index mapping
//! can be unit-tested without FLTK dependencies. Handles the favorites /
//! separator / non-favorites layout used by `refreshBrowser`.

const std = @import("std");
const vm = @import("vm.zig");
const filter_ = @import("filter.zig");

/// Given a 0-based browser line `target`, return the VM index it maps to,
/// or null if the line is the separator or out of range.
/// `vms` is the full VM array; `filter` is the current search string
/// (empty = show all).
pub fn lineToVmIndex(target: usize, vms: []const vm.VmConfig, filter: []const u8) ?usize {
    // Determine if separator is present: at least one fav AND one non-fav visible.
    var has_favs = false;
    var has_nonfavs = false;
    for (vms) |*v| {
        if (filter_.filterMatch(v, filter)) {
            if (v.favorite) has_favs = true else has_nonfavs = true;
        }
    }
    const has_sep = has_favs and has_nonfavs;

    var cursor: usize = 0;

    // Pass 1: favorites
    for (vms, 0..) |*v, i| {
        if (!v.favorite or !filter_.filterMatch(v, filter)) continue;
        if (cursor == target) return i;
        cursor += 1;
    }

    // Separator line
    if (has_sep) {
        if (cursor == target) return null;
        cursor += 1;
    }

    // Pass 2: non-favorites (or all if no favs)
    // Only enter pass 2 if non-favorites are visible; otherwise pass 1
    // already covered everything.
    if (has_nonfavs) {
        for (vms, 0..) |*v, i| {
            const eligible = if (has_sep) !v.favorite else true;
            if (!eligible or !filter_.filterMatch(v, filter)) continue;
            if (cursor == target) return i;
            cursor += 1;
        }
    }

    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

fn makeVm(name: []const u8, fav: bool) vm.VmConfig {
    var v: vm.VmConfig = .{};
    v.setName(name);
    v.favorite = fav;
    return v;
}

test "lineToVmIndex: empty list returns null" {
    var vms: [4]vm.VmConfig = undefined;
    try std.testing.expect(lineToVmIndex(0, vms[0..0], "") == null);
}

test "lineToVmIndex: single VM line 0" {
    var vms = [_]vm.VmConfig{makeVm("a", false)};
    try std.testing.expectEqual(@as(?usize, 0), lineToVmIndex(0, &vms, ""));
}

test "lineToVmIndex: single VM out of bounds" {
    var vms = [_]vm.VmConfig{makeVm("a", false)};
    try std.testing.expect(lineToVmIndex(1, &vms, "") == null);
}

test "lineToVmIndex: only favorites (no separator)" {
    var vms = [_]vm.VmConfig{ makeVm("A", true), makeVm("B", true), makeVm("C", true) };
    try std.testing.expectEqual(@as(?usize, 0), lineToVmIndex(0, &vms, ""));
    try std.testing.expectEqual(@as(?usize, 1), lineToVmIndex(1, &vms, ""));
    try std.testing.expectEqual(@as(?usize, 2), lineToVmIndex(2, &vms, ""));
    try std.testing.expect(lineToVmIndex(3, &vms, "") == null);
}

test "lineToVmIndex: only non-favorites (no separator)" {
    var vms = [_]vm.VmConfig{ makeVm("X", false), makeVm("Y", false) };
    try std.testing.expectEqual(@as(?usize, 0), lineToVmIndex(0, &vms, ""));
    try std.testing.expectEqual(@as(?usize, 1), lineToVmIndex(1, &vms, ""));
    try std.testing.expect(lineToVmIndex(2, &vms, "") == null);
}

test "lineToVmIndex: mixed fav+non-fav (separator present)" {
    var vms = [_]vm.VmConfig{ makeVm("fav1", true), makeVm("non1", false), makeVm("fav2", true), makeVm("non2", false) };
    // Layout: fav1(0), fav2(2), sep(→null), non1(1), non2(3)
    try std.testing.expectEqual(@as(?usize, 0), lineToVmIndex(0, &vms, "")); // fav1
    try std.testing.expectEqual(@as(?usize, 2), lineToVmIndex(1, &vms, "")); // fav2
    try std.testing.expect(lineToVmIndex(2, &vms, "") == null);              // separator
    try std.testing.expectEqual(@as(?usize, 1), lineToVmIndex(3, &vms, "")); // non1
    try std.testing.expectEqual(@as(?usize, 3), lineToVmIndex(4, &vms, "")); // non2
    try std.testing.expect(lineToVmIndex(5, &vms, "") == null);
}

test "lineToVmIndex: filtered — favs hidden, no separator" {
    var vms = [_]vm.VmConfig{ makeVm("fav_ubuntu", true), makeVm("non_debian", false), makeVm("non_arch", false) };
    // Filter "deb" → only non_debian visible, no favs visible → no separator
    try std.testing.expectEqual(@as(?usize, 1), lineToVmIndex(0, &vms, "deb"));
    try std.testing.expect(lineToVmIndex(1, &vms, "deb") == null);
}

test "lineToVmIndex: filtered — non-favs hidden, no separator" {
    var vms = [_]vm.VmConfig{ makeVm("fav_win", true), makeVm("non_linux", false), makeVm("fav_mac", true) };
    // Filter "fav" → fav_win(0), fav_mac(2) visible, no non-favs → no separator
    try std.testing.expectEqual(@as(?usize, 0), lineToVmIndex(0, &vms, "fav"));
    try std.testing.expectEqual(@as(?usize, 2), lineToVmIndex(1, &vms, "fav"));
    try std.testing.expect(lineToVmIndex(2, &vms, "fav") == null);
}

test "lineToVmIndex: filter excludes all" {
    var vms = [_]vm.VmConfig{ makeVm("abc", true), makeVm("def", false) };
    try std.testing.expect(lineToVmIndex(0, &vms, "zzz") == null);
}

test "fuzz: lineToVmIndex never panics and returns valid index or null" {
    var prng = std.Random.DefaultPrng.init(0xFEED0055);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, 20);
        var vms: [20]vm.VmConfig = [_]vm.VmConfig{.{}} ** 20;
        for (vms[0..n], 0..) |*v, i| {
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "vm{d}", .{i}) catch "x";
            v.setName(name);
            v.favorite = rnd.boolean();
        }
        // Also test with empty filter and random filter
        var filter_buf: [16]u8 = undefined;
        const flen = rnd.uintLessThan(usize, 10);
        for (filter_buf[0..flen]) |*b| b.* = rnd.int(u8);
        const filter = filter_buf[0..flen];

        const max_lines = n + 1; // upper bound: n VMs + maybe separator
        for (0..max_lines + 2) |line| {
            const result = lineToVmIndex(line, vms[0..n], filter);
            if (result) |idx| {
                try std.testing.expect(idx < n);
            }
        }
        // Empty filter: line 0 should always yield something if n > 0
        if (n > 0) {
            _ = lineToVmIndex(0, vms[0..n], "");
        }
    }
}
