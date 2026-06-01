//! Pure path-manipulation helpers extracted from main.zig and dialogs.zig.
//!
//! Functions for deriving filenames, clone disk paths, and VMDK hrefs.
//! All pure: no FLTK, no I/O, no global state.

const std = @import("std");

/// Extract the basename from a path and strip the file extension.
/// Returns the portion after the last '/' and before the last '.'.
/// If no extension, returns the whole basename.
pub fn basenameWithoutExt(path: []const u8, buf: []u8) []const u8 {
    const sep = std.mem.lastIndexOfScalar(u8, path, '/');
    const filename = if (sep) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.');
    const base = if (dot) |d| filename[0..d] else filename;
    const len = @min(base.len, buf.len);
    @memcpy(buf[0..len], base[0..len]);
    return buf[0..len];
}

/// Build a clone disk path by stripping the source extension and appending a suffix.
/// E.g. cloneDiskPath(buf, "/vms/vm.qcow2", "_clone.qcow2") → "/vms/vm_clone.qcow2"
pub fn cloneDiskPath(buf: []u8, src_disk: []const u8, suffix: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, src_disk, '.');
    const base = if (dot) |d| src_disk[0..d] else src_disk;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix });
}

/// Derive a VMDK filename from an OVF save path.
/// Strips the extension from save_path and appends "-disk1.vmdk".
/// E.g. deriveVmdkHref(buf, "/tmp/myvm.ovf") → "/tmp/myvm-disk1.vmdk"
pub fn deriveVmdkHref(save_path: []const u8, buf: []u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, save_path, '.');
    const base = if (dot) |d| save_path[0..d] else save_path;
    return std.fmt.bufPrint(buf, "{s}-disk1.vmdk", .{base});
}

// ── Tests ───────────────────────────────────────────────────────────

test "basenameWithoutExt: strips path and extension" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("myvm", basenameWithoutExt("/tmp/images/myvm.qcow2", &buf));
    try std.testing.expectEqualStrings("vm", basenameWithoutExt("vm.raw", &buf));
}

test "basenameWithoutExt: no extension" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("plain", basenameWithoutExt("/tmp/plain", &buf));
    try std.testing.expectEqualStrings("noext", basenameWithoutExt("noext", &buf));
}

test "basenameWithoutExt: multiple dots" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("vm.backup", basenameWithoutExt("/tmp/vm.backup.qcow2", &buf));
}

test "basenameWithoutExt: empty path" {
    var buf: [64]u8 = undefined;
    const result = basenameWithoutExt("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "cloneDiskPath: strips extension and appends suffix" {
    var buf: [128]u8 = undefined;
    const result = try cloneDiskPath(&buf, "/vms/myvm.qcow2", "_clone.qcow2");
    try std.testing.expectEqualStrings("/vms/myvm_clone.qcow2", result);
}

test "cloneDiskPath: linked clone suffix" {
    var buf: [128]u8 = undefined;
    const result = try cloneDiskPath(&buf, "/vms/vm.qcow2", "_linked.qcow2");
    try std.testing.expectEqualStrings("/vms/vm_linked.qcow2", result);
}

test "cloneDiskPath: no extension" {
    var buf: [128]u8 = undefined;
    const result = try cloneDiskPath(&buf, "/vms/disk", ".qcow2");
    try std.testing.expectEqualStrings("/vms/disk.qcow2", result);
}

test "deriveVmdkHref: strips .ovf and appends -disk1.vmdk" {
    var buf: [256]u8 = undefined;
    const result = try deriveVmdkHref("/tmp/myvm.ovf", &buf);
    try std.testing.expectEqualStrings("/tmp/myvm-disk1.vmdk", result);
}

test "deriveVmdkHref: no extension" {
    var buf: [256]u8 = undefined;
    const result = try deriveVmdkHref("/tmp/plain", &buf);
    try std.testing.expectEqualStrings("/tmp/plain-disk1.vmdk", result);
}

test "deriveVmdkHref: path with multiple dots" {
    var buf: [256]u8 = undefined;
    const result = try deriveVmdkHref("/tmp/my.vm.ovf", &buf);
    try std.testing.expectEqualStrings("/tmp/my.vm-disk1.vmdk", result);
}

test "fuzz: basenameWithoutExt never panics" {
    var prng = std.Random.DefaultPrng.init(0xBA5EBA5E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var path_buf: [128]u8 = undefined;
        var out_buf: [64]u8 = undefined;
        const n = rnd.uintLessThan(usize, 128);
        for (path_buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = basenameWithoutExt(path_buf[0..n], &out_buf);
    }
}

test "fuzz: cloneDiskPath never panics" {
    var prng = std.Random.DefaultPrng.init(0xBA5EBA6E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var path_buf: [128]u8 = undefined;
        var out_buf: [128]u8 = undefined;
        const n = rnd.uintLessThan(usize, 120);
        for (path_buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = cloneDiskPath(&out_buf, path_buf[0..n], ".qcow2") catch continue;
    }
}

test "fuzz: deriveVmdkHref never panics" {
    var prng = std.Random.DefaultPrng.init(0xBA5EBA7E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var path_buf: [256]u8 = undefined;
        var out_buf: [256]u8 = undefined;
        const n = rnd.uintLessThan(usize, 200);
        for (path_buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = deriveVmdkHref(path_buf[0..n], &out_buf) catch continue;
    }
}
