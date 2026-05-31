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
//! The `enable_kvm` flag in VmConfig is renamed conceptually to
//! `enable_accel` — it means "use hardware acceleration if available."
//! When false, TCG (software emulation) is forced.

const std = @import("std");
const builtin = @import("builtin");

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
};

/// Which accelerator mode to use.
pub const AccelMode = enum {
    /// Use the best hardware accelerator available, fall back to TCG.
    auto,
    /// Force TCG (software emulation) regardless of platform.
    force_tcg,
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

/// The Vmm interface that every hypervisor backend must implement.
pub const Vmm = struct {
    /// Backend identifier.
    backend: Backend,

    /// The accelerator this VM instance is using.
    accelerator: Accelerator,

    /// Spawn the VM process. Non-blocking — returns immediately.
    /// The `config` pointer is an opaque VM config (VmConfig from vm.zig).
    startFn: *const fn (ctx: VmmHandle, config: *anyopaque) VmmError!void,

    /// Send graceful shutdown (ACPI power button via QMP or equivalent).
    shutdownFn: *const fn (ctx: VmmHandle) VmmError!void,

    /// Force-kill the VM process (SIGKILL or equivalent).
    forceStopFn: *const fn (ctx: VmmHandle) void,

    /// Check if the VM process is still alive. Reaps zombie if dead.
    isAliveFn: *const fn (ctx: VmmHandle) bool,

    /// Block until the VM process exits, then reap it.
    reapFn: *const fn (ctx: VmmHandle) void,

    /// Pause the VM (QMP `stop` or equivalent).
    pauseFn: *const fn (ctx: VmmHandle) VmmError!void,

    /// Resume a paused VM (QMP `cont` or equivalent).
    resumeFn: *const fn (ctx: VmmHandle) VmmError!void,

    /// Get the display port for VNC/SPICE connection, if applicable.
    getDisplayPortFn: *const fn (ctx: VmmHandle) ?u16,

    /// Get the serial socket path, if applicable.
    getSerialSocketFn: *const fn (ctx: VmmHandle) ?[]const u8,

    /// Create a disk image for this VM.
    /// The `config` pointer is an opaque VM config.
    createDiskFn: *const fn (ctx: VmmHandle, config: *anyopaque, alloc: std.mem.Allocator) VmmError!void,

    /// Resize an existing disk image.
    resizeDiskFn: *const fn (ctx: VmmHandle, disk_path: []const u8, new_size_gb: u32, alloc: std.mem.Allocator) VmmError!void,

    /// Create a linked clone disk.
    createLinkedCloneFn: *const fn (ctx: VmmHandle, dest: []const u8, backing: []const u8, backing_fmt: u32, alloc: std.mem.Allocator) VmmError!void,

    /// Snapshot operations (offline, via qemu-img or equivalent).
    snapshotCreateFn: *const fn (ctx: VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) VmmError!void,
    snapshotApplyFn: *const fn (ctx: VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) VmmError!void,
    snapshotDeleteFn: *const fn (ctx: VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) VmmError!void,
    snapshotListFn: *const fn (ctx: VmmHandle, disk_path: []const u8, out: []u8, alloc: std.mem.Allocator) VmmError!usize,

    /// Generate the command-line script for this VM.
    buildScriptFn: *const fn (ctx: VmmHandle, config: *anyopaque, alloc: std.mem.Allocator) VmmError![]const u8,

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

test "AccelMode enum values" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(AccelMode.auto));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(AccelMode.force_tcg));
}

test "Backend enum has qemu as default" {
    try std.testing.expectEqual(Backend.qemu, @as(Backend, @enumFromInt(0)));
}


