// SPDX-License-Identifier: MIT
//! Case-insensitive VM name filter helper.
//!
//! Pure logic extracted from appstate.zig so it can be unit-tested without
//! UI dependencies. Used by the VM list search/filter feature.

const std = @import("std");
const vm = @import("vm.zig");

/// Check whether a VM matches the filter string (case-insensitive substring).
/// An empty filter always matches (show all VMs).
pub fn filterMatch(v: *const vm.VmConfig, filter: []const u8) bool {
    if (filter.len == 0) return true;
    const name = v.getNameSlice();
    // VM names are capped at MAX_NAME; a filter longer than the name can never
    // be a substring. Rejecting early gives the right answer and guarantees
    // both inputs fit the MAX_NAME-sized lowercase buffers below.
    if (filter.len > name.len) return false;
    var name_buf: [vm.MAX_NAME + 1]u8 = undefined;
    var filter_buf: [vm.MAX_NAME + 1]u8 = undefined;
    const lower_name = std.ascii.lowerString(name_buf[0..name.len], name);
    const lower_filter = std.ascii.lowerString(filter_buf[0..filter.len], filter);
    return std.mem.indexOf(u8, lower_name, lower_filter) != null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "filterMatch: empty filter always matches" {
    var v: vm.VmConfig = .{};
    v.setName("test-vm");
    try std.testing.expect(filterMatch(&v, ""));
}

test "filterMatch: exact name match" {
    var v: vm.VmConfig = .{};
    v.setName("Ubuntu Server");
    try std.testing.expect(filterMatch(&v, "Ubuntu"));
    try std.testing.expect(filterMatch(&v, "ubuntu"));
    try std.testing.expect(filterMatch(&v, "server"));
}

test "filterMatch: substring in middle" {
    var v: vm.VmConfig = .{};
    v.setName("Windows 11 Pro");
    try std.testing.expect(filterMatch(&v, "11"));
}

test "filterMatch: no match" {
    var v: vm.VmConfig = .{};
    v.setName("Debian");
    try std.testing.expect(!filterMatch(&v, "ubuntu"));
    try std.testing.expect(!filterMatch(&v, "xyz"));
}

test "filterMatch: case insensitive" {
    var v: vm.VmConfig = .{};
    v.setName("MyVM");
    try std.testing.expect(filterMatch(&v, "myvm"));
    try std.testing.expect(filterMatch(&v, "MYVM"));
    try std.testing.expect(filterMatch(&v, "myVm"));
}

test "filterMatch: empty name" {
    var v: vm.VmConfig = .{};
    v.setName("");
    try std.testing.expect(filterMatch(&v, "")); // empty filter matches empty name
    try std.testing.expect(!filterMatch(&v, "x")); // non-empty filter doesn't match
}

test "filterMatch: long name beyond 128 bytes does not overflow" {
    var v: vm.VmConfig = .{};
    const long = "a" ** 200 ++ "needle" ++ "b" ** 40; // 246 bytes, < MAX_NAME
    v.setName(long);
    try std.testing.expect(filterMatch(&v, "needle"));
    try std.testing.expect(filterMatch(&v, "NEEDLE"));
    try std.testing.expect(!filterMatch(&v, "missing"));
    // A filter longer than the (capped) name can never match.
    try std.testing.expect(!filterMatch(&v, "z" ** 250));
}

test "fuzz: filterMatch never panics on random inputs" {
    var prng = std.Random.DefaultPrng.init(0xCAFEF1AB);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const name_len = rnd.uintLessThan(usize, 100);
        const filter_len = rnd.uintLessThan(usize, 80);
        var name_buf: [100]u8 = undefined;
        var filter_buf: [80]u8 = undefined;
        for (name_buf[0..name_len]) |*b| b.* = rnd.int(u8);
        for (filter_buf[0..filter_len]) |*b| b.* = rnd.int(u8);
        var v: vm.VmConfig = .{};
        v.setName(name_buf[0..@min(name_len, vm.MAX_NAME)]);
        _ = filterMatch(&v, filter_buf[0..filter_len]);
    }
}
