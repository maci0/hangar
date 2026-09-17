// SPDX-License-Identifier: MIT
//! Path helpers for configuration storage, filenames, clone disks, and VMDK hrefs.

const std = @import("std");
const appio = @import("appio.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Read an env var, treating an empty value as unset.
fn getenvNonEmpty(key: [*:0]const u8) ?[]const u8 {
    const v = appio.getenv(key) orelse return null;
    return if (v.len > 0) v else null;
}

fn configHome() ?[]const u8 {
    // Treat an env var set to the empty string as unset: an empty
    // HANGAR_CONFIG_HOME/HOME would otherwise produce filesystem-root paths
    // like "/.config/hangar/vms.json" instead of falling through correctly.
    return getenvNonEmpty("HANGAR_CONFIG_HOME") orelse getenvNonEmpty("HOME");
}

/// Return the hangar config directory path, or null if no config home is set.
pub fn configDir(buf: *[512]u8) ?[]const u8 {
    const home = configHome() orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar", .{home}) catch null;
}

/// Return the path to vms.json, or null if no config home is set.
pub fn vmsPath(buf: *[512]u8) ?[]const u8 {
    const home = configHome() orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar/vms.json", .{home}) catch null;
}

/// Return the path to networks.json, or null if no config home is set.
pub fn networksPath(buf: *[512]u8) ?[]const u8 {
    const home = configHome() orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar/networks.json", .{home}) catch null;
}

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
    const ext = std.fs.path.extension(src_disk);
    const base = src_disk[0 .. src_disk.len - ext.len];
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix });
}

/// Derive a VMDK filename from an OVF save path.
/// Strips the extension from save_path and appends "-disk1.vmdk".
/// E.g. deriveVmdkHref(buf, "/tmp/myvm.ovf") → "/tmp/myvm-disk1.vmdk"
pub fn deriveVmdkHref(save_path: []const u8, buf: []u8) ![]const u8 {
    const ext = std.fs.path.extension(save_path);
    const base = save_path[0 .. save_path.len - ext.len];
    return std.fmt.bufPrint(buf, "{s}-disk1.vmdk", .{base});
}

test "configDir returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (configDir(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar"));
    }
}

test "vmsPath returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (vmsPath(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar/vms.json"));
    }
}

test "networksPath returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (networksPath(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar/networks.json"));
    }
}

test "config path helpers return null when HOME is unset" {
    // Save and clear HOME.
    const saved = appio.getenv("HOME");
    const saved_config = appio.getenv("HANGAR_CONFIG_HOME");
    defer {
        if (saved) |v| _ = setenv("HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HOME");
        if (saved_config) |v| _ = setenv("HANGAR_CONFIG_HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HANGAR_CONFIG_HOME");
    }
    _ = unsetenv("HOME");
    _ = unsetenv("HANGAR_CONFIG_HOME");

    var buf: [512]u8 = undefined;
    try std.testing.expect(configDir(&buf) == null);
    try std.testing.expect(vmsPath(&buf) == null);
    try std.testing.expect(networksPath(&buf) == null);
}

test "empty config-home env vars are treated as unset" {
    const saved_home = appio.getenv("HOME");
    const saved_config = appio.getenv("HANGAR_CONFIG_HOME");
    defer {
        if (saved_home) |v| _ = setenv("HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HOME");
        if (saved_config) |v| _ = setenv("HANGAR_CONFIG_HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HANGAR_CONFIG_HOME");
    }

    // Empty HANGAR_CONFIG_HOME must fall through to HOME rather than yielding
    // a filesystem-root path.
    _ = setenv("HANGAR_CONFIG_HOME", "", 1);
    _ = setenv("HOME", "/tmp/hangar-home-test", 1);
    var buf: [512]u8 = undefined;
    const path = vmsPath(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/hangar-home-test/.config/hangar/vms.json", path);

    // Both empty → no config home at all.
    _ = setenv("HOME", "", 1);
    try std.testing.expect(vmsPath(&buf) == null);
}

test "HANGAR_CONFIG_HOME overrides HOME" {
    const saved_home = appio.getenv("HOME");
    const saved_config = appio.getenv("HANGAR_CONFIG_HOME");
    defer {
        if (saved_home) |v| _ = setenv("HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HOME");
        if (saved_config) |v| _ = setenv("HANGAR_CONFIG_HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HANGAR_CONFIG_HOME");
    }
    _ = setenv("HOME", "/home/ignored", 1);
    _ = setenv("HANGAR_CONFIG_HOME", "/tmp/hangar-config-test", 1);

    var buf: [512]u8 = undefined;
    const path = configDir(&buf).?;
    try std.testing.expectEqualStrings("/tmp/hangar-config-test/.config/hangar", path);
}

test "fuzz: config path helpers never panic" {
    var prng = std.Random.DefaultPrng.init(0x570A7E57);
    const rnd = prng.random();
    for (0..1000) |_| {
        var buf: [512]u8 = undefined;
        // Fill with random data before each call.
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = configDir(&buf);
        _ = vmsPath(&buf);
        _ = networksPath(&buf);
    }
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

test "derived disk paths preserve dots in parent directories" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/vms/release.1/disk_clone.qcow2", try cloneDiskPath(&buf, "/vms/release.1/disk", "_clone.qcow2"));
    try std.testing.expectEqualStrings("/vms/release.1/disk_clone.qcow2", try cloneDiskPath(&buf, "/vms/release.1/disk.raw", "_clone.qcow2"));
    try std.testing.expectEqualStrings("./export-disk1.vmdk", try deriveVmdkHref("./export", &buf));
    try std.testing.expectEqualStrings("/vms/release.1/export-disk1.vmdk", try deriveVmdkHref("/vms/release.1/export", &buf));
    try std.testing.expectEqualStrings("/vms/release.1/export-disk1.vmdk", try deriveVmdkHref("/vms/release.1/export.ovf", &buf));
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
