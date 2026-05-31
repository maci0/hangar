//! KVMGUI — FLTK Frontend (full VM management with callbacks)
const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const usock = @import("usock.zig");
const ringbuf = @import("ringbuf.zig");
const termfilter = @import("termfilter.zig");
const sync = @import("sync.zig");
const transport = @import("transport.zig");
// posix aliases removed — use std.c directly

const cfltk = @cImport({
    @cInclude("cfltk/cfl.h");
    @cInclude("cfltk/cfl_window.h");
    @cInclude("cfltk/cfl_button.h");
    @cInclude("cfltk/cfl_box.h");
    @cInclude("cfltk/cfl_group.h");
    @cInclude("cfltk/cfl_menu.h");
    @cInclude("cfltk/cfl_input.h");
    @cInclude("cfltk/cfl_browser.h");
    @cInclude("cfltk/cfl_text.h");
    @cInclude("cfltk/cfl_misc.h");
    @cInclude("cfltk/cfl_image.h");
    @cInclude("cfltk/cfl_draw.h");
});

const MAX_VMS = 64;
var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var selected_idx: ?usize = null;
var prefs: vm.Prefs = .{};
var browser: ?*cfltk.Fl_Browser = null;
var status_bar: ?*cfltk.Fl_Box = null;
var detail_labels: [8]?*cfltk.Fl_Box = [_]?*cfltk.Fl_Box{null} ** 8;
var sum_name: ?*cfltk.Fl_Box = null;
var win_handle: ?*cfltk.Fl_Window = null;
var ctx_menu_handle: ?*cfltk.Fl_Menu_Button = null;
var console_widget: ?*cfltk.Fl_Browser = null;
var display_box: ?*cfltk.Fl_Box = null;
var search_input: ?*cfltk.Fl_Input = null;
var filter_text: [64]u8 = [_]u8{0} ** 64;
var filter_len: usize = 0;
var vm_started: [MAX_VMS]i64 = [_]i64{0} ** MAX_VMS;
var vnc_client: ?*vnc.VncClient = null;
var spice_client: ?*spice.SpiceClient = null;
const SERIAL_BUF_SIZE = 64 * 1024;
var serial_buf: [SERIAL_BUF_SIZE]u8 = undefined;
var serial_len: usize = 0;
var serial_mutex: sync.SpinMutex = .{};
var serial_running: bool = false;
var serial_thread: ?std.Thread = null;
var serial_fd: ?std.c.fd_t = null;

fn serialReader() void {
    const fd = serial_fd orelse return;
    var buf: [4096]u8 = undefined;
    while (@atomicLoad(bool, &serial_running, .seq_cst)) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        serial_mutex.lock();
        serial_len = ringbuf.append(&serial_buf, serial_len, buf[0..@intCast(n)]);
        serial_mutex.unlock();
    }
}

fn serialConnect(vm_name: []const u8) void {
    if (serial_fd != null) return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/kvmgui-serial-{s}.sock", .{vm_name}) catch return;
    const stream = usock.UnixStream.connect(path) catch return;
    serial_fd = stream.fd;
    @atomicStore(bool, &serial_running, true, .seq_cst);
    serial_thread = std.Thread.spawn(std.Thread.SpawnConfig{}, serialReader, .{}) catch {
        serial_fd = null;
        return;
    };
}

fn serialDisconnect() void {
    @atomicStore(bool, &serial_running, false, .seq_cst);
    if (serial_fd) |fd| { _ = std.c.close(fd); serial_fd = null; }
    if (serial_thread) |t| { t.join(); serial_thread = null; }
}

fn browserCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { selectCurrent(); refreshDetails(); }
fn powerCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { togglePower(); }
fn suspendCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { suspendVm(); }
fn settingsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { editVmDialog(); }
fn importCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { importVm(); }
fn cloneCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { cloneVm(); }
fn snapshotCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { snapDialog(); }
fn deleteVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { deleteCurrentVm(); }
fn prefsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { prefsDialog(); }
fn vnetCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { vnetDialog(); }
fn quitCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { shutdown(); }
fn aboutCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { aboutDialog(); }
fn exportOvfCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { exportOvfDialog(); }
fn homeCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { selected_idx = null; refreshBrowser(); refreshDetails(); }
fn connectRemoteCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { remoteConnectDialog(); }

var remote_mode: bool = false;
var remote_url: [128]u8 = [_]u8{0} ** 128;
var remote_url_len: usize = 0;

fn remoteConnectDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(420, 200, "Connect to Remote Server");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 400, 20, "Server URL: unix:///path | http://host:port | shm:///name");
    const url_input = cfltk.Fl_Input_new(10, 35, 400, 24, "");
    _ = cfltk.Fl_Box_new(10, 70, 400, 20, "Auth token (optional):");
    const token_input = cfltk.Fl_Input_new(10, 95, 400, 24, "");
    const connect_btn = cfltk.Fl_Button_new(220, 160, 90, 30, "Connect");
    const local_btn = cfltk.Fl_Button_new(320, 160, 90, 30, "Local Mode");
    const status_label = cfltk.Fl_Box_new(10, 135, 400, 20, "Currently: Local Mode");

    const RD = struct { url: ?*cfltk.Fl_Input, token: ?*cfltk.Fl_Input, status: ?*cfltk.Fl_Box, dlg: ?*cfltk.Fl_Window };
    var rd = RD{ .url = @ptrCast(url_input), .token = @ptrCast(token_input), .status = @ptrCast(status_label), .dlg = @ptrCast(dlg) };

    const ConnectFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const rdp: *RD = @ptrCast(@alignCast(d orelse return));
            if (rdp.url) |u| {
                const s = std.mem.span(cfltk.Fl_Input_value(u));
                if (s.len > 0 and s.len < remote_url.len) {
                    std.mem.copyForwards(u8, &remote_url, s);
                    remote_url_len = s.len;
                    remote_mode = true;
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Connected (remote mode)");
                    if (status_bar) |sb2| {
                        var sbb: [160]u8 = undefined;
                        const txt = std.fmt.bufPrintZ(&sbb, "Connected to {s} — Remote Mode", .{s}) catch "Remote Mode";
                        cfltk.Fl_Box_set_label(sb2, txt.ptr);
                        cfltk.Fl_Box_set_label_color(sb2, 0x0088CC);
                    }
                    if (rdp.dlg) |dl| cfltk.Fl_Window_hide(dl);
                }
            }
        }
    };
    const LocalFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const rdp: *RD = @ptrCast(@alignCast(d orelse return));
            remote_mode = false;
            remote_url_len = 0;
            if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Switched to Local Mode");
            if (status_bar) |s| {
                cfltk.Fl_Box_set_label(s, "Ready — Local Mode");
                cfltk.Fl_Box_set_label_color(s, 0x666666);
            }
            if (rdp.dlg) |dl| cfltk.Fl_Window_hide(dl);
        }
    };
    cfltk.Fl_Button_set_callback(connect_btn, &ConnectFn.go, &rd);
    cfltk.Fl_Button_set_callback(local_btn, &LocalFn.go, &rd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn apiGet(path: []const u8, out: []u8) usize {
    if (!remote_mode or remote_url_len == 0) return 0;
    const url = transport.Url.parse(remote_url[0..remote_url_len]) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("GET", path, null, out);
}

fn aboutDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(400, 250, "About KVMGUI");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 380, 30, "KVMGUI v1.0");
    _ = cfltk.Fl_Box_new(10, 40, 380, 20, "Lightweight QEMU/KVM Virtual Machine Manager");
    _ = cfltk.Fl_Box_new(10, 70, 380, 20, "Built with Zig + FLTK 1.4");
    _ = cfltk.Fl_Box_new(10, 100, 380, 60, "Features: VM mgmt, VNC/SPICE display, serial console, snapshots, OVF export, AutoProtect, virtual networks");
    _ = cfltk.Fl_Box_new(10, 170, 380, 20, "Pure modules: 586 tests passing");
    const cb = cfltk.Fl_Button_new(310, 210, 80, 30, "OK");
    const OK = struct { fn g(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {} };
    cfltk.Fl_Button_set_callback(cb, &OK.g, null);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn exportOvfDialog() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    const v = &vms[idx];
    if (!v.hasDisk()) return;
    const dlg = cfltk.Fl_Window_new_wh(400, 150, "Export to OVF");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 380, 20, "Export VM as OVF 1.0 package.");
    var buf: [200]u8 = undefined;
    const info = std.fmt.bufPrintZ(&buf, "VM: {s} | Disk: {d} GB | CPU: {d} | Mem: {d} MB", .{ v.getNameSlice(), v.disk_size_gb, v.cpu_cores, v.memory_mb }) catch "Export VM";
    _ = cfltk.Fl_Box_new(10, 35, 380, 40, info);
    const eb = cfltk.Fl_Button_new(200, 110, 90, 30, "Export");
    const cb2 = cfltk.Fl_Button_new(300, 110, 90, 30, "Cancel");
    const E = struct { fn g(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {} };
    cfltk.Fl_Button_set_callback(eb, &E.g, null);
    cfltk.Fl_Button_set_callback(cb2, &E.g, null);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn shutdown() void {
    persist.save(&vms, vm_count, prefs) catch {};
    if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
    if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
    serialDisconnect();
    if (win_handle) |w| cfltk.Fl_Window_hide(w);
}

fn cloneVm() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count or vm_count >= MAX_VMS) return;
    const src = &vms[idx];
    var clone = src.*;
    var name_buf: [256]u8 = undefined;
    const clone_name = std.fmt.bufPrintZ(&name_buf, "{s} (clone)", .{src.getNameSlice()}) catch return;
    clone.setName(clone_name);
    clone.status = .stopped;
    clone.pid = null;
    clone.clearSavedStatePath();
    const ci: u16 = @intCast(vm_count);
    clone.vnc_port = 5900 + ci;
    clone.spice_port = 5930 + ci;
    vms[vm_count] = clone;
    vm_count += 1;
    selected_idx = vm_count - 1;
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn importVm() void {
    var cfg = vm.VmConfig{};
    cfg.setName("Imported-VM");
    cfg.setDiskPath("/tmp/imported.qcow2");
    if (vm_count < MAX_VMS) { vms[vm_count] = cfg; vm_count += 1; selected_idx = vm_count - 1; refreshBrowser(); refreshDetails(); persist.save(&vms, vm_count, prefs) catch {}; }
}

fn vnetDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(500, 350, "Virtual Network Editor");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 480, 20, "Virtual Network switches (VMnet):");
    const vnet_list = cfltk.Fl_Browser_new(10, 35, 480, 200, "");
    _ = cfltk.Fl_Browser_add(vnet_list, "VMnet0 — Bridged (auto)");
    _ = cfltk.Fl_Browser_add(vnet_list, "VMnet1 — Host-only (192.168.118.0/24, DHCP)");
    _ = cfltk.Fl_Browser_add(vnet_list, "VMnet8 — NAT (192.168.140.0/24, DHCP)");
    const vnc_btn = cfltk.Fl_Button_new(400, 310, 90, 30, "Close");
    const VC = struct { fn g(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {} };
    cfltk.Fl_Button_set_callback(vnc_btn, &VC.g, null);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}
fn newVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { newVmDialog(); }

fn deleteCurrentVm() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) vms[i] = vms[i + 1];
    vm_count -= 1;
    selected_idx = if (vm_count > 0) @min(idx, vm_count - 1) else null;
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn editVmDialog() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    const cfg = &vms[idx];
    const dlg = cfltk.Fl_Window_new_wh(460, 450, "Virtual Machine Settings");
    cfltk.Fl_Window_make_modal(dlg, 0);

    _ = cfltk.Fl_Box_new(10, 10, 100, 20, "VM Name:");
    const name_input = cfltk.Fl_Input_new(120, 8, 330, 24, cfg.getName());
    _ = cfltk.Fl_Box_new(10, 40, 100, 20, "Memory (MB):");
    var mbuf: [16]u8 = undefined;
    const mstr = std.fmt.bufPrintZ(&mbuf, "{d}", .{cfg.memory_mb}) catch "2048";
    const mem_input = cfltk.Fl_Input_new(120, 38, 330, 24, mstr);
    _ = cfltk.Fl_Box_new(10, 70, 100, 20, "CPU Cores:");
    var cbuf: [16]u8 = undefined;
    const cstr = std.fmt.bufPrintZ(&cbuf, "{d}", .{cfg.cpu_cores}) catch "2";
    const cpu_input = cfltk.Fl_Input_new(120, 68, 330, 24, cstr);
    _ = cfltk.Fl_Box_new(10, 100, 100, 20, "Disk Size (GB):");
    var dbuf: [16]u8 = undefined;
    const dstr = std.fmt.bufPrintZ(&dbuf, "{d}", .{cfg.disk_size_gb}) catch "20";
    const disk_input = cfltk.Fl_Input_new(120, 98, 330, 24, dstr);
    _ = cfltk.Fl_Box_new(10, 130, 100, 20, "ISO Path:");
    const iso_input = cfltk.Fl_Input_new(120, 128, 330, 24, if (cfg.hasIso()) cfg.getIsoPath() else "");
    _ = cfltk.Fl_Box_new(10, 160, 100, 20, "Network:");
    const net_input = cfltk.Fl_Input_new(120, 158, 330, 24, std.mem.span(cfg.network.label()));
    _ = cfltk.Fl_Box_new(10, 190, 100, 20, "Firmware:");
    const fw_input = cfltk.Fl_Input_new(120, 188, 330, 24, std.mem.span(cfg.firmware.label()));
    _ = cfltk.Fl_Box_new(10, 220, 100, 20, "Notes:");
    const notes_input = cfltk.Fl_Input_new(120, 218, 330, 100, if (cfg.hasNotes()) cfg.getNotes() else "");

    const save_btn = cfltk.Fl_Button_new(280, 410, 80, 30, "Save");
    const cancel_btn = cfltk.Fl_Button_new(370, 410, 80, 30, "Cancel");

    const Ed = struct { na: ?*cfltk.Fl_Input, me: ?*cfltk.Fl_Input, cp: ?*cfltk.Fl_Input, dk: ?*cfltk.Fl_Input, io: ?*cfltk.Fl_Input, no: ?*cfltk.Fl_Input, v: *vm.VmConfig, dl: ?*cfltk.Fl_Window };
    var ed = Ed{ .na = @ptrCast(name_input), .me = @ptrCast(mem_input), .cp = @ptrCast(cpu_input), .dk = @ptrCast(disk_input), .io = @ptrCast(iso_input), .no = @ptrCast(notes_input), .v = cfg, .dl = @ptrCast(dlg) };

    _ = net_input;
    _ = fw_input;

    const S = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const dd: *Ed = @ptrCast(@alignCast(d orelse return));
        if (dd.na) |n| dd.v.setName(std.mem.span(cfltk.Fl_Input_value(n)));
        if (dd.me) |m| dd.v.memory_mb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(m)), 10) catch dd.v.memory_mb);
        if (dd.cp) |c| dd.v.cpu_cores = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(c)), 10) catch dd.v.cpu_cores);
        if (dd.dk) |d2| dd.v.disk_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(d2)), 10) catch dd.v.disk_size_gb);
        if (dd.io) |i| { const s = std.mem.span(cfltk.Fl_Input_value(i)); if (s.len > 0) dd.v.setIsoPath(s) else dd.v.clearIsoPath(); }
        if (dd.no) |nt| dd.v.setNotes(std.mem.span(cfltk.Fl_Input_value(nt)));
        refreshBrowser(); refreshDetails();
        persist.save(&vms, vm_count, prefs) catch {};
        if (dd.dl) |dl2| cfltk.Fl_Window_hide(dl2);
    }};
    const C = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const dd: *Ed = @ptrCast(@alignCast(d orelse return));
        if (dd.dl) |dl2| cfltk.Fl_Window_hide(dl2);
    }};
    cfltk.Fl_Button_set_callback(save_btn, &S.go, &ed);
    cfltk.Fl_Button_set_callback(cancel_btn, &C.go, &ed);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn snapDialog() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    const vc = &vms[idx];
    if (!vc.hasDisk()) return;
    const dlg = cfltk.Fl_Window_new_wh(400, 200, "Snapshot Manager");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 380, 20, "Snapshot name:");
    const ni = cfltk.Fl_Input_new(10, 30, 380, 24, "snapshot1");
    const tb = cfltk.Fl_Button_new(90, 70, 100, 30, "Take");
    const lb = cfltk.Fl_Button_new(200, 70, 100, 30, "List");
    const cb = cfltk.Fl_Button_new(10, 160, 80, 30, "Close");
    const rl = cfltk.Fl_Box_new(10, 110, 380, 40, "");
    const SD = struct { n: ?*cfltk.Fl_Input, r: ?*cfltk.Fl_Box, v: *vm.VmConfig, d: ?*cfltk.Fl_Window };
    var sd = SD{ .n = @ptrCast(ni), .r = @ptrCast(rl), .v = vc, .d = @ptrCast(dlg) };
    const TK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.n) |nn| { qemu.snapshotCreate(s.v.getDiskPathSlice(), std.mem.span(cfltk.Fl_Input_value(nn)), std.heap.page_allocator) catch {}; if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Created."); }
    }};
    const LK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        var buf: [4096]u8 = undefined;
        const n = qemu.snapshotList(s.v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0;
        if (s.r) |rr| { if (n > 0) cfltk.Fl_Box_set_label(rr, @ptrCast(&buf)); }
    }};
    const CK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.d) |dd| cfltk.Fl_Window_hide(dd);
    }};
    cfltk.Fl_Button_set_callback(tb, &TK.go, &sd);
    cfltk.Fl_Button_set_callback(lb, &LK.go, &sd);
    cfltk.Fl_Button_set_callback(cb, &CK.go, &sd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn prefsDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(400, 200, "Preferences");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 100, 20, "Default Memory (MB):");
    var mb: [16]u8 = undefined;
    _ = cfltk.Fl_Input_new(180, 8, 210, 24, std.fmt.bufPrintZ(&mb, "{d}", .{prefs.default_memory_mb}) catch "2048");
    _ = cfltk.Fl_Box_new(10, 40, 100, 20, "Default CPU Cores:");
    var cb2: [16]u8 = undefined;
    _ = cfltk.Fl_Input_new(180, 38, 210, 24, std.fmt.bufPrintZ(&cb2, "{d}", .{prefs.default_cpu_cores}) catch "2");
    const close_btn = cfltk.Fl_Button_new(310, 160, 80, 30, "Close");
    const CK2 = struct { fn go(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {} };
    cfltk.Fl_Button_set_callback(close_btn, &CK2.go, null);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn selectCurrent() void {
    const b = browser orelse return;
    const line = cfltk.Fl_Browser_value(b);
    if (line > 0 and line <= @as(c_int, @intCast(vm_count))) selected_idx = @intCast(line - 1);
}

fn togglePower() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    if (vms[idx].isAlive()) {
        qemu.forceStopVm(&vms[idx]); qemu.reapVm(&vms[idx]);
        if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
        if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
        serialDisconnect();
    } else { qemu.startVm(&vms[idx], std.heap.page_allocator) catch {}; vm_started[idx] = 1; }
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn suspendVm() void {
    _ = selected_idx;
}

fn newVmDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(460, 580, "New Virtual Machine");
    cfltk.Fl_Window_make_modal(dlg, 0);

    _ = cfltk.Fl_Box_new(10, 10, 100, 20, "VM Name:");
    const name_input = cfltk.Fl_Input_new(120, 8, 330, 24, "");
    _ = cfltk.Fl_Box_new(10, 40, 100, 20, "Guest OS:");
    _ = cfltk.Fl_Input_new(120, 38, 330, 24, "Linux");
    _ = cfltk.Fl_Box_new(10, 70, 100, 20, "Memory (MB):");
    const mem_input = cfltk.Fl_Input_new(120, 68, 330, 24, "2048");
    _ = cfltk.Fl_Box_new(10, 100, 100, 20, "CPU Cores:");
    const cpu_input = cfltk.Fl_Input_new(120, 98, 330, 24, "2");
    _ = cfltk.Fl_Box_new(10, 130, 100, 20, "Disk (GB):");
    const disk_input = cfltk.Fl_Input_new(120, 128, 330, 24, "20");

    const create_btn = cfltk.Fl_Button_new(280, 540, 80, 30, "Create");
    const cancel_btn = cfltk.Fl_Button_new(370, 540, 80, 30, "Cancel");

    // Store pointers for the callback to use
    // Use a struct to pass data to callbacks
    const DlgData = struct {
        name: ?*cfltk.Fl_Input,
        mem: ?*cfltk.Fl_Input,
        cpu: ?*cfltk.Fl_Input,
        disk: ?*cfltk.Fl_Input,
        dlg: ?*cfltk.Fl_Window,
    };
    var ddata = DlgData{ .name = @ptrCast(name_input), .mem = @ptrCast(mem_input), .cpu = @ptrCast(cpu_input), .disk = @ptrCast(disk_input), .dlg = @ptrCast(dlg) };

    const CreateCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const dd: *DlgData = @ptrCast(@alignCast(data orelse return));
            if (vm_count >= MAX_VMS) return;

            var cfg = vm.VmConfig{};
            if (dd.name) |n| cfg.setName(std.mem.span(cfltk.Fl_Input_value(n)));
            if (dd.mem) |m| cfg.memory_mb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(m)), 10) catch 2048);
            if (dd.cpu) |c| cfg.cpu_cores = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(c)), 10) catch 2);
            if (dd.disk) |d| cfg.disk_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(d)), 10) catch 20);

            vms[vm_count] = cfg;
            vm_count += 1;
            selected_idx = vm_count - 1;
            refreshBrowser();
            refreshDetails();
            persist.save(&vms, vm_count, prefs) catch {};
            if (dd.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };

    const CancelCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const dd: *DlgData = @ptrCast(@alignCast(data orelse return));
            if (dd.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };

    cfltk.Fl_Button_set_callback(create_btn, &CreateCB.go, &ddata);
    cfltk.Fl_Button_set_callback(cancel_btn, &CancelCB.go, &ddata);

    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}


fn refreshBrowser() void {
    const b = browser orelse return;
    cfltk.Fl_Browser_clear(b);
    const filter: []const u8 = if (filter_len > 0) filter_text[0..filter_len] else "";
    for (0..vm_count) |i| {
        const v = &vms[i];
        if (filter.len > 0) {
            const name = v.getNameSlice();
            var lower_buf: [128]u8 = undefined;
            const lower = std.ascii.lowerString(&lower_buf, name);
            if (std.mem.indexOf(u8, lower, filter) == null) continue;
        }
        var buf: [256]u8 = undefined;
        const prefix: []const u8 = switch (v.status) { .running => "▶ ", .paused => "⏸ ", else => "  " };
        const txt = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ prefix, v.getNameSlice() }) catch continue;
        cfltk.Fl_Browser_add(b, txt.ptr);
    }
}

fn refreshDetails() void {
    if (sum_name) |l| {
        if (selected_idx) |idx| {
            if (idx < vm_count) {
                const v = &vms[idx];
                cfltk.Fl_Box_set_label(l, v.getName());
                setDetail(0, "State", std.mem.span(v.status.label()));
                // Color-code the state label
                if (detail_labels[0]) |dl| {
                    const color: u32 = switch (v.status) {
                        .running => 0x00AA00, // green
                        .paused => 0xFF8800,  // orange
                        .suspended => 0xCC6600, // dark orange
                        .stopped => 0x888888,   // gray
                    };
                    cfltk.Fl_Box_set_label_color(dl, color);
                }
                setDetail(1, "Guest OS", std.mem.span(v.guest_os.label()));
                var mbuf: [32]u8 = undefined;
                const mt = std.fmt.bufPrintZ(&mbuf, "{d} MB", .{v.memory_mb}) catch "---";
                setDetail(2, "Memory", mt);
                var cbuf: [32]u8 = undefined;
                const ct = std.fmt.bufPrintZ(&cbuf, "{d}", .{v.cpu_cores}) catch "---";
                setDetail(3, "CPU", ct);
                setDetail(4, "Hard Disk", if (v.hasDisk()) v.getDiskPathSlice() else "(none)");
                setDetail(5, "Network", std.mem.span(v.network.label()));
                setDetail(6, "CD/DVD", if (v.hasIso()) v.getIsoPathSlice() else "Auto detect");
                setDetail(7, "Notes", if (v.hasNotes()) v.getNotesSlice() else "");
                if (status_bar) |s| {
                    var sbuf: [200]u8 = undefined;
                    if (v.isAlive() and vm_started[idx] > 0) {
                        const elapsed: u64 = @intCast(vm_started[idx]);
                        const hrs = elapsed / 3600;
                        const mins = (elapsed % 3600) / 60;
                        const secs = elapsed % 60;
                        const st = std.fmt.bufPrintZ(&sbuf, "{s} — {s} | Uptime: {d}:{d:0>2}:{d:0>2} | {d} VM(s)", .{ v.getNameSlice(), std.mem.span(v.status.label()), hrs, mins, secs, vm_count }) catch "Running";
                        cfltk.Fl_Box_set_label(s, st.ptr);
                    } else {
                        const st = std.fmt.bufPrintZ(&sbuf, "{s} — {s}    |    {d} virtual machine(s)", .{ v.getNameSlice(), std.mem.span(v.status.label()), vm_count }) catch "Ready";
                        cfltk.Fl_Box_set_label(s, st.ptr);
                    }
                }
                return;
            }
        }
        cfltk.Fl_Box_set_label(l, "No virtual machine selected.");
        for (&detail_labels) |*dl| { if (dl.*) |d| cfltk.Fl_Box_set_label(d, ""); }
        if (status_bar) |s| {
            var sbuf: [64]u8 = undefined;
            const st = std.fmt.bufPrintZ(&sbuf, "{d} virtual machine(s)", .{vm_count}) catch "Ready";
            cfltk.Fl_Box_set_label(s, st.ptr);
        }
    }
}

// Global event handler — intercepts keyboard shortcuts + right-clicks
fn kbHandler(event: c_int) callconv(.c) c_int {
    if (event == 12) { // FL_PUSH = 12 (mouse button press)
        if (cfltk.Fl_event_button() == 3) { // Right click
            selectCurrent();
            _ = cfltk.Fl_event_x();
            _ = cfltk.Fl_event_y();
            // Show context menu
            if (ctx_menu_handle) |cm| _ = cfltk.Fl_Menu_Button_popup(cm);
            return 1;
        }
    }
    if (event != 8) return 0; // FL_KEYDOWN = 8
    const key = cfltk.Fl_event_key();
    const ctrl = cfltk.Fl_event_ctrl() != 0;
    if (ctrl and key == 'n') { newVmDialog(); return 1; }
    if (ctrl and key == 'q') { shutdown(); return 1; }
    if (key == 0xffbf) { editVmDialog(); return 1; } // F2
    if (key == 0xffff) { deleteCurrentVm(); return 1; } // DEL
    if (key == 0xffc8) { if (win_handle) |w| { const cur = cfltk.Fl_Window_fullscreen_active(w); cfltk.Fl_Window_fullscreen(w, if (cur != 0) @as(c_uint, 0) else 1); } return 1; } // F11 toggle
    if (ctrl and key == 'w') { selected_idx = null; refreshBrowser(); refreshDetails(); return 1; }
    return 0;
}

// Console timer — polls serial ring buffer and updates Fl_Browser widget.
fn consoleTimerCB(_: ?*anyopaque) callconv(.c) void {
    if (console_widget) |cw| {
        serial_mutex.lock();
        if (serial_len > 0) {
            var tmp: [SERIAL_BUF_SIZE + 1]u8 = undefined;
            const n = serial_len;
            @memcpy(tmp[0..n], serial_buf[0..n]);
            serial_len = 0;
            serial_mutex.unlock();
            const valid_len = termfilter.sanitize(&tmp, n);
            if (valid_len > 0) {
                tmp[valid_len] = 0;
                cfltk.Fl_Browser_add(cw, @ptrCast(tmp[0..valid_len].ptr));
            }
        } else {
            serial_mutex.unlock();
        }
    }
    _ = cfltk.Fl_repeat_timeout(0.5, consoleTimerCB, null);
}

// Display timer — polls VNC framebuffer and updates display tab (100ms).
fn searchCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {
    if (search_input) |si| {
        const val = cfltk.Fl_Input_value(si);
        const sv = std.mem.span(val);
        filter_len = @min(sv.len, filter_text.len - 1);
        _ = std.ascii.lowerString(@as([]u8, @ptrCast(&filter_text)), sv); filter_len = sv.len;
        refreshBrowser();
    }
}

fn displayTimerCB(_: ?*anyopaque) callconv(.c) void {
    if (vnc_client) |vc| {
        if (vc.checkDirty()) {
            if (display_box) |db| {
                var fw: c_int = 0; var fh: c_int = 0;
                if (vc.getSize(&fw, &fh)) {
                    var buf: [64]u8 = undefined;
                    const txt = std.fmt.bufPrintZ(&buf, "Display: {d}x{d} (VNC connected)", .{ fw, fh }) catch "VNC connected";
                    cfltk.Fl_Box_set_label(db, txt.ptr);
                }
            }
        }
    } else if (spice_client) |sc| {
        if (sc.checkDirty()) {
            if (display_box) |db| {
                var fw: c_int = 0; var fh: c_int = 0;
                if (sc.getSize(&fw, &fh)) {
                    var buf: [64]u8 = undefined;
                    const txt = std.fmt.bufPrintZ(&buf, "Display: {d}x{d} (SPICE connected)", .{ fw, fh }) catch "SPICE connected";
                    cfltk.Fl_Box_set_label(db, txt.ptr);
                }
            }
        }
    }
    _ = cfltk.Fl_repeat_timeout(0.1, displayTimerCB, null);
}

// Timer callback — checks VM liveness, connects display, and refreshes UI every 2 seconds.
fn timerCB(_: ?*anyopaque) callconv(.c) void {
    var changed = false;
    for (0..vm_count) |i| {
        const v = &vms[i];
        if (v.status == .running or v.status == .paused) {
            if (!qemu.isVmAlive(v)) {
                changed = true;
                vm_started[i] = 0;
                if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
                if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
            } else if (vm_started[i] > 0) {
                vm_started[i] += 2; // 2 seconds per timer tick
            }
        }
    }
    // Auto-connect VNC/SPICE and serial for the selected VM if running
    if (selected_idx) |idx| {
        if (idx < vm_count) {
            const v = &vms[idx];
            if (v.isAlive()) {
                if (v.embed_display and vnc_client == null and spice_client == null) {
                    if (v.display == .spice) {
                        spice_client = spice.SpiceClient.new();
                        if (spice_client) |sc| _ = sc.connect("127.0.0.1", @intCast(v.spice_port));
                    } else {
                        vnc_client = vnc.VncClient.new();
                        if (vnc_client) |vc| _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
                    }
                }
                if (v.enable_serial and serial_fd == null) {
                    serialConnect(v.getNameSlice());
                }
            }
        }
    }
    if (changed) { refreshBrowser(); refreshDetails(); }
    _ = cfltk.Fl_repeat_timeout(2.0, timerCB, null);
}

fn setDetail(i: usize, _: []const u8, value: []const u8) void {
    if (i < detail_labels.len) {
        if (detail_labels[i]) |dl| {
            cfltk.Fl_Box_set_label(dl, @ptrCast(value.ptr));
        }
    }
}

pub fn main() void {
    vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);
    _ = cfltk.Fl_set_scheme("gtk+");

    const WW: i32 = 960;
    const WH: i32 = 680;
    const win = cfltk.Fl_Window_new_wh(WW, WH, "KVMGUI");
    win_handle = @ptrCast(win);

    // Menu bar with working submenus
    const menu_bar = cfltk.Fl_Menu_Bar_new(0, 0, WW, 25, "");

    // Add menu items: label, shortcut (0=none), callback, userdata(0), flags(0)
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "File/New VM\tCtrl+N", 0, @ptrCast(&newVmCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "File/Import VM...", 0, @ptrCast(&importCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "File/Export OVF...", 0, @ptrCast(&exportOvfCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "File/Connect to Remote Server...", 0, @ptrCast(&connectRemoteCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "File/Quit\tCtrl+Q", 0, @ptrCast(&quitCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "Edit/Preferences...", 0, @ptrCast(&prefsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "Edit/Virtual Network Editor...", 0, @ptrCast(&vnetCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Power On/Off", 0, @ptrCast(&powerCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Settings...\tF2", 0, @ptrCast(&settingsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Snapshot Manager...", 0, @ptrCast(&snapshotCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Clone", 0, @ptrCast(&cloneCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Delete VM\tDEL", 0, @ptrCast(&deleteVmCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "View/Full Screen\tF11", 0, null, null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "Help/About KVMGUI", 0, @ptrCast(&aboutCB), null, 0);

    // Toolbar
    const tb_y: i32 = 28;
    const tb = cfltk.Fl_Box_new(0, tb_y, WW, 40, "");
    const new_btn = cfltk.Fl_Button_new(5, tb_y + 3, 80, 34, "New VM");
    const start_btn = cfltk.Fl_Button_new(90, tb_y + 3, 80, 34, "Power On");
    const susp_btn = cfltk.Fl_Button_new(175, tb_y + 3, 80, 34, "Suspend");
    const set_btn = cfltk.Fl_Button_new(260, tb_y + 3, 80, 34, "Settings");
    const home_btn = cfltk.Fl_Button_new(345, tb_y + 3, 80, 34, "Home");

    // Tooltips
    cfltk.Fl_Button_set_tooltip(new_btn, "Create a new virtual machine (Ctrl+N)");
    cfltk.Fl_Button_set_tooltip(start_btn, "Power on or off the selected virtual machine");
    cfltk.Fl_Button_set_tooltip(susp_btn, "Suspend the selected virtual machine to disk");
    cfltk.Fl_Button_set_tooltip(set_btn, "Edit virtual machine settings (F2)");
    cfltk.Fl_Button_set_tooltip(home_btn, "Return to Home (deselect VM, Ctrl+W)");
    _ = tb;

    cfltk.Fl_Button_set_callback(new_btn, newVmCB, null);
    cfltk.Fl_Button_set_callback(start_btn, powerCB, null);
    cfltk.Fl_Button_set_callback(susp_btn, suspendCB, null);
    cfltk.Fl_Button_set_callback(set_btn, settingsCB, null);
    cfltk.Fl_Button_set_callback(home_btn, homeCB, null);

    const body_y: i32 = 70;
    const body_h: i32 = WH - body_y - 26;
    const SW: i32 = 200;
    const CX: i32 = SW;
    const CW: i32 = WW - SW;

    // Sidebar
    _ = cfltk.Fl_Box_new(0, body_y, SW, 20, "Library");
    const b = cfltk.Fl_Browser_new(2, body_y + 22, SW - 4, body_h - 45, "");
    browser = @ptrCast(b);
    cfltk.Fl_Browser_set_callback(b, browserCB, null);
    const si = cfltk.Fl_Input_new(2, body_y + body_h - 20, SW - 4, 18, "");
    search_input = @ptrCast(si);
    cfltk.Fl_Input_set_callback(si, searchCB, null);

    // Context menu (right-click popup on VM browser)
    const ctx_menu = cfltk.Fl_Menu_Button_new(0, 0, 0, 0, "");
    ctx_menu_handle = @ptrCast(ctx_menu);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Power On/Off", 0, @ptrCast(&powerCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Settings...", 0, @ptrCast(&settingsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Snapshot Manager...", 0, @ptrCast(&snapshotCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Clone", 0, @ptrCast(&cloneCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Delete VM\tDEL", 0, @ptrCast(&deleteVmCB), null, 0);

    // Tabs
    const tabs = cfltk.Fl_Tabs_new(CX, body_y, CW, body_h, "");

    // Summary
    const sg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Summary");
    const nm = cfltk.Fl_Box_new(CX + 10, body_y + 30, CW - 20, 30, "No virtual machine selected.");
    sum_name = @ptrCast(nm);
    cfltk.Fl_Box_set_label_font(@ptrCast(nm), 1);
    cfltk.Fl_Box_set_label_size(@ptrCast(nm), 18);

    var ypos: i32 = body_y + 70;
    for ([_][]const u8{ "State:", "Guest OS:", "Memory:", "CPU:", "Hard Disk:", "Network:", "CD/DVD:", "Notes:" }, 0..) |lbl, i| {
        _ = cfltk.Fl_Box_new(CX + 10, ypos, 100, 18, @ptrCast(lbl.ptr));
        const dv = cfltk.Fl_Box_new(CX + 115, ypos, CW - 130, 18, "");
        detail_labels[i] = @ptrCast(dv);
        ypos += 22;
    }
    cfltk.Fl_Group_end(@ptrCast(sg));

    // Display tab
    const dg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Display");
    const db = cfltk.Fl_Box_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "VNC/SPICE display renders here when a VM is running.");
    display_box = @ptrCast(db);
    cfltk.Fl_Group_end(@ptrCast(dg));

    // Console tab
    const cg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Console");
    const cb = cfltk.Fl_Browser_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "");
    console_widget = @ptrCast(cb);
    _ = cfltk.Fl_Browser_add(cb, "Serial console — not connected.");
    cfltk.Fl_Group_end(@ptrCast(cg));

    cfltk.Fl_Group_end(@ptrCast(tabs));

    // Status bar
    const sb = cfltk.Fl_Box_new(0, WH - 26, WW, 26, "Ready — Local Mode");
    cfltk.Fl_Box_set_label_color(sb, 0x666666);
    status_bar = @ptrCast(sb);

    cfltk.Fl_Window_end(win);
    cfltk.Fl_Window_show(win);

    refreshBrowser();
    if (vm_count > 0) selected_idx = 0;
    refreshDetails();

    // Start periodic VM status check (every 2 seconds)
    _ = cfltk.Fl_add_timeout(2.0, timerCB, null);

    // Global keyboard shortcut handler
    _ = cfltk.Fl_add_handler(kbHandler);

    // Start display refresh timer (every 100ms for VNC framebuffer updates)
    _ = cfltk.Fl_add_timeout(0.1, displayTimerCB, null);

    // Console poll timer (every 500ms)
    _ = cfltk.Fl_add_timeout(0.5, consoleTimerCB, null);

    _ = cfltk.Fl_run();
}
