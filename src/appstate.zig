// SPDX-License-Identifier: MIT
//! Shared global state for the Hangar web backend and CLI tools.
//!
//! VM arrays, session state, transition guards, and VMM handles shared by handlers.

const std = @import("std");
const vm = @import("vm.zig");
const sync = @import("sync.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");

pub const MAX_VMS = vm.MAX_VMS;

// ── VM state ────────────────────────────────────────────────────────

pub var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
pub var vm_count: usize = 0;
pub var vms_mutex: sync.SpinMutex = .{};
pub var prefs: vm.Prefs = .{};
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
/// Used to re-resolve a slot after releasing the lock for blocking I/O, the
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
/// the call and any use of the returned handle. Do not add an internal lock:
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
/// tickers. (Non-reentrant, never call while already holding a different lock
/// that the freed backend might re-acquire.)
pub fn destroyVmmHandle(idx: usize) void {
    std.debug.assert(g_vmm_ready);
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
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
    // g_vmm_handles[0] is null by default: should not crash.
    destroyVmmHandle(0);
    // A no-op on a null slot must leave the slot null (no spurious handle).
    try std.testing.expectEqual(@as(?hv_iface.VmmHandle, null), g_vmm_handles[0]);
}
