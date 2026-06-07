// SPDX-License-Identifier: MIT
//! QEMU process management.
//!
//! Provides functions to build the QEMU command line from a `VmConfig`,
//! spawn/stop/force-stop the QEMU process, check liveness via `waitpid`
//! (preventing zombie accumulation), and create disk images via `qemu-img`.
//!
//! Process lifecycle:
//!   1. `startVm`      — spawn QEMU, store PID, mark running
//!   2. `stopVm`       — send SIGTERM (does NOT update state)
//!   3. `forceStopVm`  — send SIGKILL (does NOT update state)
//!   4. `isVmAlive`    — non-blocking `waitpid`; reaps zombie + updates state
//!   5. `reapVm`       — blocking `waitpid`; for synchronous cleanup (e.g. delete)
//!
//! All buffer-formatted arguments are kept in function-scoped storage so
//! that their slices remain valid through the `forkExec` call.

const std = @import("std");
const vm = @import("vm.zig");
const appio = @import("appio.zig");
const sync = @import("sync.zig");

/// libc PATH-searching exec. `std.process` in 0.16 routes spawning through the
/// `std.Io` interface, which would hand the child an empty environment unless
/// we capture and forward the parent environ. A direct `fork`+`execvp` instead
/// inherits the full parent environment (DISPLAY, XDG_RUNTIME_DIR, HOME — all
/// required by QEMU's GTK display) and resolves the binary via PATH for free.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Errors that can occur during QEMU operations.
pub const QemuError = error{
    /// The spawned `qemu-img` process exited with a non-zero status.
    DiskImageCreationFailed,

    /// UEFI firmware was requested but no OVMF image was found on this system.
    OvmfNotFound,

    /// `fork` failed when spawning a child process.
    ForkFailed,

    /// A spawned process exited with a non-zero status.
    ProcessFailed,
};

/// True if a raw `waitpid` status reflects a clean exit: not terminated by a
/// signal (low 7 bits clear) and exit code 0 (next 8 bits clear).
fn exitedClean(status: c_int) bool {
    const u: u32 = @bitCast(status);
    return (u & 0x7f) == 0 and (u >> 8) & 0xff == 0;
}

/// Build a null-terminated C `argv` array from a Zig slice.
fn buildCArgv(argv: []const []const u8, arena: std.mem.Allocator) ![:null]?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| out[i] = (try arena.dupeZ(u8, a)).ptr;
    return out;
}

/// Run `argv` to completion, returning an error unless it exits with 0.
/// If `err_path` is non-null, stderr is redirected to that file.
pub fn runWait(argv: []const []const u8, allocator: std.mem.Allocator, err_path: ?[:0]const u8) !void {
    const pid = try forkExec(argv, allocator, err_path);
    var status: c_int = 0;
    // Retry on EINTR; a failed wait must not be reported as success (status
    // would stay 0 → caller believes the op succeeded when it did not).
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return QemuError.ProcessFailed;
        }
        break;
    }
    if (!exitedClean(status)) return QemuError.ProcessFailed;
}

/// Run `argv`, capturing its stdout into `out`. Returns the number of bytes
/// written (truncated to `out.len`). Returns an error unless it exits 0.
/// stdin/stderr are sent to /dev/null.
pub fn runCapture(argv: []const []const u8, out: []u8, allocator: std.mem.Allocator) !usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const c_argv = try buildCArgv(argv, arena_state.allocator());

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return QemuError.ProcessFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return QemuError.ForkFailed;
    }
    if (pid == 0) {
        // Child: stdout → pipe write end; stdin/stderr → /dev/null.
        _ = std.c.close(read_fd);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 2);
        }
        _ = std.c.dup2(write_fd, 1);
        _ = execvp(c_argv[0].?, c_argv.ptr);
        std.c._exit(127);
    }

    // Parent: read all stdout until EOF.
    _ = std.c.close(write_fd);
    var total: usize = 0;
    while (total < out.len) {
        const n = std.c.read(read_fd, out[total..].ptr, out.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = std.c.close(read_fd);

    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return QemuError.ProcessFailed;
        }
        break;
    }
    if (!exitedClean(status)) return QemuError.ProcessFailed;
    return total;
}

/// Offline snapshot operations via `qemu-img snapshot` on the primary disk.
/// Used when the VM is powered off (QMP savevm/loadvm need a running QEMU).
pub fn snapshotCreate(disk_path: []const u8, name: []const u8, allocator: std.mem.Allocator) !void {
    try runWait(&.{ "qemu-img", "snapshot", "-c", name, disk_path }, allocator, null);
}
pub fn snapshotApply(disk_path: []const u8, name: []const u8, allocator: std.mem.Allocator) !void {
    try runWait(&.{ "qemu-img", "snapshot", "-a", name, disk_path }, allocator, null);
}
pub fn snapshotDelete(disk_path: []const u8, name: []const u8, allocator: std.mem.Allocator) !void {
    try runWait(&.{ "qemu-img", "snapshot", "-d", name, disk_path }, allocator, null);
}
pub fn snapshotList(disk_path: []const u8, out: []u8, allocator: std.mem.Allocator) !usize {
    return runCapture(&.{ "qemu-img", "snapshot", "-l", disk_path }, out, allocator);
}

/// Fork and exec `argv`, redirecting stdin/stdout to /dev/null.
/// If `err_path` is non-null, stderr is redirected to that file
/// (created/truncated); otherwise it also goes to /dev/null.
/// Returns the child PID. The child resolves `argv[0]` via PATH
/// and inherits our environment.
fn forkExec(argv: []const []const u8, allocator: std.mem.Allocator, err_path: ?[:0]const u8) !std.c.pid_t {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const c_argv = try buildCArgv(argv, arena_state.allocator());

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: only async-signal-safe calls until exec.
        // Tighten the umask before exec so files QEMU/qemu-img create are
        // owner-only regardless of the operator's umask: the serial and QMP
        // control sockets (other local users could otherwise connect to the
        // live guest console or drive the VM) and qemu-img disk images (guest
        // data at rest). umask() is async-signal-safe.
        _ = std.c.umask(0o077);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
        }
        if (err_path) |path| {
            // 0o600: the VM stderr log lands in shared /var/tmp and can contain
            // disk paths, MAC/network config, and guest console output. Owner-only
            // perms keep other local users from reading it (matches the 0o600 used
            // for sockets in transport.zig).
            const errfd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            if (errfd >= 0) {
                _ = std.c.dup2(errfd, 2);
                _ = std.c.close(errfd);
            } else if (devnull >= 0) {
                _ = std.c.dup2(devnull, 2);
            }
        } else if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2);
        }
        _ = execvp(c_argv[0].?, c_argv.ptr);
        std.c._exit(127);
    }
    return pid;
}

/// Well-known OVMF firmware image paths (searched in order).
/// Different Linux distributions install OVMF in different locations;
/// we probe each path at runtime because there is no standard.
const ovmf_search_paths = [_][]const u8{
    "/usr/share/edk2/x64/OVMF.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2-ovmf/x64/OVMF.4m.fd",
    "/usr/share/qemu/OVMF.fd",
};

/// Locate an OVMF firmware image on this system.
///
/// Returns the first path that exists, or `null` if none was found.
fn findOvmfPath() ?[]const u8 {
    for (ovmf_search_paths) |path| {
        if (std.Io.Dir.cwd().access(appio.io(), path, .{})) {
            return path;
        } else |_| {}
    }
    return null;
}

/// Well-known locations for the virtio-win guest tools ISO (distro packages
/// install it under /usr/share/virtio-win; users often download it too).
const virtio_win_search_paths = [_][]const u8{
    "/usr/share/virtio-win/virtio-win.iso",
    "/usr/share/virtio-win/virtio-win.iso.latest",
    "/var/lib/libvirt/images/virtio-win.iso",
};

/// Locate the virtio-win ISO, also checking `$HOME/Downloads`.
/// Copies the result into `dest` and returns a slice of `dest`, or `null`.
/// Thread-safe: each caller provides its own buffer.
fn findVirtioWinIsoInto(dest: []u8) ?[]const u8 {
    for (virtio_win_search_paths) |path| {
        if (std.Io.Dir.cwd().access(appio.io(), path, .{})) {
            const len = @min(dest.len, path.len);
            @memcpy(dest[0..len], path[0..len]);
            return dest[0..len];
        } else |_| {}
    }
    // Static buffer for the $HOME/Downloads path — guarded by SpinMutex
    // because buildArgs can be called from concurrent web_server handlers.
    {
        _ = virtio_mutex.lock();
        defer virtio_mutex.unlock();
        if (appio.getenv("HOME")) |home| {
            const p = std.fmt.bufPrint(&virtio_buf, "{s}/Downloads/virtio-win.iso", .{home}) catch return null;
            if (std.Io.Dir.cwd().access(appio.io(), p, .{})) {
                const len = @min(dest.len, p.len);
                @memcpy(dest[0..len], p[0..len]);
                return dest[0..len];
            } else |_| {}
        }
    }
    return null;
}

var virtio_buf: [vm.MAX_PATH + 1]u8 = undefined;
var virtio_mutex: sync.SpinMutex = .{};

/// QEMU-side socket expected from a separately running gvproxy daemon:
/// `gvproxy -listen-qemu unix:///tmp/hangar-gvproxy-qemu.sock ...`.
/// QEMU 7.2+ can connect to it directly with the stream netdev backend.
const gvproxy_qemu_socket = "/tmp/hangar-gvproxy-qemu.sock";

/// Formatting buffers for QEMU arguments.
///
/// These must outlive the `forkExec` call: `buildArgs` stores slices into
/// these buffers, so if they were stack-local inside `buildArgs` they'd be
/// freed before the argv is handed to `execvp`.
const ArgBuffers = struct {
    mach_buf: [64]u8 = undefined,
    smp_buf: [32]u8 = undefined,
    mem_buf: [32]u8 = undefined,
    disk_buf: [vm.MAX_PATH + 192]u8 = undefined,
    cdrom_buf: [vm.MAX_PATH + 64]u8 = undefined,
    tools_buf: [vm.MAX_PATH + 64]u8 = undefined,
    tools_iso_buf: [vm.MAX_PATH]u8 = undefined,
    vnc_buf: [64]u8 = undefined,
    spice_buf: [128]u8 = undefined,
    serial_buf: [vm.MAX_PATH + 64]u8 = undefined,
    ga_buf: [vm.MAX_PATH + 64]u8 = undefined,
    qmp_buf: [vm.MAX_PATH + 64]u8 = undefined,
    vga_buf: [64]u8 = undefined,
    net_mac_buf: [128]u8 = undefined,
    // Sized for the worst case: port_forwards is capped at 511 bytes (see
    // VmConfig.setPortForwards). Each "h:g" pair expands to ",hostfwd=tcp::h-:g"
    // (16 literal bytes added per pair), so a buffer full of minimal "1:1," pairs
    // grows to ~2.3 KB. 4096 covers any valid input without silently dropping
    // forwards via the `catch break` in the builder below.
    netdev_user_buf: [4096]u8 = undefined,
    boot_buf: [64]u8 = undefined,
    incoming_buf: [vm.MAX_PATH + 64]u8 = undefined,
    shared_buf: [vm.MAX_PATH + 128]u8 = undefined,
    disk2_buf: [vm.MAX_PATH + 64]u8 = undefined,
    extra_disk_bufs: [vm.MAX_EXTRA_DISKS][vm.MAX_PATH + 64]u8 = [_][vm.MAX_PATH + 64]u8{[_]u8{0} ** (vm.MAX_PATH + 64)} ** vm.MAX_EXTRA_DISKS,
    usb_buf: [128]u8 = undefined,
    nic_dev_buf: [vm.MAX_NICS][192]u8 = [_][192]u8{[_]u8{0} ** 192} ** vm.MAX_NICS,
    floppy_buf: [vm.MAX_PATH + 64]u8 = undefined,
    disp_buf: [32]u8 = undefined,
    watchdog_buf: [32]u8 = undefined,
};

/// Append an additional network adapter ("netN") for `mode`. `.none` is a
/// no-op (adapter absent). Extra adapters don't carry port forwards.
fn appendExtraNic(
    args: *std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    dev_buf: []u8,
    id: []const u8,
    mode: vm.NetworkMode,
    mac: []const u8,
) !void {
    if (mode == .none) return;
    try args.append(alloc, "-device");
    // On a formatting failure the device would lose its `netdev={id}` binding
    // (or the netdev would carry the wrong id), producing a silently-broken or
    // duplicate-id adapter. Propagate the error instead of emitting a bad arg.
    // Only embed a caller-supplied MAC if it is well-formed: an unvalidated
    // value containing a comma would inject extra `-device` properties
    // (argument injection, CWE-88). An invalid MAC falls through to the
    // auto-assigned form rather than poisoning the device string.
    if (mac.len > 0 and vm.isValidMac(mac)) {
        const dev = try std.fmt.bufPrint(dev_buf, "virtio-net-pci,netdev={s},mac={s}", .{ id, mac });
        try args.append(alloc, dev);
    } else {
        const dev = try std.fmt.bufPrint(dev_buf, "virtio-net-pci,netdev={s}", .{id});
        try args.append(alloc, dev);
    }
    try args.append(alloc, "-netdev");
    switch (mode) {
        .user => {
            const nd = try std.fmt.bufPrint(dev_buf[64..], "user,id={s}", .{id});
            try args.append(alloc, nd);
        },
        .bridge => {
            const nd = try std.fmt.bufPrint(dev_buf[64..], "bridge,id={s},br=br0", .{id});
            try args.append(alloc, nd);
        },
        .gvproxy => {
            const nd = try std.fmt.bufPrint(dev_buf[64..], "stream,id={s},addr.type=unix,addr.path={s}", .{ id, gvproxy_qemu_socket });
            try args.append(alloc, nd);
        },
        .none => unreachable, // filtered at function entry above
    }
}

/// Populates an ArrayList with QEMU arguments.
fn buildArgs(config: *const vm.VmConfig, args: *std.ArrayList([]const u8), alloc: std.mem.Allocator, bufs: *ArgBuffers) !void {
    try args.append(alloc, "qemu-system-x86_64");

    // The VM name is interpolated into the comma-separated chardev property lists
    // for -serial / -qmp / -chardev (and their socket paths). A name containing a
    // comma or slash would inject extra QEMU properties or escape the socket
    // directory — and names loaded from vms.json or the remote daemon bypass the
    // web layer's isValidVmName check. Reject an unsafe name at the sink (same
    // posture as the disk-path guards below) so a hostile config cannot produce a
    // dangerous launch.
    if (config.hasName() and !vm.isValidVmName(config.getNameSlice())) return error.UnsafeVmName;

    const accel_flag = config.accel.toStr();
    try args.append(alloc, "-machine");
    const mach_str = if (config.secure_boot)
        try std.fmt.bufPrint(&bufs.mach_buf, "type=q35,smm=on,accel={s}", .{std.mem.span(accel_flag)})
    else
        try std.fmt.bufPrint(&bufs.mach_buf, "type=q35,accel={s}", .{std.mem.span(accel_flag)});
    try args.append(alloc, mach_str);
    try args.append(alloc, "-cpu");
    if (config.hyperv_enlightenments) {
        try args.append(alloc, "host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_reset,hv_frequencies,hv_tlbflush,hv_reenlightenment,hv_ipi");
    } else {
        const cpu_str = config.cpu_model.toStr();
        try args.append(alloc, std.mem.span(cpu_str));
    }

    // QEMU rejects -smp 0 and -m 0; clamp to a sane range. The upper bound also
    // prevents `sockets * cores` from overflowing u32 when the UI passes huge
    // values (found by fuzzing).
    const effective_cores = std.math.clamp(config.cpu_cores, 1, 1024);
    const effective_sockets = std.math.clamp(config.cpu_sockets, 1, 1024);
    const effective_mem = if (config.memory_mb == 0) 64 else config.memory_mb;

    // -smp total,sockets=S,cores=C — QEMU derives topology; total = S*C.
    const smp_str = try std.fmt.bufPrint(&bufs.smp_buf, "{d},sockets={d},cores={d}", .{ effective_sockets * effective_cores, effective_sockets, effective_cores });
    try args.append(alloc, "-smp");
    try args.append(alloc, smp_str);

    const mem_str = try std.fmt.bufPrint(&bufs.mem_buf, "{d}", .{effective_mem});
    try args.append(alloc, "-m");
    try args.append(alloc, mem_str);

    if (config.hasDisk()) {
        // The disk path is interpolated into a comma-separated -drive property
        // list, so a comma (or NUL/newline) in it would inject extra drive
        // options (argument injection, CWE-88) — reject such paths, matching the
        // floppy/ISO/shared-folder guards below.
        if (!isSafeQemuPropValue(config.getDiskPathSlice())) return error.UnsafeDiskPath;
        // Throttle options are part of the SAME -drive that defines the disk —
        // a standalone `-drive throttling.*` with no file= makes QEMU reject
        // the command line ("Device needs media, but drive is empty").
        // With io_threads, use the split blockdev form so the disk can bind to
        // the iothread object (an `if=virtio` drive has no way to take iothread=,
        // leaving the iothread idle). Otherwise keep the simple implicit-device
        // `if=virtio` form.
        const use_iothread = config.io_threads > 0;
        const base = if (use_iothread)
            try std.fmt.bufPrint(&bufs.disk_buf, "file={s},format={s},if=none,id=hdd0,cache={s}", .{
                config.getDiskPathSlice(),
                std.mem.span(config.disk_format.toStr()),
                std.mem.span(config.disk_cache.toStr()),
            })
        else
            try std.fmt.bufPrint(&bufs.disk_buf, "file={s},format={s},if=virtio,cache={s}", .{
                config.getDiskPathSlice(),
                std.mem.span(config.disk_format.toStr()),
                std.mem.span(config.disk_cache.toStr()),
            });
        var dpos: usize = base.len;
        if (config.disk_bps_throttle > 0) {
            const chunk = try std.fmt.bufPrint(bufs.disk_buf[dpos..], ",throttling.bps-total={d}", .{config.disk_bps_throttle});
            dpos += chunk.len;
        }
        if (config.disk_iops_throttle > 0) {
            const chunk = try std.fmt.bufPrint(bufs.disk_buf[dpos..], ",throttling.iops-total={d}", .{config.disk_iops_throttle});
            dpos += chunk.len;
        }
        try args.append(alloc, "-drive");
        try args.append(alloc, bufs.disk_buf[0..dpos]);
        if (use_iothread) {
            try args.append(alloc, "-device");
            try args.append(alloc, "virtio-blk-pci,drive=hdd0,iothread=iothread0");
        }
    }

    // Optional second (data) disk, attached as another virtio drive.
    if (config.hasDisk2()) {
        // Same argument-injection guard as the primary disk: the disk2 path is
        // attacker-influenced (e.g. the uploaded filename via /upload-disk).
        if (!isSafeQemuPropValue(config.getDisk2PathSlice())) return error.UnsafeDiskPath;
        const disk2_str = try std.fmt.bufPrint(&bufs.disk2_buf, "file={s},format={s},if=virtio,cache={s}", .{
            config.getDisk2PathSlice(),
            std.mem.span(config.disk2_format.toStr()),
            std.mem.span(config.disk_cache.toStr()),
        });
        try args.append(alloc, "-drive");
        try args.append(alloc, disk2_str);
    }

    // Extra disks (up to MAX_EXTRA_DISKS), attached as additional virtio drives.
    for (&bufs.extra_disk_bufs, config.extra_disks, 0..) |*ed_buf, ed, i| {
        if (config.hasExtraDisk(i)) {
            if (!isSafeQemuPropValue(config.getExtraDiskPathSlice(i))) return error.UnsafeDiskPath;
            const ed_str = try std.fmt.bufPrint(ed_buf, "file={s},format={s},if=virtio,cache={s}", .{
                config.getExtraDiskPathSlice(i),
                std.mem.span(ed.format.toStr()),
                std.mem.span(config.disk_cache.toStr()),
            });
            try args.append(alloc, "-drive");
            try args.append(alloc, ed_str);
        }
    }

    // Optional floppy drive (drive A:), raw image. The path is interpolated into
    // a comma-separated `-drive` property list, so a comma (or NUL/newline) in it
    // would inject extra drive options (argument injection, CWE-88); reject such
    // paths rather than emit them.
    if (config.hasFloppy() and isSafeQemuPropValue(config.getFloppyPathSlice())) {
        const fd_str = try std.fmt.bufPrint(&bufs.floppy_buf, "file={s},if=floppy,format=raw", .{config.getFloppyPathSlice()});
        try args.append(alloc, "-drive");
        try args.append(alloc, fd_str);
    }

    // Use an explicit ide-cd device with a stable id ("ide2-cd0") so that
    // QMP `change ide2-cd0` can hot-swap the ISO without rebooting. As with the
    // floppy, an ISO path carrying a comma could inject `-drive` options (e.g.
    // flipping `readonly=on`), so an unsafe path is treated as "no ISO" — the
    // empty drive is still emitted so the ide-cd device has a backing slot.
    try args.append(alloc, "-device");
    try args.append(alloc, "ide-cd,drive=cdrom0,id=ide2-cd0");
    if (config.hasIso() and isSafeQemuPropValue(config.getIsoPathSlice())) {
        const cdrom_str = try std.fmt.bufPrint(&bufs.cdrom_buf, "file={s},if=none,id=cdrom0,media=cdrom,readonly=on", .{config.getIsoPathSlice()});
        try args.append(alloc, "-drive");
        try args.append(alloc, cdrom_str);
    } else {
        try args.append(alloc, "-drive");
        try args.append(alloc, "if=none,id=cdrom0,media=cdrom,readonly=on");
    }

    // Auto-mount the virtio-win guest tools ISO as a second CD (ide2-cd1) so
    // Windows guests can install virtio drivers + qemu-guest-agent.
    if (config.guest_tools) {
        if (findVirtioWinIsoInto(&bufs.tools_iso_buf)) |iso| {
            try args.append(alloc, "-device");
            try args.append(alloc, "ide-cd,drive=tools0,id=ide2-cd1");
            const tools_str = try std.fmt.bufPrint(&bufs.tools_buf, "file={s},if=none,id=tools0,media=cdrom,readonly=on", .{iso});
            try args.append(alloc, "-drive");
            try args.append(alloc, tools_str);
        }
    }

    try args.append(alloc, "-boot");
    const boot_str = try std.fmt.bufPrint(&bufs.boot_buf, "order={s},menu=on", .{std.mem.span(config.boot_order.toStr())});
    try args.append(alloc, boot_str);

    const wants_virgl = config.enable_3d and config.gpu_device.needsVirgl();
    const embedded_spice_gl = config.embed_display and config.display == .spice and wants_virgl;

    if (config.embed_display) {
        // When embedding the display inside our app, QEMU must not open
        // its own window. For virgl-over-SPICE we still need a GL-capable
        // headless display backend, otherwise QEMU rejects virtio-*-gl.
        try args.append(alloc, "-display");
        try args.append(alloc, if (embedded_spice_gl) "egl-headless,gl=on" else "none");
        if (config.display == .spice) {
            const spice_str = if (embedded_spice_gl)
                try std.fmt.bufPrint(&bufs.spice_buf, "port={d},disable-ticketing=on,gl=on", .{config.spice_port})
            else
                try std.fmt.bufPrint(&bufs.spice_buf, "port={d},disable-ticketing=on", .{config.spice_port});
            try args.append(alloc, "-spice");
            try args.append(alloc, spice_str);
        } else {
            const vnc_str = try std.fmt.bufPrint(&bufs.vnc_buf, "localhost:{d}", .{vncDisplayNum(config.vnc_port)});
            try args.append(alloc, "-vnc");
            try args.append(alloc, vnc_str);
        }
    } else if (config.display == .vnc) {
        // QEMU has no "vnc" backend for `-display`; VNC is configured via
        // `-vnc`. Emitting `-display vnc` makes QEMU reject the command line
        // ("Display 'vnc' is not available"), so route it like the embedded
        // VNC path: headless display plus a `-vnc` listener.
        const vnc_str = try std.fmt.bufPrint(&bufs.vnc_buf, "localhost:{d}", .{vncDisplayNum(config.vnc_port)});
        try args.append(alloc, "-display");
        try args.append(alloc, "none");
        try args.append(alloc, "-vnc");
        try args.append(alloc, vnc_str);
    } else {
        try args.append(alloc, "-display");
        // 3D acceleration (virgl) needs a GL-capable native display.
        if (config.enable_3d and (config.display == .gtk or config.display == .sdl or config.display == .spice)) {
            const disp_str = try std.fmt.bufPrint(&bufs.disp_buf, "{s},gl=on", .{std.mem.span(config.display.toStr())});
            try args.append(alloc, disp_str);
        } else {
            try args.append(alloc, std.mem.span(config.display.toStr()));
        }
    }

    // GPU device selection.
    const gl_ok = wants_virgl and ((config.embed_display and embedded_spice_gl) or (!config.embed_display and (config.display == .gtk or config.display == .sdl or config.display == .spice)));
    // gl_ok already implies wants_virgl, which includes gpu_device.needsVirgl().
    if (gl_ok) {
        // virgl 3D-accelerated variants: virtio-gpu-gl or virtio-vga-gl
        const dev_str: []const u8 = switch (config.gpu_device) {
            .virtio_gpu_gl => "virtio-gpu-gl",
            .virtio_vga_gl => "virtio-vga-gl",
            else => unreachable,
        };
        if (config.display_resolution == .auto) {
            try args.append(alloc, "-device");
            try args.append(alloc, dev_str);
        } else {
            const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "{s},xres={d},yres={d}", .{ dev_str, config.display_resolution.xres(), config.display_resolution.yres() });
            try args.append(alloc, "-device");
            try args.append(alloc, vga_str);
        }
    } else switch (config.gpu_device) {
        .virtio_gpu, .virtio_gpu_gl => {
            if (config.display_resolution == .auto) {
                try args.append(alloc, "-device");
                try args.append(alloc, "virtio-gpu");
            } else {
                const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "virtio-gpu,xres={d},yres={d}", .{ config.display_resolution.xres(), config.display_resolution.yres() });
                try args.append(alloc, "-device");
                try args.append(alloc, vga_str);
            }
        },
        .virtio_vga, .virtio_vga_gl => {
            if (config.display_resolution == .auto) {
                try args.append(alloc, "-vga");
                try args.append(alloc, "virtio");
            } else {
                const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "virtio-vga,xres={d},yres={d}", .{ config.display_resolution.xres(), config.display_resolution.yres() });
                try args.append(alloc, "-device");
                try args.append(alloc, vga_str);
            }
        },
        .qxl => {
            try args.append(alloc, "-device");
            try args.append(alloc, "qxl");
        },
        .std_vga => {
            try args.append(alloc, "-vga");
            try args.append(alloc, "std");
        },
    }

    // Additional displays for multi-monitor support.  Clamp here so a value
    // loaded from a hand-edited vms.json cannot explode the device list.
    const display_count = std.math.clamp(config.num_displays, 1, vm.MAX_DISPLAYS);
    var disp_n: u32 = 1;
    while (disp_n < display_count) : (disp_n += 1) {
        try args.append(alloc, "-device");
        try args.append(alloc, "virtio-gpu");
    }

    if (config.enable_serial and config.hasName()) {
        const serial_str = try std.fmt.bufPrint(&bufs.serial_buf, "unix:/tmp/hangar-serial-{s}.sock,server=on,wait=off", .{config.getNameSlice()});
        try args.append(alloc, "-serial");
        try args.append(alloc, serial_str);
    }

    if (config.virtio_rng) {
        try args.append(alloc, "-object");
        try args.append(alloc, "rng-random,filename=/dev/urandom,id=rng0");
        try args.append(alloc, "-device");
        try args.append(alloc, "virtio-rng-pci,rng=rng0");
    }

    if (config.guest_agent and config.hasName()) {
        try args.append(alloc, "-chardev");
        const ga_str = try std.fmt.bufPrint(&bufs.ga_buf, "socket,path=/tmp/hangar-ga-{s}.sock,server=on,wait=off,id=ga0", .{config.getNameSlice()});
        try args.append(alloc, ga_str);
        try args.append(alloc, "-device");
        try args.append(alloc, "virtserialport,chardev=ga0,name=org.qemu.guest_agent.0");
    }

    if (config.watchdog != .none) {
        // Modern QEMU (the legacy `-watchdog`/`-watchdog-action` were removed):
        // `-device i6300esb -action watchdog=<action>`.
        try args.append(alloc, "-device");
        try args.append(alloc, "i6300esb,id=watchdog0");
        try args.append(alloc, "-action");
        const wd_str = try std.fmt.bufPrint(&bufs.watchdog_buf, "watchdog={s}", .{std.mem.span(config.watchdog.toStr())});
        try args.append(alloc, wd_str);
    }

    // TPM: intentionally NOT emitted. The QEMU `emulator` tpmdev backend requires
    // a chardev wired to a running swtpm process (`-chardev socket,id=chrtpm,
    // path=<sock> -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,
    // tpmdev=tpm0`). Emitting the tpmdev without that chardev makes QEMU reject
    // the command line, so a TPM-enabled VM would not boot at all. Until swtpm is
    // wired in (spawn `swtpm socket --tpm2 --ctrl ... --daemon --terminate` per
    // VM before launch, gated on swtpm being installed), skip TPM so the VM boots.
    // config.tpm is still persisted/round-tripped; it's just inert here.
    // (Was: a bare `-tpmdev emulator,...` that left the VM unbootable.)

    // Secure Boot needs no extra args here: SMM is already enabled via
    // -machine q35,smm=on and the Bios/UEFI firmware selection handles pflash.

    if (config.hugepages) {
        try args.append(alloc, "-mem-prealloc");
        try args.append(alloc, "-mem-path");
        try args.append(alloc, "/dev/hugepages");
    }

    if (config.io_threads > 0) {
        try args.append(alloc, "-object");
        try args.append(alloc, "iothread,id=iothread0");
    }

    if (config.ballooning) {
        try args.append(alloc, "-balloon");
        try args.append(alloc, "virtio");
    }

    if (config.hasName()) {
        const qmp_str = try std.fmt.bufPrint(&bufs.qmp_buf, "unix:/tmp/hangar-qmp-{s}.sock,server=on,wait=off", .{config.getNameSlice()});
        try args.append(alloc, "-qmp");
        try args.append(alloc, qmp_str);
    }

    // The net0 `-device` line is identical for user and bridge modes; only the
    // `-netdev` value that follows differs. Emit the shared part once here.
    if (config.nics[0].mode != .none) {
        try args.append(alloc, "-device");
        if (config.hasMacAddress() and vm.isValidMac(config.getMacAddressSlice())) {
            const mac_str = std.fmt.bufPrint(&bufs.net_mac_buf, "virtio-net-pci,netdev=net0,mac={s}", .{config.getMacAddressSlice()}) catch "virtio-net-pci,netdev=net0";
            try args.append(alloc, mac_str);
        } else {
            try args.append(alloc, "virtio-net-pci,netdev=net0");
        }
        try args.append(alloc, "-netdev");
    }

    switch (config.nics[0].mode) {
        .user => {
            if (config.hasPortForwards()) {
                var fwd_str: []u8 = &bufs.netdev_user_buf;
                var offset: usize = 0;
                const base = "user,id=net0";
                @memcpy(fwd_str[0..base.len], base);
                offset += base.len;
                var iter = std.mem.splitScalar(u8, config.getPortForwardsSlice(), ',');
                while (iter.next()) |pair| {
                    const trimmed = std.mem.trim(u8, pair, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    var parts = std.mem.splitScalar(u8, trimmed, ':');
                    const host = parts.next() orelse continue;
                    const guest = parts.next() orelse continue;
                    // Only emit forwards whose host and guest are bare port
                    // numbers; anything else is dropped rather than passed into
                    // the netdev property list (see isDecimalPort).
                    if (!isDecimalPort(host) or !isDecimalPort(guest)) continue;
                    const chunk = std.fmt.bufPrint(fwd_str[offset..], ",hostfwd=tcp::{s}-:{s}", .{ host, guest }) catch break;
                    offset += chunk.len;
                }
                try args.append(alloc, fwd_str[0..offset]);
            } else {
                try args.append(alloc, "user,id=net0");
            }
        },
        .bridge => {
            try args.append(alloc, "bridge,id=net0,br=br0");
        },
        .gvproxy => {
            const nd = try std.fmt.bufPrint(&bufs.netdev_user_buf, "stream,id=net0,addr.type=unix,addr.path={s}", .{gvproxy_qemu_socket});
            try args.append(alloc, nd);
        },
        .none => {},
    }

    // Additional network adapters (VMware-style multi-NIC).
    for (config.nics[1..], 1..) |nic, i| {
        var id_buf: [8]u8 = undefined;
        const net_id = std.fmt.bufPrintZ(&id_buf, "net{d}", .{i}) catch continue;
        try appendExtraNic(args, alloc, &bufs.nic_dev_buf[i], net_id, nic.mode, nic.mac_buf[0..nic.mac_len]);
    }

    if (config.firmware == .uefi) {
        const ovmf = findOvmfPath() orelse return QemuError.OvmfNotFound;
        try args.append(alloc, "-bios");
        try args.append(alloc, ovmf);
    }

    // Audiodev backend: route to the SPICE client when the display is SPICE
    // (the only path that carries host audio in this headless manager), else a
    // dummy `none` backend so the guest still sees the sound card without
    // depending on a host audio system. The old hard-coded `sdl` backend is
    // rarely compiled in and made QEMU reject the command line outright.
    const audiodev_arg: []const u8 = if (config.display == .spice) "spice,id=snd0" else "none,id=snd0";
    switch (config.audio) {
        .hda => {
            try args.append(alloc, "-device");
            try args.append(alloc, "intel-hda");
            try args.append(alloc, "-device");
            // hda-duplex must reference the audiodev id explicitly; modern QEMU
            // no longer auto-binds the lone backend, so without audiodev= the
            // codec attaches to a null backend and the guest gets no sound.
            try args.append(alloc, "hda-duplex,audiodev=snd0");
            try args.append(alloc, "-audiodev");
            try args.append(alloc, audiodev_arg);
        },
        .ac97 => {
            try args.append(alloc, "-device");
            // The AC97 device must reference the audiodev id explicitly; without
            // audiodev= modern QEMU binds it to a null backend and emits no sound.
            try args.append(alloc, "AC97,audiodev=snd0");
            try args.append(alloc, "-audiodev");
            try args.append(alloc, audiodev_arg);
        },
        .none => {},
    }

    if (config.hasName()) {
        try args.append(alloc, "-name");
        try args.append(alloc, config.getNameSlice());
    }

    if (config.hasSavedState()) {
        // Validate path: no shell metacharacters.  QEMU's `exec:` protocol
        // runs its argument via /bin/sh, so we must reject anything that
        // could break out of the `cat` command.
        const sp = config.getSavedStatePathSlice();
        if (!isSafeShellPath(sp)) return error.UnsafeSavedStatePath;
        const cmd = try std.fmt.bufPrint(&bufs.incoming_buf, "exec:cat {s}", .{sp});
        try args.append(alloc, "-incoming");
        try args.append(alloc, cmd);
    }

    // USB controller — configurable via usb_policy (none / EHCI / xHCI).
    switch (config.usb_policy) {
        .none => {},
        .usb2 => {
            try args.append(alloc, "-device");
            try args.append(alloc, "usb-ehci");
        },
        .usb3 => {
            try args.append(alloc, "-device");
            try args.append(alloc, "qemu-xhci");
        },
    }
    // USB tablet provides absolute pointing so the guest cursor matches
    // the host cursor position — essential for embedded VNC/SPICE where
    // relative mouse input would desync. Only attach when a USB controller
    // is present.
    if (config.usb_policy != .none) {
        try args.append(alloc, "-device");
        try args.append(alloc, "usb-tablet");
    }

    // USB device passthrough. The field holds "vendorid:productid" in hex
    // (e.g. "046d:c52b"). The q35 machine already provides a USB controller.
    //
    // vendor/product are interpolated into a comma-separated `-device` property
    // list, so each must be validated as plain hex. A value such as
    // "046d,hostbus=1" would otherwise inject extra QEMU device properties
    // (argument injection, CWE-88) — selecting a different physical device than
    // intended. The web boundary only strips "..", so enforce the format here at
    // the sink, where it also covers names loaded from vms.json / the daemon.
    if (config.hasUsbDevice()) {
        const spec = config.getUsbDeviceSlice();
        if (std.mem.indexOfScalar(u8, spec, ':')) |sep| {
            const vendor = spec[0..sep];
            const product = spec[sep + 1 ..];
            if (isHexId(vendor) and isHexId(product)) {
                const usb_str = try std.fmt.bufPrint(&bufs.usb_buf, "usb-host,vendorid=0x{s},productid=0x{s}", .{ vendor, product });
                try args.append(alloc, "-device");
                try args.append(alloc, usb_str);
            }
        }
    }

    // Shared folder via virtio-9p: mounts a host directory into the guest.
    // Guest mounts with: mount -t 9p -o trans=virtio shared /mnt/shared
    //
    // The path is interpolated into a comma-separated `-fsdev` property list. A
    // comma (QEMU's property delimiter) in the path would inject extra fsdev
    // properties — e.g. downgrading `security_model` or adding `readonly=off`
    // (argument injection, CWE-88). QEMU itself cannot represent an un-escaped
    // comma in this position anyway, so a path containing one (or a NUL /
    // newline) is rejected outright rather than emitted.
    if (config.hasSharedFolder()) {
        const folder = config.getSharedFolderSlice();
        if (isSafeQemuPropValue(folder)) {
            const shared_str = try std.fmt.bufPrint(&bufs.shared_buf, "local,id=shared0,path={s},security_model=mapped-xattr", .{folder});
            try args.append(alloc, "-fsdev");
            try args.append(alloc, shared_str);
            try args.append(alloc, "-device");
            try args.append(alloc, "virtio-9p-pci,fsdev=shared0,mount_tag=shared");
        }
    }
}

/// Start a QEMU process for the given VM configuration.
/// QEMU stderr is written to /var/tmp/hangar-vm-<name>.log for diagnostics
/// when the VM has a name; otherwise it is discarded (/dev/null).
pub fn startVm(config: *vm.VmConfig, allocator: std.mem.Allocator) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var bufs = ArgBuffers{};
    try buildArgs(config, &args, allocator, &bufs);

    // Build stderr log path from the VM name.
    var err_path_buf: [128]u8 = undefined;
    const err_path: ?[:0]const u8 = if (config.hasName()) blk: {
        const path = std.fmt.bufPrintZ(&err_path_buf, "/var/tmp/hangar-vm-{s}.log", .{config.getNameSlice()}) catch break :blk null;
        break :blk path;
    } else null;

    config.pid = try forkExec(args.items, allocator, err_path);
    config.status = .running;
}

/// Write an argument to the output, shell-quoted if it contains unsafe characters.
/// Uses single-quote wrapping with internal single-quote escaping ('\'').
fn appendShellQuoted(arg: []const u8, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    // If the arg contains only safe characters, output verbatim.
    const needs_quote = for (arg) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '/', ':', '=', '+', ',' => {},
            else => break true,
        }
    } else false;

    if (!needs_quote) {
        try out.appendSlice(alloc, arg);
        return;
    }

    // Wrap in single quotes, escaping any internal single quotes as '\''.
    try out.appendSlice(alloc, "'");
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, arg, start, '\'')) |pos| {
        try out.appendSlice(alloc, arg[start..pos]);
        try out.appendSlice(alloc, "'\\''");
        start = pos + 1;
    }
    try out.appendSlice(alloc, arg[start..]);
    try out.appendSlice(alloc, "'");
}

/// Generate a standalone bash launch script for a VM configuration.
pub fn buildScriptStr(config: *const vm.VmConfig, allocator: std.mem.Allocator) ![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var bufs = ArgBuffers{};
    try buildArgs(config, &args, allocator, &bufs);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "#!/bin/bash\n\n# Hangar Exported VM Launch Script\n");
    if (config.hasName()) {
        try out.print(allocator, "# VM Name: {s}\n\n", .{config.getNameSlice()});
    }

    for (args.items, 0..) |arg, i| {
        try appendShellQuoted(arg, &out, allocator);
        if (i < args.items.len - 1) {
            try out.appendSlice(allocator, " \\\n    ");
        }
    }
    try out.appendSlice(allocator, "\n");

    return out.toOwnedSlice(allocator);
}

/// Send SIGTERM to the QEMU process. Does not block or reap.
/// We deliberately don't update `config.status` here because the
/// process may take time to exit; `isVmAlive` handles reaping.
pub fn stopVm(config: *const vm.VmConfig) void {
    const pid = config.pid orelse return;
    _ = std.c.kill(pid, std.c.SIG.TERM);
}

/// Send SIGKILL to the QEMU process. Does not block or reap.
pub fn forceStopVm(config: *const vm.VmConfig) void {
    const pid = config.pid orelse return;
    _ = std.c.kill(pid, std.c.SIG.KILL);
}

/// Check if the QEMU process is still running. If it exited, reaps it
/// and clears the PID and status.
pub fn isVmAlive(config: *vm.VmConfig) bool {
    const pid = config.pid orelse return false;

    // Use waitpid with WNOHANG to check status without blocking.
    var status: c_int = 0;
    const reaped = std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG);
    if (reaped == 0) {
        // Still running
        return true;
    }
    if (reaped == -1) {
        // ECHILD: child no longer exists (already reaped or never was ours).
        const e = std.c._errno().*;
        if (e == @intFromEnum(std.c.E.CHILD)) {
            config.pid = null;
            config.status = .stopped;
            return false;
        }
        // Other errors (EINTR etc.) — assume alive on transient error.
        return true;
    }

    // reaped == pid: process genuinely exited.
    config.pid = null;
    config.status = .stopped;
    return false;
}

/// Block until the QEMU process exits and reap it.
pub fn reapVm(config: *vm.VmConfig) void {
    const pid = config.pid orelse return;
    _ = std.c.waitpid(@intCast(pid), null, 0);
    config.pid = null;
    config.status = .stopped;
}

/// Create a new disk image using `qemu-img`.
pub fn createDiskImage(path: []const u8, size_gb: u32, format: vm.DiskFormat, allocator: std.mem.Allocator) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{d}G", .{size_gb});

    const args = [_][]const u8{
        "qemu-img",
        "create",
        "-f",
        std.mem.span(format.toStr()),
        path,
        size_str,
    };

    runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
}

/// Grow an existing disk image to `new_size_gb` using `qemu-img resize`.
/// Only supports growing — shrinking risks data loss and is rejected by the
/// UI before reaching here.
pub fn resizeDiskImage(path: []const u8, new_size_gb: u32, allocator: std.mem.Allocator) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{d}G", .{new_size_gb});

    const args = [_][]const u8{ "qemu-img", "resize", path, size_str };
    runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
}

/// Convert a disk image to a different format using `qemu-img convert`.
/// Used by OVF export to produce a VMDK stream-optimized image suitable
/// for ESXi / VMware Workstation import.
pub fn convertDiskImage(src_path: []const u8, src_format: vm.DiskFormat, dest_path: []const u8, dest_format: vm.DiskFormat, allocator: std.mem.Allocator) !void {
    const dest_str = std.mem.span(dest_format.toStr());
    if (dest_format == .vmdk) {
        const args = [_][]const u8{
            "qemu-img", "convert",
            "-f",       std.mem.span(src_format.toStr()),
            "-O",       dest_str,
            "-o",       "subformat=streamOptimized",
            src_path,   dest_path,
        };
        runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
    } else {
        const args = [_][]const u8{
            "qemu-img", "convert",
            "-f",       std.mem.span(src_format.toStr()),
            "-O",       dest_str,
            src_path,   dest_path,
        };
        runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
    }
}

/// Start a disk conversion in the background (fork + exec qemu-img convert).
/// Returns the child PID.  Does NOT wait — the caller must eventually reap
/// the child via `waitpid`.  This keeps the UI responsive during long
/// conversions (e.g. OVF export).
pub fn convertDiskImageNoWait(src_path: []const u8, src_format: vm.DiskFormat, dest_path: []const u8, dest_format: vm.DiskFormat, allocator: std.mem.Allocator) !std.c.pid_t {
    const src_str = std.mem.span(src_format.toStr());
    const dest_str = std.mem.span(dest_format.toStr());
    if (dest_format == .vmdk) {
        return try forkExec(&.{ "qemu-img", "convert", "-f", src_str, "-O", dest_str, "-o", "subformat=streamOptimized", src_path, dest_path }, allocator, null);
    }
    return try forkExec(&.{ "qemu-img", "convert", "-f", src_str, "-O", dest_str, src_path, dest_path }, allocator, null);
}

/// Reap a background process started by convertDiskImageNoWait (or any
/// child).  Returns `null` if still running, `true` on success (exit 0),
/// `false` on failure.
pub fn tryReapChild(pid: std.c.pid_t) ?bool {
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == 0) return null; // still running
    if (r < 0) return false; // error / already reaped
    return exitedClean(status);
}

/// Create a linked clone: a new qcow2 image backed by `backing_path`.
/// The clone shares the backing image's blocks copy-on-write, so it is
/// created near-instantly and consumes almost no space initially. The
/// backing file must not be modified while linked clones depend on it.
pub fn createLinkedClone(dest_path: []const u8, backing_path: []const u8, backing_format: vm.DiskFormat, allocator: std.mem.Allocator) !void {
    var backing_arg: [vm.MAX_PATH + 16]u8 = undefined;
    const backing_str = try std.fmt.bufPrint(&backing_arg, "backing_file={s},backing_fmt={s}", .{
        backing_path,
        std.mem.span(backing_format.toStr()),
    });

    const args = [_][]const u8{
        "qemu-img", "create", "-f", "qcow2", "-o", backing_str, dest_path,
    };
    runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
}

/// Return true if `path` contains no shell metacharacters and is safe
/// to embed in a single-argument position of `exec:cat {path}`.
fn isSafeShellPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| {
        switch (c) {
            // Shell metacharacters and control characters
            ' ',
            ';',
            '|',
            '&',
            '$',
            '`',
            '(',
            ')',
            '<',
            '>',
            '\'',
            '"',
            '\\',
            '~',
            '#',
            '!',
            '*',
            '?',
            '\n',
            '\r',
            '\t',
            0,
            => return false,
            else => {},
        }
    }
    return true;
}

/// Returns true if `s` is a non-empty run of 1–4 hex digits — the only shape a
/// USB vendor/product id may take. Rejecting anything else stops a comma (or
/// other QEMU `-device` property delimiter) from injecting extra device
/// properties when the id is interpolated into a property list.
fn isHexId(s: []const u8) bool {
    if (s.len == 0 or s.len > 4) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Returns true if `s` is a syntactically valid TCP port: a non-empty run of
/// 1–5 decimal digits that parses as a non-zero `u16`. Port-forward tokens are
/// interpolated into the QEMU `-netdev user,...,hostfwd=...` property list;
/// restricting them to bare port numbers keeps any other byte (a stray comma,
/// `=`, or property name) from being smuggled into that list, matching the
/// guarding applied to every other user value that reaches a QEMU argument.
fn isDecimalPort(s: []const u8) bool {
    if (s.len == 0 or s.len > 5) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    const n = std.fmt.parseInt(u16, s, 10) catch return false;
    return n != 0;
}

/// VNC display number for a TCP port: `port - 5900`, saturated to 0 when
/// `port < 5900` to prevent u16 underflow (panic in debug, UB in release).
fn vncDisplayNum(port: u16) u16 {
    return if (port >= 5900) port - 5900 else 0;
}

/// Returns true if `s` can be safely interpolated into a single value of a
/// comma-separated QEMU `-fsdev`/`-device` property list. Rejects the comma
/// property delimiter and the NUL/newline terminators; everything else (spaces,
/// slashes, etc.) is a legitimate path byte.
fn isSafeQemuPropValue(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c == ',' or c == 0 or c == '\n' or c == '\r') return false;
    }
    return true;
}

// ── Arg-builder helpers for disk operations ─────────────────────────
// These return the argv that would be passed to runWait / forkExec, so
// the arg format can be tested without spawning a child.

/// Returns the argv slice for `qemu-img convert`, with stream-optimized
/// subformat flag when the destination is VMDK.
pub fn buildConvertArgs(
    src_path: []const u8,
    src_format: vm.DiskFormat,
    dest_path: []const u8,
    dest_format: vm.DiskFormat,
    allocator: std.mem.Allocator,
) !std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, "qemu-img");
    try args.append(allocator, "convert");
    try args.append(allocator, "-f");
    try args.append(allocator, std.mem.span(src_format.toStr()));
    try args.append(allocator, "-O");
    try args.append(allocator, std.mem.span(dest_format.toStr()));
    if (dest_format == .vmdk) {
        try args.append(allocator, "-o");
        try args.append(allocator, "subformat=streamOptimized");
    }
    try args.append(allocator, src_path);
    try args.append(allocator, dest_path);
    return args;
}

/// Returns the argv slice for `qemu-img create` with backing file options.
pub fn buildLinkedCloneArgs(
    dest_path: []const u8,
    backing_path: []const u8,
    backing_format: vm.DiskFormat,
    allocator: std.mem.Allocator,
) !std.ArrayList([]const u8) {
    var backing_arg: [vm.MAX_PATH + 64]u8 = undefined;
    const backing_str = try std.fmt.bufPrint(&backing_arg, "backing_file={s},backing_fmt={s}", .{
        backing_path,
        std.mem.span(backing_format.toStr()),
    });

    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, "qemu-img");
    try args.append(allocator, "create");
    try args.append(allocator, "-f");
    try args.append(allocator, "qcow2");
    try args.append(allocator, "-o");
    try args.append(allocator, try allocator.dupe(u8, backing_str));
    try args.append(allocator, dest_path);
    return args;
}

test "isSafeShellPath: safe and unsafe paths" {
    try std.testing.expect(isSafeShellPath("/tmp/vm_state.bin"));
    try std.testing.expect(!isSafeShellPath("/home/user/VM Data/state.bin"));
    try std.testing.expect(!isSafeShellPath("bad; rm -rf /"));
    try std.testing.expect(!isSafeShellPath("bad$(id)"));
    try std.testing.expect(!isSafeShellPath("bad`id`"));
    try std.testing.expect(!isSafeShellPath("bad|cat /etc/passwd"));
    try std.testing.expect(!isSafeShellPath("bad\"quotes"));
    try std.testing.expect(!isSafeShellPath(""));
}

test "isHexId: accepts only short hex runs" {
    try std.testing.expect(isHexId("046d"));
    try std.testing.expect(isHexId("c52b"));
    try std.testing.expect(isHexId("0"));
    try std.testing.expect(isHexId("ABCD"));
    try std.testing.expect(!isHexId("")); // empty
    try std.testing.expect(!isHexId("12345")); // too long
    try std.testing.expect(!isHexId("046d,hostbus=1")); // property injection
    try std.testing.expect(!isHexId("xy")); // non-hex
    try std.testing.expect(!isHexId("0x46")); // no prefix allowed here
}

test "fuzz: isHexId never panics and accepts only [0-9a-fA-F]{1,4}" {
    var seed: u64 = 0x9e3779b97f4a7c15;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var buf: [12]u8 = undefined;
        const n = seed % buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            buf[j] = @truncate(s);
        }
        const arg = buf[0..n];
        if (isHexId(arg)) {
            try std.testing.expect(arg.len >= 1 and arg.len <= 4);
            for (arg) |c| {
                const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
                try std.testing.expect(ok);
            }
        }
    }
}

test "vncDisplayNum: subtracts 5900 and saturates" {
    try std.testing.expectEqual(@as(u16, 0), vncDisplayNum(5900));
    try std.testing.expectEqual(@as(u16, 1), vncDisplayNum(5901));
    try std.testing.expectEqual(@as(u16, 100), vncDisplayNum(6000));
    try std.testing.expectEqual(@as(u16, 0), vncDisplayNum(0)); // below 5900 saturates
    try std.testing.expectEqual(@as(u16, 0), vncDisplayNum(5899));
}

test "fuzz: vncDisplayNum never underflows" {
    var seed: u64 = 0x9e3779b97f4a7c15;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const port: u16 = @truncate(seed);
        const d = vncDisplayNum(port);
        if (port >= 5900) try std.testing.expectEqual(port - 5900, d) else try std.testing.expectEqual(@as(u16, 0), d);
    }
}

test "isSafeQemuPropValue: rejects comma and terminators" {
    try std.testing.expect(isSafeQemuPropValue("/home/user/shared"));
    try std.testing.expect(isSafeQemuPropValue("/path with spaces/x"));
    try std.testing.expect(!isSafeQemuPropValue("")); // empty
    try std.testing.expect(!isSafeQemuPropValue("/x,security_model=none")); // injection
    try std.testing.expect(!isSafeQemuPropValue("/x\x00y"));
    try std.testing.expect(!isSafeQemuPropValue("/x\ny"));
}

test "fuzz: isSafeQemuPropValue never panics and rejects delimiters" {
    var seed: u64 = 0xd1b54a32d192ed03;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var buf: [24]u8 = undefined;
        const n = seed % buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            buf[j] = @truncate(s);
        }
        const arg = buf[0..n];
        if (isSafeQemuPropValue(arg)) {
            try std.testing.expect(arg.len > 0);
            for (arg) |c| try std.testing.expect(c != ',' and c != 0 and c != '\n' and c != '\r');
        }
    }
}

test "convertDiskImage: arg builder includes streamOptimized for VMDK" {
    const alloc = std.testing.allocator;
    var args = try buildConvertArgs("/disk.qcow2", .qcow2, "/disk.vmdk", .vmdk, alloc);
    defer args.deinit(alloc);
    // Verify the -o subformat=streamOptimized flag appears for VMDK.
    var found_o = false;
    var found_sub = false;
    for (args.items) |a| {
        if (std.mem.eql(u8, a, "-o")) found_o = true;
        if (std.mem.eql(u8, a, "subformat=streamOptimized")) found_sub = true;
    }
    try std.testing.expect(found_o);
    try std.testing.expect(found_sub);
}

test "convertDiskImage: arg builder omits streamOptimized for non-VMDK" {
    const alloc = std.testing.allocator;
    var args = try buildConvertArgs("/disk.qcow2", .qcow2, "/disk.raw", .raw, alloc);
    defer args.deinit(alloc);
    for (args.items) |a| {
        try std.testing.expect(!std.mem.eql(u8, a, "-o"));
        try std.testing.expect(!std.mem.eql(u8, a, "subformat=streamOptimized"));
    }
}

test "createLinkedClone: arg builder produces backing_file and backing_fmt" {
    const alloc = std.testing.allocator;
    var args = try buildLinkedCloneArgs("/clone.qcow2", "/base.qcow2", .qcow2, alloc);
    defer {
        for (args.items) |s| {
            // The backing_str is the only heap-duped item; the rest are
            // slices into string literals or caller buffers.
            if (std.mem.indexOf(u8, s, "backing_file=") != null) alloc.free(s);
        }
        args.deinit(alloc);
    }
    // The backing option string is one arg: backing_file=/base.qcow2,backing_fmt=qcow2
    var found_f = false;
    var found_bb = false;
    for (args.items) |a| {
        if (std.mem.eql(u8, a, "-o")) found_f = true;
        if (std.mem.indexOf(u8, a, "backing_file=") != null and
            std.mem.indexOf(u8, a, "backing_fmt=qcow2") != null) found_bb = true;
    }
    try std.testing.expect(found_f);
    try std.testing.expect(found_bb);
}

// ── Fuzz tests ──────────────────────────────────────────────────────
//
// `buildArgs`/`buildScriptStr` format a VmConfig into fixed-size stack buffers
// (ArgBuffers) and parse the port-forward / USB strings. Feed thousands of
// random configs — long paths, port-forward strings full of ':'/',', odd USB
// specs, every enum index — and assert it never overflows a buffer, panics, or
// leaks. Reproducible via the fixed seed.

test "fuzz: buildScriptStr never crashes on random configs" {
    const std_t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5EED_0011);
    const rnd = prng.random();
    var sbuf: [600]u8 = undefined;

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        var c = vm.VmConfig{};
        c.cpu_cores = rnd.int(u32);
        c.cpu_sockets = rnd.int(u32);
        c.memory_mb = rnd.int(u32);
        c.disk_size_gb = rnd.int(u32);
        c.disk2_size_gb = rnd.int(u32);
        for (0..vm.MAX_EXTRA_DISKS) |i| {
            c.extra_disks[i].size_gb = rnd.int(u32);
            c.extra_disks[i].format = vm.DiskFormat.fromIndex(rnd.int(usize));
        }
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
        // .uefi would require an OVMF file on disk; pin BIOS so the fuzzer
        // exercises arg-building, not firmware discovery.
        c.firmware = .bios;
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
                for (b[0..n]) |*x| {
                    // Bias toward characters meaningful to the parsers.
                    x.* = if (r.boolean()) ":,0123456789-/ "[r.uintLessThan(usize, 16)] else r.int(u8);
                }
                return b[0..n];
            }
        };
        c.setName(rstr.get(rnd, &sbuf));
        c.setDiskPath(rstr.get(rnd, &sbuf));
        c.setDisk2Path(rstr.get(rnd, &sbuf));
        for (0..vm.MAX_EXTRA_DISKS) |i| {
            c.setExtraDiskPath(i, rstr.get(rnd, &sbuf));
        }
        c.setIsoPath(rstr.get(rnd, &sbuf));
        c.setFloppyPath(rstr.get(rnd, &sbuf));
        c.setSharedFolder(rstr.get(rnd, &sbuf));
        c.setPortForwards(rstr.get(rnd, &sbuf));
        c.setUsbDevice(rstr.get(rnd, &sbuf));
        c.setMacAddress(rstr.get(rnd, &sbuf));
        c.setNic2Mac(rstr.get(rnd, &sbuf));

        const script = buildScriptStr(&c, std_t.allocator) catch continue;
        defer std_t.allocator.free(script);
        try std_t.expect(script.len > 0);
        // Property: always a bash script header.
        try std_t.expect(std.mem.startsWith(u8, script, "#!/bin/bash"));
    }
}

// ── Deterministic arg-builder tests ─────────────────────────────────
// buildScriptStr drives buildArgs + appendExtraNic + firmware discovery, so
// asserting on its output exercises those paths without spawning a process.

const expect = std.testing.expect;
const talloc = std.testing.allocator;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "qemu: buildScriptStr emits core flags (user net)" {
    var cfg = vm.VmConfig{};
    cfg.setName("Test VM");
    cfg.memory_mb = 4096;
    cfg.cpu_cores = 2;
    cfg.cpu_sockets = 1;
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.nics[0].mode = .user;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(std.mem.startsWith(u8, s, "#!/bin/bash"));
    try expect(has(s, "qemu-system-x86_64"));
    try expect(has(s, "-m"));
    try expect(has(s, "4096"));
    try expect(has(s, "-smp"));
    try expect(has(s, "/tmp/disk.qcow2"));
    try expect(has(s, "user,id=net0"));
    try expect(has(s, "-name"));
}

test "qemu: non-embedded VNC display uses -vnc, not invalid -display vnc" {
    // QEMU has no "vnc" backend for -display; it must be configured via -vnc.
    var cfg = vm.VmConfig{};
    cfg.setName("VncVm");
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.nics[0].mode = .user;
    cfg.embed_display = false;
    cfg.display = .vnc;
    cfg.vnc_port = 5902;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-vnc"));
    try expect(has(s, "localhost:2"));
    try expect(!has(s, "-display vnc"));
}

test "qemu: disk path with comma is rejected (arg injection guard)" {
    var cfg = vm.VmConfig{};
    cfg.setName("Inject");
    cfg.setDiskPath("/tmp/disk.qcow2,readonly=on,if=none");
    cfg.nics[0].mode = .user;
    try std.testing.expectError(error.UnsafeDiskPath, buildScriptStr(&cfg, talloc));
}

test "qemu: malformed MAC is dropped rather than embedded" {
    var cfg = vm.VmConfig{};
    cfg.setName("MacInject");
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.nics[0].mode = .user;
    // A comma-bearing value would inject -device properties if embedded; it is
    // not a valid MAC, so the device must fall back to the auto-assigned form.
    cfg.setMacAddress("00,evil=1");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "evil=1"));
    try expect(has(s, "virtio-net-pci,netdev=net0"));
}

test "qemu: bridge network + UEFI firmware flags" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .bridge;
    cfg.firmware = .uefi;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "bridge,id=net0,br=br0"));
    // UEFI selects OVMF via -bios when findOvmfPath() locates the firmware
    // (otherwise buildScriptStr returns OvmfNotFound).
    try expect(has(s, "-bios"));
}

test "qemu: gvproxy network uses stream unix socket backend" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .gvproxy;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "stream,id=net0,addr.type=unix,addr.path=/tmp/hangar-gvproxy-qemu.sock"));
    try expect(has(s, "virtio-net-pci,netdev=net0"));
}

test "qemu: network .none omits -netdev" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .none;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "id=net0"));
}

test "qemu: port forwards appear as hostfwd" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .user;
    cfg.setPortForwards("2222:22");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "hostfwd=tcp::2222-:22"));
}

test "qemu: many port forwards are not silently truncated" {
    // A port_forwards string near its 511-byte cap expands to ~2.3 KB of
    // hostfwd args. The netdev buffer must hold all of it; previously a 1024-byte
    // buffer dropped the tail rules via `catch break`. Build many minimal pairs
    // and confirm the FIRST and LAST both survive.
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .user;
    var pf_buf: [600]u8 = undefined;
    var w: usize = 0;
    var n: u32 = 100;
    // Pairs like "100:200,101:201,..." until we approach the 511-byte cap.
    while (true) {
        const chunk = std.fmt.bufPrint(pf_buf[w..], "{d}:{d},", .{ n, n + 100 }) catch break;
        if (w + chunk.len > 500) break;
        w += chunk.len;
        n += 1;
    }
    cfg.setPortForwards(pf_buf[0 .. w - 1]); // drop trailing comma
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "hostfwd=tcp::100-:200")); // first rule
    const last = n - 1;
    var first_buf: [32]u8 = undefined;
    const last_str = try std.fmt.bufPrint(&first_buf, "hostfwd=tcp::{d}-:{d}", .{ last, last + 100 });
    try expect(has(s, last_str)); // last rule survived (no truncation)
}

test "qemu: malformed port forwards are dropped, not injected" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .user;
    // A valid pair followed by ones carrying QEMU property/metacharacters or a
    // non-numeric guest. Only the valid pair must reach the netdev value.
    cfg.setPortForwards("2222:22,80=x:81,99:smb,0:22,7:0");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "hostfwd=tcp::2222-:22"));
    try expect(!has(s, "80=x")); // '=' token rejected
    try expect(!has(s, "smb")); // non-numeric guest rejected
    try expect(!has(s, "tcp::0-")); // zero port rejected
    try expect(!has(s, "-:0")); // zero guest port rejected
}

test "qemu: isDecimalPort accepts ports, rejects junk" {
    try expect(isDecimalPort("1"));
    try expect(isDecimalPort("2222"));
    try expect(isDecimalPort("65535"));
    try expect(!isDecimalPort("")); // empty
    try expect(!isDecimalPort("0")); // zero is not a usable port
    try expect(!isDecimalPort("65536")); // overflows u16
    try expect(!isDecimalPort("123456")); // too many digits
    try expect(!isDecimalPort("80,smb=/x")); // comma/property injection
    try expect(!isDecimalPort("8a")); // non-digit
    try expect(!isDecimalPort(" 80")); // whitespace
}

test "qemu: fuzz isDecimalPort never injects metacharacters" {
    var prng = std.Random.DefaultPrng.init(0xF0F7);
    const rnd = prng.random();
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        const s = buf[0..len];
        if (isDecimalPort(s)) {
            // Anything accepted must be a bare 1-5 digit non-zero u16: no comma,
            // '=', NUL, or other byte that could escape the netdev value.
            try expect(s.len >= 1 and s.len <= 5);
            for (s) |c| try expect(c >= '0' and c <= '9');
            const n = try std.fmt.parseInt(u16, s, 10);
            try expect(n != 0);
        }
    }
}

test "qemu: extra NICs add net1/net2 devices" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .user;
    cfg.nics[1].mode = .gvproxy;
    cfg.nics[2].mode = .bridge;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "net1"));
    try expect(has(s, "net2"));
    try expect(has(s, "stream,id=net1,addr.type=unix,addr.path=/tmp/hangar-gvproxy-qemu.sock"));
}

test "qemu: buildCArgv null-terminates and preserves entries" {
    var arena_inst = std.heap.ArenaAllocator.init(talloc);
    defer arena_inst.deinit();
    const argv = [_][]const u8{ "qemu", "-m", "2048" };
    const c = try buildCArgv(&argv, arena_inst.allocator());
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try expect(c[3] == null); // sentinel
    try std.testing.expectEqualStrings("qemu", std.mem.span(c[0].?));
    try std.testing.expectEqualStrings("-m", std.mem.span(c[1].?));
    try std.testing.expectEqualStrings("2048", std.mem.span(c[2].?));
}

test "qemu: firmware/iso discovery probes never crash" {
    // Filesystem probes — return null or a real path depending on host; the
    // contract under test is "never panics / returns a valid optional".
    _ = findOvmfPath();
    var buf: [vm.MAX_PATH]u8 = undefined;
    _ = findVirtioWinIsoInto(&buf);
}

test "fuzz: buildCArgv over random argv shapes" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    var iter: usize = 0;
    while (iter < 1500) : (iter += 1) {
        var arena_inst = std.heap.ArenaAllocator.init(talloc);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();
        const n = rnd.uintLessThan(usize, 12);
        var argv = try a.alloc([]const u8, n);
        for (0..n) |i| {
            const len = rnd.uintLessThan(usize, 20);
            const buf = try a.alloc(u8, len);
            for (buf) |*ch| ch.* = rnd.intRangeAtMost(u8, 'a', 'z');
            argv[i] = buf;
        }
        const c = try buildCArgv(argv, a);
        try std.testing.expectEqual(n, c.len);
        try expect(c[n] == null);
        for (0..n) |i| try std.testing.expectEqualStrings(argv[i], std.mem.span(c[i].?));
    }
}

// ── Fuzz: process-spawn + disk-image plumbing (real, harmless targets) ──
// fork/exec and qemu-img calls are fuzzed for real against safe targets:
// /bin/true + bogus binaries for the exec path, temp qcow2 files with random
// sizes/formats/snapshot-names for the disk path, and OUR OWN short-lived child
// pids for the process-control quartet (never a random kill). Skips gracefully
// if qemu-img is absent. Asserts: no crash, no hang, no buffer overrun.

test "fuzz: forkExec/runWait/runCapture over safe argv" {
    const alloc = std.heap.page_allocator;
    var prng = std.Random.DefaultPrng.init(0x9E2_E5EC);
    const rnd = prng.random();
    var namebuf: [64]u8 = undefined;
    var out: [256]u8 = undefined;

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const pick = rnd.uintLessThan(u8, 3);
        var arg: [16]u8 = undefined;
        for (&arg) |*ch| ch.* = "abcXYZ0/.-_ "[rnd.uintLessThan(usize, 12)];
        const rarg = arg[0..rnd.uintLessThan(usize, arg.len)];
        switch (pick) {
            0 => runWait(&.{"/bin/true"}, alloc, null) catch {},
            1 => runWait(&.{ "/bin/echo", rarg }, alloc, null) catch {},
            else => {
                // bogus path → execvp fails in the child; parent must handle it.
                const bogus = std.fmt.bufPrint(&namebuf, "/nonexistent-{s}-{d}", .{ rarg, i }) catch "/nonexistent";
                runWait(&.{bogus}, alloc, null) catch {};
            },
        }
        _ = runCapture(&.{ "/bin/echo", rarg }, &out, alloc) catch {};
        // forkExec directly, then reap our own child.
        const pid = forkExec(&.{"/bin/true"}, alloc, null) catch continue;
        _ = std.c.waitpid(pid, null, 0);
    }
}

test "fuzz: createDiskImage/resize/snapshot over temp qcow2 with random params" {
    const alloc = std.heap.page_allocator;
    // Probe: skip cleanly if qemu-img is unavailable in this environment.
    createDiskImage("/tmp/hangar-qprobe.qcow2", 1, .qcow2, alloc) catch {
        return; // no qemu-img → nothing to fuzz here
    };
    _ = std.Io.Dir.cwd().deleteFile(appio.io(), "/tmp/hangar-qprobe.qcow2") catch {};

    var prng = std.Random.DefaultPrng.init(0xD15C_F0FF);
    const rnd = prng.random();
    var path_buf: [96]u8 = undefined;
    var name_buf: [40]u8 = undefined;
    var listbuf: [4096]u8 = undefined;

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-qfuzz-{d}-{d}.qcow2", .{ std.c.getpid(), i }) catch continue;
        const size: u32 = rnd.uintLessThan(u32, 64) + 1; // 1..64 GB (qcow2 sparse)
        const fmt = vm.DiskFormat.fromIndex(rnd.int(usize));
        createDiskImage(path, size, fmt, alloc) catch {
            continue;
        };
        defer _ = std.Io.Dir.cwd().deleteFile(appio.io(), path) catch {};

        // Random snapshot names (incl. odd characters) — qemu-img may accept or
        // reject; either way must not crash our wrapper.
        for (0..3) |_| {
            for (name_buf[0..]) |*ch| ch.* = "snapTEST 0123-_."[rnd.uintLessThan(usize, 16)];
            const nm = name_buf[0..rnd.uintLessThan(usize, name_buf.len)];
            snapshotCreate(path, nm, alloc) catch {};
            _ = snapshotList(path, &listbuf, alloc) catch {};
            snapshotApply(path, nm, alloc) catch {};
            snapshotDelete(path, nm, alloc) catch {};
        }
        resizeDiskImage(path, size + rnd.uintLessThan(u32, 16), alloc) catch {};

        // Linked clone with the just-created image as backing file.
        var clone_buf: [96]u8 = undefined;
        const clone = std.fmt.bufPrintZ(&clone_buf, "/tmp/hangar-qclone-{d}-{d}.qcow2", .{ std.c.getpid(), i }) catch continue;
        createLinkedClone(clone, path, fmt, alloc) catch {};
        _ = std.Io.Dir.cwd().deleteFile(appio.io(), clone) catch {};

        // convert to VMDK (stream-optimized) — exercises convertDiskImage
        var vmdk_buf: [96]u8 = undefined;
        const vmdk = std.fmt.bufPrintZ(&vmdk_buf, "/tmp/hangar-qconv-{d}-{d}.vmdk", .{ std.c.getpid(), i }) catch continue;
        convertDiskImage(path, fmt, vmdk, .vmdk, alloc) catch {};
        _ = std.Io.Dir.cwd().deleteFile(appio.io(), vmdk) catch {};
    }
}

test "fuzz: process-control quartet on our own short-lived children" {
    const alloc = std.heap.page_allocator;
    var prng = std.Random.DefaultPrng.init(0x9111_DEAD);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var cfg = vm.VmConfig{};
        // Half the time: no pid → exercises the orelse-return paths safely.
        if (rnd.boolean()) {
            stopVm(&cfg);
            forceStopVm(&cfg);
            try std.testing.expect(!isVmAlive(&cfg));
            reapVm(&cfg);
            continue;
        }
        // Otherwise: spawn a real, harmless child and drive the lifecycle on it.
        const pid = forkExec(&.{ "/bin/sleep", "0.2" }, alloc, null) catch continue;
        cfg.pid = @intCast(pid);
        _ = isVmAlive(&cfg); // likely true
        switch (rnd.uintLessThan(u8, 3)) {
            0 => stopVm(&cfg), // SIGTERM our own sleep
            1 => forceStopVm(&cfg), // SIGKILL our own sleep
            else => {},
        }
        reapVm(&cfg); // waitpid our child → no zombie
        try std.testing.expect(cfg.pid == null);
    }
}

test "fuzz: startVm spawns real QEMU (headless/TCG) then stops + reaps" {
    const alloc = std.heap.page_allocator;
    // Probe: skip if qemu-system-x86_64 is unavailable.
    runWait(&.{ "qemu-system-x86_64", "--version" }, alloc, null) catch return;

    var prng = std.Random.DefaultPrng.init(0x57A47_F0FF);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var cfg = vm.VmConfig{};
        cfg.display = .none; // no window
        cfg.embed_display = false; // no VNC/SPICE server
        cfg.accel = .tcg; // TCG — no /dev/kvm needed
        cfg.firmware = .bios;
        cfg.memory_mb = rnd.uintLessThan(u32, 256) + 16; // small + safe
        cfg.cpu_cores = rnd.uintLessThan(u32, 4) + 1;
        cfg.cpu_sockets = 1;
        cfg.nics[0].mode = vm.NetworkMode.fromIndex(rnd.int(usize));
        cfg.boot_order = vm.BootOrder.fromIndex(rnd.int(usize));
        // No disk/ISO → QEMU reaches firmware then idles ("no bootable device")
        // or exits; either way we immediately kill + reap it.
        startVm(&cfg, alloc) catch continue;
        try std.testing.expect(cfg.pid != null);
        try std.testing.expect(cfg.status == .running);
        forceStopVm(&cfg); // SIGKILL the child we just spawned
        reapVm(&cfg); // waitpid → no zombie
        try std.testing.expect(cfg.pid == null);
    }
}

// ── Missing deterministic coverage ──────────────────────────────────

test "qemu: buildScriptStr with audio.none omits audio args" {
    var cfg = vm.VmConfig{};
    cfg.audio = .none;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "-audiodev"));
    try expect(!has(s, "intel-hda"));
    try expect(!has(s, "AC97"));
}

test "qemu: audio uses a portable backend, never the rarely-built sdl" {
    // Default (non-spice display): dummy `none` backend — always valid, never
    // rejected, guest still gets the sound card.
    var cfg = vm.VmConfig{};
    cfg.audio = .hda;
    cfg.display = .vnc;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-audiodev"));
    try expect(has(s, "none,id=snd0"));
    try expect(!has(s, "sdl,id=snd0"));

    // SPICE display routes audio to the SPICE client.
    var cfg2 = vm.VmConfig{};
    cfg2.audio = .ac97;
    cfg2.display = .spice;
    const s2 = try buildScriptStr(&cfg2, talloc);
    defer talloc.free(s2);
    try expect(has(s2, "spice,id=snd0"));
}

test "qemu: buildScriptStr with saved state includes -incoming" {
    var cfg = vm.VmConfig{};
    cfg.setSavedStatePath("/tmp/state.bin");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-incoming"));
    try expect(has(s, "/tmp/state.bin"));
}

test "qemu: buildScriptStr with enable_3d + gtk uses virtio-vga-gl" {
    var cfg = vm.VmConfig{};
    cfg.enable_3d = true;
    cfg.display = .gtk;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "virtio-vga-gl"));
    try expect(has(s, "gl=on"));
}

test "qemu: buildScriptStr with embed_display forces VNC" {
    var cfg = vm.VmConfig{};
    cfg.embed_display = true;
    cfg.display = .gtk;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-display"));
    try expect(has(s, "none"));
    try expect(has(s, "-vnc"));
}

test "qemu: buildScriptStr gpu virtio-gpu (non-GL)" {
    var cfg = vm.VmConfig{};
    cfg.gpu_device = .virtio_gpu;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "virtio-gpu"));
    try expect(!has(s, "virtio-vga-gl"));
    try expect(!has(s, "qxl"));
    try expect(!has(s, "gl=on")); // non-GL device must not enable GL acceleration
}

test "qemu: buildScriptStr gpu virtio-vga (non-GL)" {
    var cfg = vm.VmConfig{};
    cfg.gpu_device = .virtio_vga;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-vga"));
    // "-vga virtio" not "virtio-gpu" or "virtio-vga"
    try expect(!has(s, "virtio-gpu"));
    try expect(!has(s, "virtio-vga"));
    try expect(!has(s, "gl=on")); // non-GL device must not enable GL acceleration
}

test "qemu: buildScriptStr gpu qxl" {
    var cfg = vm.VmConfig{};
    cfg.gpu_device = .qxl;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "qxl"));
}

test "qemu: buildScriptStr gpu std-vga" {
    var cfg = vm.VmConfig{};
    cfg.gpu_device = .std_vga;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-vga"));
    try expect(has(s, "std"));
}

test "qemu: buildScriptStr 3d enabled with non-GL gpu keeps the non-GL device (no GL)" {
    var cfg = vm.VmConfig{};
    cfg.enable_3d = true;
    cfg.display = .gtk;
    cfg.gpu_device = .std_vga;
    cfg.embed_display = false;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-vga"));
    try expect(has(s, "std"));
    // enable_3d must not swap a non-GL GPU device for a virgl variant.
    try expect(!has(s, "virtio-vga-gl"));
    try expect(!has(s, "virtio-gpu-gl"));
}

test "qemu: buildScriptStr with USB device" {
    var cfg = vm.VmConfig{};
    cfg.setUsbDevice("046d:c52b");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "usb-host"));
    try expect(has(s, "046d"));
}

test "qemu: buildScriptStr with shared folder" {
    var cfg = vm.VmConfig{};
    cfg.setSharedFolder("/mnt/share");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-fsdev"));
    try expect(has(s, "virtio-9p-pci"));
    try expect(has(s, "/mnt/share"));
}

test "qemu: buildScriptStr with floppy" {
    var cfg = vm.VmConfig{};
    cfg.setFloppyPath("/tmp/floppy.img");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "if=floppy"));
    try expect(has(s, "/tmp/floppy.img"));
}

test "qemu: buildScriptStr with KVM disabled uses TCG" {
    var cfg = vm.VmConfig{};
    cfg.accel = .tcg;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "accel=tcg"));
}

test "qemu: buildScriptStr with all NICs disabled" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .none;
    cfg.nics[1].mode = .none;
    cfg.nics[2].mode = .none;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "netdev"));
    try expect(!has(s, "net0"));
    try expect(!has(s, "net1"));
    try expect(!has(s, "net2"));
}

test "qemu: buildScriptStr with spice embed" {
    var cfg = vm.VmConfig{};
    cfg.embed_display = true;
    cfg.display = .spice;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-spice"));
    try expect(has(s, "disable-ticketing"));
}

test "qemu: buildScriptStr embedded SPICE virgl uses EGL headless GL" {
    var cfg = vm.VmConfig{};
    cfg.embed_display = true;
    cfg.display = .spice;
    cfg.enable_3d = true;
    cfg.gpu_device = .virtio_vga_gl;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "egl-headless,gl=on"));
    try expect(has(s, "disable-ticketing=on,gl=on"));
    try expect(has(s, "virtio-vga-gl"));
}

test "qemu: buildScriptStr embedded VNC virgl falls back to non-GL virtio" {
    var cfg = vm.VmConfig{};
    cfg.embed_display = true;
    cfg.display = .vnc;
    cfg.enable_3d = true;
    cfg.gpu_device = .virtio_vga_gl;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-vnc"));
    try expect(!has(s, "virtio-vga-gl"));
    try expect(has(s, "virtio"));
}

test "qemu: stopVm forceStopVm with null pid are no-ops" {
    var cfg = vm.VmConfig{};
    cfg.pid = null;
    stopVm(&cfg);
    forceStopVm(&cfg);
    try expect(cfg.pid == null);
}

test "qemu: isVmAlive with null pid returns false" {
    var cfg = vm.VmConfig{};
    cfg.pid = null;
    try expect(!isVmAlive(&cfg));
}

test "qemu: reapVm with null pid is no-op" {
    var cfg = vm.VmConfig{};
    cfg.pid = null;
    reapVm(&cfg);
    try expect(cfg.pid == null);
}

test "qemu: buildScriptStr with auto resolution omits xres/yres" {
    var cfg = vm.VmConfig{};
    cfg.display_resolution = .auto;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "xres"));
    try expect(!has(s, "yres"));
}

test "qemu: buildScriptStr with specific resolution includes xres/yres" {
    var cfg = vm.VmConfig{};
    cfg.display_resolution = .res_1024x768;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "xres=1024"));
    try expect(has(s, "yres=768"));
}

test "qemu: buildScriptStr with HDA audio" {
    var cfg = vm.VmConfig{};
    cfg.audio = .hda;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "intel-hda"));
    try expect(has(s, "hda-duplex"));
    // The codec must be bound to the audiodev backend or the guest gets no sound.
    try expect(has(s, "hda-duplex,audiodev=snd0"));
}

test "qemu: buildScriptStr with AC97 audio" {
    var cfg = vm.VmConfig{};
    cfg.audio = .ac97;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "AC97"));
    // The device must be bound to the audiodev backend or the guest gets no sound.
    try expect(has(s, "AC97,audiodev=snd0"));
}

test "qemu: buildScriptStr with data disk" {
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/main.qcow2");
    cfg.setDisk2Path("/tmp/data.qcow2");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "/tmp/main.qcow2"));
    try expect(has(s, "/tmp/data.qcow2"));
}

test "qemu: buildScriptStr handles multi-socket topology" {
    var cfg = vm.VmConfig{};
    cfg.cpu_sockets = 2;
    cfg.cpu_cores = 4;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "sockets=2"));
    try expect(has(s, "cores=4"));
}

test "qemu: buildArgs rejects a name that would inject QEMU chardev properties" {
    // A comma in the name would splice extra properties into the -serial/-qmp
    // /-chardev comma-lists (CWE-88). The sink guard must refuse to build.
    var cfg = vm.VmConfig{};
    cfg.setName("evil,logfile=/tmp/pwned");
    cfg.enable_serial = true;
    try std.testing.expectError(error.UnsafeVmName, buildScriptStr(&cfg, talloc));

    // A slash would escape the socket directory.
    var cfg2 = vm.VmConfig{};
    cfg2.setName("../../etc/x");
    try std.testing.expectError(error.UnsafeVmName, buildScriptStr(&cfg2, talloc));

    // A normal name still builds.
    var ok = vm.VmConfig{};
    ok.setName("ubuntu-server");
    ok.enable_serial = true;
    const s = try buildScriptStr(&ok, talloc);
    defer talloc.free(s);
    try expect(has(s, "hangar-serial-ubuntu-server.sock"));
}

test "qemu: buildScriptStr with disk_bps_throttle emits throttling flag" {
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.disk_bps_throttle = 104857600; // 100 MB/s
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "throttling.bps-total=104857600"));
}

test "qemu: buildScriptStr with disk_iops_throttle emits throttling flag" {
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.disk_iops_throttle = 5000;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "throttling.iops-total=5000"));
}

test "qemu: buildScriptStr with both throttles emits combined flags" {
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.disk_bps_throttle = 104857600;
    cfg.disk_iops_throttle = 5000;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "throttling.bps-total=104857600"));
    try expect(has(s, "throttling.iops-total=5000"));
}

test "qemu: throttle options ride on the disk's own -drive (not a fileless drive)" {
    // Regression: a standalone `-drive throttling.*` with no file= makes QEMU
    // reject the command line. Throttle must be appended to the file= drive.
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/disk.qcow2");
    cfg.disk_bps_throttle = 104857600;
    cfg.disk_iops_throttle = 5000;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "file=/tmp/disk.qcow2,format=qcow2,if=virtio,cache=writeback,throttling.bps-total=104857600,throttling.iops-total=5000"));
}

test "qemu: buildScriptStr with hyperv_enlightenments emits hv flags" {
    var cfg = vm.VmConfig{};
    cfg.hyperv_enlightenments = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "hv_relaxed"));
    try expect(has(s, "hv_spinlocks=0x1fff"));
    try expect(has(s, "hv_vapic"));
}

test "qemu: buildScriptStr with watchdog emits watchdog args" {
    var cfg = vm.VmConfig{};
    cfg.watchdog = .reset;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    // Modern QEMU form: -device i6300esb + -action watchdog=<action>.
    try expect(has(s, "-device"));
    try expect(has(s, "i6300esb,id=watchdog0"));
    try expect(has(s, "-action"));
    try expect(has(s, "watchdog=reset"));
    // The removed legacy flags must not appear.
    try expect(!has(s, "-watchdog "));
    try expect(!has(s, "-watchdog-action"));
}

test "qemu: buildScriptStr with watchdog none omits watchdog args" {
    var cfg = vm.VmConfig{};
    cfg.watchdog = .none;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "-watchdog"));
}

test "qemu: tpm does not emit an unbootable bare tpmdev" {
    // A bare emulator tpmdev with no swtpm chardev makes QEMU reject the command
    // line. Until swtpm is wired, TPM is inert and must NOT appear in the args
    // (so the VM still boots).
    var cfg = vm.VmConfig{};
    cfg.tpm = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(!has(s, "-tpmdev"));
    try expect(!has(s, "tpm-tis"));
}

test "qemu: buildScriptStr with secure_boot enables SMM" {
    var cfg = vm.VmConfig{};
    cfg.secure_boot = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "smm=on"));
}

test "qemu: buildScriptStr with hugepages emits mem-prealloc" {
    var cfg = vm.VmConfig{};
    cfg.hugepages = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-mem-prealloc"));
    try expect(has(s, "-mem-path"));
    try expect(has(s, "/dev/hugepages"));
}

test "qemu: buildScriptStr with io_threads binds the disk to the iothread" {
    var cfg = vm.VmConfig{};
    cfg.io_threads = 1;
    cfg.setDiskPath("/tmp/d.qcow2");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "iothread,id=iothread0"));
    // The disk must actually use the iothread, not leave it idle.
    try expect(has(s, "if=none,id=hdd0"));
    try expect(has(s, "virtio-blk-pci,drive=hdd0,iothread=iothread0"));
}

test "qemu: without io_threads the disk uses the simple if=virtio form" {
    var cfg = vm.VmConfig{};
    cfg.setDiskPath("/tmp/d.qcow2");
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "if=virtio"));
    try expect(!has(s, "iothread"));
}

test "qemu: buildScriptStr with ballooning emits balloon virtio" {
    var cfg = vm.VmConfig{};
    cfg.ballooning = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "-balloon"));
    try expect(has(s, "virtio"));
}

test "qemu: buildScriptStr with virtio_rng emits rng device" {
    var cfg = vm.VmConfig{};
    cfg.virtio_rng = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "rng-random"));
    try expect(has(s, "virtio-rng-pci"));
}

test "qemu: buildScriptStr with guest_agent emits chardev and device" {
    var cfg = vm.VmConfig{};
    cfg.setName("TestGA");
    cfg.guest_agent = true;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "virtserialport"));
    try expect(has(s, "org.qemu.guest_agent.0"));
}

test "qemu: convertDiskImageNoWait builds correct args" {
    // Verify the arg list is well-formed (not executing qemu-img).
    const arg_len = countConvertArgs("/tmp/src.qcow2", .qcow2, "/tmp/dst.vmdk", .vmdk);
    try expect(arg_len >= 8); // qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized ...
    const arg_len2 = countConvertArgs("/tmp/src.qcow2", .qcow2, "/tmp/dst.qcow2", .qcow2);
    try expect(arg_len2 >= 6); // qemu-img convert -f qcow2 -O qcow2 src dest
    try expect(arg_len2 < arg_len); // vmdk has extra -o flag
}

fn countConvertArgs(src: []const u8, src_fmt: vm.DiskFormat, dst: []const u8, dst_fmt: vm.DiskFormat) usize {
    var args = buildConvertArgs(src, src_fmt, dst, dst_fmt, std.testing.allocator) catch return 0;
    defer args.deinit(std.testing.allocator);
    return args.items.len;
}

test "qemu: tryReapChild does not crash on pid 0 (process group, not a child)" {
    // waitpid(0, WNOHANG) targets the caller's process group; the result is
    // system-state dependent (null when nothing exited, a bool otherwise), so
    // the only invariant we can assert here is that it returns without crashing.
    const result = tryReapChild(0);
    _ = result;
}

test "qemu: tryReapChild does not crash on pid -1 (reap any child)" {
    // waitpid(-1, WNOHANG) may find no exited children (null) or reap a
    // background child (a bool) — both are valid and ordering-dependent, so we
    // only assert the call completes without crashing.
    const result = tryReapChild(-1);
    _ = result;
}
