// SPDX-License-Identifier: MIT
//! Shared global state for the Hangar web backend and CLI tools.
//!
//! All VM arrays, session state, VNC/SPICE clients, and small cross-cutting
//! helpers live here so that persist, vnet, and the handler modules can share
//! them without circular imports.

const std = @import("std");
const vm = @import("vm.zig");
const sync = @import("sync.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const appio = @import("appio.zig");

pub const MAX_VMS = vm.MAX_VMS;

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

// ── Power-transition guard ──────────────────────────────────────────
// Power on/off runs its blocking fork/exec/reap WITHOUT vms_mutex held (so the
// poll/SSE/render don't spin for the ~1-2s power window). These hold the set of
// VM ids currently mid-transition so a second power op on the same VM (e.g. a
// double-click) is refused rather than spawning a duplicate QEMU. Indexed by
// id, not slot, because the array shifts on delete during the unlocked window.
// All helpers require vms_mutex.
var transition_ids: [MAX_VMS][32]u8 = undefined;
var transition_lens: [MAX_VMS]u8 = [_]u8{0} ** MAX_VMS;

/// True if `id` is already mid power-transition. Caller holds vms_mutex.
pub fn isTransitioning(id: []const u8) bool {
    for (0..MAX_VMS) |i| {
        if (transition_lens[i] != 0 and std.mem.eql(u8, transition_ids[i][0..transition_lens[i]], id)) return true;
    }
    return false;
}

/// Claim a power-transition for `id`; false if already claimed or no slot.
/// Caller holds vms_mutex.
pub fn beginTransition(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    if (isTransitioning(id)) return false;
    for (0..MAX_VMS) |i| {
        if (transition_lens[i] == 0) {
            @memcpy(transition_ids[i][0..id.len], id);
            transition_lens[i] = @intCast(id.len);
            return true;
        }
    }
    return false;
}

/// Release the power-transition claim for `id`. Caller holds vms_mutex.
pub fn endTransition(id: []const u8) void {
    for (0..MAX_VMS) |i| {
        if (transition_lens[i] != 0 and std.mem.eql(u8, transition_ids[i][0..transition_lens[i]], id)) {
            transition_lens[i] = 0;
            return;
        }
    }
}

/// Index of the VM whose stable id equals `id`, or null. Caller holds vms_mutex.
/// Used to re-resolve a slot after releasing the lock for blocking I/O — the
/// array may have shifted (delete) or the VM may be gone.
pub fn idxById(id: []const u8) ?usize {
    if (id.len == 0) return null;
    for (0..vm_count) |i| {
        if (std.mem.eql(u8, vms[i].getIdSlice(), id)) return i;
    }
    return null;
}

// ── Undo state ──────────────────────────────────────────────────────

/// Monotonic state version, bumped on every mutation (and on unexpected VM
/// exit) so the SSE /api/events stream can tell clients to refresh instantly.
pub var state_version: u64 = 1;

pub fn bumpStateVersion() void {
    _ = @atomicRmw(u64, &state_version, .Add, 1, .seq_cst);
}

pub fn getStateVersion() u64 {
    return @atomicLoad(u64, &state_version, .seq_cst);
}

pub var undo_vm: vm.VmConfig = .{};
pub var undo_idx: usize = 0;
pub var undo_available: bool = false;

// ── VMM handle helpers ──────────────────────────────────────────────

/// Get or create the Vmm handle for VM at index idx.
///
/// NOT thread-safe on its own: the `g_vmm_handles[idx]` check-then-create is a
/// data race if two threads run it concurrently (double `createHandle`, leaked
/// handle, torn slot read). The caller MUST hold `vms_mutex` for the duration of
/// the call and any use of the returned handle. Do not add an internal lock —
/// `vms_mutex` is a non-reentrant SpinMutex the callers already hold, so locking
/// here would deadlock.
pub fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], vms[idx].accel, std.heap.page_allocator) catch return null;
    }
    return g_vmm_handles[idx];
}

/// Destroy the Vmm handle for VM at index idx.
/// Requires g_vmm to be initialized (g_vmm_ready == true).
/// Caller MUST hold `vms_mutex`: it mutates the shared `g_vmm_handles` slot,
/// which is read/written concurrently by request handlers and the background
/// tickers. (Non-reentrant — never call while already holding a different lock
/// that the freed backend might re-acquire.)
pub fn destroyVmmHandle(idx: usize) void {
    std.debug.assert(g_vmm_ready);
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
}

// ── Config path helpers ────────────────────────────────────────────

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

// ── Tests ───────────────────────────────────────────────────────────

test "appstate: transition guard claim/refuse/release by id" {
    for (0..MAX_VMS) |i| transition_lens[i] = 0;
    try std.testing.expect(!isTransitioning("vm-abc"));
    try std.testing.expect(beginTransition("vm-abc"));
    try std.testing.expect(isTransitioning("vm-abc"));
    try std.testing.expect(!beginTransition("vm-abc"));
    try std.testing.expect(beginTransition("vm-def"));
    endTransition("vm-abc");
    try std.testing.expect(!isTransitioning("vm-abc"));
    try std.testing.expect(isTransitioning("vm-def"));
    endTransition("vm-def");
}

test "appstate: idxById resolves a stable id to its current slot" {
    vm_count = 2;
    vms[0] = vm.VmConfig{};
    vms[1] = vm.VmConfig{};
    vms[0].setId("id-zero");
    vms[1].setId("id-one");
    try std.testing.expectEqual(@as(?usize, 0), idxById("id-zero"));
    try std.testing.expectEqual(@as(?usize, 1), idxById("id-one"));
    try std.testing.expectEqual(@as(?usize, null), idxById("id-missing"));
    try std.testing.expectEqual(@as(?usize, null), idxById(""));
    vm_count = 0;
}

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

test "appstate: empty config-home env vars are treated as unset" {
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

test "appstate: HANGAR_CONFIG_HOME overrides HOME" {
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
    // A no-op on a null slot must leave the slot null (no spurious handle).
    try std.testing.expectEqual(@as(?hv_iface.VmmHandle, null), g_vmm_handles[0]);
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
