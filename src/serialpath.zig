// SPDX-License-Identifier: MIT
//! Serial Unix-socket path builder.
//!
//! Pure helper extracted from `serial_console.zig` so the path construction
//! can be tested without filesystem or UI dependencies.

const std = @import("std");

/// Build the Unix-domain socket path for a VM's serial console.
/// Writes a null-terminated path into `buf` and returns a `[:0]const u8`
/// slice. Returns `error.NoSpaceLeft` when `vm_name` won't fit, or
/// `error.InvalidName` when `vm_name` is not path-safe.
///
/// The VM name is interpolated directly into a filesystem path. The web input
/// boundary rejects path separators (`vm.isValidVmName`), but names loaded from
/// `vms.json` or the remote daemon skip that check — enforce the invariant here
/// so a name with a path separator or NUL can never escape `/tmp`.
/// The path template is `/tmp/hangar-serial-{vm_name}.sock`.
pub fn serialSocketPath(buf: []u8, vm_name: []const u8) ![:0]const u8 {
    if (!isPathSafeName(vm_name)) return error.InvalidName;
    return std.fmt.bufPrintZ(buf, "/tmp/hangar-serial-{s}.sock", .{vm_name});
}

/// Returns true when `name` contains no path separators or NUL, so it is safe
/// to interpolate into a single `/tmp/...` socket path component.
pub fn isPathSafeName(name: []const u8) bool {
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

test "serialSocketPath: short name" {
    var buf: [320]u8 = undefined;
    const path = try serialSocketPath(&buf, "test-vm");
    try std.testing.expectEqualStrings("/tmp/hangar-serial-test-vm.sock", path);
}

test "serialSocketPath: empty name" {
    var buf: [320]u8 = undefined;
    const path = try serialSocketPath(&buf, "");
    try std.testing.expectEqualStrings("/tmp/hangar-serial-.sock", path);
}

test "serialSocketPath: name with special chars" {
    var buf: [320]u8 = undefined;
    const path = try serialSocketPath(&buf, "my vm (copy)");
    try std.testing.expectEqualStrings("/tmp/hangar-serial-my vm (copy).sock", path);
}

test "serialSocketPath: buffer too small" {
    var buf: [32]u8 = undefined;
    const result = serialSocketPath(&buf, "a" ** 200);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "serialSocketPath: exact fit" {
    var buf: [64]u8 = undefined;
    // "/tmp/hangar-serial-" = 19 chars, ".sock" = 5 chars → 24 overhead
    // name can be up to 63-24 = 39 chars
    const name = "a" ** 39;
    const path = try serialSocketPath(&buf, name);
    try std.testing.expectEqualStrings("/tmp/hangar-serial-" ++ name ++ ".sock", path);
    try std.testing.expect(path[path.len] == 0); // null-terminated sentinel
    try std.testing.expect(path.len == 63);
}

test "serialSocketPath: rejects path-unsafe names" {
    var buf: [320]u8 = undefined;
    try std.testing.expectError(error.InvalidName, serialSocketPath(&buf, "../../etc/x"));
    try std.testing.expectError(error.InvalidName, serialSocketPath(&buf, "a/b"));
    try std.testing.expectError(error.InvalidName, serialSocketPath(&buf, "a\\b"));
    try std.testing.expectError(error.InvalidName, serialSocketPath(&buf, "a\x00b"));
    // A literal ".." with no separator is harmless and still allowed.
    const ok = try serialSocketPath(&buf, "v1..v2");
    try std.testing.expectEqualStrings("/tmp/hangar-serial-v1..v2.sock", ok);
}

test "isPathSafeName: separators and NUL" {
    try std.testing.expect(isPathSafeName("ubuntu-22.04"));
    try std.testing.expect(isPathSafeName("my vm (copy)"));
    try std.testing.expect(!isPathSafeName("a/b"));
    try std.testing.expect(!isPathSafeName("a\\b"));
    try std.testing.expect(!isPathSafeName("a\x00b"));
}

test "serialSocketPath: consistent format" {
    var buf: [320]u8 = undefined;
    const path = try serialSocketPath(&buf, "ubuntu-22.04");
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/hangar-serial-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}

test "serialSocketPath fuzz: random names never panic, always produce valid paths" {
    var prng = std.Random.DefaultPrng.init(0x5E410A70);
    const rnd = prng.random();
    var name_buf: [64]u8 = undefined;
    var path_buf: [320]u8 = undefined;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const n = rnd.uintLessThan(usize, 64);
        for (name_buf[0..n]) |*b| b.* = rnd.int(u8);
        const name = name_buf[0..n];
        if (serialSocketPath(&path_buf, name)) |path| {
            // Invariants: always starts with the prefix, always null-terminated.
            try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/hangar-serial-"));
            try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
            try std.testing.expect(path[path.len] == 0);
        } else |_| {
            // NoSpaceLeft (too long) or InvalidName (path-unsafe) are expected.
        }
    }
}
