//! QEMU hypervisor backend.
//!
//! Wraps `qemu.zig` and `qmp.zig` behind the `Vmm` interface.
//! Supports all QEMU platform accelerators: KVM (Linux), HVF (macOS),
//! WHPX (Windows), and TCG (software, all platforms).
//!
//! The accelerator is selected by `AccelMode`:
//!   `.auto`  → best hardware accelerator for the platform, TCG fallback
//!   `.force_tcg` → always TCG, for testing or platforms without /dev/kvm

const std = @import("std");
const builtin = @import("builtin");

const vm = @import("vm.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const appio = @import("appio.zig");
const hv = @import("hv/interface.zig");

/// Storage for a QEMU VM instance.
pub const QemuVm = struct {
    /// The VM config (owned by the caller, referenced here).
    config: *vm.VmConfig,
    /// The QMP client for runtime control.
    qmp_client: qmp.QmpClient = .{},
    /// The accelerator in use.
    accelerator: hv.Accelerator,
    /// Allocator for temporary operations.
    allocator: std.mem.Allocator,
};

/// Which accelerator to use.
pub const AccelMode = enum {
    /// Use the best hardware accelerator available, fall back to TCG.
    auto,
    /// Force TCG (software emulation) regardless of platform.
    force_tcg,
};

/// Create a QEMU-backed Vmm for a specific VM config.
pub fn create(config: *vm.VmConfig, mode: AccelMode, allocator: std.mem.Allocator) !hv.Vmm {
    const accel = if (mode == .force_tcg) hv.tcgAccelerator() else hv.bestAccelerator();

    // Verify the accelerator is available on this platform.
    if (accel.hardware) {
        if (!isAccelAvailable(accel)) {
            // Hardware accel not available — fall back to TCG silently.
            return create(config, .force_tcg, allocator);
        }
    }

    const qv = try allocator.create(QemuVm);
    qv.* = .{
        .config = config,
        .accelerator = accel,
        .allocator = allocator,
    };

    return hv.Vmm{
        .backend = .qemu,
        .accelerator = accel,
        .startFn = &start,
        .shutdownFn = &shutdown,
        .forceStopFn = &forceStop,
        .isAliveFn = &isAlive,
        .reapFn = &reap,
        .pauseFn = &pause,
        .resumeFn = &resume,
        .getDisplayPortFn = &getDisplayPort,
        .getSerialSocketFn = &getSerialSocket,
        .createDiskFn = &createDisk,
        .resizeDiskFn = &resizeDisk,
        .createLinkedCloneFn = &createLinkedClone,
        .snapshotCreateFn = &snapshotCreate,
        .snapshotApplyFn = &snapshotApply,
        .snapshotDeleteFn = &snapshotDelete,
        .snapshotListFn = &snapshotList,
        .buildScriptFn = &buildScript,
        .deinitFn = &deinit,
    };
}

fn getQv(ctx: hv.VmmHandle) *QemuVm {
    return @ptrCast(@alignCast(ctx));
}

fn isAccelAvailable(accel: hv.Accelerator) bool {
    _ = accel;
    return switch (builtin.os.tag) {
        .linux => std.Io.Dir.cwd().access(appio.io(), "/dev/kvm", .{}) catch false,
        .macos => true, // HVF is built into QEMU on macOS
        .windows => true, // WHPX is a Windows feature
        else => false,
    };
}

fn start(ctx: hv.VmmHandle, cfg: *const vm.VmConfig) hv.VmmError!void {
    const qv = getQv(ctx);
    qemu.startVm(cfg, qv.allocator) catch return error.SpawnFailed;
}

fn shutdown(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    if (qv.config.pid == null) return;
    // Try graceful ACPI shutdown via QMP first.
    ensureQmp(qv) catch {
        // Can't connect QMP — fall back to SIGTERM.
        qemu.stopVm(qv.config);
        return;
    };
    qv.qmp_client.powerdown() catch {
        qemu.stopVm(qv.config);
    };
}

fn forceStop(ctx: hv.VmmHandle) void {
    const qv = getQv(ctx);
    qemu.forceStopVm(qv.config);
}

fn isAlive(ctx: hv.VmmHandle) bool {
    const qv = getQv(ctx);
    return qemu.isVmAlive(qv.config);
}

fn reap(ctx: hv.VmmHandle) void {
    const qv = getQv(ctx);
    qemu.reapVm(qv.config);
}

fn pause(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    try ensureQmp(qv);
    qv.qmp_client.pause() catch return error.BackendError;
    qv.config.status = .paused;
}

fn resume(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    try ensureQmp(qv);
    qv.qmp_client.cont() catch return error.BackendError;
    qv.config.status = .running;
}

fn ensureQmp(qv: *QemuVm) !void {
    if (qv.qmp_client.connected) return;
    var buf: [256]u8 = undefined;
    const path = qmp.socketPath(qv.config.getNameSlice(), &buf) orelse return error.BackendError;
    try qv.qmp_client.connect(path);
}

fn getDisplayPort(ctx: hv.VmmHandle) ?u16 {
    const qv = getQv(ctx);
    return if (qv.config.embed_display)
        if (qv.config.display == .spice) qv.config.spice_port else qv.config.vnc_port
    else
        null;
}

fn getSerialSocket(ctx: hv.VmmHandle) ?[]const u8 {
    const qv = getQv(ctx);
    if (!qv.config.enable_serial or !qv.config.hasName()) return null;
    // Socket path is /tmp/kvmgui-serial-<name>.sock — computed at runtime.
    return null; // Caller should use uimath.serialSocketPath
}

fn createDisk(ctx: hv.VmmHandle, cfg: *const vm.VmConfig, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    qemu.createDiskImage(cfg.getDiskPathSlice(), cfg.disk_size_gb, cfg.disk_format, alloc) catch return error.BackendError;
}

fn resizeDisk(disk_path: []const u8, new_size_gb: u32, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = qemu.resizeDiskImage(disk_path, new_size_gb, alloc) catch return error.BackendError;
}

fn createLinkedClone(dest: []const u8, backing: []const u8, backing_fmt: vm.DiskFormat, alloc: std.mem.Allocator) hv.VmmError!void {
    qemu.createLinkedClone(dest, backing, backing_fmt, alloc) catch return error.BackendError;
}

fn snapshotCreate(ctx: hv.VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    qemu.snapshotCreate(disk_path, name, alloc) catch return error.BackendError;
}
fn snapshotApply(ctx: hv.VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    qemu.snapshotApply(disk_path, name, alloc) catch return error.BackendError;
}
fn snapshotDelete(ctx: hv.VmmHandle, disk_path: []const u8, name: []const u8, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    qemu.snapshotDelete(disk_path, name, alloc) catch return error.BackendError;
}
fn snapshotList(ctx: hv.VmmHandle, disk_path: []const u8, out: []u8, alloc: std.mem.Allocator) hv.VmmError!usize {
    _ = ctx;
    return qemu.snapshotList(disk_path, out, alloc) catch return error.BackendError;
}

fn buildScript(ctx: hv.VmmHandle, cfg: *const vm.VmConfig, alloc: std.mem.Allocator) hv.VmmError![]const u8 {
    _ = ctx;
    return qemu.buildScriptStr(cfg, alloc) catch return error.BackendError;
}

fn deinit(ctx: hv.VmmHandle) void {
    const qv = getQv(ctx);
    qv.qmp_client.disconnect();
    qv.allocator.destroy(qv);
}

// ── Tests ───────────────────────────────────────────────────────────

test "bestAccelerator returns platform-appropriate accelerator" {
    const accel = hv.bestAccelerator();
    try std.testing.expect(accel.flag.len > 0);
    try std.testing.expect(accel.name.len > 0);
}

test "tcgAccelerator is always software" {
    const accel = hv.tcgAccelerator();
    try std.testing.expect(!accel.hardware);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
    try std.testing.expectEqualStrings("TCG", std.mem.span(accel.name));
}

test "AccelMode enum values" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(AccelMode.auto));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(AccelMode.force_tcg));
}

test "Backend enum has qemu as default" {
    try std.testing.expectEqual(hv.Backend.qemu, @as(hv.Backend, @enumFromInt(0)));
}
