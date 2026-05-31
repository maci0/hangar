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
const qmp = @import("qmp.zig");
const ovf = @import("ovf.zig");
const vnet = @import("vnet.zig");
const appio = @import("appio.zig");
const autoprotect = @import("autoprotect.zig");
const transport = @import("transport.zig");
const fbmath = @import("fbmath.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
// posix aliases removed — use std.c directly

extern fn time(t: ?*c_long) c_long;

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
    @cInclude("cfltk/cfl_dialog.h");
});

const MAX_VMS = 64;
var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
var vm_count: usize = 0;
var selected_idx: ?usize = null;
var prefs: vm.Prefs = .{};
var browser: ?*cfltk.Fl_Browser = null;
var status_bar: ?*cfltk.Fl_Box = null;
var detail_labels: [12]?*cfltk.Fl_Box = [_]?*cfltk.Fl_Box{null} ** 12;
var sum_name: ?*cfltk.Fl_Box = null;
var win_handle: ?*cfltk.Fl_Window = null;
var ctx_menu_handle: ?*cfltk.Fl_Menu_Button = null;
var console_widget: ?*cfltk.Fl_Browser = null;
var display_box: ?*cfltk.Fl_Box = null;
var search_input: ?*cfltk.Fl_Input = null;
var filter_text: [64]u8 = [_]u8{0} ** 64;
var filter_len: usize = 0;
var vm_started: [MAX_VMS]i64 = [_]i64{0} ** MAX_VMS;
var g_vmm: hv_iface.Vmm = undefined;
var g_vmm_handles: [MAX_VMS]?hv_iface.VmmHandle = .{null} ** MAX_VMS;
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
fn shutdownCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { shutdownGuest(); }
fn resetCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { resetGuest(); }
fn suspendCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { suspendVm(); }
fn settingsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { editVmDialog(); }
fn importCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { importVm(); }
fn cloneCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { cloneVm(); }
fn snapshotCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { snapDialog(); }
fn deleteVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { deleteCurrentVm(); }
fn favCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { toggleFavorite(); }
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
    const dlg = cfltk.Fl_Window_new_wh(420, 220, "Connect to Remote Server");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 400, 20, "Server URL: unix:///path | http://host:port | shm:///name");
    const url_input = cfltk.Fl_Input_new(10, 35, 400, 24, "");
    _ = cfltk.Fl_Box_new(10, 70, 400, 20, "Auth token (optional):");
    const token_input = cfltk.Fl_Input_new(10, 95, 400, 24, "");
    const connect_btn = cfltk.Fl_Button_new(170, 175, 110, 30, "Connect");
    const local_btn = cfltk.Fl_Button_new(290, 175, 110, 30, "Local Mode");
    const status_label = cfltk.Fl_Box_new(10, 135, 400, 20, "Currently: Local Mode");

    const RD = struct { url: ?*cfltk.Fl_Input, token: ?*cfltk.Fl_Input, status: ?*cfltk.Fl_Box, dlg: ?*cfltk.Fl_Window };
    var rd = RD{ .url = @ptrCast(url_input), .token = @ptrCast(token_input), .status = @ptrCast(status_label), .dlg = @ptrCast(dlg) };

    const ConnectFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const rdp: *RD = @ptrCast(@alignCast(d orelse return));
            if (rdp.url) |u| {
                const s = std.mem.span(cfltk.Fl_Input_value(u));
                if (s.len == 0 or s.len >= remote_url.len) {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: invalid URL");
                    return;
                }
                // Parse URL and test connectivity with a health check.
                const parsed = transport.Url.parse(s) orelse {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: failed to parse URL");
                    return;
                };
                var conn = transport.Connection.connect(&parsed) orelse {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: connection failed — server unreachable");
                    return;
                };
                defer conn.close();

                // Optionally send auth token if provided.
                var auth_header: [128]u8 = undefined;
                const body: ?[]const u8 = if (rdp.token) |t| blk: {
                    const tok = std.mem.span(cfltk.Fl_Input_value(t));
                    if (tok.len > 0 and tok.len < 64) {
                        const h = std.fmt.bufPrint(&auth_header, "Authorization: Bearer {s}\r\n", .{tok}) catch "";
                        break :blk h;
                    }
                    break :blk null;
                } else null;

                // Health check: send a lightweight GET.
                var out_buf: [256]u8 = undefined;
                const n = conn.request("GET", "/api/health", body, &out_buf);
                if (n == 0) {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: health check failed — bad response");
                    return;
                }

                // Connection valid — enter remote mode.
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
                // Refresh the VM list from the remote server.
                remoteRefreshVmList();
                refreshBrowser();
                refreshDetails();
                if (rdp.dlg) |dl| cfltk.Fl_Window_hide(dl);
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
            // Reload local VM list from disk.
            vm_count = persist.load(&vms, std.heap.page_allocator, &prefs);
            refreshBrowser();
            refreshDetails();
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

fn apiPost(path: []const u8, body: []const u8, out: []u8) usize {
    if (!remote_mode or remote_url_len == 0) return 0;
    const url = transport.Url.parse(remote_url[0..remote_url_len]) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("POST", path, body, out);
}

/// Fetch the full vms.json config from the remote server and load it locally.
fn remoteRefreshVmList() void {
    if (!remote_mode or remote_url_len == 0) return;
    const url = transport.Url.parse(remote_url[0..remote_url_len]) orelse return;
    var conn = transport.Connection.connect(&url) orelse return;
    defer conn.close();

    var buf: [64 * 1024]u8 = undefined;
    const n = conn.request("GET", "/api/config", null, &buf);
    if (n == 0) return;
    var tmp_prefs: vm.Prefs = .{};
    vm_count = persist.loadFromSlice(&vms, buf[0..n], &tmp_prefs);
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
    if (!v.hasDisk()) { setStatus("VM has no disk — cannot export OVF"); return; }

    // Build a suggested filename from the VM name
    var suggest_buf: [256]u8 = undefined;
    const suggest = std.fmt.bufPrintZ(&suggest_buf, "{s}.ovf", .{v.getNameSlice()}) catch "vm.ovf";

    // Use FLTK's native file chooser to pick save path
    const path_ptr = cfltk.Fl_file_chooser("Save OVF Package", "*.ovf", suggest, 0);
    if (path_ptr == null or path_ptr[0] == 0) return;
    const save_path = std.mem.sliceTo(path_ptr, 0);

    // Build the OVF descriptor using ovf.zig
    const disk_bytes: u64 = @as(u64, v.disk_size_gb) * 1024 * 1024 * 1024;
    // Derive VMDK href from the save path
    var vmdk_name_buf: [256]u8 = undefined;
    const dot = std.mem.lastIndexOfScalar(u8, save_path, '.');
    const base = if (dot) |d| save_path[0..d] else save_path;
    const vmdk_href = std.fmt.bufPrint(&vmdk_name_buf, "{s}-disk1.vmdk", .{base}) catch {
        setStatus("Path too long for OVF export");
        return;
    };
    const spec = ovf.Spec{
        .name = v.getNameSlice(),
        .cpu_cores = v.cpu_cores,
        .memory_mb = v.memory_mb,
        .disk_capacity_bytes = disk_bytes,
        .vmdk_href = vmdk_href,
        .vmdk_size_bytes = disk_bytes,
        .has_network = v.nics[0].mode != .none,
    };

    const xml = ovf.buildDescriptor(spec, std.heap.page_allocator) catch {
        setStatus("Failed to generate OVF descriptor");
        return;
    };
    defer std.heap.page_allocator.free(xml);

    // Write the .ovf file using writeFile (atomic, single-shot)
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = save_path, .data = xml }) catch {
        setStatus("Failed to write OVF file");
        return;
    };

    // Generate the VMDK via qemu-img convert.
    const disk_path = v.getDiskPathSlice();
    if (disk_path.len > 0) {
        const vmdk_full = std.heap.page_allocator.dupeZ(u8, vmdk_href) catch {
            setStatus("OVF saved, but VMDK path buffer allocation failed");
            return;
        };
        defer std.heap.page_allocator.free(vmdk_full);
        if (getVmmHandle(idx)) |h| {
            g_vmm.convertDiskFn(h, disk_path, vmdk_full, @intFromEnum(v.disk_format), std.heap.page_allocator) catch {
                setStatus("OVF saved, but VMDK conversion failed (qemu-img missing?)");
                return;
            };
        } else {
            qemu.convertDiskImage(disk_path, v.disk_format, vmdk_full, std.heap.page_allocator) catch {
                setStatus("OVF saved, but VMDK conversion failed (qemu-img missing?)");
                return;
            };
        }
    }

    setStatus("OVF package exported successfully");
}

fn shutdown() void {
    // Save window geometry before closing.
    if (win_handle) |w| {
        const ww = cfltk.Fl_Window_width(w);
        const wh = cfltk.Fl_Window_height(w);
        if (ww > 0 and wh > 0) {
            prefs.win_x = @intCast(cfltk.Fl_Window_x(w));
            prefs.win_y = @intCast(cfltk.Fl_Window_y(w));
            prefs.win_w = @intCast(ww);
            prefs.win_h = @intCast(wh);
        }
    }
    persist.save(&vms, vm_count, prefs) catch {};
    // Clean up all Vmm handles.
    for (0..vm_count) |i| destroyVmmHandle(i);
    if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
    if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
    clearDisplay();
    serialDisconnect();
    if (win_handle) |w| cfltk.Fl_Window_hide(w);
}

fn cloneVm() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count or vm_count >= MAX_VMS) return;

    // Remote mode: dispatch clone to server, then refresh.
    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/clone/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        remoteRefreshVmList();
        refreshBrowser();
        refreshDetails();
        return;
    }

    const src = &vms[idx];

    // Ask for clone type: full (copy disk) or linked (COW backing file).
    var linked: bool = false;
    {
        const dlg = cfltk.Fl_Window_new_wh(320, 120, "Clone Type");
        cfltk.Fl_Window_make_modal(dlg, 0);
        _ = cfltk.Fl_Box_new(10, 10, 300, 20, "Choose clone type:");

        const link_check = cfltk.Fl_Check_Button_new(10, 40, 300, 24, "Linked clone (COW, needs source disk)");
        cfltk.Fl_Check_Button_set_value(link_check, 0);

        const CDlg = struct {
            link: ?*cfltk.Fl_Check_Button,
            dlg: ?*cfltk.Fl_Window,
            result: *bool,
        };
        var cd = CDlg{ .link = @ptrCast(link_check), .dlg = @ptrCast(dlg), .result = &linked };

        const FullCB = struct {
            fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
                const cd2: *CDlg = @ptrCast(@alignCast(data orelse return));
                cd2.result.* = false;
                if (cd2.dlg) |d| cfltk.Fl_Window_hide(d);
            }
        };
        const LinkedCB = struct {
            fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
                const cd2: *CDlg = @ptrCast(@alignCast(data orelse return));
                cd2.result.* = true;
                if (cd2.dlg) |d| cfltk.Fl_Window_hide(d);
            }
        };
        const full_btn = cfltk.Fl_Button_new(60, 75, 90, 30, "Full Clone");
        cfltk.Fl_Button_set_callback(full_btn, &FullCB.go, &cd);
        const linked_btn = cfltk.Fl_Button_new(170, 75, 90, 30, "Linked Clone");
        cfltk.Fl_Button_set_callback(linked_btn, &LinkedCB.go, &cd);

        cfltk.Fl_Window_show(dlg);
        while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    }

    var clone = src.*;
    var name_buf: [256]u8 = undefined;
    const suffix: [:0]const u8 = if (linked) " (linked clone)" else " (clone)";
    const clone_name = std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ src.getNameSlice(), suffix }) catch return;
    clone.setName(clone_name);
    clone.status = .stopped;
    clone.pid = null;
    clone.clearSavedStatePath();
    const ci: u16 = @intCast(vm_count);
    clone.vnc_port = 5900 + ci;
    clone.spice_port = 5930 + ci;
    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    clone.setMacAddress(std.mem.span(mac));

    if (linked and src.hasDisk()) {
        // Build a new disk path for the linked clone.
        var disk_buf: [vm.MAX_PATH]u8 = undefined;
        const src_disk = src.getDiskPathSlice();
        const dot = std.mem.lastIndexOfScalar(u8, src_disk, '.');
        const base = if (dot) |d| src_disk[0..d] else src_disk;
        const clone_disk = std.fmt.bufPrintZ(&disk_buf, "{s}_linked.qcow2", .{base}) catch {
            setStatus("Failed to build linked clone disk path");
            return;
        };
        clone.setDiskPath(clone_disk);
        clone.disk_format = .qcow2;

        // Create the linked clone backing file.
        if (getVmmHandle(idx)) |h| {
            g_vmm.createLinkedCloneFn(h, clone_disk, src_disk, @intFromEnum(src.disk_format), std.heap.page_allocator) catch {
                setStatus("Failed to create linked clone disk");
                return;
            };
        } else {
            qemu.createLinkedClone(clone_disk, src_disk, src.disk_format, std.heap.page_allocator) catch {
                setStatus("Failed to create linked clone disk");
                return;
            };
        }
    } else if (!linked) {
        // Full clone: change the disk path so it doesn't collide with source.
        if (src.hasDisk()) {
            var disk_buf: [vm.MAX_PATH]u8 = undefined;
            const src_disk = src.getDiskPathSlice();
            const dot = std.mem.lastIndexOfScalar(u8, src_disk, '.');
            const base = if (dot) |d| src_disk[0..d] else src_disk;
            if (std.fmt.bufPrintZ(&disk_buf, "{s}_clone.qcow2", .{base})) |clone_disk| {
                clone.setDiskPath(clone_disk);
            } else |_| {
                setStatus("Cloned, but failed to set disk path");
            }
        }
    }

    vms[vm_count] = clone;
    vm_count += 1;
    selected_idx = vm_count - 1;
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn importVm() void {
    if (vm_count >= MAX_VMS) { setStatus("Max VM limit reached"); return; }

    // Open file chooser for disk images
    const path_ptr = cfltk.Fl_file_chooser("Select Disk Image", "*.{qcow2,raw,img,vmdk,vdi,iso}", null, 0);
    if (path_ptr == null or path_ptr[0] == 0) return;
    const disk_path = std.mem.sliceTo(path_ptr, 0);

    // Remote mode: send the path to the server.
    if (remote_mode) {
        var out_buf: [64]u8 = undefined;
        _ = apiPost("/api/import", disk_path, &out_buf);
        remoteRefreshVmList();
        selected_idx = vm_count -| 1;
        refreshBrowser();
        refreshDetails();
        return;
    }

    // Derive VM name from the file name (strip extension)
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const name = blk: {
        // Find the last path separator
        const sep = std.mem.lastIndexOfScalar(u8, disk_path, '/');
        const basename = if (sep) |s| disk_path[s + 1 ..] else disk_path;
        // Strip extension
        const dot = std.mem.lastIndexOfScalar(u8, basename, '.');
        const name_slice = if (dot) |d| basename[0..d] else basename;
        if (name_slice.len >= name_buf.len) break :blk name_buf[0..];
        @memcpy(name_buf[0..name_slice.len], name_slice);
        break :blk name_buf[0..name_slice.len];
    };

    // Detect disk format from extension
    const fmt = blk: {
        const ext = if (std.mem.lastIndexOfScalar(u8, disk_path, '.')) |d| disk_path[d + 1 ..] else "";
        if (std.ascii.eqlIgnoreCase(ext, "qcow2")) break :blk vm.DiskFormat.qcow2;
        if (std.ascii.eqlIgnoreCase(ext, "vmdk")) break :blk vm.DiskFormat.vmdk;
        if (std.ascii.eqlIgnoreCase(ext, "vdi")) break :blk vm.DiskFormat.vdi;
        if (std.ascii.eqlIgnoreCase(ext, "raw") or std.ascii.eqlIgnoreCase(ext, "img")) break :blk vm.DiskFormat.raw;
        break :blk vm.DiskFormat.qcow2;
    };

    var cfg = vm.VmConfig{};
    cfg.setName(name);
    cfg.setDiskPath(disk_path);
    cfg.disk_format = fmt;
    cfg.disk_size_gb = 20; // default — user can resize in settings
    cfg.memory_mb = prefs.default_memory_mb;
    cfg.cpu_cores = prefs.default_cpu_cores;

    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));

    vms[vm_count] = cfg;
    vm_count += 1;
    selected_idx = vm_count - 1;
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
    setStatus("VM imported from disk image");
}

fn vnetDialog() void {
    // Load networks (or start with defaults for display)
    var net_set = vnet.load();
    if (net_set.count == 0) net_set = vnet.NetworkSet.defaults();

    const dlg = cfltk.Fl_Window_new_wh(580, 420, "Virtual Network Editor");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 560, 20, "Virtual Network switches (VMnet):");
    const net_list = cfltk.Fl_Browser_new(10, 35, 560, 260, "");
    // Populate the browser with real vnet data
    for (0..net_set.count) |i| {
        const net = &net_set.nets[i];
        var line: [256]u8 = undefined;
        const label = switch (net.vtype) {
            .bridged => blk: {
                const iface = net.getHostIfaceSlice();
                if (iface.len > 0) {
                    break :blk std.fmt.bufPrintZ(&line, "{s} — Bridged ({s})", .{ net.getNameSlice(), iface }) catch "?";
                }
                break :blk std.fmt.bufPrintZ(&line, "{s} — Bridged (auto)", .{net.getNameSlice()}) catch "?";
            },
            .host_only => std.fmt.bufPrintZ(&line, "{s} — Host-only ({s}/{s}{s})", .{ net.getNameSlice(), net.getSubnetSlice(), net.getMaskSlice(), if (net.dhcp) ", DHCP" else "" }) catch "?",
            .nat => std.fmt.bufPrintZ(&line, "{s} — NAT ({s}/{s}{s})", .{ net.getNameSlice(), net.getSubnetSlice(), net.getMaskSlice(), if (net.dhcp) ", DHCP" else "" }) catch "?",
        };
        _ = cfltk.Fl_Browser_add(net_list, label);
    }
    const VDlg = struct {
        b: ?*cfltk.Fl_Browser,
        ns: *vnet.NetworkSet,
        dlg: ?*cfltk.Fl_Window,
    };
    var vd = VDlg{ .b = @ptrCast(net_list), .ns = &net_set, .dlg = @ptrCast(dlg) };

    // Refresh helper: clears browser and re-populates from net_set
    const refreshFn = struct {
        fn refresh(vdp: *VDlg) void {
            if (vdp.b) |b| {
                cfltk.Fl_Browser_clear(b);
                for (0..vdp.ns.count) |i| {
                    const net = &vdp.ns.nets[i];
                    var line: [256]u8 = undefined;
                    const label = switch (net.vtype) {
                        .bridged => blk: {
                            const iface = net.getHostIfaceSlice();
                            if (iface.len > 0) break :blk std.fmt.bufPrintZ(&line, "{s} — Bridged ({s})", .{ net.getNameSlice(), iface }) catch "?";
                            break :blk std.fmt.bufPrintZ(&line, "{s} — Bridged (auto)", .{net.getNameSlice()}) catch "?";
                        },
                        .host_only => std.fmt.bufPrintZ(&line, "{s} — Host-only ({s}/{s}{s})", .{ net.getNameSlice(), net.getSubnetSlice(), net.getMaskSlice(), if (net.dhcp) ", DHCP" else "" }) catch "?",
                        .nat => std.fmt.bufPrintZ(&line, "{s} — NAT ({s}/{s}{s})", .{ net.getNameSlice(), net.getSubnetSlice(), net.getMaskSlice(), if (net.dhcp) ", DHCP" else "" }) catch "?",
                    };
                    _ = cfltk.Fl_Browser_add(b, label);
                }
            }
        }
    }.refresh;

    const CloseCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const vdp: *VDlg = @ptrCast(@alignCast(data orelse return));
            // Save changes before closing
            vnet.save(vdp.ns) catch {};
            if (vdp.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    const DefaultsCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const vdp: *VDlg = @ptrCast(@alignCast(data orelse return));
            vdp.ns.* = vnet.NetworkSet.defaults();
            refreshFn(vdp);
        }
    };
    const AddCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const vdp: *VDlg = @ptrCast(@alignCast(data orelse return));
            if (vdp.ns.count >= vnet.MAX_VNETS) return;
            // Add a new host-only switch with default settings
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "VMnet{d}", .{vdp.ns.count}) catch "VMnetX";
            _ = vdp.ns.add(name, .host_only, "192.168.100.0", "255.255.255.0", true, "192.168.100.128", "192.168.100.254", "");
            refreshFn(vdp);
        }
    };
    const RemoveCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const vdp: *VDlg = @ptrCast(@alignCast(data orelse return));
            if (vdp.b) |b| {
                const line = cfltk.Fl_Browser_value(b);
                if (line > 0 and line <= @as(c_int, @intCast(vdp.ns.count))) {
                    vdp.ns.remove(@intCast(line - 1));
                    refreshFn(vdp);
                }
            }
        }
    };
    const save_btn = cfltk.Fl_Button_new(10, 305, 90, 30, "Save");
    const defaults_btn = cfltk.Fl_Button_new(110, 305, 100, 30, "Use Defaults");
    const add_btn = cfltk.Fl_Button_new(220, 305, 60, 30, "Add");
    const remove_btn = cfltk.Fl_Button_new(285, 305, 70, 30, "Remove");
    const close_btn = cfltk.Fl_Button_new(480, 375, 90, 30, "Close");
    cfltk.Fl_Button_set_callback(save_btn, &CloseCB.go, &vd);
    cfltk.Fl_Button_set_callback(defaults_btn, &DefaultsCB.go, &vd);
    cfltk.Fl_Button_set_callback(add_btn, &AddCB.go, &vd);
    cfltk.Fl_Button_set_callback(remove_btn, &RemoveCB.go, &vd);
    cfltk.Fl_Button_set_callback(close_btn, &CloseCB.go, &vd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}
fn newVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { newVmDialog(); }

fn toggleFavorite() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    vms[idx].favorite = !vms[idx].favorite;
    refreshBrowser();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn deleteCurrentVm() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;

    // Remote mode: dispatch delete to server, then refresh.
    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/delete/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        remoteRefreshVmList();
        refreshBrowser();
        refreshDetails();
        return;
    }

    destroyVmmHandle(idx);
    var i = idx;
    while (i + 1 < vm_count) : (i += 1) vms[i] = vms[i + 1];
    // Shift Vmm handles too
    while (i < g_vmm_handles.len - 1) : (i += 1) g_vmm_handles[i] = g_vmm_handles[i + 1];
    g_vmm_handles[vm_count - 1] = null;
    vm_count -= 1;
    selected_idx = if (vm_count > 0) @min(idx, vm_count - 1) else null;
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

/// Build URL-encoded body for remote VM save requests from FLTK input fields.
fn buildSaveBody(buf: []u8, dd: *const anyopaque) ![]const u8 {
    const Ed = struct {
        na: ?*cfltk.Fl_Input, me: ?*cfltk.Fl_Input, cp: ?*cfltk.Fl_Input,
        dk: ?*cfltk.Fl_Input, io: ?*cfltk.Fl_Input, nt: ?*cfltk.Fl_Input,
        fw: ?*cfltk.Fl_Input, sh: ?*cfltk.Fl_Input, us: ?*cfltk.Fl_Input,
        gt: ?*cfltk.Fl_Check_Button, ap: ?*cfltk.Fl_Check_Button,
        ai: ?*cfltk.Fl_Input, am: ?*cfltk.Fl_Input,
        no: ?*cfltk.Fl_Input,
        nd: ?*cfltk.Fl_Input,
        d2p: ?*cfltk.Fl_Input, d2s: ?*cfltk.Fl_Input, d2f: ?*cfltk.Fl_Input,
        flp: ?*cfltk.Fl_Input,
        n2m: ?*cfltk.Fl_Input, n2mac: ?*cfltk.Fl_Input,
        n3m: ?*cfltk.Fl_Input, n3mac: ?*cfltk.Fl_Input,
        pf: ?*cfltk.Fl_Input,
        v: *vm.VmConfig, dl: ?*cfltk.Fl_Window,
    };
    const ed: *const Ed = @ptrCast(@alignCast(dd));
    var pos: usize = 0;
    if (ed.na) |n| { const s = try std.fmt.bufPrint(buf[pos..], "name={s}&", .{std.mem.span(cfltk.Fl_Input_value(n))}); pos += s.len; }
    if (ed.me) |m| { const s = try std.fmt.bufPrint(buf[pos..], "mem={s}&", .{std.mem.span(cfltk.Fl_Input_value(m))}); pos += s.len; }
    if (ed.cp) |c| { const s = try std.fmt.bufPrint(buf[pos..], "cpu={s}&", .{std.mem.span(cfltk.Fl_Input_value(c))}); pos += s.len; }
    if (ed.dk) |d2| { const s = try std.fmt.bufPrint(buf[pos..], "disk={s}&", .{std.mem.span(cfltk.Fl_Input_value(d2))}); pos += s.len; }
    if (ed.nt) |ni| { const s = try std.fmt.bufPrint(buf[pos..], "network={s}&", .{std.mem.span(cfltk.Fl_Input_value(ni))}); pos += s.len; }
    if (ed.fw) |fi| { const s = try std.fmt.bufPrint(buf[pos..], "firmware={s}&", .{std.mem.span(cfltk.Fl_Input_value(fi))}); pos += s.len; }
    if (ed.sh) |si| { const s = try std.fmt.bufPrint(buf[pos..], "shared_folder={s}&", .{std.mem.span(cfltk.Fl_Input_value(si))}); pos += s.len; }
    if (ed.us) |ui| { const s = try std.fmt.bufPrint(buf[pos..], "usb={s}&", .{std.mem.span(cfltk.Fl_Input_value(ui))}); pos += s.len; }
    if (ed.gt) |gti| { const s = try std.fmt.bufPrint(buf[pos..], "guest_tools={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(gti) != 0) 1 else 0)}); pos += s.len; }
    if (ed.ap) |api| { const s = try std.fmt.bufPrint(buf[pos..], "autoprotect={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(api) != 0) 1 else 0)}); pos += s.len; }
    if (ed.ai) |aii| { const s = try std.fmt.bufPrint(buf[pos..], "ap_interval={s}&", .{std.mem.span(cfltk.Fl_Input_value(aii))}); pos += s.len; }
    if (ed.am) |ami| { const s = try std.fmt.bufPrint(buf[pos..], "ap_max={s}&", .{std.mem.span(cfltk.Fl_Input_value(ami))}); pos += s.len; }
    if (ed.no) |notes_val| { const s = try std.fmt.bufPrint(buf[pos..], "notes={s}&", .{std.mem.span(cfltk.Fl_Input_value(notes_val))}); pos += s.len; }
    if (ed.d2p) |dp| { const s = try std.fmt.bufPrint(buf[pos..], "disk2_path={s}&", .{std.mem.span(cfltk.Fl_Input_value(dp))}); pos += s.len; }
    if (ed.d2s) |ds| { const s = try std.fmt.bufPrint(buf[pos..], "disk2_size={s}&", .{std.mem.span(cfltk.Fl_Input_value(ds))}); pos += s.len; }
    if (ed.flp) |fp| { const s = try std.fmt.bufPrint(buf[pos..], "floppy={s}&", .{std.mem.span(cfltk.Fl_Input_value(fp))}); pos += s.len; }
    if (ed.n2m) |nm| { const s = try std.fmt.bufPrint(buf[pos..], "nic2={s}&", .{std.mem.span(cfltk.Fl_Input_value(nm))}); pos += s.len; }
    if (ed.n3m) |nm| { const s = try std.fmt.bufPrint(buf[pos..], "nic3={s}&", .{std.mem.span(cfltk.Fl_Input_value(nm))}); pos += s.len; }
    if (ed.pf) |pfi| { const s = try std.fmt.bufPrint(buf[pos..], "portfw={s}&", .{std.mem.span(cfltk.Fl_Input_value(pfi))}); pos += s.len; }
    return buf[0..pos];
}

fn editVmDialog() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    const cfg = &vms[idx];
    const dlg = cfltk.Fl_Window_new_wh(480, 880, "Virtual Machine Settings");
    cfltk.Fl_Window_make_modal(dlg, 0);

    _ = cfltk.Fl_Box_new(10, 10, 110, 20, "VM Name:");
    const name_input = cfltk.Fl_Input_new(130, 8, 340, 24, cfg.getName());
    _ = cfltk.Fl_Box_new(10, 40, 110, 20, "Memory (MB):");
    var mbuf: [16]u8 = undefined;
    const mstr = std.fmt.bufPrintZ(&mbuf, "{d}", .{cfg.memory_mb}) catch "2048";
    const mem_input = cfltk.Fl_Input_new(130, 38, 340, 24, mstr);
    _ = cfltk.Fl_Box_new(10, 70, 110, 20, "CPU Cores:");
    var cbuf: [16]u8 = undefined;
    const cstr = std.fmt.bufPrintZ(&cbuf, "{d}", .{cfg.cpu_cores}) catch "2";
    const cpu_input = cfltk.Fl_Input_new(130, 68, 340, 24, cstr);
    _ = cfltk.Fl_Box_new(10, 100, 110, 20, "Disk Size (GB):");
    var dbuf: [16]u8 = undefined;
    const dstr = std.fmt.bufPrintZ(&dbuf, "{d}", .{cfg.disk_size_gb}) catch "20";
    const disk_input = cfltk.Fl_Input_new(130, 98, 340, 24, dstr);
    _ = cfltk.Fl_Box_new(10, 130, 110, 20, "ISO Path:");
    const iso_input = cfltk.Fl_Input_new(130, 128, 340, 24, if (cfg.hasIso()) cfg.getIsoPath() else "");
    _ = cfltk.Fl_Box_new(10, 160, 110, 20, "Network:");
    const net_input = cfltk.Fl_Input_new(130, 158, 340, 24, std.mem.span(cfg.nics[0].mode.label()));
    _ = cfltk.Fl_Box_new(10, 190, 110, 20, "Firmware:");
    const fw_input = cfltk.Fl_Input_new(130, 188, 340, 24, std.mem.span(cfg.firmware.label()));
    _ = cfltk.Fl_Box_new(10, 220, 110, 20, "Shared Folder:");
    const shared_input = cfltk.Fl_Input_new(130, 218, 340, 24, if (cfg.hasSharedFolder()) cfg.getSharedFolder() else "");
    _ = cfltk.Fl_Box_new(10, 250, 110, 20, "USB Device:");
    const usb_input = cfltk.Fl_Input_new(130, 248, 340, 24, if (cfg.hasUsbDevice()) cfg.getUsbDevice() else "");
    _ = cfltk.Fl_Box_new(10, 280, 110, 20, "Guest Tools ISO:");
    const gt_input = cfltk.Fl_Check_Button_new(130, 278, 340, 24, "Auto-mount virtio-win");
    if (cfg.guest_tools) cfltk.Fl_Check_Button_set_checked(gt_input, 1);
    _ = cfltk.Fl_Box_new(10, 310, 110, 20, "AutoProtect:");
    const ap_input = cfltk.Fl_Check_Button_new(130, 308, 100, 24, "Enabled");
    if (cfg.autoprotect) cfltk.Fl_Check_Button_set_checked(ap_input, 1);
    _ = cfltk.Fl_Box_new(240, 310, 80, 20, "Interval (min):");
    var ap_int_buf: [16]u8 = undefined;
    const ap_int_str = std.fmt.bufPrintZ(&ap_int_buf, "{d}", .{cfg.autoprotect_interval_min}) catch "1440";
    const ap_int_input = cfltk.Fl_Input_new(325, 308, 145, 24, ap_int_str);
    _ = cfltk.Fl_Box_new(10, 340, 110, 20, "Max Snapshots:");
    var ap_max_buf: [16]u8 = undefined;
    const ap_max_str = std.fmt.bufPrintZ(&ap_max_buf, "{d}", .{cfg.autoprotect_max}) catch "3";
    const ap_max_input = cfltk.Fl_Input_new(130, 338, 150, 24, ap_max_str);
    _ = cfltk.Fl_Box_new(10, 370, 110, 20, "Notes:");
    const notes_input = cfltk.Fl_Input_new(130, 368, 340, 80, if (cfg.hasNotes()) cfg.getNotes() else "");

    // ── Display count ──────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 460, 110, 20, "Displays:");
    var nd_buf: [16]u8 = undefined;
    const nd_str = std.fmt.bufPrintZ(&nd_buf, "{d}", .{cfg.num_displays}) catch "1";
    const nd_input = cfltk.Fl_Input_new(130, 458, 150, 24, nd_str);

    // ── Second disk ────────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 490, 110, 20, "Disk2 Path:");
    const d2p_input = cfltk.Fl_Input_new(130, 488, 340, 24, if (cfg.hasDisk2()) cfg.getDisk2Path() else "");
    _ = cfltk.Fl_Box_new(10, 520, 110, 20, "Disk2 Size (GB):");
    var d2s_buf: [16]u8 = undefined;
    const d2s_str = std.fmt.bufPrintZ(&d2s_buf, "{d}", .{cfg.disk2_size_gb}) catch "0";
    const d2s_input = cfltk.Fl_Input_new(130, 518, 150, 24, d2s_str);
    _ = cfltk.Fl_Box_new(300, 520, 60, 20, "Format:");
    const d2f_input = cfltk.Fl_Input_new(360, 518, 110, 24, std.mem.span(cfg.disk2_format.label()));

    // ── Floppy ─────────────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 550, 110, 20, "Floppy Path:");
    const flp_input = cfltk.Fl_Input_new(130, 548, 340, 24, if (cfg.hasFloppy()) cfg.getFloppyPath() else "");

    // ── NIC2 ───────────────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 580, 110, 20, "NIC2 Mode:");
    const n2m_input = cfltk.Fl_Input_new(130, 578, 150, 24, std.mem.span(cfg.nics[1].mode.label()));
    _ = cfltk.Fl_Box_new(300, 580, 60, 20, "MAC:");
    const n2mac_input = cfltk.Fl_Input_new(360, 578, 110, 24, if (cfg.nics[1].mac_len > 0) cfg.getNic2Mac() else "");

    // ── NIC3 ───────────────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 610, 110, 20, "NIC3 Mode:");
    const n3m_input = cfltk.Fl_Input_new(130, 608, 150, 24, std.mem.span(cfg.nics[2].mode.label()));
    _ = cfltk.Fl_Box_new(300, 610, 60, 20, "MAC:");
    const n3mac_input = cfltk.Fl_Input_new(360, 608, 110, 24, if (cfg.nics[2].mac_len > 0) cfg.getNic3Mac() else "");

    // ── Port Forwarding ────────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 640, 110, 20, "Port Forwards:");
    const pf_input = cfltk.Fl_Input_new(130, 638, 340, 24, if (cfg.hasPortForwards()) cfg.getPortForwards() else "");

    const save_btn = cfltk.Fl_Button_new(290, 840, 80, 30, "Save");
    const cancel_btn = cfltk.Fl_Button_new(380, 840, 80, 30, "Cancel");

    const Ed = struct {
        na: ?*cfltk.Fl_Input, me: ?*cfltk.Fl_Input, cp: ?*cfltk.Fl_Input,
        dk: ?*cfltk.Fl_Input, io: ?*cfltk.Fl_Input, nt: ?*cfltk.Fl_Input,
        fw: ?*cfltk.Fl_Input, sh: ?*cfltk.Fl_Input, us: ?*cfltk.Fl_Input,
        gt: ?*cfltk.Fl_Check_Button, ap: ?*cfltk.Fl_Check_Button,
        ai: ?*cfltk.Fl_Input, am: ?*cfltk.Fl_Input,
        no: ?*cfltk.Fl_Input,
        nd: ?*cfltk.Fl_Input,
        d2p: ?*cfltk.Fl_Input, d2s: ?*cfltk.Fl_Input, d2f: ?*cfltk.Fl_Input,
        flp: ?*cfltk.Fl_Input,
        n2m: ?*cfltk.Fl_Input, n2mac: ?*cfltk.Fl_Input,
        n3m: ?*cfltk.Fl_Input, n3mac: ?*cfltk.Fl_Input,
        pf: ?*cfltk.Fl_Input,
        v: *vm.VmConfig, dl: ?*cfltk.Fl_Window,
        idx: usize,
    };
    var ed = Ed{
        .na = @ptrCast(name_input), .me = @ptrCast(mem_input), .cp = @ptrCast(cpu_input),
        .dk = @ptrCast(disk_input), .io = @ptrCast(iso_input), .nt = @ptrCast(net_input),
        .fw = @ptrCast(fw_input), .sh = @ptrCast(shared_input), .us = @ptrCast(usb_input),
        .gt = @ptrCast(gt_input), .ap = @ptrCast(ap_input),
        .ai = @ptrCast(ap_int_input), .am = @ptrCast(ap_max_input),
        .no = @ptrCast(notes_input),
        .nd = @ptrCast(nd_input),
        .d2p = @ptrCast(d2p_input), .d2s = @ptrCast(d2s_input), .d2f = @ptrCast(d2f_input),
        .flp = @ptrCast(flp_input),
        .n2m = @ptrCast(n2m_input), .n2mac = @ptrCast(n2mac_input),
        .n3m = @ptrCast(n3m_input), .n3mac = @ptrCast(n3mac_input),
        .pf = @ptrCast(pf_input),
        .v = cfg, .dl = @ptrCast(dlg), .idx = idx,
    };

    const S = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const dd: *Ed = @ptrCast(@alignCast(d orelse return));
        // Remote mode: POST URL-encoded settings to server.
        if (remote_mode) {
            var body: [2048]u8 = undefined;
            const b = buildSaveBody(&body, dd) catch {
                setStatus("Failed to build save request");
                return;
            };
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/api/save/{d}", .{dd.idx}) catch return;
            var out_buf: [64]u8 = undefined;
            _ = apiPost(path, b, &out_buf);
            remoteRefreshVmList();
            refreshBrowser();
            refreshDetails();
            if (dd.dl) |dl2| cfltk.Fl_Window_hide(dl2);
            return;
        }
        if (dd.na) |n| dd.v.setName(std.mem.span(cfltk.Fl_Input_value(n)));
        if (dd.me) |m| dd.v.memory_mb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(m)), 10) catch dd.v.memory_mb);
        if (dd.cp) |c| dd.v.cpu_cores = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(c)), 10) catch dd.v.cpu_cores);
        if (dd.dk) |d2| dd.v.disk_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(d2)), 10) catch dd.v.disk_size_gb);
        if (dd.io) |i| { const s = std.mem.span(cfltk.Fl_Input_value(i)); if (s.len > 0) dd.v.setIsoPath(s) else dd.v.clearIsoPath(); }
        if (dd.nt) |ni| {
            const s = std.mem.span(cfltk.Fl_Input_value(ni));
            if (std.ascii.eqlIgnoreCase(s, "bridged")) { dd.v.nics[0].mode = .bridge; }
            else if (std.ascii.eqlIgnoreCase(s, "none")) { dd.v.nics[0].mode = .none; }
            else { dd.v.nics[0].mode = .user; }
        }
        if (dd.fw) |fi| {
            const s = std.mem.span(cfltk.Fl_Input_value(fi));
            if (std.ascii.eqlIgnoreCase(s, "uefi")) { dd.v.firmware = .uefi; }
            else { dd.v.firmware = .bios; }
        }
        if (dd.sh) |si| { const s = std.mem.span(cfltk.Fl_Input_value(si)); if (s.len > 0) dd.v.setSharedFolder(s) else dd.v.clearSharedFolder(); }
        if (dd.us) |ui| { const s = std.mem.span(cfltk.Fl_Input_value(ui)); if (s.len > 0) dd.v.setUsbDevice(s) else dd.v.clearUsbDevice(); }
        if (dd.gt) |gti| { dd.v.guest_tools = cfltk.Fl_Check_Button_is_checked(gti) != 0; }
        if (dd.ap) |api| { dd.v.autoprotect = cfltk.Fl_Check_Button_is_checked(api) != 0; }
        if (dd.ai) |aii| { dd.v.autoprotect_interval_min = std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(aii)), 10) catch dd.v.autoprotect_interval_min; }
        if (dd.am) |ami| { dd.v.autoprotect_max = std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(ami)), 10) catch dd.v.autoprotect_max; }
        if (dd.no) |notes_val| dd.v.setNotes(std.mem.span(cfltk.Fl_Input_value(notes_val)));
        if (dd.nd) |ndi| dd.v.num_displays = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(ndi)), 10) catch dd.v.num_displays);
        // ── New fields: disk2, floppy, NIC2, NIC3, port forwarding ──
        if (dd.d2p) |dp| { const s = std.mem.span(cfltk.Fl_Input_value(dp)); if (s.len > 0) dd.v.setDisk2Path(s) else dd.v.clearDisk2Path(); }
        if (dd.d2s) |ds| { dd.v.disk2_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(ds)), 10) catch dd.v.disk2_size_gb); }
        if (dd.d2f) |df| {
            const s = std.mem.span(cfltk.Fl_Input_value(df));
            if (std.ascii.eqlIgnoreCase(s, "raw")) { dd.v.disk2_format = .raw; }
            else if (std.ascii.eqlIgnoreCase(s, "vmdk")) { dd.v.disk2_format = .vmdk; }
            else if (std.ascii.eqlIgnoreCase(s, "vdi")) { dd.v.disk2_format = .vdi; }
            else { dd.v.disk2_format = .qcow2; }
        }
        if (dd.flp) |fp| { const s = std.mem.span(cfltk.Fl_Input_value(fp)); if (s.len > 0) dd.v.setFloppyPath(s) else dd.v.clearFloppyPath(); }
        if (dd.n2m) |nm| {
            const s = std.mem.span(cfltk.Fl_Input_value(nm));
            if (std.ascii.eqlIgnoreCase(s, "bridged")) { dd.v.nics[1].mode = .bridge; }
            else if (std.ascii.eqlIgnoreCase(s, "none")) { dd.v.nics[1].mode = .none; }
            else { dd.v.nics[1].mode = .user; }
        }
        if (dd.n2mac) |n2m| { const s = std.mem.span(cfltk.Fl_Input_value(n2m)); dd.v.setNic2Mac(s); }
        if (dd.n3m) |nm| {
            const s = std.mem.span(cfltk.Fl_Input_value(nm));
            if (std.ascii.eqlIgnoreCase(s, "bridged")) { dd.v.nics[2].mode = .bridge; }
            else if (std.ascii.eqlIgnoreCase(s, "none")) { dd.v.nics[2].mode = .none; }
            else { dd.v.nics[2].mode = .user; }
        }
        if (dd.n3mac) |n3m| { const s = std.mem.span(cfltk.Fl_Input_value(n3m)); dd.v.setNic3Mac(s); }
        if (dd.pf) |pfi| { const s = std.mem.span(cfltk.Fl_Input_value(pfi)); if (s.len > 0) dd.v.setPortForwards(s) else dd.v.clearPortForwards(); }
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
    const dlg = cfltk.Fl_Window_new_wh(480, 200, "Snapshot Manager");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 460, 20, "Snapshot name:");
    const ni = cfltk.Fl_Input_new(10, 30, 460, 24, "snapshot1");
    const tb = cfltk.Fl_Button_new(10, 70, 80, 30, "Take");
    const lb = cfltk.Fl_Button_new(100, 70, 80, 30, "List");
    const rb = cfltk.Fl_Button_new(190, 70, 80, 30, "Revert");
    const db = cfltk.Fl_Button_new(280, 70, 80, 30, "Delete");
    const cb = cfltk.Fl_Button_new(10, 160, 80, 30, "Close");
    const rl = cfltk.Fl_Box_new(10, 110, 460, 40, "");
    const SD = struct { n: ?*cfltk.Fl_Input, r: ?*cfltk.Fl_Box, v: *vm.VmConfig, d: ?*cfltk.Fl_Window, idx: usize, remote: bool };
    var sd = SD{ .n = @ptrCast(ni), .r = @ptrCast(rl), .v = vc, .d = @ptrCast(dlg), .idx = idx, .remote = remote_mode };
    const TK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.n) |nn| {
            if (s.remote) {
                var path_buf: [48]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "/api/snapshot/take/{d}", .{s.idx}) catch return;
                var out_buf: [64]u8 = undefined;
                _ = apiPost(path, std.mem.span(cfltk.Fl_Input_value(nn)), &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Created (remote).");
            } else if (getVmmHandle(s.idx)) |h| {
                g_vmm.snapshotCreateFn(h, s.v.getDiskPathSlice(), std.mem.span(cfltk.Fl_Input_value(nn)), std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Created.");
            } else {
                qemu.snapshotCreate(s.v.getDiskPathSlice(), std.mem.span(cfltk.Fl_Input_value(nn)), std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Created.");
            }
        }
    }};
    const LK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.remote) {
            var path_buf: [48]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/api/snapshot/list/{d}", .{s.idx}) catch return;
            var out_buf: [4096]u8 = undefined;
            const n = apiGet(path, &out_buf);
            if (s.r) |rr| {
                if (n > 0 and n <= out_buf.len) {
                    cfltk.Fl_Box_set_label(rr, @ptrCast(&out_buf));
                } else {
                    cfltk.Fl_Box_set_label(rr, "(none)");
                }
            }
        } else {
            var buf: [4096]u8 = undefined;
            const n: usize = if (getVmmHandle(s.idx)) |h|
                g_vmm.snapshotListFn(h, s.v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0
            else
                qemu.snapshotList(s.v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0;
            if (s.r) |rr| { if (n > 0) cfltk.Fl_Box_set_label(rr, @ptrCast(&buf)); }
        }
    }};
    const RK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.n) |nn| {
            const tag = std.mem.span(cfltk.Fl_Input_value(nn));
            if (tag.len == 0) return;
            if (s.remote) {
                var path_buf: [64]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "/api/snapshot/revert/{d}", .{s.idx}) catch return;
                var out_buf: [64]u8 = undefined;
                _ = apiPost(path, tag, &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Reverted (remote).");
            } else if (getVmmHandle(s.idx)) |h| {
                g_vmm.snapshotApplyFn(h, s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Reverted.");
            } else {
                qemu.snapshotApply(s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Reverted.");
            }
        }
    }};
    const DK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.n) |nn| {
            const tag = std.mem.span(cfltk.Fl_Input_value(nn));
            if (tag.len == 0) return;
            if (s.remote) {
                var path_buf: [64]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "/api/snapshot/delete/{d}", .{s.idx}) catch return;
                var out_buf: [64]u8 = undefined;
                _ = apiPost(path, tag, &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Deleted (remote).");
            } else if (getVmmHandle(s.idx)) |h| {
                g_vmm.snapshotDeleteFn(h, s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Deleted.");
            } else {
                qemu.snapshotDelete(s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Deleted.");
            }
        }
    }};
    const CK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.d) |dd| cfltk.Fl_Window_hide(dd);
    }};
    cfltk.Fl_Button_set_callback(tb, &TK.go, &sd);
    cfltk.Fl_Button_set_callback(lb, &LK.go, &sd);
    cfltk.Fl_Button_set_callback(rb, &RK.go, &sd);
    cfltk.Fl_Button_set_callback(db, &DK.go, &sd);
    cfltk.Fl_Button_set_callback(cb, &CK.go, &sd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn prefsDialog() void {
    const dlg = cfltk.Fl_Window_new_wh(420, 290, "Preferences");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 130, 20, "Default Memory (MB):");
    var mb: [16]u8 = undefined;
    const mem_input = cfltk.Fl_Input_new(140, 8, 270, 24, std.fmt.bufPrintZ(&mb, "{d}", .{prefs.default_memory_mb}) catch "2048");
    _ = cfltk.Fl_Box_new(10, 40, 130, 20, "Default CPU Cores:");
    var cb2: [16]u8 = undefined;
    const cpu_input = cfltk.Fl_Input_new(140, 38, 270, 24, std.fmt.bufPrintZ(&cb2, "{d}", .{prefs.default_cpu_cores}) catch "2");

    _ = cfltk.Fl_Box_new(10, 70, 130, 20, "AutoProtect:");
    const ap_check = cfltk.Fl_Check_Button_new(140, 68, 20, 24, "");
    cfltk.Fl_Check_Button_set_value(ap_check, if (prefs.autoprotect_enabled_default) 1 else 0);

    _ = cfltk.Fl_Box_new(10, 100, 130, 20, "Snapshot Interval (min):");
    var ab: [16]u8 = undefined;
    const ap_int_input = cfltk.Fl_Input_new(140, 98, 270, 24, std.fmt.bufPrintZ(&ab, "{d}", .{prefs.autoprotect_interval_min_default}) catch "60");

    _ = cfltk.Fl_Box_new(10, 130, 130, 20, "Max Snapshots:");
    var ac: [16]u8 = undefined;
    const ap_max_input = cfltk.Fl_Input_new(140, 128, 270, 24, std.fmt.bufPrintZ(&ac, "{d}", .{prefs.autoprotect_max_default}) catch "10");

    // Save reads the input fields back and persists prefs
    const PData = struct {
        mem: ?*cfltk.Fl_Input,
        cpu: ?*cfltk.Fl_Input,
        ap_check: ?*cfltk.Fl_Check_Button,
        ap_int: ?*cfltk.Fl_Input,
        ap_max: ?*cfltk.Fl_Input,
        dlg: ?*cfltk.Fl_Window,
    };
    var pd = PData{
        .mem = @ptrCast(mem_input),
        .cpu = @ptrCast(cpu_input),
        .ap_check = @ptrCast(ap_check),
        .ap_int = @ptrCast(ap_int_input),
        .ap_max = @ptrCast(ap_max_input),
        .dlg = @ptrCast(dlg),
    };

    const SaveCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const pp: *PData = @ptrCast(@alignCast(data orelse return));
            if (pp.mem) |mi| {
                const val = std.mem.span(cfltk.Fl_Input_value(mi));
                if (val.len > 0) {
                    prefs.default_memory_mb = std.fmt.parseInt(u32, val, 10) catch 2048;
                }
            }
            if (pp.cpu) |ci| {
                const val = std.mem.span(cfltk.Fl_Input_value(ci));
                if (val.len > 0) {
                    prefs.default_cpu_cores = std.fmt.parseInt(u32, val, 10) catch 2;
                }
            }
            if (pp.ap_check) |apc| {
                prefs.autoprotect_enabled_default = cfltk.Fl_Check_Button_value(apc) != 0;
            }
            if (pp.ap_int) |ai| {
                const val = std.mem.span(cfltk.Fl_Input_value(ai));
                if (val.len > 0) {
                    prefs.autoprotect_interval_min_default = std.fmt.parseInt(u32, val, 10) catch 60;
                }
            }
            if (pp.ap_max) |am| {
                const val = std.mem.span(cfltk.Fl_Input_value(am));
                if (val.len > 0) {
                    prefs.autoprotect_max_default = std.fmt.parseInt(u32, val, 10) catch 10;
                }
            }
            persist.save(&vms, vm_count, prefs) catch {};
            if (pp.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    const save_btn = cfltk.Fl_Button_new(230, 250, 80, 30, "Save");
    cfltk.Fl_Button_set_callback(save_btn, &SaveCB.go, &pd);

    const CancelCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const pp: *PData = @ptrCast(@alignCast(data orelse return));
            if (pp.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    const cancel_btn = cfltk.Fl_Button_new(320, 250, 90, 30, "Cancel");
    cfltk.Fl_Button_set_callback(cancel_btn, &CancelCB.go, &pd);

    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

fn selectCurrent() void {
    const b = browser orelse return;
    const line = cfltk.Fl_Browser_value(b);
    if (line <= 0) { selected_idx = null; return; }
    const target: usize = @intCast(line - 1);

    const filter: []const u8 = if (filter_len > 0) filter_text[0..filter_len] else "";
    var cursor: usize = 0;
    selected_idx = null;

    // Determine if separator is present: at least one fav AND one non-fav visible.
    var fav_count: usize = 0;
    var nonfav_count: usize = 0;
    for (0..vm_count) |i| {
        if (!filterMatch(&vms[i], filter)) continue;
        if (vms[i].favorite) fav_count += 1 else nonfav_count += 1;
    }
    const has_sep = fav_count > 0 and nonfav_count > 0;

    // Pass 1: favorites
    for (0..vm_count) |i| {
        if (!vms[i].favorite or !filterMatch(&vms[i], filter)) continue;
        if (cursor == target) { selected_idx = i; return; }
        cursor += 1;
    }

    // Separator line
    if (has_sep) {
        if (cursor == target) return; // clicked on separator → no selection
        cursor += 1;
    }

    // Pass 2: non-favorites (or all if no favs)
    for (0..vm_count) |i| {
        const eligible = if (has_sep) !vms[i].favorite else true;
        if (!eligible or !filterMatch(&vms[i], filter)) continue;
        if (cursor == target) { selected_idx = i; return; }
        cursor += 1;
    }
}

fn filterMatch(v: *const vm.VmConfig, filter: []const u8) bool {
    if (filter.len == 0) return true;
    const name = v.getNameSlice();
    var lower_buf: [128]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, name);
    return std.mem.indexOf(u8, lower, filter) != null;
}

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

fn togglePower() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;

    // Remote mode: dispatch to server.
    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/power/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        remoteRefreshVmList();
        refreshBrowser();
        refreshDetails();
        return;
    }

    if (vms[idx].isAlive()) {
        // Power off: kill the QEMU process and clean up connections
        if (getVmmHandle(idx)) |h| {
            g_vmm.forceStopFn(h);
            g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(&vms[idx]); qemu.reapVm(&vms[idx]);
        }
        if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
        if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
        clearDisplay();
        serialDisconnect();
    } else {
        // Power on: start QEMU (handles -incoming for resume from suspended state)
        if (getVmmHandle(idx)) |h| {
            g_vmm.startFn(h, @ptrCast(&vms[idx])) catch {
                setStatus("Failed to start VM");
                return;
            };
        } else {
            qemu.startVm(&vms[idx], std.heap.page_allocator) catch {
                setStatus("Failed to start VM");
                return;
            };
        }
        vm_started[idx] = 1;
        // If we resumed from a saved state, clear it so next power-on is fresh
        if (vms[idx].hasSavedState()) {
            vms[idx].clearSavedStatePath();
        }
    }
    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
}

fn shutdownGuest() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    if (!vms[idx].isAlive()) { setStatus("VM is not running"); return; }

    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/shutdown/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        setStatus("Shut down guest (remote).");
        return;
    }
    if (getVmmHandle(idx)) |h| {
        g_vmm.shutdownFn(h) catch { setStatus("Shutdown failed"); return; };
    } else {
        shutdownViaQmp(idx) catch { setStatus("Shutdown failed"); return; };
    }
    setStatus("Shut down guest — ACPI power button sent.");
}

fn resetGuest() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    if (!vms[idx].isAlive()) { setStatus("VM is not running"); return; }

    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/reset/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        setStatus("Reset guest (remote).");
        return;
    }
    if (getVmmHandle(idx)) |h| {
        g_vmm.resetFn(h) catch { setStatus("Reset failed"); return; };
    } else {
        resetViaQmp(idx) catch { setStatus("Reset failed"); return; };
    }
    setStatus("Reset guest — system_reset sent.");
}

fn shutdownViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.powerdown();
}

fn resetViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.systemReset();
}

fn suspendVm() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;

    // Remote mode: dispatch to server.
    if (remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/suspend/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = apiPost(path, "", &out_buf);
        remoteRefreshVmList();
        refreshBrowser();
        refreshDetails();
        return;
    }

    const v = &vms[idx];
    if (!v.isAlive()) {
        setStatus("VM is not running — cannot suspend");
        return;
    }

    // Generate state save path
    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/kvmgui-state-{s}.bin", .{v.getNameSlice()}) catch {
        setStatus("Failed to build state path");
        return;
    };

    // Connect QMP and migrate to file
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse {
        setStatus("Failed to build QMP socket path");
        return;
    };
    client.connect(sock) catch {
        setStatus("Failed to connect QMP for suspend");
        return;
    };
    defer client.disconnect();

    setStatus("Suspending VM to file...");
    client.suspendToFile(path) catch {
        setStatus("Suspend migration failed to start");
        return;
    };

    // Wait for migration to complete (30s timeout built into waitMigrateComplete)
    client.waitMigrateComplete() catch {
        setStatus("Suspend migration timed out — VM may still be running");
        return;
    };

    // Update config with saved state path
    v.setSavedStatePath(path[0..]);

    // Kill the QEMU process
    if (getVmmHandle(idx)) |h| {
        g_vmm.forceStopFn(h);
        g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
    }

    // Clean up display and serial connections
    if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
    if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
    clearDisplay();
    serialDisconnect();

    refreshBrowser();
    refreshDetails();
    persist.save(&vms, vm_count, prefs) catch {};
    setStatus("VM suspended to file — ready to resume on power-on");
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
            // Remote mode: POST to /api/create, then refresh from server.
            if (remote_mode) {
                var body: [512]u8 = undefined;
                var pos: usize = 0;
                if (dd.name) |n| {
                    const s = std.fmt.bufPrint(body[pos..], "name={s}&", .{std.mem.span(cfltk.Fl_Input_value(n))}) catch body[pos..];
                    pos += s.len;
                }
                if (dd.mem) |m| {
                    const s = std.fmt.bufPrint(body[pos..], "mem={s}&", .{std.mem.span(cfltk.Fl_Input_value(m))}) catch body[pos..];
                    pos += s.len;
                }
                if (dd.cpu) |c| {
                    const s = std.fmt.bufPrint(body[pos..], "cpu={s}&", .{std.mem.span(cfltk.Fl_Input_value(c))}) catch body[pos..];
                    pos += s.len;
                }
                if (dd.disk) |d2| {
                    const s = std.fmt.bufPrint(body[pos..], "disk={s}", .{std.mem.span(cfltk.Fl_Input_value(d2))}) catch body[pos..];
                    pos += s.len;
                }
                var out_buf: [64]u8 = undefined;
                _ = apiPost("/api/create", body[0..pos], &out_buf);
                remoteRefreshVmList();
                selected_idx = vm_count -| 1;
                refreshBrowser();
                refreshDetails();
                if (dd.dlg) |d| cfltk.Fl_Window_hide(d);
                return;
            }
            if (vm_count >= MAX_VMS) return;

            var cfg = vm.VmConfig{};
            if (dd.name) |n| cfg.setName(std.mem.span(cfltk.Fl_Input_value(n)));
            if (dd.mem) |m| cfg.memory_mb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(m)), 10) catch 2048);
            if (dd.cpu) |c| cfg.cpu_cores = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(c)), 10) catch 2);
            if (dd.disk) |d| cfg.disk_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(d)), 10) catch 20);

            // Apply AutoProtect defaults from preferences
            cfg.autoprotect = prefs.autoprotect_enabled_default;
            cfg.autoprotect_interval_min = prefs.autoprotect_interval_min_default;
            cfg.autoprotect_max = prefs.autoprotect_max_default;

            var mac_buf: [18]u8 = undefined;
            const mac = vm.generateMacAddress(&mac_buf);
            cfg.setMacAddress(std.mem.span(mac));

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

    // Pass 1: favorites (star prefix).
    for (0..vm_count) |i| {
        const v = &vms[i];
        if (v.favorite and filterMatch(v, filter)) {
            var buf: [256]u8 = undefined;
            const prefix: []const u8 = switch (v.status) { .running => "★▶ ", .paused => "★⏸ ", else => "★  " };
            const txt = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ prefix, v.getNameSlice() }) catch continue;
            cfltk.Fl_Browser_add(b, txt.ptr);
        }
    }

    // Check if we need a separator.
    var has_favs = false;
    var has_nonfavs = false;
    for (0..vm_count) |i| {
        if (filterMatch(&vms[i], filter)) {
            if (vms[i].favorite) has_favs = true else has_nonfavs = true;
        }
    }

    if (has_favs and has_nonfavs) {
        _ = cfltk.Fl_Browser_add(b, "──────────");
    }

    // Pass 2: non-favorites (or all if no favs).
    for (0..vm_count) |i| {
        const v = &vms[i];
        const show = if (has_favs) !v.favorite else true;
        if (show and filterMatch(v, filter)) {
            var buf: [256]u8 = undefined;
            const prefix: []const u8 = switch (v.status) { .running => "▶ ", .paused => "⏸ ", else => "  " };
            const txt = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ prefix, v.getNameSlice() }) catch continue;
            cfltk.Fl_Browser_add(b, txt.ptr);
        }
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
                setDetail(5, "Network", std.mem.span(v.nics[0].mode.label()));
                setDetail(6, "CD/DVD", if (v.hasIso()) v.getIsoPathSlice() else "Auto detect");
                setDetail(7, "Notes", if (v.hasNotes()) v.getNotesSlice() else "");
                setDetail(8, "Shared Folder", if (v.hasSharedFolder()) v.getSharedFolderSlice() else "(none)");
                setDetail(9, "USB Device", if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "(none)");
                setDetail(10, "Guest Tools", if (v.guest_tools) "Enabled" else "Disabled");
                if (v.autoprotect) {
                    var ap_buf: [64]u8 = undefined;
                    const ap_str = std.fmt.bufPrintZ(&ap_buf, "Every {d} min, keep {d}", .{ v.autoprotect_interval_min, v.autoprotect_max }) catch "Enabled";
                    setDetail(11, "AutoProtect", ap_str);
                } else {
                    setDetail(11, "AutoProtect", "Disabled");
                }
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
    if (display_box) |db| {
        const box_w = cfltk.Fl_Box_width(db);
        const box_h = cfltk.Fl_Box_height(db);
        if (vnc_client) |vc| {
            if (vc.checkDirty()) {
                if (vc.lockFb()) |fb| {
                    defer vc.unlockFb();
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (vc.getSize(&fw, &fh)) {
                        renderFramebuffer(db, fb, fw, fh, 0, box_w, box_h);
                    }
                }
            }
        } else if (spice_client) |sc| {
            if (sc.checkDirty()) {
                if (sc.getFb()) |fb| {
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (sc.getSize(&fw, &fh)) {
                        renderFramebuffer(db, fb, fw, fh, sc.stride, box_w, box_h);
                    }
                }
            }
        }
    }
    _ = cfltk.Fl_repeat_timeout(0.1, displayTimerCB, null);
}

/// Copy+swap a BGRA framebuffer to RGBA, wrap in an Fl_RGB_Image,
/// scale to fit the display box, and attach it.
fn renderFramebuffer(
    db: *cfltk.Fl_Box,
    fb: [*]const u8,
    fw: c_int,
    fh: c_int,
    src_stride: c_int,
    box_w: c_int,
    box_h: c_int,
) void {
    const px = fbmath.fbFits(fw, fh, std.math.maxInt(usize) / 4) orelse return;
    const buf_size: usize = px * 4;
    const stride: usize = if (src_stride > 0) @intCast(src_stride) else @as(usize, @intCast(fw)) * 4;

    const rgba = std.heap.c_allocator.alloc(u8, buf_size) catch return;
    defer std.heap.c_allocator.free(rgba);

    const dst_stride: usize = @as(usize, @intCast(fw)) * 4;
    var y: c_int = 0;
    while (y < fh) : (y += 1) {
        const src_row = fb[@as(usize, @intCast(y)) * stride ..];
        const dst_row = rgba[@as(usize, @intCast(y)) * dst_stride ..];
        var x: usize = 0;
        while (x < @as(usize, @intCast(fw))) : (x += 1) {
            const si = x * 4;
            const di = x * 4;
            dst_row[di + 0] = src_row[si + 2]; // R ← B
            dst_row[di + 1] = src_row[si + 1]; // G ← G
            dst_row[di + 2] = src_row[si + 0]; // B ← R
            dst_row[di + 3] = src_row[si + 3]; // A ← A
        }
    }

    const img = cfltk.Fl_RGB_Image_new(@ptrCast(rgba.ptr), fw, fh, 4, 0);
    if (img == null) return;

    // Scale down to fit the display box (proportional, no expansion).
    if (fw > box_w or fh > box_h) {
        cfltk.Fl_RGB_Image_scale(img, box_w, box_h, 1, 0);
    }

    cfltk.Fl_Box_set_label(db, "");
    cfltk.Fl_Box_set_image(db, @ptrCast(img));
    cfltk.Fl_Box_redraw(db);
}

/// Clear the display box — release any image and restore placeholder text.
fn clearDisplay() void {
    if (display_box) |db| {
        cfltk.Fl_Box_set_image(db, null);
        cfltk.Fl_Box_set_label(db, "VNC/SPICE display renders here when a VM is running.");
        cfltk.Fl_Box_redraw(db);
    }
}

// Timer callback — checks VM liveness, connects display, refreshes UI every 2 seconds.
// Also runs AutoProtect snapshot scheduling for VMs with autoprotect enabled.
fn timerCB(_: ?*anyopaque) callconv(.c) void {
    var changed = false;
    const now_unix = time(null);

    for (0..vm_count) |i| {
        const v = &vms[i];
        if (v.status == .running or v.status == .paused) {
            const alive: bool = if (getVmmHandle(i)) |h| g_vmm.isAliveFn(h) else qemu.isVmAlive(v);
            if (!alive) {
                changed = true;
                vm_started[i] = 0;
                if (vnc_client) |vc| { vc.disconnect(); vc.free(); vnc_client = null; }
                if (spice_client) |sc| { sc.disconnect(); sc.free(); spice_client = null; }
                clearDisplay();
            } else if (vm_started[i] > 0) {
                vm_started[i] += 2; // 2 seconds per timer tick
            }
        }

        // ── AutoProtect snapshot scheduling ──────────────────────
        if (v.autoprotect and v.status == .running and v.hasDisk()) {
            if (autoprotect.due(true, v.autoprotect_interval_min, v.autoprotect_last_epoch, now_unix)) {
                const seq = v.autoprotect_last_seq;
                v.autoprotect_last_seq = seq +% 1; // wrapping add — seq is u32
                v.autoprotect_last_epoch = now_unix;

                // Build snapshot name
                var name_buf: [64]u8 = undefined;
                const snap_name = autoprotect.snapName(&name_buf, seq);
                if (snap_name.len > 0) {
                    if (getVmmHandle(i)) |h| {
                        g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch {};
                    } else {
                        qemu.snapshotCreate(v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch {};
                    }

                    // Prune excess AutoProtect snapshots
                    var list_buf: [4096]u8 = undefined;
                    if (if (getVmmHandle(i)) |h|
                        g_vmm.snapshotListFn(h, v.getDiskPathSlice(), &list_buf, std.heap.page_allocator)
                    else
                        qemu.snapshotList(v.getDiskPathSlice(), &list_buf, std.heap.page_allocator)) |_| {
                        // Count AutoProtect snapshots and collect the oldest names
                        var auto_names: [16][]const u8 = undefined;
                        var auto_count: usize = 0;
                        var lines = std.mem.splitScalar(u8, list_buf[0..], '\n');
                        while (lines.next()) |line| {
                            const trimmed = std.mem.trim(u8, line, " \t\r");
                            // qemu-img snapshot -l output has columns: ID TAG VM SIZE DATE VM CLOCK
                            // The snapshot name (TAG) is typically the second column
                            if (std.mem.indexOf(u8, trimmed, autoprotect.PREFIX)) |_| {
                                // Extract the name portion (between column 1 and 2 boundaries)
                                var parts = std.mem.splitScalar(u8, trimmed, ' ');
                                _ = parts.next(); // skip ID (e.g. "1")
                                const tag = parts.next() orelse continue;
                                if (auto_count < auto_names.len) {
                                    auto_names[auto_count] = tag;
                                }
                                auto_count += 1;
                            }
                        }
                        const excess = autoprotect.pruneExcess(auto_count, v.autoprotect_max);
                        // Delete the oldest AutoProtect snapshots (they come first in the list)
                        const to_delete = @min(excess, auto_names.len);
                        const hnd = getVmmHandle(i);
                        for (0..to_delete) |j| {
                            if (hnd) |h| {
                                g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), auto_names[j], std.heap.page_allocator) catch {};
                            } else {
                                qemu.snapshotDelete(v.getDiskPathSlice(), auto_names[j], std.heap.page_allocator) catch {};
                            }
                        }
                    } else |_| {}
                }
                persist.save(&vms, vm_count, prefs) catch {};
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

fn setStatus(msg: []const u8) void {
    if (status_bar) |sb| {
        var buf: [256]u8 = undefined;
        if (msg.len >= buf.len) {
            cfltk.Fl_Box_set_label(sb, @ptrCast(msg.ptr));
        } else {
            @memcpy(buf[0..msg.len], msg);
            buf[msg.len] = 0;
            cfltk.Fl_Box_set_label(sb, @ptrCast(&buf));
        }
    }
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

    // Initialize the HV abstraction dispatch table (QEMU backend).
    g_vmm = hv_backend.createVmm(.auto);

    const WW: i32 = if (prefs.win_w > 0) prefs.win_w else 960;
    const WH: i32 = if (prefs.win_h > 0) prefs.win_h else 680;
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
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Shut Down Guest", 0, @ptrCast(&shutdownCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Reset Guest", 0, @ptrCast(&resetCB), null, 0);
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
    const sd_btn = cfltk.Fl_Button_new(260, tb_y + 3, 80, 34, "Shut Down");
    const rst_btn = cfltk.Fl_Button_new(345, tb_y + 3, 80, 34, "Reset");
    const set_btn = cfltk.Fl_Button_new(430, tb_y + 3, 80, 34, "Settings");
    const home_btn = cfltk.Fl_Button_new(515, tb_y + 3, 80, 34, "Home");

    // Tooltips
    cfltk.Fl_Button_set_tooltip(new_btn, "Create a new virtual machine (Ctrl+N)");
    cfltk.Fl_Button_set_tooltip(start_btn, "Power on or off the selected virtual machine");
    cfltk.Fl_Button_set_tooltip(susp_btn, "Suspend the selected virtual machine to disk");
    cfltk.Fl_Button_set_tooltip(sd_btn, "Send ACPI shutdown to the guest (graceful power off)");
    cfltk.Fl_Button_set_tooltip(rst_btn, "Hard reset the guest via QMP system_reset");
    cfltk.Fl_Button_set_tooltip(set_btn, "Edit virtual machine settings (F2)");
    cfltk.Fl_Button_set_tooltip(home_btn, "Return to Home (deselect VM, Ctrl+W)");
    _ = tb;

    cfltk.Fl_Button_set_callback(new_btn, newVmCB, null);
    cfltk.Fl_Button_set_callback(start_btn, powerCB, null);
    cfltk.Fl_Button_set_callback(susp_btn, suspendCB, null);
    cfltk.Fl_Button_set_callback(sd_btn, shutdownCB, null);
    cfltk.Fl_Button_set_callback(rst_btn, resetCB, null);
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
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Shut Down Guest", 0, @ptrCast(&shutdownCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Reset Guest", 0, @ptrCast(&resetCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Settings...", 0, @ptrCast(&settingsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Snapshot Manager...", 0, @ptrCast(&snapshotCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Clone", 0, @ptrCast(&cloneCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Toggle Favorite", 0, @ptrCast(&favCB), null, 0);
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
    for ([_][]const u8{ "State:", "Guest OS:", "Memory:", "CPU:", "Hard Disk:", "Network:", "CD/DVD:", "Notes:", "Shared Folder:", "USB Device:", "Guest Tools:", "AutoProtect:" }, 0..) |lbl, i| {
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

    // Restore saved window position.
    if (prefs.win_x >= 0 and prefs.win_y >= 0) {
        _ = cfltk.Fl_Window_resize(win, prefs.win_x, prefs.win_y, WW, WH);
    }

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
