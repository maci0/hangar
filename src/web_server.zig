//! KVMGUI — Web Frontend (HTTP server + HTML/CSS UI)
//! Serves a VMware WS7-style UI via embedded HTTP server.
//! Open http://localhost:9080 in any browser.
const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const ws = @import("ws.zig");
const usock = @import("usock.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const appio = @import("appio.zig");

const MAX_VMS = 64;
var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var prefs: vm.Prefs = .{};

const PORT: u16 = 9080;
const BIND_ADDR: [4]u8 = .{ 0, 0, 0, 0 }; // 0.0.0.0 — accessible remotely
var auth_token: [64]u8 = [_]u8{0} ** 64;
var auth_token_len: usize = 0;

// HV abstraction — QEMU backend dispatch table
var g_vmm: hv_iface.Vmm = undefined;
var g_vmm_handles: [MAX_VMS]?hv_iface.VmmHandle = [_]?hv_iface.VmmHandle{null} ** MAX_VMS;

/// Get or create the Vmm handle for VM at index idx.
fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        const mode: hv_backend.AccelMode = if (vms[idx].enable_kvm) .auto else .force_tcg;
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], mode, std.heap.page_allocator) catch return null;
    }
    return g_vmm_handles[idx];
}

/// Destroy the Vmm handle for VM at index idx.
fn destroyVmmHandle(idx: usize) void {
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
}

const c = std.c;

// POSIX networking constants (not in std.c in Zig 0.16)
const AF_INET: c_uint = 2;
const SOCK_STREAM: c_int = 1;
const AF_UNIX: c_uint = 1;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const SHUT_WR: c_int = 1;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 2048;

fn acceptLoop(fd: c.fd_t) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) continue;
        _ = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
    }
}

fn serveHtml(conn: c.fd_t) void {
    defer _ = c.close(conn);
    var buf: [4096]u8 = undefined;
    const n = c.read(conn, &buf, buf.len);
    if (n <= 0) return;
    const req = buf[0..@intCast(n)];

    // ── WebSocket VNC Proxy ──
    if (std.mem.startsWith(u8, req, "GET /ws/vnc/")) {
        handleWsVnc(conn, req) catch {};
        return;
    }

    // ── WebSocket Serial Console ──
    if (std.mem.startsWith(u8, req, "GET /ws/serial/")) {
        handleWsSerial(conn, req) catch {};
        return;
    }

    // Route: GET / → index page, GET /api/vms → JSON, POST /api/power/{idx} → toggle
    var response: []const u8 = "";
    var content_type: []const u8 = "text/html";

    if (std.mem.startsWith(u8, req, "GET /api/vms")) {
        content_type = "application/json";
        response = try renderJson();
    } else if (std.mem.startsWith(u8, req, "GET /api/health")) {
        response = "{\"status\":\"ok\",\"version\":\"1.0\"}";
        content_type = "application/json";
    } else if (std.mem.startsWith(u8, req, "GET /api/config")) {
        content_type = "application/json";
        response = try serveConfigRaw();
    } else if (std.mem.startsWith(u8, req, "GET /api/vm/")) {
        content_type = "application/json";
        response = try renderVmDetail(req);
    } else if (std.mem.startsWith(u8, req, "POST /api/power/")) {
        response = try handlePower(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/new")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/delete/")) {
        response = try handleDelete(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/fb/")) {
        response = try renderFramebuffer(req);
        content_type = "image/bmp";
    } else if (std.mem.startsWith(u8, req, "POST /api/clone/")) {
        response = try handleClone(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/save/")) {
        response = try handleSave(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/save")) {
        persist.save(&vms, vm_count, prefs) catch {};
        response = "saved";
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/create")) {
        response = try handleNewVm(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/suspend/")) {
        response = try handleSuspend(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/shutdown/")) {
        response = try handleShutdown(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/reset/")) {
        response = try handleReset(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/take/")) {
        response = try handleSnapshotTake(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "GET /api/snapshot/list/")) {
        response = try handleSnapshotList(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/revert/")) {
        response = try handleSnapshotRevert(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/snapshot/delete/")) {
        response = try handleSnapshotDelete(req);
        content_type = "text/plain";
    } else if (std.mem.startsWith(u8, req, "POST /api/import")) {
        response = try handleImport(req);
        content_type = "text/plain";
    } else {
        response = index_html;
        content_type = "text/html; charset=utf-8";
    }

    _ = c.write(conn, @ptrCast("HTTP/1.1 200 OK\r\nContent-Type: "), 36);
    _ = c.write(conn, content_type.ptr, content_type.len);
    _ = c.write(conn, @ptrCast("\r\nContent-Length: "), 18);
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{response.len}) catch "0";
    _ = c.write(conn, len_str.ptr, len_str.len);
    _ = c.write(conn, @ptrCast("\r\nConnection: close\r\n\r\n"), 25);
    _ = c.write(conn, response.ptr, response.len);
}

/// Return the raw vms.json content for remote clients to sync their state.
fn serveConfigRaw() ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const home = appio.getenv("HOME") orelse return "{}";
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/kvmgui/vms.json", .{home}) catch return "{}";
    return std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        path,
        std.heap.page_allocator,
        .limited(10 * 1024 * 1024),
    ) catch return "{}";
}

var fb_client: ?*vnc.VncClient = null;
// BMP output buffer — 54-byte header + up to 1 MB of pixel data
var fb_bmp_buf: [1024 * 1024 + 54]u8 = undefined;

/// Handle WebSocket VNC proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's VNC port,
/// and spawns bidirectional relay threads.
fn handleWsVnc(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/vnc/<idx>
    const prefix = "GET /ws/vnc/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.isAlive()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's VNC server.
    const vnc_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (vnc_fd < 0) return;
    defer _ = c.close(vnc_fd);

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, v.vnc_port);
    addr.addr = std.mem.nativeToBig(u32, @bitCast([4]u8{ 127, 0, 0, 1 }));

    if (c.connect(vnc_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        try ws.writeClose(conn);
        return;
    }

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        vnc_fd: c.fd_t,
    };
    var ctx = RelayCtx{ .ws_fd = conn, .vnc_fd = vnc_fd };

    // Thread: VNC → WebSocket
    const vnc2ws = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.vnc_fd, &buf, buf.len);
                if (n <= 0) break;
                // Send shutdown signal to peer via empty write
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch break;
            }
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    // Thread: WebSocket → VNC
    const ws2vnc = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ws.writePong(ctx_ptr.ws_fd) catch break;
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                _ = c.write(ctx_ptr.vnc_fd, buf[0..rlen].ptr, rlen);
            }
            _ = c.shutdown(ctx_ptr.vnc_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    vnc2ws.join();
    ws2vnc.join();
}

/// Handle WebSocket Serial Console proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's serial
/// Unix socket, and spawns bidirectional relay threads.
fn handleWsSerial(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/serial/<idx>
    const prefix = "GET /ws/serial/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.isAlive() or !v.enable_serial or !v.hasName()) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/kvmgui-serial-{s}.sock",
        .{v.getNameSlice()},
    ) catch return;

    const serial = usock.UnixStream.connect(sock_path) catch return;
    defer serial.close();

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        serial_fd: c.fd_t,
    };
    var ctx = RelayCtx{ .ws_fd = conn, .serial_fd = serial.fd };

    // Thread: serial → WebSocket
    const ser2ws = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.serial_fd, &buf, buf.len);
                if (n <= 0) break;
                ws.writeFrame(ctx_ptr.ws_fd, .text, buf[0..@intCast(n)]) catch break;
            }
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    // Thread: WebSocket → serial
    const ws2ser = try std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    ws.writePong(ctx_ptr.ws_fd) catch break;
                    continue;
                }
                if (hdr.opcode == .pong) continue;
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                _ = c.write(ctx_ptr.serial_fd, buf[0..rlen].ptr, rlen);
            }
            _ = c.shutdown(ctx_ptr.serial_fd, SHUT_WR);
        }
    }.run, .{&ctx});

    ser2ws.join();
    ws2ser.join();
}

fn renderFramebuffer(req: []const u8) ![]const u8 {
    // GET /api/fb/N — return the framebuffer for VM N as a valid BMP image
    const prefix = "GET /api/fb/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid idx";
    if (idx >= vm_count) return "no vm";
    const v = &vms[idx];
    if (!v.isAlive()) return "off";

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
    }
    const vc = fb_client.?;
    if (!vc.isConnected()) {
        _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0; var fh: c_int = 0;
        if (vc.getSize(&fw, &fh)) {
            const pixel_size: usize = @intCast(@as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4);
            const copy_size = @min(pixel_size, fb_bmp_buf.len - 54);
            const file_size: u32 = @intCast(54 + copy_size);

            // ── BITMAPFILEHEADER (14 bytes) ──────────────────────
            fb_bmp_buf[0] = 'B';
            fb_bmp_buf[1] = 'M';
            std.mem.writeInt(u32, fb_bmp_buf[2..6], file_size, .little); // bfSize
            std.mem.writeInt(u32, fb_bmp_buf[6..10], 0, .little);        // bfReserved
            std.mem.writeInt(u32, fb_bmp_buf[10..14], 54, .little);      // bfOffBits

            // ── BITMAPINFOHEADER (40 bytes) ──────────────────────
            @memset(fb_bmp_buf[14..54], 0); // zero-fill then set fields
            std.mem.writeInt(u32, fb_bmp_buf[14..18], 40, .little);     // biSize
            std.mem.writeInt(i32, fb_bmp_buf[18..22], fw, .little);      // biWidth
            std.mem.writeInt(i32, fb_bmp_buf[22..26], -fh, .little);     // biHeight (negative = top-down)
            std.mem.writeInt(u16, fb_bmp_buf[26..28], 1, .little);       // biPlanes
            std.mem.writeInt(u16, fb_bmp_buf[28..30], 32, .little);      // biBitCount
            // biCompression = 0 (BI_RGB), biSizeImage = 0 (OK for BI_RGB)
            // biXPelsPerMeter = biYPelsPerMeter = 2835 (~72 DPI)
            std.mem.writeInt(u32, fb_bmp_buf[38..42], 2835, .little);
            std.mem.writeInt(u32, fb_bmp_buf[42..46], 2835, .little);

            // ── Pixel data ───────────────────────────────────────
            @memcpy(fb_bmp_buf[54..][0..copy_size], @as([*]const u8, @ptrCast(pixels))[0..copy_size]);
            return fb_bmp_buf[0 .. 54 + copy_size];
        }
    }
    return "no fb";
}

fn renderVmDetail(req: []const u8) ![]const u8 {
    const prefix = "GET /api/vm/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "{}";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "{}";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "{}";
    if (idx >= vm_count) return "{}";
    const v = &vms[idx];
    var buf: [3072]u8 = undefined;
    var w: usize = 0;

    // First 32 fields
    const part1 = std.fmt.bufPrint(buf[w..],
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
    , .{
        idx, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
        v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
        std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
        if (v.hasIso()) v.getIsoPathSlice() else "",
        if (v.hasNotes()) v.getNotesSlice() else "",
        if (v.hasSharedFolder()) v.getSharedFolderSlice() else "",
        if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "",
        if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false",
        v.autoprotect_interval_min, v.autoprotect_max,
        if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
        if (v.hasDisk2()) v.getDisk2PathSlice() else "",
        v.disk2_format.toIndex(),
        if (v.hasFloppy()) "true" else "false",
        if (v.hasFloppy()) v.getFloppyPathSlice() else "",
        if (v.hasPortForwards()) v.getPortForwardsSlice() else "",
    }) catch return "{}";
    w += part1.len;

    // Remaining fields
    const part2 = std.fmt.bufPrint(buf[w..],
        \\,"mac":"{s}","mac_address":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"enable_kvm":{s},"embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s}}}
    , .{
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        std.mem.span(v.nics[1].mode.toStr()),
        if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
        std.mem.span(v.nics[2].mode.toStr()),
        if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
        v.num_displays,
        if (v.enable_serial) "true" else "false",
        if (v.enable_3d) "true" else "false",
        v.gpu_device.toIndex(),
        v.display.toIndex(),
        v.display_resolution.toIndex(),
        v.guest_os.toIndex(),
        v.audio.toIndex(),
        v.boot_order.toIndex(),
        if (v.enable_kvm) "true" else "false",
        if (v.embed_display) "true" else "false",
        v.vnc_port,
        v.spice_port,
        if (v.favorite) "true" else "false",
    }) catch return "{}";
    w += part2.len;
    return buf[0..w];
}

fn renderJson() ![]const u8 {
    var json_buf: [24576]u8 = undefined;
    var w: usize = 0;
    @memcpy(json_buf[w..][0..1], "[");
    w += 1;
    for (0..vm_count) |i| {
        if (i > 0) { json_buf[w] = ','; w += 1; }
        const v = &vms[i];

        // First block: up through port_forwards
        const part1 = std.fmt.bufPrint(json_buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}"
        , .{
            i, v.getNameSlice(), std.mem.span(v.status.toStr()), std.mem.span(v.guest_os.toStr()),
            v.memory_mb, v.cpu_cores, v.cpu_sockets, v.disk_size_gb, v.disk_format.toIndex(),
            std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false", if (v.hasDisk()) "true" else "false",
            if (v.hasIso()) v.getIsoPathSlice() else "",
            if (v.hasNotes()) v.getNotesSlice() else "",
            if (v.hasSharedFolder()) v.getSharedFolderSlice() else "",
            if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "",
            if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false",
            v.autoprotect_interval_min, v.autoprotect_max,
            if (v.hasDisk2()) "true" else "false", v.disk2_size_gb,
            if (v.hasDisk2()) v.getDisk2PathSlice() else "",
            v.disk2_format.toIndex(),
            if (v.hasFloppy()) "true" else "false",
            if (v.hasFloppy()) v.getFloppyPathSlice() else "",
            if (v.hasPortForwards()) v.getPortForwardsSlice() else "",
        }) catch break;
        w += part1.len;

        // Remaining fields
        const part2 = std.fmt.bufPrint(json_buf[w..],
            \\,"mac":"{s}","mac_address":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"enable_kvm":{s},"embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s}}}
        , .{
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            std.mem.span(v.nics[1].mode.toStr()),
            if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
            std.mem.span(v.nics[2].mode.toStr()),
            if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
            v.num_displays,
            if (v.enable_serial) "true" else "false",
            if (v.enable_3d) "true" else "false",
            v.gpu_device.toIndex(),
            v.display.toIndex(),
            v.display_resolution.toIndex(),
            v.guest_os.toIndex(),
            v.audio.toIndex(),
            v.boot_order.toIndex(),
            if (v.enable_kvm) "true" else "false",
            if (v.embed_display) "true" else "false",
            v.vnc_port,
            v.spice_port,
            if (v.favorite) "true" else "false",
        }) catch break;
        w += part2.len;
    }
    json_buf[w] = ']';
    w += 1;
    return json_buf[0..w];
}

fn handlePower(req: []const u8) ![]const u8 {
    // Extract idx from /api/power/N
    const prefix = "POST /api/power/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (v.isAlive()) {
        if (getVmmHandle(idx)) |h| {
            g_vmm.forceStopFn(h);
            g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(v);
            qemu.reapVm(v);
        }
        destroyVmmHandle(idx);
    } else {
        if (getVmmHandle(idx)) |h| {
            g_vmm.startFn(h, @ptrCast(v)) catch {};
        } else {
            qemu.startVm(v, std.heap.page_allocator) catch {};
        }
    }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleNewVm(req: []const u8) ![]const u8 {
    if (vm_count >= MAX_VMS) return "full";
    // Parse body: name=...&mem=...&cpu=...&disk=...
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    var cfg = vm.VmConfig{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) cfg.setName(val);
        if (std.mem.eql(u8, key, "mem")) cfg.memory_mb = std.fmt.parseInt(u32, val, 10) catch 2048;
        if (std.mem.eql(u8, key, "cpu")) cfg.cpu_cores = std.fmt.parseInt(u32, val, 10) catch 2;
        if (std.mem.eql(u8, key, "disk")) cfg.disk_size_gb = std.fmt.parseInt(u32, val, 10) catch 20;
    }
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleClone(req: []const u8) ![]const u8 {
    const prefix = "POST /api/clone/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count or vm_count >= MAX_VMS) return "full";
    var clone = vms[idx];
    var name_buf: [256]u8 = undefined;
    const cn = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{clone.getNameSlice()}) catch return "nameerr";
    clone.setName(cn);
    clone.status = .stopped;
    clone.pid = null;
    clone.vnc_port = 5900 + @as(u16, @intCast(vm_count));
    clone.spice_port = 5930 + @as(u16, @intCast(vm_count));
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    clone.setMacAddress(std.mem.span(mac));
    vms[vm_count] = clone;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleDelete(req: []const u8) ![]const u8 {
    const prefix = "POST /api/delete/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    // Shift remaining
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) vms[i] = vms[i + 1];
    vm_count -= 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleSave(req: []const u8) ![]const u8 {
    const prefix = "POST /api/save/";
    const start = std.mem.indexOf(u8, req, prefix) orelse return "invalid";
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "invalid";
    const idx = std.fmt.parseInt(usize, rest[0..end], 10) catch return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const v = &vms[idx];
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "name")) v.setName(val);
        if (std.mem.eql(u8, key, "mem")) v.memory_mb = std.fmt.parseInt(u32, val, 10) catch v.memory_mb;
        if (std.mem.eql(u8, key, "cpu")) v.cpu_cores = std.fmt.parseInt(u32, val, 10) catch v.cpu_cores;
        if (std.mem.eql(u8, key, "cpu_sockets")) v.cpu_sockets = std.fmt.parseInt(u32, val, 10) catch v.cpu_sockets;
        if (std.mem.eql(u8, key, "disk")) v.disk_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk_size_gb;
        if (std.mem.eql(u8, key, "disk_format")) v.disk_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk_format.toIndex());
        if (std.mem.eql(u8, key, "iso_path")) v.setIsoPath(val);
        if (std.mem.eql(u8, key, "mac_address")) v.setMacAddress(val);
        if (std.mem.eql(u8, key, "network")) v.nics[0].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "firmware")) v.firmware = vm.BootFirmware.fromStr(val);
        if (std.mem.eql(u8, key, "shared_folder")) v.setSharedFolder(val);
        if (std.mem.eql(u8, key, "usb")) v.setUsbDevice(val);
        if (std.mem.eql(u8, key, "guest_tools")) v.guest_tools = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "autoprotect")) v.autoprotect = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "ap_interval")) v.autoprotect_interval_min = std.fmt.parseInt(u32, val, 10) catch v.autoprotect_interval_min;
        if (std.mem.eql(u8, key, "ap_max")) v.autoprotect_max = std.fmt.parseInt(u32, val, 10) catch v.autoprotect_max;
        if (std.mem.eql(u8, key, "disk2_path")) v.setDisk2Path(val);
        if (std.mem.eql(u8, key, "disk2_size")) v.disk2_size_gb = std.fmt.parseInt(u32, val, 10) catch v.disk2_size_gb;
        if (std.mem.eql(u8, key, "disk2_format")) v.disk2_format = vm.DiskFormat.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.disk2_format.toIndex());
        if (std.mem.eql(u8, key, "floppy")) v.setFloppyPath(val);
        if (std.mem.eql(u8, key, "nic2")) v.nics[1].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic2_mac")) v.setNic2Mac(val);
        if (std.mem.eql(u8, key, "nic3")) v.nics[2].mode = vm.NetworkMode.fromStr(val);
        if (std.mem.eql(u8, key, "nic3_mac")) v.setNic3Mac(val);
        if (std.mem.eql(u8, key, "portfw")) v.setPortForwards(val);
        if (std.mem.eql(u8, key, "notes")) v.setNotes(val);
        if (std.mem.eql(u8, key, "enable_3d")) v.enable_3d = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "gpu_device")) v.gpu_device = vm.GpuDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.gpu_device.toIndex());
        if (std.mem.eql(u8, key, "display")) v.display = vm.DisplayType.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display.toIndex());
        if (std.mem.eql(u8, key, "display_resolution")) v.display_resolution = vm.DisplayResolution.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.display_resolution.toIndex());
        if (std.mem.eql(u8, key, "guest_os")) v.guest_os = vm.GuestOs.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.guest_os.toIndex());
        if (std.mem.eql(u8, key, "audio")) v.audio = vm.AudioDevice.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.audio.toIndex());
        if (std.mem.eql(u8, key, "boot_order")) v.boot_order = vm.BootOrder.fromIndex(std.fmt.parseInt(usize, val, 10) catch v.boot_order.toIndex());
        if (std.mem.eql(u8, key, "enable_kvm")) v.enable_kvm = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "embed_display")) v.embed_display = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "vnc_port")) v.vnc_port = std.fmt.parseInt(u16, val, 10) catch v.vnc_port;
        if (std.mem.eql(u8, key, "spice_port")) v.spice_port = std.fmt.parseInt(u16, val, 10) catch v.spice_port;
        if (std.mem.eql(u8, key, "enable_serial")) v.enable_serial = std.mem.eql(u8, val, "1");
        if (std.mem.eql(u8, key, "num_displays")) v.num_displays = std.fmt.parseInt(u32, val, 10) catch v.num_displays;
        if (std.mem.eql(u8, key, "favorite")) v.favorite = std.mem.eql(u8, val, "1");
    }
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn parseIdx(req: []const u8, prefix: []const u8) ?usize {
    const start = std.mem.indexOf(u8, req, prefix) orelse return null;
    const rest = req[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn handleSuspend(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/suspend/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";

    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/kvmgui-state-{s}.bin", .{v.getNameSlice()}) catch return "path err";
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
    client.connect(sock) catch return "qmp err";
    defer client.disconnect();
    client.suspendToFile(path) catch return "migrate err";
    client.waitMigrateComplete() catch return "timeout";
    v.setSavedStatePath(path[0..]);
    if (getVmmHandle(idx)) |h| {
        g_vmm.forceStopFn(h);
        g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
    }
    destroyVmmHandle(idx);
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

fn handleShutdown(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/shutdown/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    if (getVmmHandle(idx)) |h| {
        g_vmm.shutdownFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.powerdown() catch return "qmp err";
    }
    return "ok";
}

fn handleReset(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/reset/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.isAlive()) return "not running";
    if (getVmmHandle(idx)) |h| {
        g_vmm.resetFn(h) catch return "qmp err";
    } else {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse return "sock err";
        client.connect(sock) catch return "qmp err";
        defer client.disconnect();
        client.systemReset() catch return "qmp err";
    }
    return "ok";
}

fn handleSnapshotTake(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/take/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const tag = std.mem.trim(u8, body, " \r\n");
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    } else {
        qemu.snapshotCreate(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "create err";
    }
    return "ok";
}

fn handleSnapshotList(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "GET /api/snapshot/list/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    var buf: [4096]u8 = undefined;
    const n: usize = if (getVmmHandle(idx)) |h|
        g_vmm.snapshotListFn(h, v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0
    else
        qemu.snapshotList(v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0;
    if (n > 0 and n <= buf.len) return buf[0..n];
    return "(none)";
}

fn handleSnapshotRevert(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/revert/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const tag = std.mem.trim(u8, body, " \r\n");
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotApplyFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    } else {
        qemu.snapshotApply(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "apply err";
    }
    return "ok";
}

fn handleSnapshotDelete(req: []const u8) ![]const u8 {
    const idx = parseIdx(req, "POST /api/snapshot/delete/") orelse return "invalid";
    if (idx >= vm_count) return "invalid idx";
    const v = &vms[idx];
    if (!v.hasDisk()) return "no disk";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const tag = std.mem.trim(u8, body, " \r\n");
    if (tag.len == 0) return "no name";
    if (getVmmHandle(idx)) |h| {
        g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "delete err";
    } else {
        qemu.snapshotDelete(v.getDiskPathSlice(), tag, std.heap.page_allocator) catch return "delete err";
    }
    return "ok";
}

fn handleImport(req: []const u8) ![]const u8 {
    if (vm_count >= MAX_VMS) return "full";
    const body_start = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return "no body";
    const body = req[body_start + 4 ..];
    const path = std.mem.trim(u8, body, " \r\n");
    if (path.len == 0) return "no path";
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const name = blk: {
        const sep = std.mem.lastIndexOfScalar(u8, path, '/');
        const basename = if (sep) |s| path[s + 1 ..] else path;
        const dot = std.mem.lastIndexOfScalar(u8, basename, '.');
        const name_slice = if (dot) |d| basename[0..d] else basename;
        if (name_slice.len >= name_buf.len) break :blk name_buf[0..];
        @memcpy(name_buf[0..name_slice.len], name_slice);
        break :blk name_buf[0..name_slice.len];
    };
    var cfg = vm.VmConfig{};
    cfg.setName(name);
    cfg.setDiskPath(path);
    cfg.disk_size_gb = 20;
    cfg.memory_mb = prefs.default_memory_mb;
    cfg.cpu_cores = prefs.default_cpu_cores;
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));
    vms[vm_count] = cfg;
    vm_count += 1;
    persist.save(&vms, vm_count, prefs) catch {};
    return "ok";
}

const index_html =
    \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>KVMGUI</title><style>
    \\*{margin:0;padding:0;box-sizing:border-box}body{font:14px system-ui;display:flex;height:100vh;background:#1e1f23;color:#e6e7ea}
    \\aside{width:220px;background:#16171a;padding:10px;overflow-y:auto;display:flex;flex-direction:column}
    \\aside h2{font-size:13px;color:#9aa1ab;margin:10px 0 5px;text-transform:uppercase;letter-spacing:1px}
    \\aside .vm-item{padding:6px 8px;cursor:pointer;border-radius:4px;display:flex;align-items:center;gap:6px;font-size:13px}
    \\aside .vm-item:hover{background:#2c2f36}.vm-item.active{background:#3b82f6;color:#fff}
    \\main{flex:1;padding:20px;overflow-y:auto}
    \\main h1{font-size:24px;margin-bottom:10px}.detail-row{display:flex;gap:10px;padding:6px 0;font-size:13px}
    \\.detail-label{color:#9aa1ab;width:100px}.btn{padding:6px 14px;border:1px solid #3a3e46;background:#2c2f36;color:#e6e7ea;border-radius:5px;cursor:pointer;font-size:13px;margin-right:6px}
    \\.btn:hover{background:#363a42}.btn.primary{background:#3b82f6;border-color:#3b82f6;color:#fff}
    \\.btn.danger{background:#c0392b;border-color:#c0392b;color:#fff}
    \\.toolbar{display:flex;gap:6px;margin-bottom:16px;flex-wrap:wrap}
    \\#serialpanel{display:none;background:#0a0a0a;border-radius:8px;margin-bottom:16px;padding:0;overflow:hidden}
    \\#serialterm{width:100%;height:300px;background:#0a0a0a;color:#00ff66;font:13px 'Courier New',monospace;padding:8px;border:none;resize:none;outline:none;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
    \\dialog{border:none;border-radius:8px;padding:20px;background:#1e1f23;color:#e6e7ea;width:400px}
    \\dialog input,select{width:100%;padding:6px;margin:6px 0;background:#16171a;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px}
    \\dialog .btn-row{display:flex;gap:6px;margin-top:12px;justify-content:flex-end}
    \\#statusbar{position:fixed;bottom:0;left:0;right:0;padding:4px 12px;font-size:11px;background:#16171a;color:#9aa1ab}
    \\</style></head><body>
    \\<aside><h2>KVMGUI</h2><input id="search" placeholder="Filter VMs..." style="width:100%;padding:4px 8px;margin-bottom:8px;background:#2c2f36;color:#e6e7ea;border:1px solid #3a3e46;border-radius:4px;font-size:12px" oninput="filterList()"><div id="vmlist"></div>
    \\<div style="margin-top:auto"><button class="btn primary" style="width:100%" onclick="newVm()">+ New VM</button></div></aside>
    \\<main><div id="display" style="background:#000;border-radius:8px;margin-bottom:16px;display:none"><canvas id="fbcanvas" width="640" height="480" style="width:100%;max-height:400px"></canvas></div><div id="serialpanel"><textarea id="serialterm" readonly></textarea></div><div class="toolbar">
    \\<button id="powerbtn" class="btn primary" onclick="powerToggle()">▶ Power On</button>
    \\<button class="btn" onclick="shutdownGuest()">Shut Down</button>
    \\<button class="btn" onclick="resetGuest()">Reset</button>
    \\<button class="btn" onclick="editVm()">Settings</button>
    \\<button class="btn danger" onclick="deleteVm()">Delete</button>
    \\</div><h1 id="vmname">Select a VM</h1>
    \\<div id="details"></div></main>
    \\<div id="statusbar">Ready</div>
    \\<dialog id="newdlg"><h3>New Virtual Machine</h3>
    \\<input id="n_name" placeholder="VM Name" value="New VM"><input id="n_mem" placeholder="Memory (MB)" type="number" value="2048">
    \\<input id="n_cpu" placeholder="CPU Cores" type="number" value="2"><input id="n_disk" placeholder="Disk (GB)" type="number" value="20">
    \\<div class="btn-row"><button class="btn" onclick="newdlg.close()">Cancel</button><button class="btn primary" onclick="createVm()">Create</button></div></dialog>
    \\<dialog id="editdlg"><h3>Virtual Machine Settings</h3><div style="max-height:70vh;overflow-y:auto">
    \\<label style="font-size:11px;color:#9aa1ab">Name</label><input id="e_name" placeholder="VM Name">
    \\<label style="font-size:11px;color:#9aa1ab">Memory (MB)</label><input id="e_mem" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">CPU Cores</label><input id="e_cpu" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">Disk Size (GB)</label><input id="e_disk" type="number">
    \\<label style="font-size:11px;color:#9aa1ab">Network</label><select id="e_network"><option value="user">NAT (User)</option><option value="bridge">Bridged</option><option value="none">None</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Firmware</label><select id="e_firmware"><option value="bios">BIOS</option><option value="uefi">UEFI</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Shared Folder</label><input id="e_shared" placeholder="/host/path">
    \\<label style="font-size:11px;color:#9aa1ab">USB Device</label><input id="e_usb" placeholder="vendorid:prodid">
    \\<label style="font-size:11px;color:#9aa1ab">Guest Tools</label><select id="e_gt"><option value="0">No</option><option value="1">Yes</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">AutoProtect</label><select id="e_ap"><option value="0">Off</option><option value="1">On</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">AP Interval (min)</label><input id="e_apint" type="number" value="60">
    \\<label style="font-size:11px;color:#9aa1ab">AP Max Snapshots</label><input id="e_apmax" type="number" value="10">
    \\<label style="font-size:11px;color:#9aa1ab">Disk 2 Path</label><input id="e_d2path" placeholder="/path/to/disk2.qcow2">
    \\<label style="font-size:11px;color:#9aa1ab">Disk 2 Size (GB)</label><input id="e_d2size" type="number" value="0">
    \\<label style="font-size:11px;color:#9aa1ab">Floppy Path</label><input id="e_floppy" placeholder="/path/to/floppy.img">
    \\<label style="font-size:11px;color:#9aa1ab">NIC 2</label><select id="e_nic2"><option value="none">None</option><option value="user">NAT</option><option value="bridge">Bridged</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">NIC 3</label><select id="e_nic3"><option value="none">None</option><option value="user">NAT</option><option value="bridge">Bridged</option></select>
    \\<label style="font-size:11px;color:#9aa1ab">Port Forwards</label><input id="e_pf" placeholder="tcp:2222::22,tcp:8080::80">
    \\<label style="font-size:11px;color:#9aa1ab">Notes</label><input id="e_notes" placeholder="VM notes...">
    \\</div><div class="btn-row"><button class="btn" onclick="editdlg.close()">Cancel</button><button class="btn primary" onclick="saveVm()">Save</button></div></dialog>
    \\<script>
    \\let vms=[]; let sel=null;
    \\async function refresh(){const r=await fetch('/api/vms');vms=await r.json();renderList();if(sel!==null&&sel<vms.length)renderDetails();}
    \\function filterList(){const f=document.getElementById('search').value.toLowerCase();renderList(f);}
    \\function renderList(filter){const e=document.getElementById('vmlist');const f=(filter||'').toLowerCase();let h='';for(let i=0;i<vms.length;i++){const v=vms[i];if(f&&!v.name.toLowerCase().includes(f))continue;
    \\const color=v.status==='running'?'#22c55e':v.status==='paused'?'#f97316':v.status==='suspended'?'#eab308':'#9aa1ab';
    \\const icon=v.status==='running'?'▶':v.status==='paused'?'⏸':'  ';
    \\h+=`<div class="vm-item${sel===i?' active':''}" onclick="select(${i})"><span style="color:${color};font-weight:bold">${icon}</span> ${v.name}</div>`;}
    \\e.innerHTML=h||'<div style="color:#666;font-size:12px">No VMs</div>';
    \\let cnt=0,running=0;for(let v of vms){cnt++;if(v.status==='running')running++;}
    \\document.getElementById('statusbar').textContent=cnt+' virtual machine(s)'+(running>0?', '+running+' running':'');}
    \\function select(i){sel=i;renderList();renderDetails();}
    \\function renderDetails(){if(sel===null||sel>=vms.length){document.getElementById('vmname').textContent='Select a VM';document.getElementById('details').innerHTML='';return;}
    \\const v=vms[sel];const sc=v.status==='running'?'#22c55e':v.status==='paused'?'#f97316':v.status==='suspended'?'#eab308':'#9aa1ab';
    \\document.getElementById('vmname').textContent=v.name;
    \\let h=`<div class="detail-row"><span class="detail-label">State</span><span style="color:${sc};font-weight:bold">${v.status}</span></div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Guest OS</span>${v.os}</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Memory</span>${v.mem} MB</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">CPU</span>${v.cpu} cores</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Hard Disk</span>${v.disk} GB (${v.fw})</div>`;
    \\h+=`<div class="detail-row"><span class="detail-label">Network</span>${v.net}</div>`;
    \\if(v.mac)h+=`<div class="detail-row"><span class="detail-label">MAC</span>${v.mac}</div>`;
    \\if(v.nic2_mode&&v.nic2_mode!=='none')h+=`<div class="detail-row"><span class="detail-label">NIC 2</span>${v.nic2_mode}</div>`;
    \\if(v.nic3_mode&&v.nic3_mode!=='none')h+=`<div class="detail-row"><span class="detail-label">NIC 3</span>${v.nic3_mode}</div>`;
    \\if(v.shared_folder)h+=`<div class="detail-row"><span class="detail-label">Shared Folder</span>${v.shared_folder}</div>`;
    \\if(v.usb_device)h+=`<div class="detail-row"><span class="detail-label">USB Device</span>${v.usb_device}</div>`;
    \\if(v.guest_tools==='true')h+=`<div class="detail-row"><span class="detail-label">Guest Tools</span>✓ installed</div>`;
    \\if(v.autoprotect==='true')h+=`<div class="detail-row"><span class="detail-label">AutoProtect</span>every ${v.autoprotect_interval} min, keep ${v.autoprotect_max}</div>`;
    \\if(v.hasDisk2==='true')h+=`<div class="detail-row"><span class="detail-label">Disk 2</span>${v.disk2_size} GB</div>`;
    \\if(v.hasFloppy==='true')h+=`<div class="detail-row"><span class="detail-label">Floppy</span>attached</div>`;
    \\if(v.port_forwards)h+=`<div class="detail-row"><span class="detail-label">Port Fwds</span>${v.port_forwards}</div>`;
    \\if(v.notes)h+=`<div class="detail-row"><span class="detail-label">Notes</span>${v.notes}</div>`;
    \\document.getElementById('details').innerHTML=h;updatePowerBtn();}
    \\async function powerToggle(){if(sel===null)return;await fetch('/api/power/'+sel,{method:'POST'});refresh();}
    \\async function shutdownGuest(){if(sel===null)return;await fetch('/api/shutdown/'+sel,{method:'POST'});setStatus('Shut down guest — ACPI power button sent.');}
    \\async function resetGuest(){if(sel===null)return;await fetch('/api/reset/'+sel,{method:'POST'});setStatus('Reset guest — system_reset sent.');}
    \\function updatePowerBtn(){const b=document.getElementById('powerbtn');if(sel===null||sel>=vms.length){b.textContent='▶ Power On';b.className='btn primary';return;}
    \\const v=vms[sel];if(v.status==='running'){b.textContent='⏹ Power Off';b.className='btn danger';}else if(v.status==='paused'){b.textContent='▶ Resume';b.className='btn primary';}else{b.textContent='▶ Power On';b.className='btn primary';}}
    \\function newVm(){document.getElementById('newdlg').showModal();}
    \\async function createVm(){const n=document.getElementById('n_name').value;const m=document.getElementById('n_mem').value;
    \\const c=document.getElementById('n_cpu').value;const d=document.getElementById('n_disk').value;
    \\await fetch(`/api/new`,{method:'POST',body:`name=${encodeURIComponent(n)}&mem=${m}&cpu=${c}&disk=${d}`});document.getElementById('newdlg').close();refresh();}
    \\async function deleteVm(){if(sel===null)return;if(!confirm('Delete this VM?'))return;await fetch('/api/delete/'+sel,{method:'POST'});sel=null;refresh();}
    \\function editVm(){if(sel===null)return;const v=vms[sel];
    \\document.getElementById('e_name').value=v.name||'';document.getElementById('e_mem').value=v.mem||2048;
    \\document.getElementById('e_cpu').value=v.cpu||2;document.getElementById('e_disk').value=v.disk||20;
    \\document.getElementById('e_network').value=v.net||'user';document.getElementById('e_firmware').value=v.fw||'bios';
    \\document.getElementById('e_shared').value=v.shared_folder||'';document.getElementById('e_usb').value=v.usb_device||'';
    \\document.getElementById('e_gt').value=v.guest_tools==='true'?'1':'0';document.getElementById('e_ap').value=v.autoprotect==='true'?'1':'0';
    \\document.getElementById('e_apint').value=v.autoprotect_interval||60;document.getElementById('e_apmax').value=v.autoprotect_max||10;
    \\document.getElementById('e_d2path').value=v.disk2_path||'';document.getElementById('e_d2size').value=v.disk2_size||0;
    \\document.getElementById('e_floppy').value=v.floppy_path||'';document.getElementById('e_nic2').value=v.nic2_mode||'none';
    \\document.getElementById('e_nic3').value=v.nic3_mode||'none';document.getElementById('e_pf').value=v.port_forwards||'';
    \\document.getElementById('e_notes').value=v.notes||'';document.getElementById('editdlg').showModal();}
    \\async function saveVm(){if(sel===null)return;
    \\const body=['name','mem','cpu','disk','network','firmware','shared_folder','usb','guest_tools','autoprotect',
    \\'ap_interval','ap_max','disk2_path','disk2_size','floppy','nic2','nic3','portfw','notes']
    \\.map(id=>{const el=document.getElementById('e_'+id);if(el)return id+'='+encodeURIComponent(el.value);return'';}).filter(s=>s).join('&');
    \\await fetch('/api/save/'+sel,{method:'POST',body});document.getElementById('editdlg').close();refresh();}
    \\refresh();
    \\setInterval(refresh,5000);
    \\// WebGPU/Canvas2D framebuffer display
    \\let fbCanvas=document.getElementById('fbcanvas'),fbCtx=fbCanvas.getContext('2d'),fbInterval=null;
    \\async function startFb(){if(sel===null){document.getElementById('display').style.display='none';if(fbInterval)clearInterval(fbInterval);return;}
    \\document.getElementById('display').style.display='block';
    \\if(fbInterval)clearInterval(fbInterval);fbInterval=setInterval(async()=>{if(sel===null||sel>=vms.length)return;const v=vms[sel];if(v.status!=='running')return;
    \\try{const r=await fetch('/api/fb/'+sel);if(!r.ok)return;const buf=await r.arrayBuffer();if(buf.byteLength<100)return;const w=640,h=480;fbCanvas.width=w;fbCanvas.height=h;
    \\const img=fbCtx.createImageData(w,h);const src=new Uint8Array(buf);const dst=img.data;for(let i=0;i<w*h;i++){const o=i*4;dst[o]=src[o+2];dst[o+1]=src[o+1];dst[o+2]=src[o];dst[o+3]=255;}
    \\fbCtx.putImageData(img,0,0);}catch(e){}},200)};
    \\setInterval(()=>{if(sel!==null&&sel<vms.length&&vms[sel].status==='running')startFb();},2000);
    \\// Serial console
    \\let serialWs=null,serialIdx=null;
    \\function startSerial(idx){if(serialWs&&serialIdx===idx)return;stopSerial();
    \\if(idx===null||idx>=vms.length)return;const v=vms[idx];if(v.status!=='running'||!v.hasSerial)return;
    \\serialIdx=idx;const term=document.getElementById('serialterm');term.value='';document.getElementById('serialpanel').style.display='block';
    \\const proto=location.protocol==='https:'?'wss:':'ws:';serialWs=new WebSocket(proto+'//'+location.host+'/ws/serial/'+idx);
    \\serialWs.onmessage=e=>{term.value+=e.data;term.scrollTop=term.scrollHeight;};
    \\serialWs.onclose=()=>{stopSerial();};
    \\serialWs.onerror=()=>{stopSerial();};}
    \\function stopSerial(){if(serialWs){serialWs.close();serialWs=null;}serialIdx=null;document.getElementById('serialpanel').style.display='none';}
    \\document.getElementById('serialterm').addEventListener('keydown',e=>{if(!serialWs||serialWs.readyState!==WebSocket.OPEN)return;
    \\e.preventDefault();let s=e.key;if(e.key==='Enter')s='\r\n';else if(e.key==='Backspace')s='\x08';else if(e.key==='Tab')s='\t';
    \\if(s.length===1||s==='\r\n'||s==='\x08'||s==='\t')serialWs.send(s);});
    \\setInterval(()=>{if(sel!==null&&sel<vms.length){const v=vms[sel];if(v.status==='running'&&v.hasSerial)startSerial(sel);else stopSerial();}},3000);
    \\</script></body></html>
;

pub fn main() !void {
    vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);
    g_vmm = hv_backend.createVmm(.auto);

    const sock = c.socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return;
    defer _ = c.close(sock);

    const one: c_int = 1;
    _ = c.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

    // Bind to 0.0.0.0 — accessible locally and remotely
    const bind_ip: u32 = (@as(u32, BIND_ADDR[0]) << 24) | (@as(u32, BIND_ADDR[1]) << 16) | (@as(u32, BIND_ADDR[2]) << 8) | @as(u32, BIND_ADDR[3]);
    var addr: c.sockaddr.in = .{ .family = AF_INET, .port = std.mem.nativeToBig(u16, PORT), .addr = std.mem.nativeToBig(u32, bind_ip), .zero = [_]u8{0} ** 8 };
    if (c.bind(sock, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return;
    if (c.listen(sock, 10) != 0) return;

    // Create Unix socket listener for local clients
    const unix_path = "/tmp/kvmgui-daemon.sock";
    _ = c.unlink(unix_path);
    const unix_sock = c.socket(AF_UNIX, SOCK_STREAM, 0);
    var unix_addr: c.sockaddr.un = .{ .family = AF_UNIX, .path = undefined };
    @memcpy(unix_addr.path[0..unix_path.len], unix_path);
    unix_addr.path[unix_path.len] = 0;
    const unix_len = @offsetOf(c.sockaddr.un, "path") + unix_path.len + 1;
    _ = c.setsockopt(unix_sock, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    _ = c.bind(unix_sock, @ptrCast(&unix_addr), @intCast(unix_len));
    _ = c.listen(unix_sock, 10);

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  KVMGUI Daemon v1.0                         ║\n", .{});
    std.debug.print("║  TCP:   http://0.0.0.0:{d}                 ║\n", .{PORT});
    std.debug.print("║  Unix:  unix://{s}       ║\n", .{unix_path});
    std.debug.print("║  Health: GET /api/health                    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    // Spawn thread to accept Unix socket connections
    _ = std.Thread.spawn(std.Thread.SpawnConfig{}, acceptLoop, .{ unix_sock }) catch {};

    while (true) {
        const conn = c.accept(sock, null, null);
        if (conn < 0) continue;
        const th = std.Thread.spawn(std.Thread.SpawnConfig{}, serveHtml, .{conn}) catch continue;
        th.detach();
    }
}
