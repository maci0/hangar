// SPDX-License-Identifier: MIT
//! Shared global state for the Hangar web backend and CLI tools.
//!
//! All VM arrays, session state, VNC/SPICE clients, serial state,
//! remote mode flags, and small cross-cutting helpers live here so that
//! serial_console, remote, persist, and vnet modules can share them
//! without circular imports.

const std = @import("std");
const vm = @import("vm.zig");
const sync = @import("sync.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const appio = @import("appio.zig");

pub const MAX_VMS = vm.MAX_VMS;
pub const SERIAL_BUF_SIZE = 64 * 1024;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ── VM state ────────────────────────────────────────────────────────

pub var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
pub var vm_count: usize = 0;
pub var vms_mutex: sync.SpinMutex = .{};
pub var prefs: vm.Prefs = .{};
pub var vm_started: [MAX_VMS]i64 = [_]i64{0} ** MAX_VMS;
pub var g_vmm: hv_iface.Vmm = undefined;
pub var g_vmm_ready: bool = false;
pub var g_vmm_handles: [MAX_VMS]?hv_iface.VmmHandle = .{null} ** MAX_VMS;

// ── Undo state ──────────────────────────────────────────────────────

pub var undo_vm: vm.VmConfig = .{};
pub var undo_idx: usize = 0;
pub var undo_available: bool = false;

// ── Serial console state ────────────────────────────────────────────

pub var serial_buf: [SERIAL_BUF_SIZE]u8 = undefined;
pub var serial_len: usize = 0;
pub var serial_mutex: sync.SpinMutex = .{};
pub var serial_running: bool = false;
pub var serial_thread: ?std.Thread = null;
pub var serial_fd: ?std.c.fd_t = null;

// ── Remote client mode ──────────────────────────────────────────────

pub var remote_mode: bool = false;
pub var remote_url: [128]u8 = [_]u8{0} ** 128;
pub var remote_url_len: usize = 0;

// ── VMM handle helpers ──────────────────────────────────────────────

/// Get or create the Vmm handle for VM at index idx.
pub fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], vms[idx].accel, std.heap.page_allocator) catch return null;
    }
    return g_vmm_handles[idx];
}

/// Destroy the Vmm handle for VM at index idx.
/// Requires g_vmm to be initialized (g_vmm_ready == true).
pub fn destroyVmmHandle(idx: usize) void {
    std.debug.assert(g_vmm_ready);
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
}

// ── Config path helpers ────────────────────────────────────────────

/// Return the hangar config directory path, or null if HOME is unset.
pub fn configDir(buf: *[512]u8) ?[]const u8 {
    const home = appio.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar", .{home}) catch null;
}

/// Return the path to vms.json, or null if HOME is unset.
pub fn vmsPath(buf: *[512]u8) ?[]const u8 {
    const home = appio.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar/vms.json", .{home}) catch null;
}

/// Return the path to networks.json, or null if HOME is unset.
pub fn networksPath(buf: *[512]u8) ?[]const u8 {
    const home = appio.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/hangar/networks.json", .{home}) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "appstate: configDir returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (configDir(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar"));
    }
}

test "appstate: vmsPath returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (vmsPath(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar/vms.json"));
    }
}

test "appstate: networksPath returns expected suffix when HOME is set" {
    var buf: [512]u8 = undefined;
    if (networksPath(&buf)) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "/.config/hangar/networks.json"));
    }
}

test "appstate: config path helpers return null when HOME is unset" {
    // Save and clear HOME.
    const saved = appio.getenv("HOME");
    defer {
        if (saved) |v| _ = setenv("HOME", @ptrCast(v.ptr), 1) else _ = unsetenv("HOME");
    }
    _ = unsetenv("HOME");

    var buf: [512]u8 = undefined;
    try std.testing.expect(configDir(&buf) == null);
    try std.testing.expect(vmsPath(&buf) == null);
    try std.testing.expect(networksPath(&buf) == null);
}

test "appstate: getVmmHandle out-of-bounds returns null" {
    // vm_count defaults to 0, so any idx should return null.
    vm_count = 0;
    try std.testing.expect(getVmmHandle(0) == null);
    try std.testing.expect(getVmmHandle(1) == null);
    try std.testing.expect(getVmmHandle(999) == null);
}

test "appstate: destroyVmmHandle null handle no-ops" {
    // Requires g_vmm_ready to pass the assertion.
    const old_ready = g_vmm_ready;
    defer {
        g_vmm_ready = old_ready;
    }
    g_vmm_ready = true;
    // g_vmm_handles[0] is null by default — should not crash.
    destroyVmmHandle(0);
}

test "appstate: fuzz config path helpers never panic" {
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
