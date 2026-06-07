// SPDX-License-Identifier: MIT
//! Hypervisor abstraction layer.
//!
//! Each backend implements the `Vmm` interface for a specific hypervisor
//! or platform accelerator. The default backend is QEMU, which uses the
//! best available accelerator for the current platform.
//!
//! Platform accelerator selection (QEMU backend):
//!   Linux   → KVM (if /dev/kvm accessible, else TCG)
//!   macOS   → HVF (if available, else TCG)
//!   Windows → WHPX (if available, else TCG)
//!
//! Accelerator selection lives in the VmConfig `accel` field: `VmAccel.auto`
//! means "pick best available hardware accelerator," `VmAccel.tcg` forces
//! software emulation, and the single-accelerator variants (`.kvm`, `.hvf`,
//! `.whpx`) request a specific hardware backend. (Older configs used an
//! `enable_kvm` bool, still accepted on load for backward compatibility.)

const std = @import("std");
const builtin = @import("builtin");
const vm = @import("../vm.zig");

/// Opaque handle returned by `create`. The backend stores per-VM
/// state behind this pointer.
pub const VmmHandle = *anyopaque;

/// Errors that any backend can return.
pub const VmmError = error{
    /// Creating the VM process failed (fork/exec error).
    SpawnFailed,
    /// The requested accelerator is not available on this system.
    AcceleratorNotAvailable,
    /// A required binary (qemu-system-x86_64, etc.) was not found.
    BinaryNotFound,
    /// The operation timed out.
    Timeout,
    /// Generic backend failure.
    BackendError,
    /// Could not connect to the QMP control socket.
    QmpConnectFailed,
};

/// Which hypervisor backend to use.
pub const Backend = enum {
    /// QEMU with platform-optimal accelerator.
    qemu,
    // Future: libkrun, hv_framework, whpx_direct
};

/// Platform-specific accelerator info.
pub const Accelerator = struct {
    /// e.g. "kvm", "hvf", "whpx", "tcg"
    flag: [*:0]const u8,
    /// Human-readable: "KVM", "HVF", "WHPX", "TCG"
    name: [*:0]const u8,
    /// Whether this is hardware-accelerated.
    hardware: bool,
};

/// Returns the best available accelerator for this platform.
pub fn bestAccelerator() Accelerator {
    return switch (builtin.os.tag) {
        .linux => .{ .flag = "kvm", .name = "KVM", .hardware = true },
        .macos => .{ .flag = "hvf", .name = "HVF", .hardware = true },
        .windows => .{ .flag = "whpx", .name = "WHPX", .hardware = true },
        else => .{ .flag = "tcg", .name = "TCG", .hardware = false },
    };
}

/// Returns the TCG (software emulation) fallback accelerator.
pub fn tcgAccelerator() Accelerator {
    return .{ .flag = "tcg", .name = "TCG", .hardware = false };
}

/// Resolve a VmAccel enum to the actual Accelerator to use.
/// `.auto` picks the platform's best hardware accelerator,
/// falling back to TCG if unavailable. `.kvm`/`.hvf`/`.whpx`
/// select a specific hardware backend. `.tcg` is always available.
/// `checkAvail` is a caller-provided function (for /dev/kvm etc.).
pub fn resolveAccel(accel: vm.VmAccel, checkAvail: *const fn (Accelerator) bool) Accelerator {
    // Helper: try an HW accelerator; fall back to TCG if unavailable.
    const tryHw = struct {
        fn tryHw(hw: Accelerator, cb: *const fn (Accelerator) bool) Accelerator {
            if (cb(hw)) return hw;
            return tcgAccelerator();
        }
    }.tryHw;

    return switch (accel) {
        .auto => x: {
            const best = bestAccelerator();
            if (best.hardware and !checkAvail(best)) return tcgAccelerator();
            break :x best;
        },
        .tcg => tcgAccelerator(),
        .kvm => tryHw(.{ .flag = "kvm", .name = "KVM", .hardware = true }, checkAvail),
        .hvf => tryHw(.{ .flag = "hvf", .name = "HVF", .hardware = true }, checkAvail),
        .whpx => tryHw(.{ .flag = "whpx", .name = "WHPX", .hardware = true }, checkAvail),
    };
}

/// The Vmm interface a hypervisor backend implements.
///
/// Intentionally minimal: it covers only PROCESS lifecycle (spawn / force-stop /
/// liveness / reap / linked-clone / teardown), which is the part that genuinely
/// differs between backends. Guest CONTROL (pause/resume/shutdown/reset/cdrom/
/// migrate/screenshot) and offline disk ops (create/resize/convert/snapshot) are
/// driven directly from the request handlers — for QEMU via QMP over a fresh
/// connection (web_server.vmQmpByName) and via qemu-img — because routing them
/// through the dispatch added a second QEMU-specific code path with no benefit
/// while a single backend exists. When a real second backend lands, extend this
/// interface with the control/disk members it needs (history: the prior 23-member
/// table had 17 entries nothing ever dispatched).
pub const Vmm = struct {
    /// Backend identifier.
    backend: Backend,

    /// The accelerator this VM instance is using.
    accelerator: Accelerator,

    /// Spawn the VM process. Non-blocking — returns immediately.
    /// The `config` pointer is an opaque VM config (VmConfig from vm.zig).
    startFn: *const fn (ctx: VmmHandle, config: *anyopaque) VmmError!void,

    /// Force-kill the VM process (SIGKILL or equivalent).
    forceStopFn: *const fn (ctx: VmmHandle) void,

    /// Check if the VM process is still alive. Reaps zombie if dead.
    isAliveFn: *const fn (ctx: VmmHandle) bool,

    /// Block until the VM process exits, then reap it.
    reapFn: *const fn (ctx: VmmHandle) void,

    /// Create a linked clone disk (backing-file overlay).
    createLinkedCloneFn: *const fn (ctx: VmmHandle, dest: []const u8, backing: []const u8, backing_fmt: u32, alloc: std.mem.Allocator) VmmError!void,

    /// Free backend-specific resources.
    deinitFn: *const fn (ctx: VmmHandle) void,
};

// ── Tests ───────────────────────────────────────────────────────────

test "bestAccelerator returns valid strings" {
    const accel = bestAccelerator();
    try std.testing.expect(std.mem.span(accel.flag).len > 0);
    try std.testing.expect(std.mem.span(accel.name).len > 0);
}

test "tcgAccelerator is always software" {
    const accel = tcgAccelerator();
    try std.testing.expect(!accel.hardware);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
    try std.testing.expectEqualStrings("TCG", std.mem.span(accel.name));
}

test "resolveAccel: auto picks platform default" {
    const accel = resolveAccel(.auto, &alwaysOk_hv);
    try std.testing.expectEqualStrings(std.mem.span(bestAccelerator().flag), std.mem.span(accel.flag));
}

test "resolveAccel: tcg always returns tcg" {
    const accel = resolveAccel(.tcg, &alwaysOk_hv);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
    try std.testing.expect(!accel.hardware);
}

test "resolveAccel: kvm falls back to tcg when check fails" {
    const accel = resolveAccel(.kvm, &alwaysNo_hv);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
}

test "resolveAccel: whpx succeeds when check passes" {
    const accel = resolveAccel(.whpx, &alwaysOk_hv);
    try std.testing.expectEqualStrings("whpx", std.mem.span(accel.flag));
    try std.testing.expect(accel.hardware);
}

fn alwaysOk_hv(_: Accelerator) bool {
    return true;
}
fn alwaysNo_hv(_: Accelerator) bool {
    return false;
}

test "Backend enum has qemu as default" {
    try std.testing.expectEqual(Backend.qemu, @as(Backend, @enumFromInt(0)));
}

test "hv fuzz: resolveAccel with random VmAccel values never panics" {
    var prng = std.Random.DefaultPrng.init(0xACCE1101);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const idx = rnd.uintLessThan(usize, vm.VmAccel.count + 3);
        const accel: vm.VmAccel = vm.VmAccel.fromIndex(idx);
        // Random check function: either always pass or always fail.
        const check: *const fn (Accelerator) bool = if (rnd.boolean()) &alwaysOk_hv else &alwaysNo_hv;
        const result = resolveAccel(accel, check);
        // Invariants: result always has non-empty flag and name.
        try std.testing.expect(std.mem.span(result.flag).len > 0);
        try std.testing.expect(std.mem.span(result.name).len > 0);
        // tcg is always software.
        if (std.mem.eql(u8, std.mem.span(result.flag), "tcg")) {
            try std.testing.expect(!result.hardware);
        }
    }
}

test "hv fuzz: bestAccelerator and tcgAccelerator consistency" {
    const best = bestAccelerator();
    const tcg = tcgAccelerator();
    // Both must have valid strings.
    try std.testing.expect(std.mem.span(best.flag).len > 0);
    try std.testing.expect(std.mem.span(tcg.flag).len > 0);
    // tcg is never hardware-accelerated.
    try std.testing.expect(!tcg.hardware);
    // Self-consistency: resolveAccel(.tcg, alwaysOk) == tcg.
    const resolved = resolveAccel(.tcg, &alwaysOk_hv);
    try std.testing.expectEqualStrings(std.mem.span(tcg.flag), std.mem.span(resolved.flag));
}
