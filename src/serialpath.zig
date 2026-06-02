// SPDX-License-Identifier: MIT
//! Serial Unix-socket path builder.
//!
//! Pure helper extracted from `serial_console.zig` so the path construction
//! can be tested without filesystem or FLTK dependencies.

const std = @import("std");

/// Build the Unix-domain socket path for a VM's serial console.
/// Writes a null-terminated path into `buf` and returns a `[:0]const u8`
/// slice. Returns `error.NoSpaceLeft` when `vm_name` won't fit.
/// The path template is `/tmp/hangar-serial-{vm_name}.sock`.
pub fn serialSocketPath(buf: []u8, vm_name: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/hangar-serial-{s}.sock", .{vm_name});
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
    try std.testing.expect(path[63] == 0); // null-terminated
    try std.testing.expect(path.len == 63);
}

test "serialSocketPath: consistent format" {
    var buf: [320]u8 = undefined;
    const path = try serialSocketPath(&buf, "ubuntu-22.04");
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/hangar-serial-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}
