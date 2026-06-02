// SPDX-License-Identifier: MIT
//! QEMU hypervisor backend.
//!
//! Wraps `qemu.zig` and `qmp.zig` behind the `Vmm` interface.
//! Supports all QEMU platform accelerators: KVM (Linux), HVF (macOS),
//! WHPX (Windows), and TCG (software, all platforms).
//!
//! The accelerator is selected by `vm.VmAccel`:
//!   `.auto`  → best hardware accelerator for the platform, TCG fallback
//!   `.tcg`   → always TCG, for testing or platforms without hardware accel
//!   `.kvm` / `.hvf` / `.whpx` → specific hardware backend (TCG fallback if unavailable)

const std = @import("std");
const builtin = @import("builtin");

const vm = @import("../vm.zig");
const qemu = @import("../qemu.zig");
const qmp = @import("../qmp.zig");
const appio = @import("../appio.zig");
const hv = @import("interface.zig");

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

/// Create a QEMU-backed Vmm dispatch table (no allocation).
/// Use createHandle() separately for per-VM state.
pub fn createVmm(accel: vm.VmAccel) hv.Vmm {
    const resolved = hv.resolveAccel(accel, &isAccelAvailable);

    return hv.Vmm{
        .backend = .qemu,
        .accelerator = resolved,
        .startFn = &start,
        .shutdownFn = &shutdown,
        .resetFn = &resetVm,
        .forceStopFn = &forceStop,
        .isAliveFn = &isAlive,
        .reapFn = &reap,
        .pauseFn = &pause,
        .resumeFn = &resumeVm,
        .liveMigrateFn = &liveMigrateVmm,
        .queryMigrateStatusFn = &queryMigrateStatusVmm,
        .cancelMigrateFn = &cancelMigrateVmm,
        .getDisplayPortFn = &getDisplayPort,
        .getSerialSocketFn = &getSerialSocket,
        .createDiskFn = &createDisk,
        .resizeDiskFn = &resizeDisk,
        .createLinkedCloneFn = &createLinkedClone,
        .convertDiskFn = &convertDisk,
        .snapshotCreateFn = &snapshotCreate,
        .snapshotApplyFn = &snapshotApply,
        .snapshotDeleteFn = &snapshotDelete,
        .snapshotListFn = &snapshotList,
        .buildScriptFn = &buildScript,
        .deinitFn = &deinit,
    };
}

/// Allocate per-VM state for the QEMU backend.
pub fn createHandle(config: *vm.VmConfig, accel: vm.VmAccel, allocator: std.mem.Allocator) !hv.VmmHandle {
    const resolved = hv.resolveAccel(accel, &isAccelAvailable);

    const qv = try allocator.create(QemuVm);
    qv.* = .{
        .config = config,
        .accelerator = resolved,
        .allocator = allocator,
    };
    return @ptrCast(qv);
}

/// Create a QEMU-backed Vmm for a specific VM config (convenience — calls createVmm + createHandle).
pub fn create(config: *vm.VmConfig, accel: vm.VmAccel, allocator: std.mem.Allocator) !struct { vmm: hv.Vmm, handle: hv.VmmHandle } {
    const vmm = createVmm(accel);
    const handle = try createHandle(config, accel, allocator);
    return .{ .vmm = vmm, .handle = handle };
}

fn getQv(ctx: hv.VmmHandle) *QemuVm {
    return @ptrCast(@alignCast(ctx));
}

fn isAccelAvailable(accel: hv.Accelerator) bool {
    _ = accel;
    return switch (builtin.os.tag) {
        .linux => x: {
            std.Io.Dir.cwd().access(appio.io(), "/dev/kvm", .{}) catch break :x false;
            break :x true;
        },
        .macos => true, // HVF is built into QEMU on macOS
        .windows => true, // WHPX is a Windows feature
        else => false,
    };
}

fn start(ctx: hv.VmmHandle, cfg_opaque: *anyopaque) hv.VmmError!void {
    const qv = getQv(ctx);
    const cfg: *vm.VmConfig = @constCast(@ptrCast(@alignCast(cfg_opaque)));
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

fn resetVm(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    if (qv.config.pid == null) return;
    ensureQmp(qv) catch return error.QmpConnectFailed;
    qv.qmp_client.systemReset() catch return error.BackendError;
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
    ensureQmp(qv) catch return error.BackendError;
    qv.qmp_client.pause() catch return error.BackendError;
    qv.config.status = .paused;
}

fn resumeVm(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    ensureQmp(qv) catch return error.BackendError;
    qv.qmp_client.cont() catch return error.BackendError;
    qv.config.status = .running;
}

fn liveMigrateVmm(ctx: hv.VmmHandle, dest_uri: []const u8) hv.VmmError!void {
    const qv = getQv(ctx);
    ensureQmp(qv) catch return error.BackendError;
    qv.qmp_client.liveMigrate(dest_uri) catch return error.BackendError;
}

fn queryMigrateStatusVmm(ctx: hv.VmmHandle, out: []u8) hv.VmmError![]const u8 {
    const qv = getQv(ctx);
    ensureQmp(qv) catch return error.BackendError;
    return qv.qmp_client.queryMigrateStatus(out) catch return error.BackendError;
}

fn cancelMigrateVmm(ctx: hv.VmmHandle) hv.VmmError!void {
    const qv = getQv(ctx);
    ensureQmp(qv) catch return error.BackendError;
    qv.qmp_client.cancelMigrate() catch return error.BackendError;
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
    // Socket path is /tmp/hangar-serial-<name>.sock — computed at runtime.
    return null; // Caller should use uimath.serialSocketPath
}

fn createDisk(ctx: hv.VmmHandle, cfg_opaque: *anyopaque, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    const cfg: *const vm.VmConfig = @ptrCast(@alignCast(cfg_opaque));
    qemu.createDiskImage(cfg.getDiskPathSlice(), cfg.disk_size_gb, cfg.disk_format, alloc) catch return error.BackendError;
}

fn resizeDisk(ctx: hv.VmmHandle, disk_path: []const u8, new_size_gb: u32, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    _ = qemu.resizeDiskImage(disk_path, new_size_gb, alloc) catch return error.BackendError;
}

fn createLinkedClone(ctx: hv.VmmHandle, dest: []const u8, backing: []const u8, backing_fmt_u32: u32, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    const backing_fmt: vm.DiskFormat = @enumFromInt(@as(u8, @intCast(backing_fmt_u32)));
    qemu.createLinkedClone(dest, backing, backing_fmt, alloc) catch return error.BackendError;
}

fn convertDisk(ctx: hv.VmmHandle, src_path: []const u8, dst_path: []const u8, src_fmt_u32: u32, dst_fmt_u32: u32, alloc: std.mem.Allocator) hv.VmmError!void {
    _ = ctx;
    const src_fmt: vm.DiskFormat = @enumFromInt(@as(u8, @intCast(src_fmt_u32)));
    const dst_fmt: vm.DiskFormat = @enumFromInt(@as(u8, @intCast(dst_fmt_u32)));
    qemu.convertDiskImage(src_path, src_fmt, dst_path, dst_fmt, alloc) catch return error.BackendError;
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

fn buildScript(ctx: hv.VmmHandle, cfg_opaque: *anyopaque, alloc: std.mem.Allocator) hv.VmmError![]const u8 {
    _ = ctx;
    const cfg: *const vm.VmConfig = @ptrCast(@alignCast(cfg_opaque));
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
    try std.testing.expect(std.mem.span(accel.flag).len > 0);
    try std.testing.expect(std.mem.span(accel.name).len > 0);
}

test "tcgAccelerator is always software" {
    const accel = hv.tcgAccelerator();
    try std.testing.expect(!accel.hardware);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
    try std.testing.expectEqualStrings("TCG", std.mem.span(accel.name));
}

test "resolveAccel: auto chooses best platform accelerator" {
    const accel = hv.resolveAccel(.auto, &alwaysOk);
    try std.testing.expectEqualStrings(std.mem.span(hv.bestAccelerator().flag), std.mem.span(accel.flag));
}

test "resolveAccel: tcg is always tcg" {
    const accel = hv.resolveAccel(.tcg, &alwaysOk);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
    try std.testing.expect(!accel.hardware);
}

test "resolveAccel: specific HW falls back to TCG when unavailable" {
    const accel = hv.resolveAccel(.kvm, &alwaysNo);
    try std.testing.expectEqualStrings("tcg", std.mem.span(accel.flag));
}

test "resolveAccel: specific HW succeeds when available" {
    const accel = hv.resolveAccel(.hvf, &alwaysOk);
    try std.testing.expectEqualStrings("hvf", std.mem.span(accel.flag));
}

fn alwaysOk(_: hv.Accelerator) bool { return true; }
fn alwaysNo(_: hv.Accelerator) bool { return false; }

test "Backend enum has qemu as default" {
    try std.testing.expectEqual(hv.Backend.qemu, @as(hv.Backend, @enumFromInt(0)));
}

test "qemu_backend fuzz: createVmm with random VmAccel never panics" {
    var prng = std.Random.DefaultPrng.init(0xBACCA110);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const idx = rnd.uintLessThan(usize, vm.VmAccel.count + 3);
        const accel: vm.VmAccel = vm.VmAccel.fromIndex(idx);
        const vmm = createVmm(accel);
        // Invariants: Vmm struct is fully populated with non-null function pointers.
        try std.testing.expect(@intFromPtr(vmm.startFn) != 0);
        try std.testing.expect(@intFromPtr(vmm.shutdownFn) != 0);
        try std.testing.expect(@intFromPtr(vmm.deinitFn) != 0);
        try std.testing.expect(vmm.backend == .qemu);
    }
}

test "qemu_backend: createHandle + deinit lifecycle" {
    var cfg = vm.VmConfig{};
    cfg.setName("test-vm");
    const handle = try createHandle(&cfg, .tcg, std.testing.allocator);
    try std.testing.expect(@intFromPtr(handle) != 0);
    // deinit via the vmm table from createVmm
    const vmm = createVmm(.tcg);
    vmm.deinitFn(handle);
}

test "qemu_backend: getDisplayPort returns null when embed_display is false" {
    var cfg = vm.VmConfig{};
    cfg.setName("test-nodisplay");
    cfg.embed_display = false;
    const handle = try createHandle(&cfg, .tcg, std.testing.allocator);
    defer {
        const vmm = createVmm(.tcg);
        vmm.deinitFn(handle);
    }
    const port = getDisplayPort(handle);
    try std.testing.expect(port == null);
}

test "qemu_backend: getSerialSocket returns null when serial disabled" {
    var cfg = vm.VmConfig{};
    cfg.setName("test-noserial");
    cfg.enable_serial = false;
    const handle = try createHandle(&cfg, .tcg, std.testing.allocator);
    defer {
        const vmm = createVmm(.tcg);
        vmm.deinitFn(handle);
    }
    const sock = getSerialSocket(handle);
    try std.testing.expect(sock == null);
}
