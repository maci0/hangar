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
//! that their slices remain valid through the `child.spawn()` call.

const std = @import("std");
const vm = @import("vm.zig");
const appio = @import("appio.zig");

const W = std.posix.W;

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
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (!W.IFEXITED(ustatus) or W.EXITSTATUS(ustatus) != 0) {
        return QemuError.ProcessFailed;
    }
}

/// Run `argv`, capturing its stdout into `out`. Returns the number of bytes
/// written (truncated to `out.len`). Returns an error unless it exits 0.
/// stderr/stdin are sent to /dev/null.
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
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    if (!W.IFEXITED(ustatus) or W.EXITSTATUS(ustatus) != 0) return QemuError.ProcessFailed;
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
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
        }
        if (err_path) |path| {
            const errfd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
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
fn findVirtioWinIso() ?[]const u8 {
    for (virtio_win_search_paths) |path| {
        if (std.Io.Dir.cwd().access(appio.io(), path, .{})) return path else |_| {}
    }
    if (appio.getenv("HOME")) |home| {
        const buf = struct {
            var b: [vm.MAX_PATH + 1]u8 = undefined;
        };
        const p = std.fmt.bufPrint(&buf.b, "{s}/Downloads/virtio-win.iso", .{home}) catch return null;
        if (std.Io.Dir.cwd().access(appio.io(), p, .{})) return p else |_| {}
    }
    return null;
}

/// Formatting buffers for QEMU arguments.
///
/// These must outlive the `spawn()` call because Zig's `Child.init` stores
/// slices by reference — if the buffers were stack-local inside `buildArgs`,
/// they'd be freed before `spawn()` reads them.
const ArgBuffers = struct {
    mach_buf: [64]u8 = undefined,
    smp_buf: [32]u8 = undefined,
    mem_buf: [32]u8 = undefined,
    disk_buf: [vm.MAX_PATH + 64]u8 = undefined,
    cdrom_buf: [vm.MAX_PATH + 64]u8 = undefined,
    tools_buf: [vm.MAX_PATH + 64]u8 = undefined,
    vnc_buf: [64]u8 = undefined,
    spice_buf: [128]u8 = undefined,
    serial_buf: [vm.MAX_PATH + 64]u8 = undefined,
    qmp_buf: [vm.MAX_PATH + 64]u8 = undefined,
    vga_buf: [64]u8 = undefined,
    net_mac_buf: [128]u8 = undefined,
    netdev_user_buf: [1024]u8 = undefined,
    boot_buf: [64]u8 = undefined,
    incoming_buf: [vm.MAX_PATH + 64]u8 = undefined,
    shared_buf: [vm.MAX_PATH + 128]u8 = undefined,
    disk2_buf: [vm.MAX_PATH + 64]u8 = undefined,
    usb_buf: [128]u8 = undefined,
    nic_dev_buf: [vm.MAX_NICS][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** vm.MAX_NICS,
    floppy_buf: [vm.MAX_PATH + 64]u8 = undefined,
    disp_buf: [32]u8 = undefined,
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
    if (mac.len > 0) {
        const dev = std.fmt.bufPrint(dev_buf, "virtio-net-pci,netdev={s},mac={s}", .{ id, mac }) catch "virtio-net-pci";
        try args.append(alloc, dev);
    } else {
        const dev = std.fmt.bufPrint(dev_buf, "virtio-net-pci,netdev={s}", .{id}) catch "virtio-net-pci";
        try args.append(alloc, dev);
    }
    try args.append(alloc, "-netdev");
    switch (mode) {
        .user => {
            const nd = std.fmt.bufPrint(dev_buf[64..], "user,id={s}", .{id}) catch "user,id=net1";
            try args.append(alloc, nd);
        },
        .bridge => {
            const nd = std.fmt.bufPrint(dev_buf[64..], "bridge,id={s},br=br0", .{id}) catch "bridge,id=net1,br=br0";
            try args.append(alloc, nd);
        },
        .none => {
            // caller should filter .none before calling buildNetdev
            return;
        },
    }
}

/// Populates an ArrayList with QEMU arguments.
fn buildArgs(config: *const vm.VmConfig, args: *std.ArrayList([]const u8), alloc: std.mem.Allocator, bufs: *ArgBuffers) !void {
    try args.append(alloc, "qemu-system-x86_64");

    // Resolve accelerator: TCG → software, all others → hardware with host CPU.
    const is_tcg = config.accel == .tcg;
    const accel_flag = config.accel.toStr();
    try args.append(alloc, "-machine");
    const mach_str = try std.fmt.bufPrint(&bufs.mach_buf, "type=q35,accel={s}", .{std.mem.span(accel_flag)});
    try args.append(alloc, mach_str);
    try args.append(alloc, "-cpu");
    try args.append(alloc, if (is_tcg) "qemu64" else "host");

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
        const disk_str = try std.fmt.bufPrint(&bufs.disk_buf, "file={s},format={s},if=virtio", .{
            config.getDiskPathSlice(),
            std.mem.span(config.disk_format.toStr()),
        });
        try args.append(alloc, "-drive");
        try args.append(alloc, disk_str);
    }

    // Optional second (data) disk, attached as another virtio drive.
    if (config.hasDisk2()) {
        const disk2_str = try std.fmt.bufPrint(&bufs.disk2_buf, "file={s},format={s},if=virtio", .{
            config.getDisk2PathSlice(),
            std.mem.span(config.disk2_format.toStr()),
        });
        try args.append(alloc, "-drive");
        try args.append(alloc, disk2_str);
    }

    // Optional floppy drive (drive A:), raw image.
    if (config.hasFloppy()) {
        const fd_str = try std.fmt.bufPrint(&bufs.floppy_buf, "file={s},if=floppy,format=raw", .{config.getFloppyPathSlice()});
        try args.append(alloc, "-drive");
        try args.append(alloc, fd_str);
    }

    // Use an explicit ide-cd device with a stable id ("ide2-cd0") so that
    // QMP `change ide2-cd0` can hot-swap the ISO without rebooting.
    try args.append(alloc, "-device");
    try args.append(alloc, "ide-cd,drive=cdrom0,id=ide2-cd0");
    if (config.hasIso()) {
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
        if (findVirtioWinIso()) |iso| {
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

    if (config.embed_display) {
        // When embedding the display inside our app, QEMU must not open
        // its own window — we set `-display none` and connect as a
        // VNC/SPICE client instead.
        try args.append(alloc, "-display");
        try args.append(alloc, "none");
        if (config.display == .spice) {
            const spice_str = try std.fmt.bufPrint(&bufs.spice_buf, "port={d},disable-ticketing=on", .{config.spice_port});
            try args.append(alloc, "-spice");
            try args.append(alloc, spice_str);
        } else {
            // VNC display number = port - 5900.  Saturate to 0 if port < 5900
            // to prevent u16 underflow (panic in debug, UB in release).
            const vnc_display: u16 = if (config.vnc_port >= 5900) config.vnc_port - 5900 else 0;
            const vnc_str = try std.fmt.bufPrint(&bufs.vnc_buf, "localhost:{d}", .{vnc_display});
            try args.append(alloc, "-vnc");
            try args.append(alloc, vnc_str);
        }
    } else {
        try args.append(alloc, "-display");
        // 3D acceleration (virgl) needs a GL-capable native display.
        if (config.enable_3d and (config.display == .gtk or config.display == .sdl)) {
            const disp_str = try std.fmt.bufPrint(&bufs.disp_buf, "{s},gl=on", .{std.mem.span(config.display.toStr())});
            try args.append(alloc, disp_str);
        } else {
            try args.append(alloc, std.mem.span(config.display.toStr()));
        }
    }

    // GPU device selection:
    // .virtio-gpu-gl → virtio-gpu with virglrenderer (modern, preferred for 3D)
    // .virtio-vga-gl → virtio-vga with virglrenderer (compatible, legacy 3D)
    // .virtio        → standard virtio VGA (no 3D)
    // Plain embedded VNC can't show GL output, so 3D requires native/spice display.
    const gl_ok = config.enable_3d and (config.display == .gtk or config.display == .sdl or config.display == .spice);
    if (gl_ok and config.gpu_device == .virtio_gpu_gl) {
        if (config.display_resolution == .auto) {
            try args.append(alloc, "-device");
            try args.append(alloc, "virtio-gpu-gl");
        } else {
            const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "virtio-gpu-gl,xres={d},yres={d}", .{ config.display_resolution.xres(), config.display_resolution.yres() });
            try args.append(alloc, "-device");
            try args.append(alloc, vga_str);
        }
    } else if (gl_ok) {
        if (config.display_resolution == .auto) {
            try args.append(alloc, "-device");
            try args.append(alloc, "virtio-vga-gl");
        } else {
            const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "virtio-vga-gl,xres={d},yres={d}", .{ config.display_resolution.xres(), config.display_resolution.yres() });
            try args.append(alloc, "-device");
            try args.append(alloc, vga_str);
        }
    } else if (config.display_resolution == .auto) {
        try args.append(alloc, "-vga");
        try args.append(alloc, "virtio");
    } else {
        const vga_str = try std.fmt.bufPrint(&bufs.vga_buf, "virtio-vga,xres={d},yres={d}", .{ config.display_resolution.xres(), config.display_resolution.yres() });
        try args.append(alloc, "-device");
        try args.append(alloc, vga_str);
    }

    // Additional displays for multi-monitor support.
    var disp_n: u32 = 1;
    while (disp_n < config.num_displays) : (disp_n += 1) {
        try args.append(alloc, "-device");
        try args.append(alloc, "virtio-gpu");
    }

    if (config.enable_serial and config.hasName()) {
        const serial_str = try std.fmt.bufPrint(&bufs.serial_buf, "unix:/tmp/kvmgui-serial-{s}.sock,server=on,wait=off", .{config.getNameSlice()});
        try args.append(alloc, "-serial");
        try args.append(alloc, serial_str);
    }

    if (config.hasName()) {
        const qmp_str = try std.fmt.bufPrint(&bufs.qmp_buf, "unix:/tmp/kvmgui-qmp-{s}.sock,server=on,wait=off", .{config.getNameSlice()});
        try args.append(alloc, "-qmp");
        try args.append(alloc, qmp_str);
    }

    switch (config.nics[0].mode) {
        .user => {
            try args.append(alloc, "-device");
            if (config.hasMacAddress()) {
                const mac_str = std.fmt.bufPrint(&bufs.net_mac_buf, "virtio-net-pci,netdev=net0,mac={s}", .{config.getMacAddressSlice()}) catch "virtio-net-pci,netdev=net0";
                try args.append(alloc, mac_str);
            } else {
                try args.append(alloc, "virtio-net-pci,netdev=net0");
            }
            try args.append(alloc, "-netdev");

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
                    const chunk = std.fmt.bufPrint(fwd_str[offset..], ",hostfwd=tcp::{s}-:{s}", .{ host, guest }) catch break;
                    offset += chunk.len;
                }
                try args.append(alloc, fwd_str[0..offset]);
            } else {
                try args.append(alloc, "user,id=net0");
            }
        },
        .bridge => {
            try args.append(alloc, "-device");
            if (config.hasMacAddress()) {
                const mac_str = std.fmt.bufPrint(&bufs.net_mac_buf, "virtio-net-pci,netdev=net0,mac={s}", .{config.getMacAddressSlice()}) catch "virtio-net-pci,netdev=net0";
                try args.append(alloc, mac_str);
            } else {
                try args.append(alloc, "virtio-net-pci,netdev=net0");
            }
            try args.append(alloc, "-netdev");
            try args.append(alloc, "bridge,id=net0,br=br0");
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

    switch (config.audio) {
        .hda => {
            try args.append(alloc, "-device");
            try args.append(alloc, "intel-hda");
            try args.append(alloc, "-device");
            try args.append(alloc, "hda-duplex");
            try args.append(alloc, "-audiodev");
            try args.append(alloc, "sdl,id=snd0");
        },
        .ac97 => {
            try args.append(alloc, "-device");
            try args.append(alloc, "AC97");
            try args.append(alloc, "-audiodev");
            try args.append(alloc, "sdl,id=snd0");
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

    // USB tablet provides absolute pointing so the guest cursor matches
    // the host cursor position — essential for embedded VNC/SPICE where
    // relative mouse input would desync.
    try args.append(alloc, "-device");
    try args.append(alloc, "qemu-xhci");
    try args.append(alloc, "-device");
    try args.append(alloc, "usb-tablet");

    // USB device passthrough. The field holds "vendorid:productid" in hex
    // (e.g. "046d:c52b"). The q35 machine already provides a USB controller.
    if (config.hasUsbDevice()) {
        const spec = config.getUsbDeviceSlice();
        if (std.mem.indexOfScalar(u8, spec, ':')) |sep| {
            const vendor = spec[0..sep];
            const product = spec[sep + 1 ..];
            const usb_str = try std.fmt.bufPrint(&bufs.usb_buf, "usb-host,vendorid=0x{s},productid=0x{s}", .{ vendor, product });
            try args.append(alloc, "-device");
            try args.append(alloc, usb_str);
        }
    }

    // Shared folder via virtio-9p: mounts a host directory into the guest.
    // Guest mounts with: mount -t 9p -o trans=virtio shared /mnt/shared
    if (config.hasSharedFolder()) {
        const shared_str = try std.fmt.bufPrint(&bufs.shared_buf, "local,id=shared0,path={s},security_model=mapped-xattr", .{config.getSharedFolderSlice()});
        try args.append(alloc, "-fsdev");
        try args.append(alloc, shared_str);
        try args.append(alloc, "-device");
        try args.append(alloc, "virtio-9p-pci,fsdev=shared0,mount_tag=shared");
    }
}

/// Start a QEMU process for the given VM configuration.
/// QEMU stderr is written to /var/tmp/kvmgui-vm-<name>.log for diagnostics.
pub fn startVm(config: *vm.VmConfig, allocator: std.mem.Allocator) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var bufs = ArgBuffers{};
    try buildArgs(config, &args, allocator, &bufs);

    // Build stderr log path from the VM name.
    var err_path_buf: [128]u8 = undefined;
    const err_path: ?[:0]const u8 = if (config.hasName()) blk: {
        const path = std.fmt.bufPrintZ(&err_path_buf, "/var/tmp/kvmgui-vm-{s}.log", .{config.getNameSlice()}) catch break :blk null;
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

    try out.appendSlice(allocator, "#!/bin/bash\n\n# KVMGUI Exported VM Launch Script\n");
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
    _ = std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
}

/// Send SIGKILL to the QEMU process. Does not block or reap.
pub fn forceStopVm(config: *const vm.VmConfig) void {
    const pid = config.pid orelse return;
    _ = std.posix.kill(@intCast(pid), std.posix.SIG.KILL) catch {};
}

/// Check if the QEMU process is still running. If it exited, reaps it
/// and clears the PID and status.
pub fn isVmAlive(config: *vm.VmConfig) bool {
    const pid = config.pid orelse return false;

    // Use waitpid with WNOHANG to check status without blocking.
    var status: c_int = 0;
    const reaped = std.c.waitpid(@intCast(pid), &status, W.NOHANG);
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
            "-f", std.mem.span(src_format.toStr()),
            "-O", dest_str,
            "-o", "subformat=streamOptimized",
            src_path,
            dest_path,
        };
        runWait(&args, allocator, null) catch return QemuError.DiskImageCreationFailed;
    } else {
        const args = [_][]const u8{
            "qemu-img", "convert",
            "-f", std.mem.span(src_format.toStr()),
            "-O", dest_str,
            src_path,
            dest_path,
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
    const r = std.c.waitpid(pid, &status, W.NOHANG);
    if (r == 0) return null;                   // still running
    if (r < 0) return false;                   // error / already reaped
    const ustatus: u32 = @bitCast(status);
    if (!W.IFEXITED(ustatus)) return false;
    return W.EXITSTATUS(ustatus) == 0;
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
            ';', '|', '&', '$', '`', '(', ')', '<', '>', '\'', '"', '\\', '\n', '\r', '\t', 0 => return false,
            else => {},
        }
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
    try std.testing.expect(isSafeShellPath("/home/user/VM Data/state.bin"));
    try std.testing.expect(!isSafeShellPath("bad; rm -rf /"));
    try std.testing.expect(!isSafeShellPath("bad$(id)"));
    try std.testing.expect(!isSafeShellPath("bad`id`"));
    try std.testing.expect(!isSafeShellPath("bad|cat /etc/passwd"));
    try std.testing.expect(!isSafeShellPath("bad\"quotes"));
    try std.testing.expect(!isSafeShellPath(""));
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
        c.vnc_port = rnd.int(u16);
        c.spice_port = rnd.int(u16);
        c.disk_format = vm.DiskFormat.fromIndex(rnd.int(usize));
        c.disk2_format = vm.DiskFormat.fromIndex(rnd.int(usize));
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

test "qemu: bridge network + UEFI firmware flags" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .bridge;
    cfg.firmware = .uefi;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "bridge,id=net0,br=br0"));
    // UEFI selects OVMF via -bios (path comes from findOvmfPath; flag always present).
    try expect(has(s, "-bios"));
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

test "qemu: extra NICs add net1/net2 devices" {
    var cfg = vm.VmConfig{};
    cfg.nics[0].mode = .user;
    cfg.nics[1].mode = .user;
    cfg.nics[2].mode = .bridge;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "net1"));
    try expect(has(s, "net2"));
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
    _ = findVirtioWinIso();
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
    createDiskImage("/tmp/kvmgui-qprobe.qcow2", 1, .qcow2, alloc) catch {
        return; // no qemu-img → nothing to fuzz here
    };
    _ = std.Io.Dir.cwd().deleteFile(appio.io(), "/tmp/kvmgui-qprobe.qcow2") catch {};

    var prng = std.Random.DefaultPrng.init(0xD15C_F0FF);
    const rnd = prng.random();
    var path_buf: [96]u8 = undefined;
    var name_buf: [40]u8 = undefined;
    var listbuf: [4096]u8 = undefined;

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/kvmgui-qfuzz-{d}-{d}.qcow2", .{ std.c.getpid(), i }) catch continue;
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
        const clone = std.fmt.bufPrintZ(&clone_buf, "/tmp/kvmgui-qclone-{d}-{d}.qcow2", .{ std.c.getpid(), i }) catch continue;
        createLinkedClone(clone, path, fmt, alloc) catch {};
        _ = std.Io.Dir.cwd().deleteFile(appio.io(), clone) catch {};

        // convert to VMDK (stream-optimized) — exercises convertDiskImage
        var vmdk_buf: [96]u8 = undefined;
        const vmdk = std.fmt.bufPrintZ(&vmdk_buf, "/tmp/kvmgui-qconv-{d}-{d}.vmdk", .{ std.c.getpid(), i }) catch continue;
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
}

test "qemu: buildScriptStr with AC97 audio" {
    var cfg = vm.VmConfig{};
    cfg.audio = .ac97;
    const s = try buildScriptStr(&cfg, talloc);
    defer talloc.free(s);
    try expect(has(s, "AC97"));
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
