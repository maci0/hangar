// SPDX-License-Identifier: MIT
//! VM configuration persistence — JSON save/load to disk.
//!
//! Saves VM configurations to `~/.config/hangar/vms.json` and loads
//! them back at startup.  Runtime state (status, pid) is NOT persisted.
//!
//! Format: JSON object with `version` (integer) and `vms` (array of objects).
//! Enum fields are stored as their QEMU command-line strings (e.g. "qcow2",
//! "gtk", "user") for human readability and forward compatibility.
//!
//! Save builds JSON in memory using `std.ArrayList(u8)` then writes the
//! whole buffer with `File.writeAll()`.  Load uses `File.readToEndAlloc()`
//! and a hand-rolled JSON parser (std.json is banned due to f128 linker
//! errors with the system `cc` link step).

const std = @import("std");
const appio = @import("appio.zig");
const vm = @import("vm.zig");

/// Maximum number of VMs (single source in vm.zig).
const MAX_VMS = vm.MAX_VMS;

// ── JSON-friendly intermediate struct ───────────────────────────────

/// Flat VM config — used as an intermediate representation for the
/// `fromVmJson` conversion and for the round-trip test.
const VmJson = struct {
    name: []const u8 = "",
    cpu_cores: u32 = 2,
    cpu_sockets: u32 = 1,
    cpu_model: []const u8 = "host",
    memory_mb: u32 = 2048,
    disk_size_gb: u32 = 20,
    disk_format: []const u8 = "qcow2",
    disk_cache: []const u8 = "writeback",
    disk_path: []const u8 = "",
    iso_path: []const u8 = "",
    mac_address: []const u8 = "",
    notes: []const u8 = "",
    port_forwards: []const u8 = "",
    saved_state_path: []const u8 = "",
    shared_folder: []const u8 = "",
    disk2_path: []const u8 = "",
    disk2_size_gb: u32 = 0,
    disk2_format: []const u8 = "qcow2",
    usb_device: []const u8 = "",
    nic2_mode: []const u8 = "none",
    nic2_mac: []const u8 = "",
    nic3_mode: []const u8 = "none",
    nic3_mac: []const u8 = "",
    enable_3d: bool = false,
    gpu_device: []const u8 = "virtio_vga_gl",
    guest_tools: bool = false,
    favorite: bool = false,
    autoprotect: bool = false,
    autoprotect_interval_min: u32 = 1440,
    autoprotect_max: u32 = 3,
    autoprotect_last_epoch: i64 = 0,
    autoprotect_last_seq: u32 = 0,
    floppy_path: []const u8 = "",
    display: []const u8 = "gtk",
    display_resolution: u32 = 0,
    network: []const u8 = "user",
    firmware: []const u8 = "bios",
    guest_os: []const u8 = "linux",
    audio: []const u8 = "none",
    boot_order: []const u8 = "cdn",
    accel: []const u8 = "auto",
    embed_display: bool = true,
    vnc_port: u16 = 5900,
    spice_port: u16 = 5930,
    enable_serial: bool = true,
    virtio_rng: bool = false,
    guest_agent: bool = false,
    watchdog: []const u8 = "none",
    tpm: bool = false,
    secure_boot: bool = false,
    hyperv_enlightenments: bool = false,
    hugepages: bool = false,
    io_threads: u32 = 0,
    disk_bps_throttle: u64 = 0,
    disk_iops_throttle: u32 = 0,
    ballooning: bool = false,
    host_autostart: bool = false,
    num_displays: u32 = 1,
};

// ── Config path helpers ─────────────────────────────────────────────

fn getConfigDir(buf: *[512]u8) ?[]const u8 {
    const home = appio.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar", .{home}) catch null;
}

fn getConfigPath(buf: *[512]u8) ?[]const u8 {
    const home = appio.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar/vms.json", .{home}) catch null;
}

// ── Enum string mappers (load direction) ────────────────────────────

fn parseDiskFormat(s: []const u8) vm.DiskFormat {
    return vm.DiskFormat.fromStr(s);
}

fn parseDiskCache(s: []const u8) vm.DiskCache {
    return vm.DiskCache.fromStr(s);
}

fn parseDisplayType(s: []const u8) vm.DisplayType {
    return vm.DisplayType.fromStr(s);
}

fn parseNetworkMode(s: []const u8) vm.NetworkMode {
    return vm.NetworkMode.fromStr(s);
}

fn parseFirmware(s: []const u8) vm.BootFirmware {
    return vm.BootFirmware.fromStr(s);
}

fn parseGuestOs(s: []const u8) vm.GuestOs {
    return vm.GuestOs.fromStr(s);
}

fn parseAudioDevice(s: []const u8) vm.AudioDevice {
    return vm.AudioDevice.fromStr(s);
}

fn parseGpuDevice(s: []const u8) vm.GpuDevice {
    return vm.GpuDevice.fromStr(s);
}

fn parseWatchdogAction(s: []const u8) vm.WatchdogAction {
    return vm.WatchdogAction.fromStr(s);
}

fn parseBootOrder(s: []const u8) vm.BootOrder {
    return vm.BootOrder.fromStr(s);
}

pub fn parseAccel(s: []const u8) vm.VmAccel {
    return vm.VmAccel.fromStr(s);
}

// ── Conversion: VmJson → VmConfig ───────────────────────────────────

fn fromVmJson(j: *const VmJson) vm.VmConfig {
    var cfg = vm.VmConfig{};
    cfg.setName(j.name);
    cfg.cpu_cores = j.cpu_cores;
    cfg.cpu_sockets = j.cpu_sockets;
    cfg.cpu_model = vm.CpuModel.fromStr(j.cpu_model);
    cfg.memory_mb = j.memory_mb;
    cfg.disk_size_gb = j.disk_size_gb;
    cfg.disk_format = parseDiskFormat(j.disk_format);
    cfg.disk_cache = parseDiskCache(j.disk_cache);
    cfg.setDiskPath(j.disk_path);
    cfg.setIsoPath(j.iso_path);
    cfg.setMacAddress(j.mac_address);
    cfg.setNotes(j.notes);
    cfg.setPortForwards(j.port_forwards);
    cfg.setSavedStatePath(j.saved_state_path);
    cfg.setSharedFolder(j.shared_folder);
    cfg.setDisk2Path(j.disk2_path);
    cfg.disk2_size_gb = j.disk2_size_gb;
    cfg.disk2_format = parseDiskFormat(j.disk2_format);
    cfg.setUsbDevice(j.usb_device);
    cfg.nics[1].mode = parseNetworkMode(j.nic2_mode);
    cfg.setNic2Mac(j.nic2_mac);
    cfg.nics[2].mode = parseNetworkMode(j.nic3_mode);
    cfg.setNic3Mac(j.nic3_mac);
    cfg.enable_3d = j.enable_3d;
    cfg.gpu_device = parseGpuDevice(j.gpu_device);
    cfg.guest_tools = j.guest_tools;
    cfg.favorite = j.favorite;
    cfg.autoprotect = j.autoprotect;
    cfg.autoprotect_interval_min = j.autoprotect_interval_min;
    cfg.autoprotect_max = j.autoprotect_max;
    cfg.autoprotect_last_epoch = j.autoprotect_last_epoch;
    cfg.autoprotect_last_seq = j.autoprotect_last_seq;
    cfg.setFloppyPath(j.floppy_path);
    cfg.display = parseDisplayType(j.display);
    cfg.display_resolution = vm.DisplayResolution.fromIndex(j.display_resolution);
    cfg.nics[0].mode = parseNetworkMode(j.network);
    cfg.firmware = parseFirmware(j.firmware);
    cfg.guest_os = parseGuestOs(j.guest_os);
    cfg.audio = parseAudioDevice(j.audio);
    cfg.boot_order = parseBootOrder(j.boot_order);
    cfg.accel = parseAccel(j.accel);
    cfg.embed_display = j.embed_display;
    cfg.vnc_port = j.vnc_port;
    cfg.spice_port = j.spice_port;
    cfg.enable_serial = j.enable_serial;
    cfg.virtio_rng = j.virtio_rng;
    cfg.guest_agent = j.guest_agent;
    cfg.watchdog = parseWatchdogAction(j.watchdog);
    cfg.tpm = j.tpm;
    cfg.secure_boot = j.secure_boot;
    cfg.hyperv_enlightenments = j.hyperv_enlightenments;
    cfg.hugepages = j.hugepages;
    cfg.io_threads = j.io_threads;
    cfg.disk_bps_throttle = j.disk_bps_throttle;
    cfg.disk_iops_throttle = j.disk_iops_throttle;
    cfg.ballooning = j.ballooning;
    cfg.host_autostart = j.host_autostart;
    cfg.num_displays = j.num_displays;
    return cfg;
}

// ── JSON building helpers ───────────────────────────────────────────
// Zig 0.15.2 ArrayList requires the allocator on every method call.

const List = std.ArrayList(u8);

fn emit(list: *List, alloc: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(alloc, s);
}

fn emitByte(list: *List, alloc: std.mem.Allocator, c: u8) !void {
    try list.append(alloc, c);
}

fn emitJsonStr(list: *List, alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    // Buffer is exactly 6 bytes for \uXXXX — always fits,
                    // so this catch is defensive-only (cannot actually fail).
                    var esc_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{@as(u32, c)}) catch
                        return error.OutOfMemory;
                    try list.appendSlice(alloc, esc);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
    try list.append(alloc, '"');
}

fn emitInt(list: *List, alloc: std.mem.Allocator, val: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch
        return error.OutOfMemory;
    try list.appendSlice(alloc, s);
}

fn emitBool(list: *List, alloc: std.mem.Allocator, val: bool) !void {
    try list.appendSlice(alloc, if (val) "true" else "false");
}

/// Append a single VM config as a JSON object.
fn emitVmJson(list: *List, alloc: std.mem.Allocator, cfg: *const vm.VmConfig) !void {
    try emit(list, alloc, "\n    {\n");

    try emit(list, alloc, "      \"name\": ");
    try emitJsonStr(list, alloc, cfg.getNameSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"cpu_cores\": ");
    try emitInt(list, alloc, cfg.cpu_cores);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"cpu_sockets\": ");
    try emitInt(list, alloc, cfg.cpu_sockets);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"cpu_model\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.cpu_model.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"memory_mb\": ");
    try emitInt(list, alloc, cfg.memory_mb);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_size_gb\": ");
    try emitInt(list, alloc, cfg.disk_size_gb);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_format\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.disk_format.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_cache\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.disk_cache.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_path\": ");
    try emitJsonStr(list, alloc, cfg.getDiskPathSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"iso_path\": ");
    try emitJsonStr(list, alloc, cfg.getIsoPathSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"mac_address\": ");
    try emitJsonStr(list, alloc, cfg.getMacAddressSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"notes\": ");
    try emitJsonStr(list, alloc, cfg.getNotesSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"port_forwards\": ");
    try emitJsonStr(list, alloc, cfg.getPortForwardsSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"saved_state_path\": ");
    try emitJsonStr(list, alloc, cfg.getSavedStatePathSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"shared_folder\": ");
    try emitJsonStr(list, alloc, cfg.getSharedFolderSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk2_path\": ");
    try emitJsonStr(list, alloc, cfg.getDisk2PathSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk2_size_gb\": ");
    try emitInt(list, alloc, cfg.disk2_size_gb);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk2_format\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.disk2_format.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"usb_device\": ");
    try emitJsonStr(list, alloc, cfg.getUsbDeviceSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"nic2_mode\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.nics[1].mode.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"nic2_mac\": ");
    try emitJsonStr(list, alloc, cfg.getNic2MacSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"nic3_mode\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.nics[2].mode.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"nic3_mac\": ");
    try emitJsonStr(list, alloc, cfg.getNic3MacSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"enable_3d\": ");
    try emitBool(list, alloc, cfg.enable_3d);
    try emit(list, alloc, ",\n      \"gpu_device\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.gpu_device.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"guest_tools\": ");
    try emitBool(list, alloc, cfg.guest_tools);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"favorite\": ");
    try emitBool(list, alloc, cfg.favorite);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"autoprotect\": ");
    try emitBool(list, alloc, cfg.autoprotect);
    try emit(list, alloc, ",\n");
    try emit(list, alloc, "      \"autoprotect_interval_min\": ");
    try emitInt(list, alloc, cfg.autoprotect_interval_min);
    try emit(list, alloc, ",\n");
    try emit(list, alloc, "      \"autoprotect_max\": ");
    try emitInt(list, alloc, cfg.autoprotect_max);
    try emit(list, alloc, ",\n");
    try emit(list, alloc, "      \"autoprotect_last_epoch\": ");
    try emitInt(list, alloc, cfg.autoprotect_last_epoch);
    try emit(list, alloc, ",\n");
    try emit(list, alloc, "      \"autoprotect_last_seq\": ");
    try emitInt(list, alloc, cfg.autoprotect_last_seq);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"floppy_path\": ");
    try emitJsonStr(list, alloc, cfg.getFloppyPathSlice());
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"display\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.display.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"display_resolution\": ");
    try emitInt(list, alloc, @as(u32, @intCast(cfg.display_resolution.toIndex())));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"network\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.nics[0].mode.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"firmware\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.firmware.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"guest_os\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.guest_os.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"audio\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.audio.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"boot_order\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.boot_order.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"accel\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.accel.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"embed_display\": ");
    try emitBool(list, alloc, cfg.embed_display);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"vnc_port\": ");
    try emitInt(list, alloc, cfg.vnc_port);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"spice_port\": ");
    try emitInt(list, alloc, cfg.spice_port);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"enable_serial\": ");
    try emitBool(list, alloc, cfg.enable_serial);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"virtio_rng\": ");
    try emitBool(list, alloc, cfg.virtio_rng);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"guest_agent\": ");
    try emitBool(list, alloc, cfg.guest_agent);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"watchdog\": ");
    try emitJsonStr(list, alloc, std.mem.span(cfg.watchdog.toStr()));
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"tpm\": ");
    try emitBool(list, alloc, cfg.tpm);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"secure_boot\": ");
    try emitBool(list, alloc, cfg.secure_boot);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"hyperv_enlightenments\": ");
    try emitBool(list, alloc, cfg.hyperv_enlightenments);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"hugepages\": ");
    try emitBool(list, alloc, cfg.hugepages);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"io_threads\": ");
    try emitInt(list, alloc, cfg.io_threads);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_bps_throttle\": ");
    try emitInt(list, alloc, cfg.disk_bps_throttle);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"disk_iops_throttle\": ");
    try emitInt(list, alloc, cfg.disk_iops_throttle);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"ballooning\": ");
    try emitBool(list, alloc, cfg.ballooning);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"host_autostart\": ");
    try emitBool(list, alloc, cfg.host_autostart);
    try emit(list, alloc, ",\n");

    try emit(list, alloc, "      \"num_displays\": ");
    try emitInt(list, alloc, cfg.num_displays);
    try emit(list, alloc, "\n");

    try emit(list, alloc, "    }");
}

// ── Save ────────────────────────────────────────────────────────────

/// Save all VM configs and preferences to `~/.config/hangar/vms.json`.
/// Does not persist runtime state (status, pid).
pub fn save(vms: []const vm.VmConfig, count: usize, prefs: vm.Prefs) !void {
    const alloc = std.heap.page_allocator;

    // Ensure config directory exists.
    var dir_buf: [512]u8 = undefined;
    if (getConfigDir(&dir_buf)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {
            _ = std.c.write(2, "persist: createDirPath failed\n", 30);
        };
    }

    var path_buf: [512]u8 = undefined;
    const file_path = getConfigPath(&path_buf) orelse return error.HomeNotFound;

    // Build JSON in memory.
    var list: List = .empty;
    defer list.deinit(alloc);

    emit(&list, alloc, "{\n  \"version\": 2,\n  \"theme\": ") catch return error.OutOfMemory;
    emitJsonStr(&list, alloc, std.mem.span(prefs.theme.toStr())) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n  \"prefs\": {\n    \"default_vm_dir\": ") catch return error.OutOfMemory;
    emitJsonStr(&list, alloc, prefs.default_vm_dir_buf[0..prefs.default_vm_dir_len]) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"default_memory_mb\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.default_memory_mb) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"default_cpu_cores\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.default_cpu_cores) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"autoprotect_enabled_default\": ") catch return error.OutOfMemory;
    emitBool(&list, alloc, prefs.autoprotect_enabled_default) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"autoprotect_interval_min_default\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.autoprotect_interval_min_default) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"autoprotect_max_default\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.autoprotect_max_default) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"win_x\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.win_x) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"win_y\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.win_y) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"win_w\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.win_w) catch return error.OutOfMemory;
    emit(&list, alloc, ",\n    \"win_h\": ") catch return error.OutOfMemory;
    emitInt(&list, alloc, prefs.win_h) catch return error.OutOfMemory;
    emit(&list, alloc, "\n  }") catch return error.OutOfMemory;
    emit(&list, alloc, ",\n  \"vms\": [") catch return error.OutOfMemory;

    const n = @min(count, MAX_VMS);
    for (0..n) |i| {
        if (i > 0) emit(&list, alloc, ",") catch return error.OutOfMemory;
        emitVmJson(&list, alloc, &vms[i]) catch return error.OutOfMemory;
    }

    emit(&list, alloc, "\n  ]\n}\n") catch return error.OutOfMemory;

    // Write to file.
    std.Io.Dir.cwd().writeFile(appio.io(), .{
        .sub_path = file_path,
        .data = list.items,
    }) catch return error.WriteFailed;
}

// ── Load ────────────────────────────────────────────────────────────

/// Minimal JSON key/value parser — avoids std.json (which pulls in f128
/// float math that causes linker errors with system cc).
///
/// Only handles the exact format we emit: flat objects with string, integer,
/// and boolean values.  Skips unknown keys.  No nesting beyond the top-level
/// `"vms": [...]` array.
/// Skip whitespace, return remaining slice.
fn skipWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
    return s[i..];
}

/// Try to consume a literal prefix. Returns remaining slice or null.
fn consumeLiteral(s: []const u8, literal: []const u8) ?[]const u8 {
    if (s.len >= literal.len and std.mem.eql(u8, s[0..literal.len], literal)) {
        return s[literal.len..];
    }
    return null;
}

/// Parse a JSON string value (supports \", \\, \n, \r, \t, and \uXXXX).
/// Returns the string content (unescaped into `out_buf`) and the remaining input.
fn parseJsonString(s: []const u8, out_buf: []u8) ?struct { value: []const u8, rest: []const u8 } {
    if (s.len == 0 or s[0] != '"') return null;
    var i: usize = 1;
    var out_len: usize = 0;
    while (i < s.len) {
        if (s[i] == '"') {
            return .{ .value = out_buf[0..out_len], .rest = s[i + 1 ..] };
        }
        if (s[i] == '\\' and i + 1 < s.len) {
            if (s[i + 1] == 'u' and i + 5 < s.len) {
                // Decode \uXXXX into a proper UTF-8 sequence.
                const hex = s[i + 2 .. i + 6];
                if (std.fmt.parseInt(u16, hex, 16)) |codepoint| {
                    if (codepoint < 0x80) {
                        if (out_len < out_buf.len) {
                            out_buf[out_len] = @intCast(codepoint);
                            out_len += 1;
                        }
                    } else if (codepoint < 0x800) {
                        if (out_len + 1 < out_buf.len) {
                            out_buf[out_len] = @intCast(0xC0 | (codepoint >> 6));
                            out_buf[out_len + 1] = @intCast(0x80 | (codepoint & 0x3F));
                            out_len += 2;
                        }
                    } else {
                        if (out_len + 2 < out_buf.len) {
                            out_buf[out_len] = @intCast(0xE0 | (codepoint >> 12));
                            out_buf[out_len + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                            out_buf[out_len + 2] = @intCast(0x80 | (codepoint & 0x3F));
                            out_len += 3;
                        }
                    }
                } else |_| {
                    // Invalid hex, just skip it to avoid crashing
                }
                i += 6;
                continue;
            }

            const esc: u8 = switch (s[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i + 1],
            };
            if (out_len < out_buf.len) {
                out_buf[out_len] = esc;
                out_len += 1;
            }
            i += 2;
        } else {
            if (out_len < out_buf.len) {
                out_buf[out_len] = s[i];
                out_len += 1;
            }
            i += 1;
        }
    }
    return null; // unterminated string
}

/// Parse a JSON integer value (unsigned, decimal only).
fn parseJsonInt(s: []const u8) ?struct { value: u32, rest: []const u8 } {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    const val = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    return .{ .value = val, .rest = s[i..] };
}

/// Parse a JSON boolean value.
fn parseJsonBool(s: []const u8) ?struct { value: bool, rest: []const u8 } {
    const cur = skipWs(s);
    if (consumeLiteral(cur, "true")) |rest| return .{ .value = true, .rest = rest };
    if (consumeLiteral(cur, "false")) |rest| return .{ .value = false, .rest = rest };
    return null;
}

/// Skip a JSON value (string, number, bool, null, object, or array).
fn skipJsonValue(s: []const u8) []const u8 {
    var cur = skipWs(s);
    if (cur.len == 0) return cur;
    switch (cur[0]) {
        '"' => {
            // Skip string
            var i: usize = 1;
            while (i < cur.len) {
                if (cur[i] == '"') return cur[i + 1 ..];
                if (cur[i] == '\\') i += 1; // skip escaped char
                i += 1;
            }
            return cur[cur.len..];
        },
        '{' => {
            // Skip object — count braces
            var depth: usize = 1;
            var i: usize = 1;
            var in_str = false;
            while (i < cur.len and depth > 0) {
                if (in_str) {
                    if (cur[i] == '\\') {
                        i += 1;
                    } else if (cur[i] == '"') {
                        in_str = false;
                    }
                } else {
                    if (cur[i] == '"') in_str = true else if (cur[i] == '{') depth += 1 else if (cur[i] == '}') depth -= 1;
                }
                i += 1;
            }
            return cur[i..];
        },
        '[' => {
            // Skip array — count brackets
            var depth: usize = 1;
            var i: usize = 1;
            var in_str = false;
            while (i < cur.len and depth > 0) {
                if (in_str) {
                    if (cur[i] == '\\') {
                        i += 1;
                    } else if (cur[i] == '"') {
                        in_str = false;
                    }
                } else {
                    if (cur[i] == '"') in_str = true else if (cur[i] == '[') depth += 1 else if (cur[i] == ']') depth -= 1;
                }
                i += 1;
            }
            return cur[i..];
        },
        else => {
            // number, bool, null — skip until delimiter
            var i: usize = 0;
            while (i < cur.len and cur[i] != ',' and cur[i] != '}' and cur[i] != ']' and cur[i] != '\n') : (i += 1) {}
            return cur[i..];
        },
    }
}

/// Parse a single VM object from the JSON and populate cfg.
/// Returns the remaining input after the closing '}'.
fn parseVmObject(input: []const u8, cfg: *vm.VmConfig) []const u8 {
    var cur = skipWs(input);
    // Expect '{'
    if (cur.len == 0 or cur[0] != '{') return cur;
    cur = cur[1..];

    var key_buf: [64]u8 = undefined;
    var str_buf: [4096]u8 = undefined;

    while (cur.len > 0) {
        cur = skipWs(cur);
        if (cur.len == 0) break;
        if (cur[0] == '}') return cur[1..];
        if (cur[0] == ',') {
            cur = cur[1..];
            continue;
        }

        // Parse key
        const key_result = parseJsonString(cur, &key_buf) orelse {
            // Guarantee forward progress. skipJsonValue stops at a delimiter and
            // returns its input unchanged on a stray ']' (its else branch sees the
            // delimiter at index 0). The loop top already consumes '}' and ',', so
            // a ']' here would otherwise spin forever on malformed input. Drop one
            // byte when nothing was consumed.
            const skipped = skipJsonValue(cur);
            cur = if (skipped.len < cur.len) skipped else cur[1..];
            continue;
        };
        const key = key_result.value;
        cur = skipWs(key_result.rest);

        // Expect ':'
        if (cur.len == 0 or cur[0] != ':') break;
        cur = skipWs(cur[1..]);

        // Parse value based on key
        if (std.mem.eql(u8, key, "name")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setName(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_path")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setDiskPath(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "iso_path")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setIsoPath(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "mac_address")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setMacAddress(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "notes")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setNotes(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "port_forwards")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setPortForwards(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "saved_state_path")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setSavedStatePath(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "shared_folder")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setSharedFolder(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk2_path")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setDisk2Path(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk2_size_gb")) {
            if (parseJsonInt(cur)) |r| {
                cfg.disk2_size_gb = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk2_format")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.disk2_format = parseDiskFormat(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "usb_device")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setUsbDevice(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "nic2_mode")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.nics[1].mode = parseNetworkMode(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "nic2_mac")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setNic2Mac(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "nic3_mode")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.nics[2].mode = parseNetworkMode(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "nic3_mac")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setNic3Mac(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "enable_3d")) {
            if (parseJsonBool(cur)) |r| {
                cfg.enable_3d = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "gpu_device")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.gpu_device = parseGpuDevice(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "guest_tools")) {
            if (parseJsonBool(cur)) |r| {
                cfg.guest_tools = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "favorite")) {
            if (parseJsonBool(cur)) |r| {
                cfg.favorite = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "autoprotect")) {
            if (parseJsonBool(cur)) |r| {
                cfg.autoprotect = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "autoprotect_interval_min")) {
            if (parseJsonInt(cur)) |r| {
                cfg.autoprotect_interval_min = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "autoprotect_max")) {
            if (parseJsonInt(cur)) |r| {
                cfg.autoprotect_max = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "autoprotect_last_epoch")) {
            if (parseJsonInt(cur)) |r| {
                cfg.autoprotect_last_epoch = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "autoprotect_last_seq")) {
            if (parseJsonInt(cur)) |r| {
                cfg.autoprotect_last_seq = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "floppy_path")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.setFloppyPath(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_format")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.disk_format = parseDiskFormat(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_cache")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.disk_cache = parseDiskCache(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "display")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.display = parseDisplayType(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "display_resolution")) {
            if (parseJsonInt(cur)) |r| {
                cfg.display_resolution = vm.DisplayResolution.fromIndex(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "network")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.nics[0].mode = parseNetworkMode(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "firmware")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.firmware = parseFirmware(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "guest_os")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.guest_os = parseGuestOs(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "audio")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.audio = parseAudioDevice(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "boot_order")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.boot_order = parseBootOrder(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "cpu_sockets")) {
            if (parseJsonInt(cur)) |r| {
                cfg.cpu_sockets = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "cpu_model")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.cpu_model = vm.CpuModel.fromStr(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "cpu_cores")) {
            if (parseJsonInt(cur)) |r| {
                cfg.cpu_cores = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "memory_mb")) {
            if (parseJsonInt(cur)) |r| {
                cfg.memory_mb = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_size_gb")) {
            if (parseJsonInt(cur)) |r| {
                cfg.disk_size_gb = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "vnc_port")) {
            if (parseJsonInt(cur)) |r| {
                cfg.vnc_port = @intCast(r.value & 0xFFFF);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "spice_port")) {
            if (parseJsonInt(cur)) |r| {
                cfg.spice_port = @intCast(r.value & 0xFFFF);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "accel")) {
            if (parseJsonString(cur, &key_buf)) |r| {
                cfg.accel = parseAccel(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "enable_kvm")) {
            // Backward compat: old configs used "enable_kvm": true/false.
            // true → "auto" (best HW accel), false → "tcg".
            if (parseJsonBool(cur)) |r| {
                cfg.accel = if (r.value) .auto else .tcg;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "embed_display")) {
            if (parseJsonBool(cur)) |r| {
                cfg.embed_display = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "enable_serial")) {
            if (parseJsonBool(cur)) |r| {
                cfg.enable_serial = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "virtio_rng")) {
            if (parseJsonBool(cur)) |r| {
                cfg.virtio_rng = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "guest_agent")) {
            if (parseJsonBool(cur)) |r| {
                cfg.guest_agent = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "watchdog")) {
            if (parseJsonString(cur, &str_buf)) |r| {
                cfg.watchdog = parseWatchdogAction(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "tpm")) {
            if (parseJsonBool(cur)) |r| {
                cfg.tpm = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "secure_boot")) {
            if (parseJsonBool(cur)) |r| {
                cfg.secure_boot = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "hyperv_enlightenments")) {
            if (parseJsonBool(cur)) |r| {
                cfg.hyperv_enlightenments = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "hugepages")) {
            if (parseJsonBool(cur)) |r| {
                cfg.hugepages = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "io_threads")) {
            if (parseJsonInt(cur)) |r| {
                cfg.io_threads = @intCast(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_bps_throttle")) {
            if (parseJsonInt(cur)) |r| {
                cfg.disk_bps_throttle = @as(u64, @intCast(r.value));
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "disk_iops_throttle")) {
            if (parseJsonInt(cur)) |r| {
                cfg.disk_iops_throttle = @intCast(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "ballooning")) {
            if (parseJsonBool(cur)) |r| {
                cfg.ballooning = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "host_autostart")) {
            if (parseJsonBool(cur)) |r| {
                cfg.host_autostart = r.value;
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else if (std.mem.eql(u8, key, "num_displays")) {
            if (parseJsonInt(cur)) |r| {
                cfg.num_displays = @intCast(r.value);
                cur = r.rest;
            } else cur = skipJsonValue(cur);
        } else {
            // Unknown key — skip value
            cur = skipJsonValue(cur);
        }
    }
    return cur;
}

/// Extract the top-level `"theme"` value from raw config bytes. Defaults to
/// `.light` when absent or malformed. Pure (no I/O) so it can be fuzzed.
fn parseThemeKey(content: []const u8) vm.Theme {
    if (std.mem.indexOf(u8, content, "\"theme\"")) |tidx| {
        const tcur = skipWs(content[tidx + 7 ..]);
        if (tcur.len > 0 and tcur[0] == ':') {
            var tbuf: [32]u8 = undefined;
            if (parseJsonString(skipWs(tcur[1..]), &tbuf)) |r| return vm.Theme.fromStr(r.value);
        }
    }
    return .light;
}

/// Parse the top-level "prefs" object from config bytes into `prefs_out`.
fn parsePrefs(content: []const u8, prefs_out: *vm.Prefs) void {
    prefs_out.* = .{};
    if (std.mem.indexOf(u8, content, "\"prefs\"")) |pidx| {
        var cur = skipWs(content[pidx + 7 ..]);
        if (cur.len == 0 or cur[0] != ':') return;
        cur = skipWs(cur[1..]);
        if (cur.len == 0 or cur[0] != '{') return;
        cur = cur[1..];
        var key_buf: [40]u8 = undefined;
        var str_buf: [vm.MAX_PATH + 1]u8 = undefined;
        while (cur.len > 0) {
            cur = skipWs(cur);
            if (cur.len == 0) break;
            if (cur[0] == '}') break;
            if (cur[0] == ',') { cur = cur[1..]; continue; }
            const kr = parseJsonString(cur, &key_buf) orelse { cur = cur[1..]; continue; };
            const key = kr.value;
            cur = skipWs(kr.rest);
            if (cur.len == 0 or cur[0] != ':') break;
            cur = skipWs(cur[1..]);
            if (std.mem.eql(u8, key, "default_vm_dir")) {
                if (parseJsonString(cur, &str_buf)) |r| {
                    const n = @min(r.value.len, vm.MAX_PATH);
                    @memcpy(prefs_out.default_vm_dir_buf[0..n], r.value[0..n]);
                    prefs_out.default_vm_dir_buf[n] = 0;
                    prefs_out.default_vm_dir_len = @intCast(n);
                    cur = r.rest;
                } else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "default_memory_mb")) {
                if (parseJsonInt(cur)) |r| { prefs_out.default_memory_mb = r.value; cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "default_cpu_cores")) {
                if (parseJsonInt(cur)) |r| { prefs_out.default_cpu_cores = r.value; cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "autoprotect_enabled_default")) {
                if (parseJsonBool(cur)) |r| { prefs_out.autoprotect_enabled_default = r.value; cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "autoprotect_interval_min_default")) {
                if (parseJsonInt(cur)) |r| { prefs_out.autoprotect_interval_min_default = r.value; cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "autoprotect_max_default")) {
                if (parseJsonInt(cur)) |r| { prefs_out.autoprotect_max_default = r.value; cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "win_x")) {
                if (parseJsonInt(cur)) |r| { prefs_out.win_x = @intCast(r.value); cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "win_y")) {
                if (parseJsonInt(cur)) |r| { prefs_out.win_y = @intCast(r.value); cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "win_w")) {
                if (parseJsonInt(cur)) |r| { prefs_out.win_w = @intCast(r.value); cur = r.rest; }
                else cur = cur[1..];
            } else if (std.mem.eql(u8, key, "win_h")) {
                if (parseJsonInt(cur)) |r| { prefs_out.win_h = @intCast(r.value); cur = r.rest; }
                else cur = cur[1..];
            } else {
                cur = skipJsonValue(cur);
            }
        }
    }
}

/// Load VM configs and preferences from vms.json on disk.
/// Returns the number of VMs loaded (0 if file doesn't exist or is invalid).
pub fn load(vms: *[MAX_VMS]vm.VmConfig, allocator: std.mem.Allocator, prefs_out: *vm.Prefs) usize {
    prefs_out.* = .{};
    prefs_out.theme = .light;
    var path_buf: [512]u8 = undefined;
    const file_path = getConfigPath(&path_buf) orelse return 0;

    const content = std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        file_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch return 0;
    defer allocator.free(content);

    if (content.len == 0) return 0;
    return loadFromSlice(vms, content, prefs_out);
}

/// Load VM configs and preferences from a JSON buffer (same format as vms.json).
/// Returns the number of VMs loaded (0 if buffer is empty or invalid).
pub fn loadFromSlice(vms: *[MAX_VMS]vm.VmConfig, content: []const u8, prefs_out: *vm.Prefs) usize {
    if (content.len == 0) return 0;

    // Top-level "theme" + "prefs" keys (optional).
    // parsePrefs resets prefs_out, so save/restore the theme.
    const loaded_theme = parseThemeKey(content);
    parsePrefs(content, prefs_out);
    prefs_out.theme = loaded_theme;

    // Find the "vms" array in the top-level object.
    var cur: []const u8 = content;

    // Skip to the "vms" key.  Two guards prevent false matches inside string
    // values: (1) the byte before `"vms"` must be a JSON key-position
    // character (start-of-input, `{`, `,`, or whitespace), and (2) the
    // character after the closing quote must be `:`.
    while (cur.len > 0) {
        if (std.mem.indexOf(u8, cur, "\"vms\"")) |idx| {
            // Guard 1: the byte before the match must be at a key position.
            const before = if (idx == 0) 0 else cur[idx - 1];
            if (idx > 0 and before != '{' and before != ',' and before != ' ' and before != '\t' and before != '\n' and before != '\r') {
                cur = cur[idx + 1 ..]; // skip one byte for forward progress
                continue;
            }
            cur = cur[idx + 5 ..]; // skip past "vms"
            cur = skipWs(cur);
            // Guard 2: the key must be followed by `:`.
            if (cur.len > 0 and cur[0] == ':') {
                cur = skipWs(cur[1..]);
                break;
            }
        } else {
            return 0; // no "vms" key found
        }
    }

    // Expect '['
    if (cur.len == 0 or cur[0] != '[') return 0;
    cur = cur[1..];

    // Parse VM objects
    var count: usize = 0;
    while (count < MAX_VMS) {
        cur = skipWs(cur);
        if (cur.len == 0) break;
        if (cur[0] == ']') break;
        if (cur[0] == ',') {
            cur = cur[1..];
            continue;
        }
        if (cur[0] == '{') {
            var cfg = vm.VmConfig{};
            cur = parseVmObject(cur, &cfg);
            vms.*[count] = cfg;
            count += 1;
        } else {
            break; // unexpected token
        }
    }

    return count;
}

// ── Tests ───────────────────────────────────────────────────────────

test "round-trip: VmConfig → VmJson fields → VmConfig preserves values" {
    var original = vm.VmConfig{};
    original.setName("TestVM");
    original.cpu_cores = 4;
    original.cpu_sockets = 2;
    original.cpu_model = .Skylake_Server;
    original.memory_mb = 8192;
    original.disk_size_gb = 100;
    original.disk_format = .vmdk;
    original.disk_cache = .unsafe;
    original.setDiskPath("/home/user/VMs/test.vmdk");
    original.setIsoPath("/tmp/ubuntu-22.04.iso");
    original.setMacAddress("02:00:11:22:33:44");
    original.setNotes("These are test notes\nfor the VM.");
    original.setPortForwards("8080:80,2222:22");
    original.setSavedStatePath("/tmp/state.bin");
    original.setSharedFolder("/srv/share");
    original.setDisk2Path("/tmp/data.qcow2");
    original.disk2_size_gb = 50;
    original.disk2_format = .raw;
    original.setUsbDevice("046d:c52b");
    original.nics[1].mode = .none;
    original.setNic2Mac("02:11:22:33:44:55");
    original.nics[2].mode = .user;
    original.setNic3Mac("02:66:77:88:99:AA");
    original.enable_3d = true;
    original.gpu_device = .virtio_gpu_gl;
    original.guest_tools = true;
    original.favorite = true;
    original.autoprotect = true;
    original.autoprotect_interval_min = 60;
    original.autoprotect_max = 10;
    original.autoprotect_last_epoch = 1717000000;
    original.autoprotect_last_seq = 7;
    original.setFloppyPath("/tmp/boot.img");
    original.display = .vnc;
    original.display_resolution = .res_1920x1080;
    original.nics[0].mode = .bridge;
    original.firmware = .uefi;
    original.guest_os = .windows;
    original.audio = .hda;
    original.boot_order = .cdrom_first;
    original.accel = .tcg;
    original.embed_display = true;
    original.vnc_port = 5901;
    original.spice_port = 5931;
    original.enable_serial = true;
    original.virtio_rng = true;
    original.guest_agent = true;
    original.watchdog = .reset;
    original.tpm = true;
    original.secure_boot = true;
    original.hyperv_enlightenments = true;
    original.hugepages = true;
    original.io_threads = 4;
    original.disk_bps_throttle = 104857600;
    original.disk_iops_throttle = 1000;
    original.ballooning = true;
    original.host_autostart = true;
    original.num_displays = 2;

    const json = VmJson{
        .name = original.getNameSlice(),
        .cpu_cores = original.cpu_cores,
        .cpu_sockets = original.cpu_sockets,
        .cpu_model = std.mem.span(original.cpu_model.toStr()),
        .memory_mb = original.memory_mb,
        .disk_size_gb = original.disk_size_gb,
        .disk_format = std.mem.span(original.disk_format.toStr()),
        .disk_cache = std.mem.span(original.disk_cache.toStr()),
        .disk_path = original.getDiskPathSlice(),
        .iso_path = original.getIsoPathSlice(),
        .mac_address = original.getMacAddressSlice(),
        .notes = original.getNotesSlice(),
        .port_forwards = original.getPortForwardsSlice(),
        .saved_state_path = original.getSavedStatePathSlice(),
        .shared_folder = original.getSharedFolderSlice(),
        .disk2_path = original.getDisk2PathSlice(),
        .disk2_size_gb = original.disk2_size_gb,
        .disk2_format = std.mem.span(original.disk2_format.toStr()),
        .usb_device = original.getUsbDeviceSlice(),
        .nic2_mode = std.mem.span(original.nics[1].mode.toStr()),
        .nic2_mac = original.getNic2MacSlice(),
        .nic3_mode = std.mem.span(original.nics[2].mode.toStr()),
        .nic3_mac = original.getNic3MacSlice(),
        .enable_3d = original.enable_3d,
        .gpu_device = std.mem.span(original.gpu_device.toStr()),
        .guest_tools = original.guest_tools,
        .favorite = original.favorite,
        .autoprotect = original.autoprotect,
        .autoprotect_interval_min = original.autoprotect_interval_min,
        .autoprotect_max = original.autoprotect_max,
        .autoprotect_last_epoch = original.autoprotect_last_epoch,
        .autoprotect_last_seq = original.autoprotect_last_seq,
        .floppy_path = original.getFloppyPathSlice(),
        .display = std.mem.span(original.display.toStr()),
        .display_resolution = @as(u32, @intCast(original.display_resolution.toIndex())),
        .network = std.mem.span(original.nics[0].mode.toStr()),
        .firmware = std.mem.span(original.firmware.toStr()),
        .guest_os = std.mem.span(original.guest_os.toStr()),
        .audio = std.mem.span(original.audio.toStr()),
        .boot_order = std.mem.span(original.boot_order.toStr()),
        .accel = std.mem.span(original.accel.toStr()),
        .embed_display = original.embed_display,
        .vnc_port = original.vnc_port,
        .spice_port = original.spice_port,
        .enable_serial = original.enable_serial,
        .virtio_rng = original.virtio_rng,
        .guest_agent = original.guest_agent,
        .watchdog = std.mem.span(original.watchdog.toStr()),
        .tpm = original.tpm,
        .secure_boot = original.secure_boot,
        .hyperv_enlightenments = original.hyperv_enlightenments,
        .hugepages = original.hugepages,
        .io_threads = original.io_threads,
        .disk_bps_throttle = original.disk_bps_throttle,
        .disk_iops_throttle = original.disk_iops_throttle,
        .ballooning = original.ballooning,
        .host_autostart = original.host_autostart,
        .num_displays = original.num_displays,
    };

    const restored = fromVmJson(&json);

    try std.testing.expectEqualStrings("TestVM", restored.getNameSlice());
    try std.testing.expectEqual(@as(u32, 4), restored.cpu_cores);
    try std.testing.expectEqual(@as(u32, 2), restored.cpu_sockets);
    try std.testing.expectEqual(vm.CpuModel.Skylake_Server, restored.cpu_model);
    try std.testing.expectEqual(@as(u32, 8192), restored.memory_mb);
    try std.testing.expectEqual(@as(u32, 100), restored.disk_size_gb);
    try std.testing.expectEqual(vm.DiskFormat.vmdk, restored.disk_format);
    try std.testing.expectEqual(vm.DiskCache.unsafe, restored.disk_cache);
    try std.testing.expectEqualStrings("/home/user/VMs/test.vmdk", restored.getDiskPathSlice());
    try std.testing.expectEqualStrings("/tmp/ubuntu-22.04.iso", restored.getIsoPathSlice());
    try std.testing.expectEqualStrings("02:00:11:22:33:44", restored.getMacAddressSlice());
    try std.testing.expectEqualStrings("These are test notes\nfor the VM.", restored.getNotesSlice());
    try std.testing.expectEqualStrings("8080:80,2222:22", restored.getPortForwardsSlice());
    try std.testing.expectEqualStrings("/tmp/state.bin", restored.getSavedStatePathSlice());
    try std.testing.expectEqualStrings("/srv/share", restored.getSharedFolderSlice());
    try std.testing.expectEqualStrings("/tmp/data.qcow2", restored.getDisk2PathSlice());
    try std.testing.expectEqual(@as(u32, 50), restored.disk2_size_gb);
    try std.testing.expectEqual(vm.DiskFormat.raw, restored.disk2_format);
    try std.testing.expectEqualStrings("046d:c52b", restored.getUsbDeviceSlice());
    try std.testing.expectEqual(vm.NetworkMode.none, restored.nics[1].mode);
    try std.testing.expectEqualStrings("02:11:22:33:44:55", restored.getNic2MacSlice());
    try std.testing.expectEqual(vm.NetworkMode.user, restored.nics[2].mode);
    try std.testing.expectEqualStrings("02:66:77:88:99:AA", restored.getNic3MacSlice());
    try std.testing.expect(restored.enable_3d);
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu_gl, restored.gpu_device);
    try std.testing.expect(restored.guest_tools);
    try std.testing.expect(restored.favorite);
    try std.testing.expect(restored.autoprotect);
    try std.testing.expectEqual(@as(u32, 60), restored.autoprotect_interval_min);
    try std.testing.expectEqual(@as(u32, 10), restored.autoprotect_max);
    try std.testing.expectEqual(@as(i64, 1717000000), restored.autoprotect_last_epoch);
    try std.testing.expectEqual(@as(u32, 7), restored.autoprotect_last_seq);
    try std.testing.expectEqualStrings("/tmp/boot.img", restored.getFloppyPathSlice());
    try std.testing.expectEqual(vm.DisplayType.vnc, restored.display);
    try std.testing.expectEqual(vm.DisplayResolution.res_1920x1080, restored.display_resolution);
    try std.testing.expectEqual(vm.NetworkMode.bridge, restored.nics[0].mode);
    try std.testing.expectEqual(vm.BootFirmware.uefi, restored.firmware);
    try std.testing.expectEqual(vm.GuestOs.windows, restored.guest_os);
    try std.testing.expectEqual(vm.AudioDevice.hda, restored.audio);
    try std.testing.expectEqual(vm.BootOrder.cdrom_first, restored.boot_order);
    try std.testing.expectEqual(vm.VmAccel.tcg, restored.accel);
    try std.testing.expect(restored.embed_display);
    try std.testing.expectEqual(@as(u16, 5901), restored.vnc_port);
    try std.testing.expectEqual(@as(u16, 5931), restored.spice_port);
    try std.testing.expect(restored.enable_serial);
    try std.testing.expect(restored.virtio_rng);
    try std.testing.expect(restored.guest_agent);
    try std.testing.expectEqual(vm.WatchdogAction.reset, restored.watchdog);
    try std.testing.expect(restored.tpm);
    try std.testing.expect(restored.secure_boot);
    try std.testing.expect(restored.hyperv_enlightenments);
    try std.testing.expect(restored.hugepages);
    try std.testing.expectEqual(@as(u32, 4), restored.io_threads);
    try std.testing.expectEqual(@as(u64, 104857600), restored.disk_bps_throttle);
    try std.testing.expectEqual(@as(u32, 1000), restored.disk_iops_throttle);
    try std.testing.expect(restored.ballooning);
    try std.testing.expect(restored.host_autostart);
    try std.testing.expectEqual(@as(u32, 2), restored.num_displays);
}

test "parseDiskFormat: maps strings to enums" {
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("qcow2"));
    try std.testing.expectEqual(vm.DiskFormat.raw, parseDiskFormat("raw"));
    try std.testing.expectEqual(vm.DiskFormat.vmdk, parseDiskFormat("vmdk"));
    try std.testing.expectEqual(vm.DiskFormat.vdi, parseDiskFormat("vdi"));
    try std.testing.expectEqual(vm.DiskFormat.qcow2, parseDiskFormat("unknown"));
}

test "parseDisplayType: maps strings to enums" {
    try std.testing.expectEqual(vm.DisplayType.gtk, parseDisplayType("gtk"));
    try std.testing.expectEqual(vm.DisplayType.sdl, parseDisplayType("sdl"));
    try std.testing.expectEqual(vm.DisplayType.spice, parseDisplayType("spice-app"));
    try std.testing.expectEqual(vm.DisplayType.spice, parseDisplayType("spice"));
    try std.testing.expectEqual(vm.DisplayType.vnc, parseDisplayType("vnc"));
    try std.testing.expectEqual(vm.DisplayType.none, parseDisplayType("none"));
    try std.testing.expectEqual(vm.DisplayType.gtk, parseDisplayType("unknown"));
}

test "parseNetworkMode: maps strings to enums" {
    try std.testing.expectEqual(vm.NetworkMode.user, parseNetworkMode("user"));
    try std.testing.expectEqual(vm.NetworkMode.bridge, parseNetworkMode("bridge"));
    try std.testing.expectEqual(vm.NetworkMode.none, parseNetworkMode("none"));
    try std.testing.expectEqual(vm.NetworkMode.user, parseNetworkMode("unknown"));
}

test "parseFirmware: maps strings to enums" {
    try std.testing.expectEqual(vm.BootFirmware.bios, parseFirmware("bios"));
    try std.testing.expectEqual(vm.BootFirmware.uefi, parseFirmware("uefi"));
    try std.testing.expectEqual(vm.BootFirmware.bios, parseFirmware("unknown"));
}

test "parseGuestOs: maps strings to enums" {
    try std.testing.expectEqual(vm.GuestOs.linux, parseGuestOs("linux"));
    try std.testing.expectEqual(vm.GuestOs.windows, parseGuestOs("windows"));
    try std.testing.expectEqual(vm.GuestOs.freebsd, parseGuestOs("freebsd"));
    try std.testing.expectEqual(vm.GuestOs.macos, parseGuestOs("macos"));
    try std.testing.expectEqual(vm.GuestOs.other, parseGuestOs("other"));
    try std.testing.expectEqual(vm.GuestOs.linux, parseGuestOs("unknown"));
}

test "parseAudioDevice: maps strings to enums" {
    try std.testing.expectEqual(vm.AudioDevice.none, parseAudioDevice("none"));
    try std.testing.expectEqual(vm.AudioDevice.hda, parseAudioDevice("intel-hda"));
    try std.testing.expectEqual(vm.AudioDevice.ac97, parseAudioDevice("AC97"));
    try std.testing.expectEqual(vm.AudioDevice.none, parseAudioDevice("unknown"));
}

test "parseBootOrder: maps strings to enums" {
    try std.testing.expectEqual(vm.BootOrder.disk_first, parseBootOrder("cdn"));
    try std.testing.expectEqual(vm.BootOrder.cdrom_first, parseBootOrder("dcn"));
    try std.testing.expectEqual(vm.BootOrder.network_first, parseBootOrder("ncd"));
    try std.testing.expectEqual(vm.BootOrder.disk_first, parseBootOrder("unknown"));
}

test "parseAccel: maps strings to enums with safe defaults" {
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("auto"));
    try std.testing.expectEqual(vm.VmAccel.tcg, parseAccel("tcg"));
    try std.testing.expectEqual(vm.VmAccel.kvm, parseAccel("kvm"));
    try std.testing.expectEqual(vm.VmAccel.hvf, parseAccel("hvf"));
    try std.testing.expectEqual(vm.VmAccel.whpx, parseAccel("whpx"));
    // Unknown / empty / mixed-case → safe default (auto)
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("unknown"));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel(""));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("KVM"));
    try std.testing.expectEqual(vm.VmAccel.auto, parseAccel("Hvf"));
}

test "parseGpuDevice: maps strings to enums" {
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu_gl, parseGpuDevice("virtio_gpu_gl"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice("virtio_vga_gl"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice("unknown"));
    try std.testing.expectEqual(vm.GpuDevice.virtio_vga_gl, parseGpuDevice(""));
}

test "parseDiskCache: maps strings to enums" {
    for (0..vm.DiskCache.count) |i| {
        const dc = vm.DiskCache.fromIndex(i);
        try std.testing.expectEqual(dc, parseDiskCache(std.mem.span(dc.toStr())));
    }
    try std.testing.expectEqual(vm.DiskCache.writeback, parseDiskCache("unknown"));
    try std.testing.expectEqual(vm.DiskCache.writeback, parseDiskCache(""));
}

test "parseWatchdogAction: maps strings to enums" {
    for (0..vm.WatchdogAction.count) |i| {
        const wa = vm.WatchdogAction.fromIndex(i);
        try std.testing.expectEqual(wa, parseWatchdogAction(std.mem.span(wa.toStr())));
    }
    try std.testing.expectEqual(vm.WatchdogAction.none, parseWatchdogAction("unknown"));
    try std.testing.expectEqual(vm.WatchdogAction.none, parseWatchdogAction(""));
}

test "emit→parse JSON text round-trip preserves all fields" {
    const alloc = std.testing.allocator;

    // Build a fully-populated VmConfig.
    var original = vm.VmConfig{};
    original.setName("RoundTrip");
    original.cpu_cores = 8;
    original.cpu_sockets = 2;
    original.cpu_model = .Skylake_Server;
    original.memory_mb = 16384;
    original.disk_size_gb = 200;
    original.disk_format = .vmdk;
    original.disk_cache = .unsafe;
    original.setDiskPath("/home/user/VMs/rt.vmdk");
    original.setIsoPath("/tmp/debian.iso");
    original.setMacAddress("02:AA:BB:CC:DD:EE");
    original.setNotes("Line 1\nLine 2");
    original.setPortForwards("8080:80,2222:22");
    original.setSavedStatePath("/tmp/rt.state");
    original.display = .spice;
    original.display_resolution = .res_1280x800;
    original.nics[0].mode = .bridge;
    original.firmware = .uefi;
    original.guest_os = .freebsd;
    original.audio = .ac97;
    original.boot_order = .network_first;
    original.accel = .tcg;
    original.embed_display = false;
    original.vnc_port = 5905;
    original.spice_port = 5935;
    original.enable_serial = false;
    original.virtio_rng = true;
    original.guest_agent = true;
    original.watchdog = .poweroff;
    original.tpm = true;
    original.secure_boot = true;
    original.hyperv_enlightenments = true;
    original.hugepages = true;
    original.io_threads = 4;
    original.disk_bps_throttle = 52428800;
    original.disk_iops_throttle = 500;
    original.ballooning = true;
    original.host_autostart = true;
    original.setSharedFolder("/srv/share");
    original.setDisk2Path("/home/user/VMs/rt-data.qcow2");
    original.disk2_size_gb = 50;
    original.disk2_format = .raw;
    original.setUsbDevice("046d:c52b");
    original.nics[1].mode = .bridge;
    original.setNic2Mac("02:11:22:33:44:55");
    original.nics[2].mode = .user;
    original.setNic3Mac("02:66:77:88:99:AA");
    original.enable_3d = true;
    original.gpu_device = .virtio_gpu_gl;
    original.guest_tools = true;
    original.favorite = true;
    original.autoprotect = true;
    original.autoprotect_interval_min = 720;
    original.autoprotect_max = 5;
    original.autoprotect_last_epoch = 1717000000;
    original.autoprotect_last_seq = 42;
    original.setFloppyPath("/tmp/boot.img");
    original.num_displays = 3;

    // Emit to JSON text.
    var list: List = .empty;
    defer list.deinit(alloc);
    try emitVmJson(&list, alloc, &original);

    // Parse back via parseVmObject.
    var restored = vm.VmConfig{};
    _ = parseVmObject(list.items, &restored);

    // Verify every field survived the round-trip.
    try std.testing.expectEqualStrings("RoundTrip", restored.getNameSlice());
    try std.testing.expectEqual(@as(u32, 8), restored.cpu_cores);
    try std.testing.expectEqual(@as(u32, 2), restored.cpu_sockets);
    try std.testing.expectEqual(vm.CpuModel.Skylake_Server, restored.cpu_model);
    try std.testing.expectEqual(@as(u32, 16384), restored.memory_mb);
    try std.testing.expectEqual(@as(u32, 200), restored.disk_size_gb);
    try std.testing.expectEqual(vm.DiskFormat.vmdk, restored.disk_format);
    try std.testing.expectEqual(vm.DiskCache.unsafe, restored.disk_cache);
    try std.testing.expectEqualStrings("/home/user/VMs/rt.vmdk", restored.getDiskPathSlice());
    try std.testing.expectEqualStrings("/tmp/debian.iso", restored.getIsoPathSlice());
    try std.testing.expectEqualStrings("02:AA:BB:CC:DD:EE", restored.getMacAddressSlice());
    try std.testing.expectEqualStrings("Line 1\nLine 2", restored.getNotesSlice());
    try std.testing.expectEqualStrings("8080:80,2222:22", restored.getPortForwardsSlice());
    try std.testing.expectEqualStrings("/tmp/rt.state", restored.getSavedStatePathSlice());
    try std.testing.expectEqual(vm.DisplayType.spice, restored.display);
    try std.testing.expectEqual(vm.DisplayResolution.res_1280x800, restored.display_resolution);
    try std.testing.expectEqual(vm.NetworkMode.bridge, restored.nics[0].mode);
    try std.testing.expectEqual(vm.BootFirmware.uefi, restored.firmware);
    try std.testing.expectEqual(vm.GuestOs.freebsd, restored.guest_os);
    try std.testing.expectEqual(vm.AudioDevice.ac97, restored.audio);
    try std.testing.expectEqual(vm.BootOrder.network_first, restored.boot_order);
    try std.testing.expectEqual(vm.VmAccel.tcg, restored.accel);
    try std.testing.expect(!restored.embed_display);
    try std.testing.expectEqual(@as(u16, 5905), restored.vnc_port);
    try std.testing.expectEqual(@as(u16, 5935), restored.spice_port);
    try std.testing.expect(!restored.enable_serial);
    try std.testing.expect(restored.virtio_rng);
    try std.testing.expect(restored.guest_agent);
    try std.testing.expectEqual(vm.WatchdogAction.poweroff, restored.watchdog);
    try std.testing.expect(restored.tpm);
    try std.testing.expect(restored.secure_boot);
    try std.testing.expect(restored.hyperv_enlightenments);
    try std.testing.expect(restored.hugepages);
    try std.testing.expectEqual(@as(u32, 4), restored.io_threads);
    try std.testing.expectEqual(@as(u64, 52428800), restored.disk_bps_throttle);
    try std.testing.expectEqual(@as(u32, 500), restored.disk_iops_throttle);
    try std.testing.expect(restored.ballooning);
    try std.testing.expect(restored.host_autostart);
    try std.testing.expectEqualStrings("/srv/share", restored.getSharedFolderSlice());
    try std.testing.expectEqualStrings("/home/user/VMs/rt-data.qcow2", restored.getDisk2PathSlice());
    try std.testing.expectEqual(@as(u32, 50), restored.disk2_size_gb);
    try std.testing.expectEqual(vm.DiskFormat.raw, restored.disk2_format);
    try std.testing.expectEqualStrings("046d:c52b", restored.getUsbDeviceSlice());
    try std.testing.expectEqual(vm.NetworkMode.bridge, restored.nics[1].mode);
    try std.testing.expectEqualStrings("02:11:22:33:44:55", restored.getNic2MacSlice());
    try std.testing.expectEqual(vm.NetworkMode.user, restored.nics[2].mode);
    try std.testing.expectEqualStrings("02:66:77:88:99:AA", restored.getNic3MacSlice());
    try std.testing.expect(restored.enable_3d);
    try std.testing.expectEqual(vm.GpuDevice.virtio_gpu_gl, restored.gpu_device);
    try std.testing.expect(restored.guest_tools);
    try std.testing.expect(restored.favorite);
    try std.testing.expect(restored.autoprotect);
    try std.testing.expectEqual(@as(u32, 720), restored.autoprotect_interval_min);
    try std.testing.expectEqual(@as(u32, 5), restored.autoprotect_max);
    try std.testing.expectEqual(@as(i64, 1717000000), restored.autoprotect_last_epoch);
    try std.testing.expectEqual(@as(u32, 42), restored.autoprotect_last_seq);
    try std.testing.expectEqualStrings("/tmp/boot.img", restored.getFloppyPathSlice());
    try std.testing.expectEqual(@as(u32, 3), restored.num_displays);
}

test "emit→parse: strings with special characters survive round-trip" {
    const alloc = std.testing.allocator;

    var original = vm.VmConfig{};
    original.setName("Test\"VM");
    original.setNotes("tab:\there\nnewline\r\nend");

    var list: List = .empty;
    defer list.deinit(alloc);
    try emitVmJson(&list, alloc, &original);

    var restored = vm.VmConfig{};
    _ = parseVmObject(list.items, &restored);

    try std.testing.expectEqualStrings("Test\"VM", restored.getNameSlice());
    try std.testing.expectEqualStrings("tab:\there\nnewline\r\nend", restored.getNotesSlice());
}

test "parseVmObject: empty object yields defaults" {
    var cfg = vm.VmConfig{};
    cfg.cpu_cores = 999; // set to non-default to prove parsing resets nothing extra
    _ = parseVmObject("{}", &cfg);
    // An empty object leaves fields at their initial values (cpu_cores was set before parsing,
    // and the parser doesn't reset it because there's no "cpu_cores" key).
    try std.testing.expectEqual(@as(u32, 999), cfg.cpu_cores);
}

test "parseVmObject: unknown keys are skipped gracefully" {
    var cfg = vm.VmConfig{};
    const json =
        \\{"unknown_key": "ignored", "name": "SkipTest", "extra": 42}
    ;
    _ = parseVmObject(json, &cfg);
    try std.testing.expectEqualStrings("SkipTest", cfg.getNameSlice());
}

test "emitJsonStr: control characters become \\uXXXX" {
    const alloc = std.testing.allocator;
    var list: List = .empty;
    defer list.deinit(alloc);

    // Emit a string containing ASCII 0x01 (SOH control character).
    try emitJsonStr(&list, alloc, &[_]u8{0x01});

    // Should produce: "\u0001"
    try std.testing.expectEqualStrings("\"\\u0001\"", list.items);
}

test "parseJsonString: handles \\uXXXX for control chars" {
    var out: [64]u8 = undefined;
    const result = parseJsonString("\"hello\\u000aworld\"", &out) orelse unreachable;
    // \u000a = newline
    try std.testing.expectEqualStrings("hello\nworld", result.value);
}

test "parseJsonString: handles \\uXXXX non-ASCII (UTF-8)" {
    var out: [64]u8 = undefined;
    // \u00E9 = é (U+00E9, 2-byte UTF-8: 0xC3 0xA9)
    const r1 = parseJsonString("\"caf\\u00E9\"", &out) orelse unreachable;
    try std.testing.expectEqualStrings("café", r1.value);
    // \u20AC = € (U+20AC, 3-byte UTF-8: 0xE2 0x82 0xAC)
    const r2 = parseJsonString("\"\\u20AC100\"", &out) orelse unreachable;
    try std.testing.expectEqualStrings("€100", r2.value);
    // \u0000 = NUL (still 1 byte)
    const r3 = parseJsonString("\"a\\u0000b\"", &out) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 3), r3.value.len);
    try std.testing.expectEqual(@as(u8, 'a'), r3.value[0]);
    try std.testing.expectEqual(@as(u8, 0), r3.value[1]);
    try std.testing.expectEqual(@as(u8, 'b'), r3.value[2]);
}

test "loadFromSlice: vms key not confused by 'vms' inside string value" {
    var vms: [MAX_VMS]vm.VmConfig = undefined;
    var prefs: vm.Prefs = .{};
    // "vms" appears inside a VM name value — should not confuse the parser.
    const json =
        \\{"vms":[
        \\  {"name":"vms-server","cpu_cores":1,"memory_mb":256,"disk_size_gb":10}
        \\]}
    ;
    const n = loadFromSlice(&vms, json, &prefs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("vms-server", std.mem.span(vms[0].getName()));
}

test "loadFromSlice: \"vms\" inside string followed by colon does not match" {
    var vms: [MAX_VMS]vm.VmConfig = undefined;
    var prefs: vm.Prefs = .{};
    // The notes field contains the literal text `"vms" :` which superficially
    // looks like a key-value pair. The parser must reject it because it's
    // inside a string value, not at a JSON key position.
    const json =
        \\{"vms":[
        \\  {"name":"test","notes":"look at \\"vms\\" : tricked"}
        \\]}
    ;
    const n = loadFromSlice(&vms, json, &prefs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("test", std.mem.span(vms[0].getName()));
}

// ── Fuzz tests ──────────────────────────────────────────────────────
//
// The hand-rolled JSON parser is the riskiest surface: it consumes untrusted
// file contents. Feed it tens of thousands of random + adversarial byte
// streams and assert it never crashes (no OOB/overflow/UB), always terminates,
// and only ever returns suffix slices of its input. Reproducible via the seed.

/// Returns true if `sub` is a suffix view of `whole` (same backing memory).
fn isSuffix(whole: []const u8, sub: []const u8) bool {
    const base = @intFromPtr(whole.ptr);
    const end = base + whole.len;
    const p = @intFromPtr(sub.ptr);
    return p >= base and p <= end and p + sub.len == end;
}

/// Fill `buf` with random bytes, biased toward JSON-significant characters so
/// the parser exercises real control paths rather than mostly rejecting noise.
fn fuzzFill(rnd: std.Random, buf: []u8) void {
    const toks = "{}[]\":,\\ \t\n0123456789truefalsanmevbcdx";
    for (buf) |*b| {
        if (rnd.boolean()) {
            b.* = toks[rnd.uintLessThan(usize, toks.len)];
        } else {
            b.* = rnd.int(u8);
        }
    }
}

test "parseVmObject: stray ']' terminates (no infinite loop)" {
    // Regression: a ']' where a key is expected used to spin forever because
    // skipJsonValue returned its input unchanged at a delimiter. These must all
    // return promptly with a suffix of their input.
    inline for (.{ "{]", "{]]]]]", "{ ]", "{\"a\":]]", "{,],}", "{\"name\":\"x\"]" }) |s| {
        var cfg = vm.VmConfig{};
        const rest = parseVmObject(s, &cfg);
        try std.testing.expect(isSuffix(s, rest));
    }
}

test "fuzz: parseVmObject never crashes and returns a suffix" {
    var prng = std.Random.DefaultPrng.init(0x1357_9BDF);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;

    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        fuzzFill(rnd, buf[0..len]);
        var cfg = vm.VmConfig{};
        const rest = parseVmObject(buf[0..len], &cfg);
        try std.testing.expect(isSuffix(buf[0..len], rest));
    }
}

test "fuzz: parseThemeKey never crashes on random input" {
    var prng = std.Random.DefaultPrng.init(0x7EA_5EED);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        fuzzFill(rnd, buf[0..len]);
        // Sometimes splice in a literal "theme" token to reach the value path.
        if (len >= 8 and rnd.boolean()) {
            const at = rnd.uintLessThan(usize, len - 7);
            @memcpy(buf[at..][0..7], "\"theme\"");
        }
        const t = parseThemeKey(buf[0..len]);
        // Result must always be a valid Theme variant.
        try std.testing.expect(t.toIndex() < vm.Theme.count);
    }
}

test "fuzz: json primitive parsers never crash and stay in bounds" {
    var prng = std.Random.DefaultPrng.init(0x2468_ACE0);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var out: [128]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        fuzzFill(rnd, buf[0..len]);
        const s = buf[0..len];

        try std.testing.expect(isSuffix(s, skipWs(s)));
        try std.testing.expect(isSuffix(s, skipJsonValue(s)));
        if (parseJsonString(s, &out)) |r| {
            try std.testing.expect(r.value.len <= out.len);
            try std.testing.expect(isSuffix(s, r.rest));
        }
        if (parseJsonInt(s)) |r| try std.testing.expect(isSuffix(s, r.rest));
        if (parseJsonBool(s)) |r| try std.testing.expect(isSuffix(s, r.rest));
    }
}

/// Build a random VmConfig: random enums (via fromIndex of arbitrary usize)
/// and random-byte strings (incl. quotes/backslashes/control chars to stress
/// the emitter's escaping).
fn fuzzConfig(rnd: std.Random, sbuf: []u8) vm.VmConfig {
    var c = vm.VmConfig{};
    c.cpu_cores = rnd.int(u32);
    c.cpu_sockets = rnd.int(u32);
    c.memory_mb = rnd.int(u32);
    c.disk_size_gb = rnd.int(u32);
    c.disk2_size_gb = rnd.int(u32);
    c.vnc_port = rnd.int(u16);
    c.spice_port = rnd.int(u16);
    c.disk_format = vm.DiskFormat.fromIndex(rnd.int(usize));
    c.disk2_format = vm.DiskFormat.fromIndex(rnd.int(usize));
    c.disk_cache = vm.DiskCache.fromIndex(rnd.int(usize));
    c.display = vm.DisplayType.fromIndex(rnd.int(usize));
    c.display_resolution = vm.DisplayResolution.fromIndex(rnd.int(usize));
    c.nics[0].mode = vm.NetworkMode.fromIndex(rnd.int(usize));
    c.nics[1].mode = vm.NetworkMode.fromIndex(rnd.int(usize));
    c.nics[2].mode = vm.NetworkMode.fromIndex(rnd.int(usize));
    c.firmware = vm.BootFirmware.fromIndex(rnd.int(usize));
    c.guest_os = vm.GuestOs.fromIndex(rnd.int(usize));
    c.audio = vm.AudioDevice.fromIndex(rnd.int(usize));
    c.boot_order = vm.BootOrder.fromIndex(rnd.int(usize));
    c.accel = vm.VmAccel.fromIndex(rnd.int(usize));
    c.embed_display = rnd.boolean();
    c.enable_serial = rnd.boolean();
    c.virtio_rng = rnd.boolean();
    c.guest_agent = rnd.boolean();
    c.watchdog = vm.WatchdogAction.fromIndex(rnd.int(usize));
    c.tpm = rnd.boolean();
    c.secure_boot = rnd.boolean();
    c.hyperv_enlightenments = rnd.boolean();
    c.hugepages = rnd.boolean();
    c.io_threads = rnd.int(u32);
    c.disk_bps_throttle = rnd.int(u64);
    c.disk_iops_throttle = rnd.int(u32);
    c.ballooning = rnd.boolean();
    c.host_autostart = rnd.boolean();
    c.enable_3d = rnd.boolean();
    const rstr = struct {
        fn get(r: std.Random, b: []u8) []const u8 {
            const n = r.uintLessThan(usize, b.len + 1);
            for (b[0..n]) |*x| x.* = r.int(u8);
            return b[0..n];
        }
    };
    c.setName(rstr.get(rnd, sbuf));
    c.setNotes(rstr.get(rnd, sbuf));
    c.setDiskPath(rstr.get(rnd, sbuf));
    c.setPortForwards(rstr.get(rnd, sbuf));
    c.setMacAddress(rstr.get(rnd, sbuf));
    c.setUsbDevice(rstr.get(rnd, sbuf));
    return c;
}

test "fuzz: emit then parse random configs never crashes" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0BAD_F00D);
    const rnd = prng.random();
    var sbuf: [300]u8 = undefined;

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var orig = fuzzConfig(rnd, &sbuf);
        var list: List = .empty;
        defer list.deinit(alloc);
        try emitVmJson(&list, alloc, &orig);

        var restored = vm.VmConfig{};
        _ = parseVmObject(list.items, &restored);
        // Numeric/enum fields are emitted unambiguously, so they must survive.
        try std.testing.expectEqual(orig.cpu_cores, restored.cpu_cores);
        try std.testing.expectEqual(orig.memory_mb, restored.memory_mb);
        try std.testing.expectEqual(orig.disk_format, restored.disk_format);
        try std.testing.expectEqual(orig.guest_os, restored.guest_os);
    }
}

test "fuzz: mutated valid JSON never crashes the parser" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FF_EE11);
    const rnd = prng.random();
    var sbuf: [120]u8 = undefined;

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var cfg = fuzzConfig(rnd, &sbuf);
        var list: List = .empty;
        defer list.deinit(alloc);
        try emitVmJson(&list, alloc, &cfg);

        // Apply a handful of random byte mutations to the valid JSON.
        const muts = rnd.uintLessThan(usize, 12);
        var m: usize = 0;
        while (m < muts and list.items.len > 0) : (m += 1) {
            list.items[rnd.uintLessThan(usize, list.items.len)] = rnd.int(u8);
        }

        var restored = vm.VmConfig{};
        const rest = parseVmObject(list.items, &restored);
        try std.testing.expect(isSuffix(list.items, rest));
    }
}

// ── Direct coverage for primitive parsers (previously only fuzzed) ──

test "consumeLiteral: matches prefix or returns null" {
    try std.testing.expectEqualStrings(" rest", consumeLiteral("true rest", "true").?);
    try std.testing.expect(consumeLiteral("false", "true") == null);
    try std.testing.expect(consumeLiteral("tru", "true") == null); // too short
    try std.testing.expectEqualStrings("", consumeLiteral("null", "null").?);
}

test "parseJsonInt: decimal parse + delimiter stop" {
    const r = parseJsonInt("42,").?;
    try std.testing.expectEqual(@as(u32, 42), r.value);
    try std.testing.expectEqualStrings(",", r.rest);
    try std.testing.expect(parseJsonInt("abc") == null);
    try std.testing.expect(parseJsonInt("") == null);
    const big = parseJsonInt("4096}").?;
    try std.testing.expectEqual(@as(u32, 4096), big.value);
    try std.testing.expectEqualStrings("}", big.rest);
}

test "parseJsonBool: true/false/none" {
    try std.testing.expect(parseJsonBool("true,").?.value == true);
    try std.testing.expect(parseJsonBool("false}").?.value == false);
    try std.testing.expect(parseJsonBool("null") == null);
    try std.testing.expect(parseJsonBool("True") == null); // case-sensitive
}

test "parseThemeKey: concrete values + default" {
    try std.testing.expectEqual(vm.Theme.dark, parseThemeKey("{ \"theme\": \"dark\" }"));
    try std.testing.expectEqual(vm.Theme.system, parseThemeKey("{\"theme\":\"system\"}"));
    try std.testing.expectEqual(vm.Theme.light, parseThemeKey("{\"theme\":\"light\"}"));
    try std.testing.expectEqual(vm.Theme.light, parseThemeKey("{}")); // absent → default light
}

test "emitByte: appends a single byte" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emitByte(&list, std.testing.allocator, 'Z');
    try std.testing.expectEqualStrings("Z", list.items);
}

// ── Missing standalone coverage ─────────────────────────────────────

test "emit: appends a slice" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emit(&list, std.testing.allocator, "hello");
    try emit(&list, std.testing.allocator, " world");
    try std.testing.expectEqualStrings("hello world", list.items);
}

test "emitInt: zero and max u32" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emitInt(&list, std.testing.allocator, @as(u32, 0));
    try std.testing.expectEqualStrings("0", list.items);

    list.clearRetainingCapacity();
    try emitInt(&list, std.testing.allocator, @as(u32, 4294967295));
    try std.testing.expectEqualStrings("4294967295", list.items);
}

test "emitBool: true and false" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emitBool(&list, std.testing.allocator, true);
    try std.testing.expectEqualStrings("true", list.items);

    list.clearRetainingCapacity();
    try emitBool(&list, std.testing.allocator, false);
    try std.testing.expectEqualStrings("false", list.items);
}

test "emitJsonStr: empty string" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emitJsonStr(&list, std.testing.allocator, "");
    try std.testing.expectEqualStrings("\"\"", list.items);
}

test "emitJsonStr: all JSON-special characters escaped" {
    var list: List = .empty;
    defer list.deinit(std.testing.allocator);
    try emitJsonStr(&list, std.testing.allocator, "a\"b\\c\nd\re\tf");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\"", list.items);
}

test "parseJsonString: empty string" {
    var out: [64]u8 = undefined;
    const r = parseJsonString("\"\"", &out).?;
    try std.testing.expectEqual(@as(usize, 0), r.value.len);
    try std.testing.expectEqualStrings("", r.rest);
}

test "parseJsonString: unescaped slashes pass through" {
    var out: [64]u8 = undefined;
    const r = parseJsonString("\"a/b/c\"", &out).?;
    try std.testing.expectEqualStrings("a/b/c", r.value);
}

test "parseJsonInt: max u32 value" {
    const r = parseJsonInt("4294967295").?;
    try std.testing.expectEqual(@as(u32, 4294967295), r.value);
}

test "parseJsonInt: value too large for u32 returns null" {
    try std.testing.expect(parseJsonInt("4294967296") == null); // > max u32
    try std.testing.expect(parseJsonInt("99999999999") == null);
}

test "parseJsonBool: with whitespace before" {
    const r = parseJsonBool("  true").?;
    try std.testing.expect(r.value == true);
    try std.testing.expectEqualStrings("", r.rest);
}

test "skipJsonValue: skips nested object" {
    const s = "{\"a\": {\"b\": 1}}tail";
    const rest = skipJsonValue(s);
    try std.testing.expectEqualStrings("tail", rest);
}

test "skipJsonValue: skips nested array" {
    const s = "[1, [2, 3]]tail";
    const rest = skipJsonValue(s);
    try std.testing.expectEqualStrings("tail", rest);
}

test "skipJsonValue: skips string with escapes" {
    const s = "\"hello \\\"world\\\"\"tail";
    const rest = skipJsonValue(s);
    try std.testing.expectEqualStrings("tail", rest);
}

test "skipJsonValue: skips number/bool/null to delimiter" {
    try std.testing.expectEqualStrings(",next", skipJsonValue("123.45,next"));
    try std.testing.expectEqualStrings("}", skipJsonValue("true}"));
    try std.testing.expectEqualStrings("]", skipJsonValue("null]"));
}

test "parseVmObject: missing colon between key and value skips" {
    var cfg = vm.VmConfig{};
    const rest = parseVmObject("{\"name\" \"novalue\"}", &cfg);
    try std.testing.expect(isSuffix("{\"name\" \"novalue\"}", rest));
}

test "parseVmObject: key without closing quote is skipped" {
    var cfg = vm.VmConfig{};
    const rest = parseVmObject("{\"name: \"value\"}", &cfg);
    try std.testing.expect(isSuffix("{\"name: \"value\"}", rest));
}

test "emit→parse: empty config round-trip" {
    const alloc = std.testing.allocator;
    const orig = vm.VmConfig{};

    var list: List = .empty;
    defer list.deinit(alloc);
    try emitVmJson(&list, alloc, &orig);

    var restored = vm.VmConfig{};
    _ = parseVmObject(list.items, &restored);

    // All fields should be at defaults.
    try std.testing.expectEqual(@as(u32, 2), restored.cpu_cores);
    try std.testing.expectEqual(@as(u32, 2048), restored.memory_mb);
    try std.testing.expectEqual(vm.DiskFormat.qcow2, restored.disk_format);
    try std.testing.expectEqual(vm.VmAccel.auto, restored.accel);
    try std.testing.expectEqual(vm.NetworkMode.user, restored.nics[0].mode);
}

test "loadFromSlice: direct" {
    var vms: [MAX_VMS]vm.VmConfig = undefined;
    var prefs: vm.Prefs = .{};

    // Empty input → 0 VMs.
    {
        const n = loadFromSlice(&vms, "", &prefs);
        try std.testing.expectEqual(@as(usize, 0), n);
    }

    // Missing "vms" key → 0 VMs.
    {
        const n = loadFromSlice(&vms, "{}", &prefs);
        try std.testing.expectEqual(@as(usize, 0), n);
    }
    {
        const n = loadFromSlice(&vms, "{\"prefs\":{}}", &prefs);
        try std.testing.expectEqual(@as(usize, 0), n);
    }

    // Single VM object.
    {
        const json =
            \\{"vms":[
            \\  {"name":"test","cpu_cores":4,"memory_mb":8192,"disk_size_gb":100,"disk_format":"qcow2"}
            \\]}
        ;
        const n = loadFromSlice(&vms, json, &prefs);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqualStrings("test", std.mem.span(vms[0].getName()));
        try std.testing.expectEqual(@as(u32, 4), vms[0].cpu_cores);
        try std.testing.expectEqual(@as(u32, 8192), vms[0].memory_mb);
        try std.testing.expectEqual(@as(u32, 100), vms[0].disk_size_gb);
    }

    // Multiple VM objects.
    {
        const json =
            \\{"vms":[
            \\  {"name":"a","cpu_cores":1,"memory_mb":512,"disk_size_gb":10},
            \\  {},
            \\  {"name":"c","cpu_cores":8,"memory_mb":4096,"disk_size_gb":200}
            \\]}
        ;
        const n = loadFromSlice(&vms, json, &prefs);
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expectEqualStrings("a", std.mem.span(vms[0].getName()));
        try std.testing.expectEqual(@as(u32, 1), vms[0].cpu_cores);
        // Second VM: all defaults (empty object).
        try std.testing.expectEqualStrings("", std.mem.span(vms[1].getName()));
        try std.testing.expectEqual(@as(u32, 2), vms[1].cpu_cores);
        // Third VM.
        try std.testing.expectEqualStrings("c", std.mem.span(vms[2].getName()));
        try std.testing.expectEqual(@as(u32, 8), vms[2].cpu_cores);
    }

    // JSON with theme + prefs but no VMs → 0 VMs, prefs parsed.
    {
        const json =
            \\{"theme":"light","prefs":{"default_memory_mb":1024},
            \\"vms":[]}
        ;
        const n = loadFromSlice(&vms, json, &prefs);
        try std.testing.expectEqual(@as(usize, 0), n);
        try std.testing.expectEqual(vm.Theme.light, prefs.theme);
    }

    // Malformed JSON — no closing bracket.
    {
        const json = "{\"vms\":[{\"name\":\"dangling\"}";
        const n = loadFromSlice(&vms, json, &prefs);
        // Should parse the one VM and return 1 (not infinite-loop).
        try std.testing.expectEqual(@as(usize, 1), n);
    }

    // Interleaved whitespace and commas.
    {
        const json =
            \\ { "vms" : [ { "name" : "spaced" , "cpu_cores" : 3 } , { } ] }
        ;
        const n = loadFromSlice(&vms, json, &prefs);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqualStrings("spaced", std.mem.span(vms[0].getName()));
        try std.testing.expectEqual(@as(u32, 3), vms[0].cpu_cores);
    }

    // Theme key alone.
    {
        const json =
            \\{"theme":"light","vms":[]}
        ;
        const n = loadFromSlice(&vms, json, &prefs);
        try std.testing.expectEqual(@as(usize, 0), n);
        try std.testing.expectEqual(vm.Theme.light, prefs.theme);
    }
}
