// SPDX-License-Identifier: MIT
//! Pure string-to-enum parsers for the web UI and configuration.
//!
//! These functions map UI label strings (case-insensitive) to their corresponding
//! enum values. All functions are pure: no I/O, no global state.
//!
//! Also includes parseU32OrDefault and themeFromIndex.

const std = @import("std");
const vm = @import("vm.zig");

/// Parse a disk format label ("qcow2", "raw", "vmdk", "vdi") into a DiskFormat enum.
/// Delegates to vm.DiskFormat.fromStr (case-insensitive).
pub fn parseDiskFormat(s: []const u8) vm.DiskFormat {
    return vm.DiskFormat.fromStr(s);
}

/// Map a file extension (without dot) to a DiskFormat enum.
/// Delegates to vm.DiskFormat.fromExtension — kept for backward compatibility.
pub fn diskFormatFromExtension(ext: []const u8) vm.DiskFormat {
    // fromExtension expects a path containing a dot; prepend a dummy stem.
    if (ext.len == 0) return vm.DiskFormat.fromExtension("");
    // Use a stack buffer to prepend "x." so fromExtension can find the extension.
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "x.{s}", .{ext}) catch return .qcow2;
    return vm.DiskFormat.fromExtension(path);
}

/// Parse a NIC mode label ("bridged", "none") into a NetworkMode enum.
/// UI labels are matched first, then falls back to NetworkMode.fromStr
/// for exact toStr values. Defaults to .user.
pub fn parseNicMode(s: []const u8) vm.NetworkMode {
    // UI label matching (labels differ from toStr values).
    if (std.ascii.eqlIgnoreCase(s, "bridged")) return .bridge;
    if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
    // Fallback to exact toStr matching ("user", "bridge").
    return vm.NetworkMode.fromStr(s);
}

/// Parse a guest OS label into a GuestOs enum.
/// Matches against substrings: "linux", "windows", "freebsd", "macos".
/// Falls back to GuestOs.fromStr for the exact "other" match,
/// then defaults to .other for unrecognized input.
pub fn parseGuestOs(s: []const u8) vm.GuestOs {
    if (std.ascii.indexOfIgnoreCase(s, "linux") != null) return .linux;
    if (std.ascii.indexOfIgnoreCase(s, "windows") != null) return .windows;
    if (std.ascii.indexOfIgnoreCase(s, "freebsd") != null) return .freebsd;
    if (std.ascii.indexOfIgnoreCase(s, "macos") != null) return .macos;
    if (std.ascii.eqlIgnoreCase(s, "other")) return .other;
    return .other;
}

/// Parse a boot order label ("cd/dvd", "network (pxe)", "disk first") into a BootOrder enum.
/// UI labels are matched first, then falls back to BootOrder.fromStr
/// for exact toStr values. Defaults to .disk_first.
pub fn parseBootOrder(s: []const u8) vm.BootOrder {
    if (std.ascii.eqlIgnoreCase(s, "cd/dvd")) return .cdrom_first;
    if (std.ascii.eqlIgnoreCase(s, "network (pxe)")) return .network_first;
    if (std.ascii.indexOfIgnoreCase(s, "disk") != null) return .disk_first;
    return vm.BootOrder.fromStr(s);
}

/// Parse a display type label ("sdl", "spice", "vnc", "none", "headless") into a DisplayType enum.
/// Uses substring matching because the UI dropdown labels can be longer descriptive
/// strings (e.g. "SPICE (recommended)"). Falls back to DisplayType.fromStr for exact
/// toStr values. Defaults to .gtk.
pub fn parseDisplay(s: []const u8) vm.DisplayType {
    if (std.ascii.indexOfIgnoreCase(s, "sdl") != null) return .sdl;
    if (std.ascii.indexOfIgnoreCase(s, "spice") != null) return .spice;
    if (std.ascii.indexOfIgnoreCase(s, "vnc") != null) return .vnc;
    if (std.ascii.indexOfIgnoreCase(s, "none") != null or std.ascii.indexOfIgnoreCase(s, "headless") != null) return .none;
    return vm.DisplayType.fromStr(s);
}

/// Parse a display resolution string ("800x600", "1024x768", "1280x800", "1920x1080") into a DisplayResolution enum.
/// Delegates to vm.DisplayResolution.fromStr (case-insensitive).
pub fn parseDisplayResolution(s: []const u8) vm.DisplayResolution {
    return vm.DisplayResolution.fromStr(s);
}

/// Parse a firmware label ("uefi") into a BootFirmware enum.
/// Delegates to vm.BootFirmware.fromStr (case-insensitive).
pub fn parseFirmware(s: []const u8) vm.BootFirmware {
    return vm.BootFirmware.fromStr(s);
}

/// Parse a GPU device label into a GpuDevice enum.
/// Handles full label names ("Virtio-GPU (virgl 3D)", "QXL (SPICE)", "Standard VGA", etc.)
/// Falls back to GpuDevice.fromStr for exact toStr matches.
pub fn parseGpuDevice(s: []const u8) vm.GpuDevice {
    if (std.ascii.indexOfIgnoreCase(s, "virtio-gpu") != null) {
        if (std.ascii.indexOfIgnoreCase(s, "virgl") != null or std.ascii.indexOfIgnoreCase(s, "3d") != null) return .virtio_gpu_gl;
        return .virtio_gpu;
    }
    if (std.ascii.indexOfIgnoreCase(s, "virtio-vga") != null) {
        if (std.ascii.indexOfIgnoreCase(s, "virgl") != null or std.ascii.indexOfIgnoreCase(s, "3d") != null) return .virtio_vga_gl;
        return .virtio_vga;
    }
    if (std.ascii.indexOfIgnoreCase(s, "qxl") != null) return .qxl;
    if (std.ascii.indexOfIgnoreCase(s, "standard") != null and std.ascii.indexOfIgnoreCase(s, "vga") != null) return .std_vga;
    // Fallback for exact toStr values and unknown inputs.
    return vm.GpuDevice.fromStr(s);
}

/// Parse an audio device label ("hda", "ac97") into an AudioDevice enum.
/// UI labels are matched first, then falls back to AudioDevice.fromStr
/// for exact toStr values. Defaults to .none.
pub fn parseAudio(s: []const u8) vm.AudioDevice {
    if (std.ascii.indexOfIgnoreCase(s, "hda") != null) return .hda;
    if (std.ascii.indexOfIgnoreCase(s, "ac97") != null) return .ac97;
    return vm.AudioDevice.fromStr(s);
}

/// Map a theme choice index (0 or 1) to a Theme enum.
pub fn themeFromIndex(idx: u8) vm.Theme {
    return if (idx == 1) .dark else .light;
}

/// Parse a string as u32, returning a default on failure or empty input.
/// Extracted from dialogs.zig prefsDialog (used 4+ times for mem, cpu, ap_interval, ap_max).
pub fn parseU32OrDefault(input: []const u8, default: u32) u32 {
    if (input.len == 0) return default;
    return std.fmt.parseInt(u32, input, 10) catch default;
}

/// Parse a QEMU acceleration string ("auto", "tcg", "kvm", "hvf", "whpx") into a VmAccel enum.
/// Delegates to VmAccel.fromStr (case-insensitive). Defaults to .auto for unrecognized values.
pub fn parseAccel(s: []const u8) vm.VmAccel {
    return vm.VmAccel.fromStr(s);
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseDiskFormat: known formats" {
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("qcow2"));
    try std.testing.expectEqual(vm.DiskFormat.raw, parseDiskFormat("raw"));
    try std.testing.expectEqual(vm.DiskFormat.vmdk, parseDiskFormat("vmdk"));
    try std.testing.expectEqual(vm.DiskFormat.vdi, parseDiskFormat("vdi"));
}

test "parseDiskFormat: case insensitive" {
    try std.testing.expectEqual(vm.DiskFormat.raw, parseDiskFormat("RAW"));
    try std.testing.expectEqual(vm.DiskFormat.vmdk, parseDiskFormat("Vmdk"));
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("QCOW2"));
}

test "parseDiskFormat: unknown defaults to qcow2" {
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("unknown"));
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat(""));
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("foo"));
}

test "diskFormatFromExtension: known extensions" {
    try std.testing.expectEqual(vm.DiskFormat.qcow2, diskFormatFromExtension("qcow2"));
    try std.testing.expectEqual(vm.DiskFormat.vmdk, diskFormatFromExtension("vmdk"));
    try std.testing.expectEqual(vm.DiskFormat.vdi, diskFormatFromExtension("vdi"));
    try std.testing.expectEqual(vm.DiskFormat.raw, diskFormatFromExtension("raw"));
    try std.testing.expectEqual(vm.DiskFormat.raw, diskFormatFromExtension("img"));
}

test "diskFormatFromExtension: unknown defaults to qcow2" {
    try std.testing.expectEqual(vm.DiskFormat.qcow2, diskFormatFromExtension("iso"));
    try std.testing.expectEqual(vm.DiskFormat.qcow2, diskFormatFromExtension(""));
}

test "parseNicMode: known modes" {
    try std.testing.expectEqual(vm.NetworkMode.bridge, parseNicMode("bridged"));
    try std.testing.expectEqual(vm.NetworkMode.none, parseNicMode("none"));
    try std.testing.expectEqual(vm.NetworkMode.user, parseNicMode("user"));
    // Exact toStr values also work via fallback.
    try std.testing.expectEqual(vm.NetworkMode.bridge, parseNicMode("bridge"));
    try std.testing.expectEqual(vm.NetworkMode.user, parseNicMode("user"));
}

test "parseNicMode: defaults to user" {
    try std.testing.expectEqual(vm.NetworkMode.user, parseNicMode("nat"));
    try std.testing.expectEqual(vm.NetworkMode.user, parseNicMode(""));
    try std.testing.expectEqual(vm.NetworkMode.user, parseNicMode("anything"));
}

test "parseGuestOs: known OS names" {
    try std.testing.expectEqual(vm.GuestOs.linux, parseGuestOs("Linux"));
    try std.testing.expectEqual(vm.GuestOs.windows, parseGuestOs("Windows 11"));
    try std.testing.expectEqual(vm.GuestOs.freebsd, parseGuestOs("FreeBSD 14"));
    try std.testing.expectEqual(vm.GuestOs.macos, parseGuestOs("macOS"));
    try std.testing.expectEqual(vm.GuestOs.linux, parseGuestOs("Ubuntu Linux"));
}

test "parseGuestOs: unknown defaults to other" {
    try std.testing.expectEqual(vm.GuestOs.other, parseGuestOs(""));
    try std.testing.expectEqual(vm.GuestOs.other, parseGuestOs("Solaris"));
    try std.testing.expectEqual(vm.GuestOs.other, parseGuestOs("unknown"));
}

test "parseBootOrder: known orders" {
    try std.testing.expectEqual(vm.BootOrder.cdrom_first, parseBootOrder("cd/dvd"));
    try std.testing.expectEqual(vm.BootOrder.network_first, parseBootOrder("network (pxe)"));
    try std.testing.expectEqual(vm.BootOrder.disk_first, parseBootOrder("disk first"));
}

test "parseBootOrder: defaults to disk_first" {
    try std.testing.expectEqual(vm.BootOrder.disk_first, parseBootOrder(""));
    try std.testing.expectEqual(vm.BootOrder.disk_first, parseBootOrder("floppy"));
}

test "parseDisplay: known displays" {
    try std.testing.expectEqual(vm.DisplayType.sdl, parseDisplay("SDL"));
    try std.testing.expectEqual(vm.DisplayType.spice, parseDisplay("SPICE"));
    try std.testing.expectEqual(vm.DisplayType.vnc, parseDisplay("VNC"));
    try std.testing.expectEqual(vm.DisplayType.none, parseDisplay("None"));
    try std.testing.expectEqual(vm.DisplayType.none, parseDisplay("Headless"));
}

test "parseDisplay: defaults to gtk" {
    try std.testing.expectEqual(vm.DisplayType.gtk, parseDisplay(""));
    try std.testing.expectEqual(vm.DisplayType.gtk, parseDisplay("GTK"));
    try std.testing.expectEqual(vm.DisplayType.gtk, parseDisplay("unknown"));
}

test "parseDisplayResolution: known resolutions" {
    try std.testing.expectEqual(vm.DisplayResolution.res_800x600, parseDisplayResolution("800x600"));
    try std.testing.expectEqual(vm.DisplayResolution.res_1024x768, parseDisplayResolution("1024x768"));
    try std.testing.expectEqual(vm.DisplayResolution.res_1280x800, parseDisplayResolution("1280x800"));
    try std.testing.expectEqual(vm.DisplayResolution.res_1920x1080, parseDisplayResolution("1920x1080"));
}

test "parseDisplayResolution: defaults to auto" {
    try std.testing.expectEqual(vm.DisplayResolution.auto, parseDisplayResolution(""));
    try std.testing.expectEqual(vm.DisplayResolution.auto, parseDisplayResolution("640x480"));
}

test "parseFirmware: uefi vs bios" {
    try std.testing.expectEqual(vm.BootFirmware.uefi, parseFirmware("uefi"));
    try std.testing.expectEqual(vm.BootFirmware.uefi, parseFirmware("UEFI"));
    try std.testing.expectEqual(vm.BootFirmware.bios, parseFirmware("bios"));
    try std.testing.expectEqual(vm.BootFirmware.bios, parseFirmware(""));
    try std.testing.expectEqual(vm.BootFirmware.bios, parseFirmware("anything"));
}

test "parseGpuDevice: all six variants via labels" {
    // Labels from GpuDevice.label():
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu_gl, parseGpuDevice("Virtio-GPU (virgl 3D)"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice("Virtio-VGA (virgl 3D)"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu, parseGpuDevice("Virtio-GPU"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga, parseGpuDevice("Virtio-VGA"));
    try std.testing.expectEqual(vm.GpuDevice.qxl, parseGpuDevice("QXL (SPICE)"));
    try std.testing.expectEqual(vm.GpuDevice.std_vga, parseGpuDevice("Standard VGA"));
}

test "parseGpuDevice: toStr values via fallback" {
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu_gl, parseGpuDevice("virtio_gpu_gl"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice("virtio_vga_gl"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu, parseGpuDevice("virtio_gpu"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga, parseGpuDevice("virtio_vga"));
    try std.testing.expectEqual(vm.GpuDevice.qxl, parseGpuDevice("qxl"));
    try std.testing.expectEqual(vm.GpuDevice.std_vga, parseGpuDevice("std_vga"));
}

test "parseGpuDevice: unknown defaults via fromStr" {
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice(""));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice("any"));
}

test "parseAudio: hda, ac97, none" {
    try std.testing.expectEqual(vm.AudioDevice.hda, parseAudio("HDA"));
    try std.testing.expectEqual(vm.AudioDevice.hda, parseAudio("intel-hda"));
    try std.testing.expectEqual(vm.AudioDevice.ac97, parseAudio("AC97"));
    try std.testing.expectEqual(vm.AudioDevice.ac97, parseAudio("ac97"));
    try std.testing.expectEqual(vm.AudioDevice.none, parseAudio(""));
    try std.testing.expectEqual(vm.AudioDevice.none, parseAudio("sb16"));
}

test "themeFromIndex: 0→light, 1→dark" {
    try std.testing.expectEqual(vm.Theme.light, themeFromIndex(0));
    try std.testing.expectEqual(vm.Theme.dark, themeFromIndex(1));
}

test "parseAccel: known accelerators" {
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("auto"));
    try std.testing.expectEqual(vm.VmAccel.tcg, parseAccel("tcg"));
    try std.testing.expectEqual(vm.VmAccel.kvm, parseAccel("kvm"));
    try std.testing.expectEqual(vm.VmAccel.hvf, parseAccel("hvf"));
    try std.testing.expectEqual(vm.VmAccel.whpx, parseAccel("whpx"));
}

test "parseAccel: case insensitive" {
    try std.testing.expectEqual(vm.VmAccel.kvm, parseAccel("KVM"));
    try std.testing.expectEqual(vm.VmAccel.hvf, parseAccel("Hvf"));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("AUTO"));
}

test "parseAccel: unknown defaults to auto" {
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel(""));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("unknown"));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("xen"));
}

test "parseU32OrDefault: valid numbers" {
    try std.testing.expectEqual(@as(u32, 2048), parseU32OrDefault("2048", 1024));
    try std.testing.expectEqual(@as(u32, 0), parseU32OrDefault("0", 1024));
    try std.testing.expectEqual(@as(u32, 4294967295), parseU32OrDefault("4294967295", 0));
}

test "parseU32OrDefault: empty returns default" {
    try std.testing.expectEqual(@as(u32, 1024), parseU32OrDefault("", 1024));
    try std.testing.expectEqual(@as(u32, 60), parseU32OrDefault("", 60));
}

test "parseU32OrDefault: invalid returns default" {
    try std.testing.expectEqual(@as(u32, 2048), parseU32OrDefault("not-a-number", 2048));
    try std.testing.expectEqual(@as(u32, 10), parseU32OrDefault("abc", 10));
    try std.testing.expectEqual(@as(u32, 2), parseU32OrDefault("-1", 2));
}

test "parseU32OrDefault: overflow returns default" {
    try std.testing.expectEqual(@as(u32, 60), parseU32OrDefault("99999999999", 60));
}

test "fuzz: parseDiskFormat never panics" {
    var prng = std.Random.DefaultPrng.init(0xDA1AFA1E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var buf: [32]u8 = undefined;
        const n = rnd.uintLessThan(usize, 32);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = parseDiskFormat(buf[0..n]);
    }
}

test "fuzz: parseNicMode never panics" {
    var prng = std.Random.DefaultPrng.init(0xDA1AFA2E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var buf: [32]u8 = undefined;
        const n = rnd.uintLessThan(usize, 32);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = parseNicMode(buf[0..n]);
    }
}

test "fuzz: parseGuestOs never panics" {
    var prng = std.Random.DefaultPrng.init(0xDA1AFA3E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var buf: [64]u8 = undefined;
        const n = rnd.uintLessThan(usize, 64);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = parseGuestOs(buf[0..n]);
    }
}

test "fuzz: parseU32OrDefault never panics" {
    var prng = std.Random.DefaultPrng.init(0xDA1AFA4E);
    const rnd = prng.random();
    for (0..4000) |_| {
        var buf: [64]u8 = undefined;
        const n = rnd.uintLessThan(usize, 64);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = parseU32OrDefault(buf[0..n], rnd.int(u32));
    }
}

test "fuzz: all parsers consistency — never panic, return valid enum indices" {
    var prng = std.Random.DefaultPrng.init(0xDA1AFA5E);
    const rnd = prng.random();
    for (0..5000) |_| {
        var buf: [64]u8 = undefined;
        const n = rnd.uintLessThan(usize, 64);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        const s = buf[0..n];

        // All return values must be valid enum indices.
        _ = @intFromEnum(parseDiskFormat(s));
        _ = @intFromEnum(diskFormatFromExtension(s));
        _ = @intFromEnum(parseNicMode(s));
        _ = @intFromEnum(parseGuestOs(s));
        _ = @intFromEnum(parseBootOrder(s));
        _ = @intFromEnum(parseDisplay(s));
        _ = @intFromEnum(parseDisplayResolution(s));
        _ = @intFromEnum(parseFirmware(s));
        _ = @intFromEnum(parseGpuDevice(s));
        _ = @intFromEnum(parseAudio(s));
        _ = @intFromEnum(parseAccel(s));
        _ = @intFromEnum(themeFromIndex(@intCast(rnd.uintLessThan(u8, 4))));
        _ = parseU32OrDefault(s, rnd.int(u32));
    }
}
