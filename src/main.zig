//! KVMGUI — FLTK Frontend (VM operation callbacks, remaining dialogs, main loop)
const std = @import("std");
const vm = @import("vm.zig");
const vnet = @import("vnet.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const termfilter = @import("termfilter.zig");
const qmp = @import("qmp.zig");
const autoprotect = @import("autoprotect.zig");
const app = @import("appstate.zig");
const serial = @import("serial_console.zig");
const display_mod = @import("display.zig");
const remote = @import("remote.zig");
const dialogs = @import("dialogs.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const cfltk = @import("cfltk_import.zig").c;

extern fn time(t: ?*c_long) c_long;

// ── Callback stubs (delegate to helpers and dialog modules) ──────────
fn browserCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { app.selectCurrent(); app.refreshDetails(); }
fn powerCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { togglePower(); }
fn shutdownCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { shutdownGuest(); }
fn resetCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { resetGuest(); }
fn suspendCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { suspendVm(); }
fn pauseCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { pauseGuest(); }
fn resumeCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { resumeGuest(); }
fn settingsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { editVmDialog(); }
fn importCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { importVm(); }
fn cloneCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { cloneVm(); }
fn snapshotCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { snapDialog(); }
fn deleteVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { deleteCurrentVm(); }
fn renameCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { renameVm(); }
fn cadCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { sendCtrlAltDel(); }
fn favCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.toggleFavorite(); }
fn startAllCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { startAllVms(); }
fn stopAllCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { stopAllVms(); }
fn prefsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.prefsDialog(); }
fn vnetCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.vnetDialog(); }
fn quitCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { shutdown(); }
fn aboutCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.aboutDialog(); }
fn exportOvfCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.exportOvfDialog(); }
fn homeCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); }
fn connectRemoteCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.remoteConnectDialog(); }

fn newVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { newVmDialog(); }

fn shutdown() void {
    // Save window geometry before closing.
    if (app.win_handle) |w| {
        const ww = cfltk.Fl_Window_width(w);
        const wh = cfltk.Fl_Window_height(w);
        if (ww > 0 and wh > 0) {
            app.prefs.win_x = @intCast(cfltk.Fl_Window_x(w));
            app.prefs.win_y = @intCast(cfltk.Fl_Window_y(w));
            app.prefs.win_w = @intCast(ww);
            app.prefs.win_h = @intCast(wh);
        }
    }
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    // Clean up all Vmm handles.
    for (0..app.vm_count) |i| app.destroyVmmHandle(i);
    if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
    if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
    display_mod.clearDisplay();
    serial.serialDisconnect();
    if (app.win_handle) |w| cfltk.Fl_Window_hide(w);
}

fn cloneVm() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count or app.vm_count >= app.MAX_VMS) return;

    // Remote mode: dispatch clone to server, then refresh.
    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/clone/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        remote.remoteRefreshVmList();
        app.refreshBrowser();
        app.refreshDetails();
        return;
    }

    const src = &app.vms[idx];

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
    const ci: u16 = @intCast(app.vm_count);
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
            app.setStatus("Failed to build linked clone disk path");
            return;
        };
        clone.setDiskPath(clone_disk);
        clone.disk_format = .qcow2;

        // Create the linked clone backing file.
        if (app.getVmmHandle(idx)) |h| {
            app.g_vmm.createLinkedCloneFn(h, clone_disk, src_disk, @intFromEnum(src.disk_format), std.heap.page_allocator) catch {
                app.setStatus("Failed to create linked clone disk");
                return;
            };
        } else {
            qemu.createLinkedClone(clone_disk, src_disk, src.disk_format, std.heap.page_allocator) catch {
                app.setStatus("Failed to create linked clone disk");
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
                app.setStatus("Cloned, but failed to set disk path");
            }
        }
    }

    app.vms[app.vm_count] = clone;
    app.vm_count += 1;
    app.selected_idx = app.vm_count - 1;
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
}

fn importVm() void {
    if (app.vm_count >= app.MAX_VMS) { app.setStatus("Max VM limit reached"); return; }

    // Open file chooser for disk images
    const path_ptr = cfltk.Fl_file_chooser("Select Disk Image", "*.{qcow2,raw,img,vmdk,vdi,iso}", null, 0);
    if (path_ptr == null or path_ptr[0] == 0) return;
    const disk_path = std.mem.sliceTo(path_ptr, 0);

    // Remote mode: send the path to the server.
    if (app.remote_mode) {
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost("/api/import", disk_path, &out_buf);
        remote.remoteRefreshVmList();
        app.selected_idx = app.vm_count -| 1;
        app.refreshBrowser();
        app.refreshDetails();
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
    cfg.memory_mb = app.prefs.default_memory_mb;
    cfg.cpu_cores = app.prefs.default_cpu_cores;

    var mac_buf: [18]u8 = undefined;
    const mac = vm.generateMacAddress(&mac_buf);
    cfg.setMacAddress(std.mem.span(mac));

    app.vms[app.vm_count] = cfg;
    app.vm_count += 1;
    app.selected_idx = app.vm_count - 1;
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    app.setStatus("VM imported from disk image");
}

fn vnetDialog() void {
    // Load networks (or start with defaults for display)
    var net_set = vnet.load();
    if (net_set.count == 0) net_set = vnet.NetworkSet.defaults();

    const dlg = cfltk.Fl_Window_new_wh(580, 420, "Virtual Network Editor");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 560, 20, "Virtual Network switches (VMnet):");
    const net_list = cfltk.Fl_Browser_new(10, 35, 560, 260, "");
    // Populate the app.browser with real vnet data
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

    // Refresh helper: clears app.browser and re-populates from net_set
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

fn toggleFavorite() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    app.vms[idx].favorite = !app.vms[idx].favorite;
    app.refreshBrowser();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
}

fn deleteCurrentVm() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;

    // Remote mode: dispatch delete to server, then refresh.
    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/delete/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        remote.remoteRefreshVmList();
        app.refreshBrowser();
        app.refreshDetails();
        return;
    }

    app.destroyVmmHandle(idx);
    var i = idx;
    while (i + 1 < app.vm_count) : (i += 1) app.vms[i] = app.vms[i + 1];
    // Shift Vmm handles too
    while (i < app.g_vmm_handles.len - 1) : (i += 1) app.g_vmm_handles[i] = app.g_vmm_handles[i + 1];
    app.g_vmm_handles[app.vm_count - 1] = null;
    app.vm_count -= 1;
    app.selected_idx = if (app.vm_count > 0) @min(idx, app.vm_count - 1) else null;
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
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
        cs: ?*cfltk.Fl_Input, kv: ?*cfltk.Fl_Check_Button,
        os: ?*cfltk.Fl_Input, bo: ?*cfltk.Fl_Input,
        dp: ?*cfltk.Fl_Input, rs: ?*cfltk.Fl_Input,
        e3: ?*cfltk.Fl_Check_Button, gp: ?*cfltk.Fl_Input,
        em: ?*cfltk.Fl_Check_Button, sr: ?*cfltk.Fl_Check_Button,
        vn: ?*cfltk.Fl_Input, sp: ?*cfltk.Fl_Input,
        df: ?*cfltk.Fl_Input, ma: ?*cfltk.Fl_Input,
        au: ?*cfltk.Fl_Input, fv: ?*cfltk.Fl_Check_Button,
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
    if (ed.cs) |csi| { const s = try std.fmt.bufPrint(buf[pos..], "cpu_sockets={s}&", .{std.mem.span(cfltk.Fl_Input_value(csi))}); pos += s.len; }
    if (ed.kv) |kvi| { const s = try std.fmt.bufPrint(buf[pos..], "enable_kvm={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(kvi) != 0) 1 else 0)}); pos += s.len; }
    if (ed.os) |osi| { const s = try std.fmt.bufPrint(buf[pos..], "guest_os={s}&", .{std.mem.span(cfltk.Fl_Input_value(osi))}); pos += s.len; }
    if (ed.bo) |boi| { const s = try std.fmt.bufPrint(buf[pos..], "boot_order={s}&", .{std.mem.span(cfltk.Fl_Input_value(boi))}); pos += s.len; }
    if (ed.dp) |dpi| { const s = try std.fmt.bufPrint(buf[pos..], "display={s}&", .{std.mem.span(cfltk.Fl_Input_value(dpi))}); pos += s.len; }
    if (ed.rs) |rsi| { const s = try std.fmt.bufPrint(buf[pos..], "display_resolution={s}&", .{std.mem.span(cfltk.Fl_Input_value(rsi))}); pos += s.len; }
    if (ed.e3) |e3i| { const s = try std.fmt.bufPrint(buf[pos..], "enable_3d={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(e3i) != 0) 1 else 0)}); pos += s.len; }
    if (ed.gp) |gpi| { const s = try std.fmt.bufPrint(buf[pos..], "gpu_device={s}&", .{std.mem.span(cfltk.Fl_Input_value(gpi))}); pos += s.len; }
    if (ed.em) |emi| { const s = try std.fmt.bufPrint(buf[pos..], "embed_display={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(emi) != 0) 1 else 0)}); pos += s.len; }
    if (ed.sr) |sri| { const s = try std.fmt.bufPrint(buf[pos..], "enable_serial={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(sri) != 0) 1 else 0)}); pos += s.len; }
    if (ed.vn) |vni| { const s = try std.fmt.bufPrint(buf[pos..], "vnc_port={s}&", .{std.mem.span(cfltk.Fl_Input_value(vni))}); pos += s.len; }
    if (ed.sp) |spi| { const s = try std.fmt.bufPrint(buf[pos..], "spice_port={s}&", .{std.mem.span(cfltk.Fl_Input_value(spi))}); pos += s.len; }
    if (ed.df) |dfi| { const s = try std.fmt.bufPrint(buf[pos..], "disk_format={s}&", .{std.mem.span(cfltk.Fl_Input_value(dfi))}); pos += s.len; }
    if (ed.ma) |mai| { const s = try std.fmt.bufPrint(buf[pos..], "mac_address={s}&", .{std.mem.span(cfltk.Fl_Input_value(mai))}); pos += s.len; }
    if (ed.au) |aui| { const s = try std.fmt.bufPrint(buf[pos..], "audio={s}&", .{std.mem.span(cfltk.Fl_Input_value(aui))}); pos += s.len; }
    if (ed.fv) |fvi| { const s = try std.fmt.bufPrint(buf[pos..], "favorite={d}&", .{@as(u8, if (cfltk.Fl_Check_Button_is_checked(fvi) != 0) 1 else 0)}); pos += s.len; }
    return buf[0..pos];
}

fn editVmDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const cfg = &app.vms[idx];
    const dlg = cfltk.Fl_Window_new_wh(480, 1020, "Virtual Machine Settings");
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

    // ── CPU Sockets / KVM ─────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 700, 110, 20, "CPU Sockets:");
    var csbuf: [16]u8 = undefined;
    const cs_str = std.fmt.bufPrintZ(&csbuf, "{d}", .{cfg.cpu_sockets}) catch "1";
    const cs_input = cfltk.Fl_Input_new(130, 698, 150, 24, cs_str);
    const kvm_input = cfltk.Fl_Check_Button_new(300, 698, 170, 24, "Enable KVM");
    if (cfg.enable_kvm) cfltk.Fl_Check_Button_set_checked(kvm_input, 1);

    // ── Guest OS / Boot Order ─────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 730, 110, 20, "Guest OS:");
    const os_input = cfltk.Fl_Input_new(130, 728, 150, 24, std.mem.span(cfg.guest_os.label()));
    _ = cfltk.Fl_Box_new(300, 730, 60, 20, "Boot:");
    const boot_input = cfltk.Fl_Input_new(360, 728, 110, 24, std.mem.span(cfg.boot_order.label()));

    // ── Display Type / Resolution ─────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 760, 110, 20, "Display:");
    const disp_input = cfltk.Fl_Input_new(130, 758, 150, 24, std.mem.span(cfg.display.label()));
    _ = cfltk.Fl_Box_new(300, 760, 60, 20, "Res:");
    const res_input = cfltk.Fl_Input_new(360, 758, 110, 24, std.mem.span(cfg.display_resolution.label()));

    // ── 3D Accel / GPU ────────────────────────────────────────────
    const e3d_input = cfltk.Fl_Check_Button_new(130, 788, 160, 24, "3D Acceleration");
    if (cfg.enable_3d) cfltk.Fl_Check_Button_set_checked(e3d_input, 1);
    _ = cfltk.Fl_Box_new(300, 790, 60, 20, "GPU:");
    const gpu_input = cfltk.Fl_Input_new(360, 788, 110, 24, std.mem.span(cfg.gpu_device.label()));

    // ── Embed Display / Serial ────────────────────────────────────
    const emb_input = cfltk.Fl_Check_Button_new(130, 818, 160, 24, "Embed Display");
    if (cfg.embed_display) cfltk.Fl_Check_Button_set_checked(emb_input, 1);
    const ser_input = cfltk.Fl_Check_Button_new(300, 818, 170, 24, "Enable Serial");
    if (cfg.enable_serial) cfltk.Fl_Check_Button_set_checked(ser_input, 1);

    // ── VNC Port / SPICE Port ─────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 850, 110, 20, "VNC Port:");
    var vncbuf: [16]u8 = undefined;
    const vnc_str = std.fmt.bufPrintZ(&vncbuf, "{d}", .{cfg.vnc_port}) catch "5900";
    const vnc_input = cfltk.Fl_Input_new(130, 848, 150, 24, vnc_str);
    _ = cfltk.Fl_Box_new(300, 850, 60, 20, "SPICE:");
    var spcbuf: [16]u8 = undefined;
    const spc_str = std.fmt.bufPrintZ(&spcbuf, "{d}", .{cfg.spice_port}) catch "5901";
    const spc_input = cfltk.Fl_Input_new(360, 848, 110, 24, spc_str);

    // ── Disk Format / MAC ─────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 880, 110, 20, "Disk Format:");
    const df_input = cfltk.Fl_Input_new(130, 878, 150, 24, std.mem.span(cfg.disk_format.label()));
    _ = cfltk.Fl_Box_new(300, 880, 60, 20, "MAC:");
    const mac_input = cfltk.Fl_Input_new(360, 878, 110, 24, if (cfg.nics[0].mac_len > 0) cfg.getMacAddress() else "");

    // ── Audio / Favorite ──────────────────────────────────────────
    _ = cfltk.Fl_Box_new(10, 910, 110, 20, "Audio:");
    const aud_input = cfltk.Fl_Input_new(130, 908, 150, 24, std.mem.span(cfg.audio.label()));
    const fav_input = cfltk.Fl_Check_Button_new(300, 908, 170, 24, "Favorite");
    if (cfg.favorite) cfltk.Fl_Check_Button_set_checked(fav_input, 1);

    const save_btn = cfltk.Fl_Button_new(290, 980, 80, 30, "Save");
    const cancel_btn = cfltk.Fl_Button_new(380, 980, 80, 30, "Cancel");

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
        cs: ?*cfltk.Fl_Input, kv: ?*cfltk.Fl_Check_Button,
        os: ?*cfltk.Fl_Input, bo: ?*cfltk.Fl_Input,
        dp: ?*cfltk.Fl_Input, rs: ?*cfltk.Fl_Input,
        e3: ?*cfltk.Fl_Check_Button, gp: ?*cfltk.Fl_Input,
        em: ?*cfltk.Fl_Check_Button, sr: ?*cfltk.Fl_Check_Button,
        vn: ?*cfltk.Fl_Input, sp: ?*cfltk.Fl_Input,
        df: ?*cfltk.Fl_Input, ma: ?*cfltk.Fl_Input,
        au: ?*cfltk.Fl_Input, fv: ?*cfltk.Fl_Check_Button,
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
        .cs = @ptrCast(cs_input), .kv = @ptrCast(kvm_input),
        .os = @ptrCast(os_input), .bo = @ptrCast(boot_input),
        .dp = @ptrCast(disp_input), .rs = @ptrCast(res_input),
        .e3 = @ptrCast(e3d_input), .gp = @ptrCast(gpu_input),
        .em = @ptrCast(emb_input), .sr = @ptrCast(ser_input),
        .vn = @ptrCast(vnc_input), .sp = @ptrCast(spc_input),
        .df = @ptrCast(df_input), .ma = @ptrCast(mac_input),
        .au = @ptrCast(aud_input), .fv = @ptrCast(fav_input),
        .v = cfg, .dl = @ptrCast(dlg), .idx = idx,
    };

    const S = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const dd: *Ed = @ptrCast(@alignCast(d orelse return));
        // Remote mode: POST URL-encoded settings to server.
        if (app.remote_mode) {
            var body: [3072]u8 = undefined;
            const b = buildSaveBody(&body, dd) catch {
                app.setStatus("Failed to build save request");
                return;
            };
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/api/save/{d}", .{dd.idx}) catch return;
            var out_buf: [64]u8 = undefined;
            _ = remote.apiPost(path, b, &out_buf);
            remote.remoteRefreshVmList();
            app.refreshBrowser();
            app.refreshDetails();
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
        // ── New fields: sockets, kvm, os, boot, display, res, 3d, gpu, embed, serial, vnc, spice, diskfmt, mac, audio, fav ──
        if (dd.cs) |csi| dd.v.cpu_sockets = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(csi)), 10) catch dd.v.cpu_sockets);
        if (dd.kv) |kvi| dd.v.enable_kvm = cfltk.Fl_Check_Button_is_checked(kvi) != 0;
        if (dd.os) |osi| {
            const s = std.mem.span(cfltk.Fl_Input_value(osi));
            // Match against label() values displayed in the dialog
            if (std.ascii.indexOfIgnoreCase(s, "linux") != null) { dd.v.guest_os = .linux; }
            else if (std.ascii.indexOfIgnoreCase(s, "windows") != null) { dd.v.guest_os = .windows; }
            else if (std.ascii.indexOfIgnoreCase(s, "freebsd") != null) { dd.v.guest_os = .freebsd; }
            else if (std.ascii.indexOfIgnoreCase(s, "macos") != null) { dd.v.guest_os = .macos; }
            else { dd.v.guest_os = .other; }
        }
        if (dd.bo) |boi| {
            const s = std.mem.span(cfltk.Fl_Input_value(boi));
            if (std.ascii.eqlIgnoreCase(s, "cd/dvd")) { dd.v.boot_order = .cdrom_first; }
            else if (std.ascii.eqlIgnoreCase(s, "network (pxe)")) { dd.v.boot_order = .network_first; }
            else if (std.ascii.indexOfIgnoreCase(s, "disk") != null) { dd.v.boot_order = .disk_first; }
            else { dd.v.boot_order = .disk_first; }
        }
        if (dd.dp) |dpi| {
            const s = std.mem.span(cfltk.Fl_Input_value(dpi));
            if (std.ascii.indexOfIgnoreCase(s, "sdl") != null) { dd.v.display = .sdl; }
            else if (std.ascii.indexOfIgnoreCase(s, "spice") != null) { dd.v.display = .spice; }
            else if (std.ascii.indexOfIgnoreCase(s, "vnc") != null) { dd.v.display = .vnc; }
            else if (std.ascii.indexOfIgnoreCase(s, "none") != null or std.ascii.indexOfIgnoreCase(s, "headless") != null) { dd.v.display = .none; }
            else { dd.v.display = .gtk; }
        }
        if (dd.rs) |rsi| {
            const s = std.mem.span(cfltk.Fl_Input_value(rsi));
            if (std.ascii.eqlIgnoreCase(s, "800x600")) { dd.v.display_resolution = .res_800x600; }
            else if (std.ascii.eqlIgnoreCase(s, "1024x768")) { dd.v.display_resolution = .res_1024x768; }
            else if (std.ascii.eqlIgnoreCase(s, "1280x800")) { dd.v.display_resolution = .res_1280x800; }
            else if (std.ascii.eqlIgnoreCase(s, "1920x1080")) { dd.v.display_resolution = .res_1920x1080; }
            else { dd.v.display_resolution = .auto; }
        }
        if (dd.e3) |e3i| dd.v.enable_3d = cfltk.Fl_Check_Button_is_checked(e3i) != 0;
        if (dd.gp) |gpi| {
            const s = std.mem.span(cfltk.Fl_Input_value(gpi));
            if (std.ascii.indexOfIgnoreCase(s, "vga") != null) { dd.v.gpu_device = .virtio_vga_gl; }
            else { dd.v.gpu_device = .virtio_gpu_gl; }
        }
        if (dd.em) |emi| dd.v.embed_display = cfltk.Fl_Check_Button_is_checked(emi) != 0;
        if (dd.sr) |sri| dd.v.enable_serial = cfltk.Fl_Check_Button_is_checked(sri) != 0;
        if (dd.vn) |vni| dd.v.vnc_port = std.fmt.parseInt(u16, std.mem.span(cfltk.Fl_Input_value(vni)), 10) catch dd.v.vnc_port;
        if (dd.sp) |spi| dd.v.spice_port = std.fmt.parseInt(u16, std.mem.span(cfltk.Fl_Input_value(spi)), 10) catch dd.v.spice_port;
        if (dd.df) |dfi| {
            const s = std.mem.span(cfltk.Fl_Input_value(dfi));
            if (std.ascii.eqlIgnoreCase(s, "raw")) { dd.v.disk_format = .raw; }
            else if (std.ascii.eqlIgnoreCase(s, "vmdk")) { dd.v.disk_format = .vmdk; }
            else if (std.ascii.eqlIgnoreCase(s, "vdi")) { dd.v.disk_format = .vdi; }
            else { dd.v.disk_format = .qcow2; }
        }
        if (dd.ma) |mai| { const s = std.mem.span(cfltk.Fl_Input_value(mai)); dd.v.setMacAddress(s); }
        if (dd.au) |aui| {
            const s = std.mem.span(cfltk.Fl_Input_value(aui));
            if (std.ascii.indexOfIgnoreCase(s, "hda") != null) { dd.v.audio = .hda; }
            else if (std.ascii.indexOfIgnoreCase(s, "ac97") != null) { dd.v.audio = .ac97; }
            else { dd.v.audio = .none; }
        }
        if (dd.fv) |fvi| dd.v.favorite = cfltk.Fl_Check_Button_is_checked(fvi) != 0;
        app.refreshBrowser(); app.refreshDetails();
        persist.save(&app.vms, app.vm_count, app.prefs) catch {};
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
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const vc = &app.vms[idx];
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
    var sd = SD{ .n = @ptrCast(ni), .r = @ptrCast(rl), .v = vc, .d = @ptrCast(dlg), .idx = idx, .remote = app.remote_mode };
    const TK = struct { fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        const s: *SD = @ptrCast(@alignCast(d orelse return));
        if (s.n) |nn| {
            if (s.remote) {
                var path_buf: [48]u8 = undefined;
                const path = std.fmt.bufPrintZ(&path_buf, "/api/snapshot/take/{d}", .{s.idx}) catch return;
                var out_buf: [64]u8 = undefined;
                _ = remote.apiPost(path, std.mem.span(cfltk.Fl_Input_value(nn)), &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Created (remote).");
            } else if (app.getVmmHandle(s.idx)) |h| {
                app.g_vmm.snapshotCreateFn(h, s.v.getDiskPathSlice(), std.mem.span(cfltk.Fl_Input_value(nn)), std.heap.page_allocator) catch {};
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
            const n = remote.apiGet(path, &out_buf);
            if (s.r) |rr| {
                if (n > 0 and n <= out_buf.len) {
                    cfltk.Fl_Box_set_label(rr, @ptrCast(&out_buf));
                } else {
                    cfltk.Fl_Box_set_label(rr, "(none)");
                }
            }
        } else {
            var buf: [4096]u8 = undefined;
            const n: usize = if (app.getVmmHandle(s.idx)) |h|
                app.g_vmm.snapshotListFn(h, s.v.getDiskPathSlice(), &buf, std.heap.page_allocator) catch 0
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
                _ = remote.apiPost(path, tag, &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Reverted (remote).");
            } else if (app.getVmmHandle(s.idx)) |h| {
                app.g_vmm.snapshotApplyFn(h, s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
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
                _ = remote.apiPost(path, tag, &out_buf);
                if (s.r) |rr| cfltk.Fl_Box_set_label(rr, "Deleted (remote).");
            } else if (app.getVmmHandle(s.idx)) |h| {
                app.g_vmm.snapshotDeleteFn(h, s.v.getDiskPathSlice(), tag, std.heap.page_allocator) catch {};
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
    const mem_input = cfltk.Fl_Input_new(140, 8, 270, 24, std.fmt.bufPrintZ(&mb, "{d}", .{app.prefs.default_memory_mb}) catch "2048");
    _ = cfltk.Fl_Box_new(10, 40, 130, 20, "Default CPU Cores:");
    var cb2: [16]u8 = undefined;
    const cpu_input = cfltk.Fl_Input_new(140, 38, 270, 24, std.fmt.bufPrintZ(&cb2, "{d}", .{app.prefs.default_cpu_cores}) catch "2");

    _ = cfltk.Fl_Box_new(10, 70, 130, 20, "AutoProtect:");
    const ap_check = cfltk.Fl_Check_Button_new(140, 68, 20, 24, "");
    cfltk.Fl_Check_Button_set_value(ap_check, if (app.prefs.autoprotect_enabled_default) 1 else 0);

    _ = cfltk.Fl_Box_new(10, 100, 130, 20, "Snapshot Interval (min):");
    var ab: [16]u8 = undefined;
    const ap_int_input = cfltk.Fl_Input_new(140, 98, 270, 24, std.fmt.bufPrintZ(&ab, "{d}", .{app.prefs.autoprotect_interval_min_default}) catch "60");

    _ = cfltk.Fl_Box_new(10, 130, 130, 20, "Max Snapshots:");
    var ac: [16]u8 = undefined;
    const ap_max_input = cfltk.Fl_Input_new(140, 128, 270, 24, std.fmt.bufPrintZ(&ac, "{d}", .{app.prefs.autoprotect_max_default}) catch "10");

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
                    app.prefs.default_memory_mb = std.fmt.parseInt(u32, val, 10) catch 2048;
                }
            }
            if (pp.cpu) |ci| {
                const val = std.mem.span(cfltk.Fl_Input_value(ci));
                if (val.len > 0) {
                    app.prefs.default_cpu_cores = std.fmt.parseInt(u32, val, 10) catch 2;
                }
            }
            if (pp.ap_check) |apc| {
                app.prefs.autoprotect_enabled_default = cfltk.Fl_Check_Button_value(apc) != 0;
            }
            if (pp.ap_int) |ai| {
                const val = std.mem.span(cfltk.Fl_Input_value(ai));
                if (val.len > 0) {
                    app.prefs.autoprotect_interval_min_default = std.fmt.parseInt(u32, val, 10) catch 60;
                }
            }
            if (pp.ap_max) |am| {
                const val = std.mem.span(cfltk.Fl_Input_value(am));
                if (val.len > 0) {
                    app.prefs.autoprotect_max_default = std.fmt.parseInt(u32, val, 10) catch 10;
                }
            }
            persist.save(&app.vms, app.vm_count, app.prefs) catch {};
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


/// Get or create the Vmm handle for VM at index idx.

/// Destroy the Vmm handle for VM at index idx.

fn togglePower() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;

    // Remote mode: dispatch to server.
    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/power/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        remote.remoteRefreshVmList();
        app.refreshBrowser();
        app.refreshDetails();
        return;
    }

    if (app.vms[idx].isAlive()) {
        // Power off: kill the QEMU process and clean up connections
        if (app.getVmmHandle(idx)) |h| {
            app.g_vmm.forceStopFn(h);
            app.g_vmm.reapFn(h);
        } else {
            qemu.forceStopVm(&app.vms[idx]); qemu.reapVm(&app.vms[idx]);
        }
        if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
        if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
        display_mod.clearDisplay();
        serial.serialDisconnect();
    } else {
        // Power on: start QEMU (handles -incoming for resume from suspended state)
        if (app.getVmmHandle(idx)) |h| {
            app.g_vmm.startFn(h, @ptrCast(&app.vms[idx])) catch {
                app.setStatus("Failed to start VM");
                return;
            };
        } else {
            qemu.startVm(&app.vms[idx], std.heap.page_allocator) catch {
                app.setStatus("Failed to start VM");
                return;
            };
        }
        app.vm_started[idx] = 1;
        // If we resumed from a saved state, clear it so next power-on is fresh
        if (app.vms[idx].hasSavedState()) {
            app.vms[idx].clearSavedStatePath();
        }
    }
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
}

/// Power on all stopped VMs.
fn startAllVms() void {
    const saved_idx = app.selected_idx;
    defer { app.selected_idx = saved_idx; }
    for (0..app.vm_count) |i| {
        if (app.vms[i].isAlive()) continue;
        if (app.remote_mode) {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/api/power/{d}", .{i}) catch continue;
            var out_buf: [64]u8 = undefined;
            _ = remote.apiPost(path, "", &out_buf);
        } else {
            if (app.getVmmHandle(i)) |h| {
                app.g_vmm.startFn(h, @ptrCast(&app.vms[i])) catch continue;
            } else {
                qemu.startVm(&app.vms[i], std.heap.page_allocator) catch continue;
            }
            app.vm_started[i] = 1;
            if (app.vms[i].hasSavedState()) app.vms[i].clearSavedStatePath();
        }
    }
    if (app.remote_mode) remote.remoteRefreshVmList();
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    app.setStatus("All stopped VMs powered on.");
}

/// Power off all running VMs.
fn stopAllVms() void {
    const saved_idx = app.selected_idx;
    defer { app.selected_idx = saved_idx; }
    for (0..app.vm_count) |i| {
        if (!app.vms[i].isAlive()) continue;
        if (app.remote_mode) {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/api/power/{d}", .{i}) catch continue;
            var out_buf: [64]u8 = undefined;
            _ = remote.apiPost(path, "", &out_buf);
        } else {
            if (app.getVmmHandle(i)) |h| {
                app.g_vmm.forceStopFn(h);
                app.g_vmm.reapFn(h);
            } else {
                qemu.forceStopVm(&app.vms[i]); qemu.reapVm(&app.vms[i]);
            }
        }
    }
    if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
    if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
    display_mod.clearDisplay();
    serial.serialDisconnect();
    if (app.remote_mode) remote.remoteRefreshVmList();
    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    app.setStatus("All running VMs powered off.");
}

fn shutdownGuest() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (!app.vms[idx].isAlive()) { app.setStatus("VM is not running"); return; }

    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/shutdown/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        app.setStatus("Shut down guest (remote).");
        return;
    }
    if (app.getVmmHandle(idx)) |h| {
        app.g_vmm.shutdownFn(h) catch { app.setStatus("Shutdown failed"); return; };
    } else {
        shutdownViaQmp(idx) catch { app.setStatus("Shutdown failed"); return; };
    }
    app.setStatus("Shut down guest — ACPI power button sent.");
}

fn resetGuest() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (!app.vms[idx].isAlive()) { app.setStatus("VM is not running"); return; }

    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/reset/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        app.setStatus("Reset guest (remote).");
        return;
    }
    if (app.getVmmHandle(idx)) |h| {
        app.g_vmm.resetFn(h) catch { app.setStatus("Reset failed"); return; };
    } else {
        resetViaQmp(idx) catch { app.setStatus("Reset failed"); return; };
    }
    app.setStatus("Reset guest — system_reset sent.");
}

fn shutdownViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(app.vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.powerdown();
}

fn resetViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(app.vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.systemReset();
}

fn pauseGuest() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (!app.vms[idx].isAlive()) { app.setStatus("VM is not running"); return; }
    if (app.vms[idx].isPaused()) { app.setStatus("VM is already paused"); return; }

    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/pause/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        app.setStatus("Paused guest (remote).");
        return;
    }
    if (app.getVmmHandle(idx)) |h| {
        app.g_vmm.pauseFn(h) catch { app.setStatus("Pause failed"); return; };
    } else {
        pauseViaQmp(idx) catch { app.setStatus("Pause failed"); return; };
    }
    app.setStatus("Paused guest — execution frozen.");
}

fn resumeGuest() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (!app.vms[idx].isPaused()) { app.setStatus("VM is not paused"); return; }

    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/resume/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        app.setStatus("Resumed guest (remote).");
        return;
    }
    if (app.getVmmHandle(idx)) |h| {
        app.g_vmm.resumeFn(h) catch { app.setStatus("Resume failed"); return; };
    } else {
        resumeViaQmp(idx) catch { app.setStatus("Resume failed"); return; };
    }
    app.setStatus("Resumed guest — execution continued.");
}

fn sendCtrlAltDel() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (!app.vms[idx].isAlive()) { app.setStatus("VM is not running"); return; }

    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/cad/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        app.setStatus("Ctrl+Alt+Del sent to guest (remote).");
        return;
    }
    cadViaQmp(idx) catch { app.setStatus("Ctrl+Alt+Del failed"); return; };
    app.setStatus("Ctrl+Alt+Del sent to guest.");
}

fn cadViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(app.vms[idx].getNameSlice(), &sock_buf) orelse return error.SocketPath;
    try client.connect(sock);
    defer client.disconnect();
    try client.sendCtrlAltDel();
}

fn renameVm() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;

    const rw = cfltk.Fl_Window_new_wh(340, 110, "Rename VM");
    _ = cfltk.Fl_Box_new(10, 10, 320, 20, "Enter new name for the virtual machine:");

    const ni = cfltk.Fl_Input_new(10, 35, 320, 30, "");
    _ = cfltk.Fl_Input_set_value(ni, app.vms[idx].getNameSlice().ptr);

    var ok = false;
    const RDlg = struct {
        dlg: ?*cfltk.Fl_Window,
        input: ?*cfltk.Fl_Input,
        ok: *bool,
        fn okCB(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const rd: *@This() = @ptrCast(@alignCast(data orelse return));
            rd.ok.* = true;
            if (rd.dlg) |d| cfltk.Fl_Window_hide(d);
        }
        fn cancelCB(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const rd: *@This() = @ptrCast(@alignCast(data orelse return));
            rd.ok.* = false;
            if (rd.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    var rd = RDlg{ .dlg = @ptrCast(rw), .input = @ptrCast(ni), .ok = &ok };

    const ok_btn = cfltk.Fl_Button_new(90, 75, 70, 25, "OK");
    cfltk.Fl_Button_set_callback(ok_btn, &RDlg.okCB, &rd);
    const cancel_btn = cfltk.Fl_Button_new(180, 75, 70, 25, "Cancel");
    cfltk.Fl_Button_set_callback(cancel_btn, &RDlg.cancelCB, &rd);

    cfltk.Fl_Window_end(@ptrCast(rw));
    cfltk.Fl_Window_show(@ptrCast(rw));
    while (cfltk.Fl_Window_shown(@ptrCast(rw)) != 0) { _ = cfltk.Fl_wait(); }

    if (!ok) return;

    const new_name = std.mem.span(cfltk.Fl_Input_value(ni));
    if (new_name.len == 0) return;
    if (std.mem.eql(u8, new_name, app.vms[idx].getNameSlice())) return;

    // Remote mode: post via API
    if (app.remote_mode) {
        var body_buf: [280]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "name={s}", .{new_name}) catch return;
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/rename/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, body, &out_buf);
        app.refreshBrowser();
        app.refreshDetails();
        return;
    }

    app.vms[idx].setName(new_name);
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    app.refreshBrowser();
    app.refreshDetails();
}

fn pauseViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(app.vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.pause();
}

fn resumeViaQmp(idx: usize) !void {
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(app.vms[idx].getNameSlice(), &sock_buf) orelse return error.NoSocket;
    try client.connect(sock);
    defer client.disconnect();
    try client.cont();
}

fn suspendVm() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;

    // Remote mode: dispatch to server.
    if (app.remote_mode) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/api/suspend/{d}", .{idx}) catch return;
        var out_buf: [64]u8 = undefined;
        _ = remote.apiPost(path, "", &out_buf);
        remote.remoteRefreshVmList();
        app.refreshBrowser();
        app.refreshDetails();
        return;
    }

    const v = &app.vms[idx];
    if (!v.isAlive()) {
        app.setStatus("VM is not running — cannot suspend");
        return;
    }

    // Generate state save path
    var state_path: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&state_path, "/tmp/kvmgui-state-{s}.bin", .{v.getNameSlice()}) catch {
        app.setStatus("Failed to build state path");
        return;
    };

    // Connect QMP and migrate to file
    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(v.getNameSlice(), &sock_buf) orelse {
        app.setStatus("Failed to build QMP socket path");
        return;
    };
    client.connect(sock) catch {
        app.setStatus("Failed to connect QMP for suspend");
        return;
    };
    defer client.disconnect();

    app.setStatus("Suspending VM to file...");
    client.suspendToFile(path) catch {
        app.setStatus("Suspend migration failed to start");
        return;
    };

    // Wait for migration to complete (30s timeout built into waitMigrateComplete)
    client.waitMigrateComplete() catch {
        app.setStatus("Suspend migration timed out — VM may still be running");
        return;
    };

    // Update config with saved state path
    v.setSavedStatePath(path[0..]);

    // Kill the QEMU process
    if (app.getVmmHandle(idx)) |h| {
        app.g_vmm.forceStopFn(h);
        app.g_vmm.reapFn(h);
    } else {
        qemu.forceStopVm(v);
        qemu.reapVm(v);
    }

    // Clean up display and serial connections
    if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
    if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
    display_mod.clearDisplay();
    serial.serialDisconnect();

    app.refreshBrowser();
    app.refreshDetails();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
    app.setStatus("VM suspended to file — ready to resume on power-on");
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
            if (app.remote_mode) {
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
                _ = remote.apiPost("/api/create", body[0..pos], &out_buf);
                remote.remoteRefreshVmList();
                app.selected_idx = app.vm_count -| 1;
                app.refreshBrowser();
                app.refreshDetails();
                if (dd.dlg) |d| cfltk.Fl_Window_hide(d);
                return;
            }
            if (app.vm_count >= app.MAX_VMS) return;

            var cfg = vm.VmConfig{};
            if (dd.name) |n| cfg.setName(std.mem.span(cfltk.Fl_Input_value(n)));
            if (dd.mem) |m| cfg.memory_mb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(m)), 10) catch 2048);
            if (dd.cpu) |c| cfg.cpu_cores = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(c)), 10) catch 2);
            if (dd.disk) |d| cfg.disk_size_gb = @intCast(std.fmt.parseInt(u32, std.mem.span(cfltk.Fl_Input_value(d)), 10) catch 20);

            // Apply AutoProtect defaults from preferences
            cfg.autoprotect = app.prefs.autoprotect_enabled_default;
            cfg.autoprotect_interval_min = app.prefs.autoprotect_interval_min_default;
            cfg.autoprotect_max = app.prefs.autoprotect_max_default;

            var mac_buf: [18]u8 = undefined;
            const mac = vm.generateMacAddress(&mac_buf);
            cfg.setMacAddress(std.mem.span(mac));

            app.vms[app.vm_count] = cfg;
            app.vm_count += 1;
            app.selected_idx = app.vm_count - 1;
            app.refreshBrowser();
            app.refreshDetails();
            persist.save(&app.vms, app.vm_count, app.prefs) catch {};
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




// Global event handler — intercepts keyboard shortcuts + right-clicks
fn kbHandler(event: c_int) callconv(.c) c_int {
    if (event == 12) { // FL_PUSH = 12 (mouse button press)
        if (cfltk.Fl_event_button() == 3) { // Right click
            app.selectCurrent();
            _ = cfltk.Fl_event_x();
            _ = cfltk.Fl_event_y();
            // Show context menu
            if (app.ctx_menu_handle) |cm| _ = cfltk.Fl_Menu_Button_popup(cm);
            return 1;
        }
    }
    if (event != 8) return 0; // FL_KEYDOWN = 8
    const key = cfltk.Fl_event_key();
    const ctrl = cfltk.Fl_event_ctrl() != 0;
    const shift = cfltk.Fl_event_shift() != 0;
    if (ctrl and key == 'n') { if (shift) { cloneVm(); } else { newVmDialog(); } return 1; }
    if (ctrl and key == 'q') { shutdown(); return 1; }
    if (ctrl and key == 'e') { editVmDialog(); return 1; }
    if (ctrl and key == 'i') { importVm(); return 1; }
    if (key == 0xffbf) { editVmDialog(); return 1; } // F2
    if (key == 0xffff) { deleteCurrentVm(); return 1; } // DEL
    if (key == 0xffc8) { if (app.win_handle) |w| { const cur = cfltk.Fl_Window_fullscreen_active(w); cfltk.Fl_Window_fullscreen(w, if (cur != 0) @as(c_uint, 0) else 1); } return 1; } // F11 toggle
    if (ctrl and key == 'w') { app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); return 1; }
    if (key == 0xff0d) { togglePower(); return 1; } // Enter → Power On/Off
    if (key == 0xff1b) { app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); return 1; } // Escape → Home
    return 0;
}

// Console timer — polls serial ring buffer and updates Fl_Browser widget.
fn consoleTimerCB(_: ?*anyopaque) callconv(.c) void {
    if (app.console_widget) |cw| {
        app.serial_mutex.lock();
        if (app.serial_len > 0) {
            var tmp: [app.SERIAL_BUF_SIZE + 1]u8 = undefined;
            const n = app.serial_len;
            @memcpy(tmp[0..n], app.serial_buf[0..n]);
            app.serial_len = 0;
            app.serial_mutex.unlock();
            const valid_len = termfilter.sanitize(&tmp, n);
            if (valid_len > 0) {
                tmp[valid_len] = 0;
                cfltk.Fl_Browser_add(cw, @ptrCast(tmp[0..valid_len].ptr));
            }
        } else {
            app.serial_mutex.unlock();
        }
    }
    _ = cfltk.Fl_repeat_timeout(0.5, consoleTimerCB, null);
}

// Display timer — polls VNC framebuffer and updates display tab (100ms).
fn searchCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {
    if (app.search_input) |si| {
        const val = cfltk.Fl_Input_value(si);
        const sv = std.mem.span(val);
        app.filter_len = @min(sv.len, app.filter_text.len - 1);
        _ = std.ascii.lowerString(@as([]u8, @ptrCast(&app.filter_text)), sv); app.filter_len = sv.len;
        app.refreshBrowser();
    }
}


/// Copy+swap a BGRA framebuffer to RGBA, wrap in an Fl_RGB_Image,
/// scale to fit the display box, and attach it.

// Timer callback — checks VM liveness, connects display, refreshes UI every 2 seconds.
// Also runs AutoProtect snapshot scheduling for VMs with autoprotect enabled.
fn timerCB(_: ?*anyopaque) callconv(.c) void {
    var changed = false;
    const now_unix = time(null);

    for (0..app.vm_count) |i| {
        const v = &app.vms[i];
        if (v.status == .running or v.status == .paused) {
            const alive: bool = if (app.getVmmHandle(i)) |h| app.g_vmm.isAliveFn(h) else qemu.isVmAlive(v);
            if (!alive) {
                changed = true;
                app.vm_started[i] = 0;
                if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
                if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
                display_mod.clearDisplay();
            } else if (app.vm_started[i] > 0) {
                app.vm_started[i] += 2; // 2 seconds per timer tick
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
                    if (app.getVmmHandle(i)) |h| {
                        app.g_vmm.snapshotCreateFn(h, v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch {};
                    } else {
                        qemu.snapshotCreate(v.getDiskPathSlice(), snap_name, std.heap.page_allocator) catch {};
                    }

                    // Prune excess AutoProtect snapshots
                    var list_buf: [4096]u8 = undefined;
                    if (if (app.getVmmHandle(i)) |h|
                        app.g_vmm.snapshotListFn(h, v.getDiskPathSlice(), &list_buf, std.heap.page_allocator)
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
                        const hnd = app.getVmmHandle(i);
                        for (0..to_delete) |j| {
                            if (hnd) |h| {
                                app.g_vmm.snapshotDeleteFn(h, v.getDiskPathSlice(), auto_names[j], std.heap.page_allocator) catch {};
                            } else {
                                qemu.snapshotDelete(v.getDiskPathSlice(), auto_names[j], std.heap.page_allocator) catch {};
                            }
                        }
                    } else |_| {}
                }
                persist.save(&app.vms, app.vm_count, app.prefs) catch {};
            }
        }
    }
    // Auto-connect VNC/SPICE and serial for the selected VM if running
    if (app.selected_idx) |idx| {
        if (idx < app.vm_count) {
            const v = &app.vms[idx];
            if (v.isAlive()) {
                if (v.embed_display and app.vnc_client == null and app.spice_client == null) {
                    if (v.display == .spice) {
                        app.spice_client = spice.SpiceClient.new();
                        if (app.spice_client) |sc| _ = sc.connect("127.0.0.1", @intCast(v.spice_port));
                    } else {
                        app.vnc_client = vnc.VncClient.new();
                        if (app.vnc_client) |vc| _ = vc.connect("127.0.0.1", @intCast(v.vnc_port));
                    }
                }
                if (v.enable_serial and app.serial_fd == null) {
                    serial.serialConnect(v.getNameSlice());
                }
            }
        }
    }
    if (changed) { app.refreshBrowser(); app.refreshDetails(); }
    _ = cfltk.Fl_repeat_timeout(2.0, timerCB, null);
}



pub fn main() void {
    app.vm_count = persist.load(&app.vms, std.heap.page_allocator, &app.prefs);
    _ = cfltk.Fl_set_scheme("gtk+");

    // Initialize the HV abstraction dispatch table (QEMU backend).
    app.g_vmm = hv_backend.createVmm(.auto);

    const WW: i32 = if (app.prefs.win_w > 0) app.prefs.win_w else 960;
    const WH: i32 = if (app.prefs.win_h > 0) app.prefs.win_h else 680;
    const win = cfltk.Fl_Window_new_wh(WW, WH, "KVMGUI");
    app.win_handle = @ptrCast(win);

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
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Pause Guest", 0, @ptrCast(&pauseCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Resume Guest", 0, @ptrCast(&resumeCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Suspend VM", 0, @ptrCast(&suspendCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Shut Down Guest", 0, @ptrCast(&shutdownCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Reset Guest", 0, @ptrCast(&resetCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Send Ctrl+Alt+Del", 0, @ptrCast(&cadCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Settings...\tF2", 0, @ptrCast(&settingsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "VM/Rename...", 0, @ptrCast(&renameCB), null, 0);
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
    const pause_btn = cfltk.Fl_Button_new(260, tb_y + 3, 80, 34, "Pause");
    const resume_btn = cfltk.Fl_Button_new(345, tb_y + 3, 80, 34, "Resume");
    const sd_btn = cfltk.Fl_Button_new(430, tb_y + 3, 80, 34, "Shut Down");
    const rst_btn = cfltk.Fl_Button_new(515, tb_y + 3, 80, 34, "Reset");
    const set_btn = cfltk.Fl_Button_new(600, tb_y + 3, 80, 34, "Settings");
    const cad_btn = cfltk.Fl_Button_new(685, tb_y + 3, 110, 34, "Ctrl+Alt+Del");
    const home_btn = cfltk.Fl_Button_new(800, tb_y + 3, 80, 34, "Home");
    const batch_start_btn = cfltk.Fl_Button_new(885, tb_y + 3, 80, 34, "Start All");
    const batch_stop_btn = cfltk.Fl_Button_new(970, tb_y + 3, 80, 34, "Stop All");

    // Tooltips
    cfltk.Fl_Button_set_tooltip(new_btn, "Create a new virtual machine (Ctrl+N)");
    cfltk.Fl_Button_set_tooltip(start_btn, "Power on or off the selected virtual machine");
    cfltk.Fl_Button_set_tooltip(susp_btn, "Suspend the selected virtual machine to disk");
    cfltk.Fl_Button_set_tooltip(pause_btn, "Freeze guest execution (QMP stop)");
    cfltk.Fl_Button_set_tooltip(resume_btn, "Resume paused guest execution (QMP cont)");
    cfltk.Fl_Button_set_tooltip(sd_btn, "Send ACPI shutdown to the guest (graceful power off)");
    cfltk.Fl_Button_set_tooltip(rst_btn, "Hard reset the guest via QMP system_reset");
    cfltk.Fl_Button_set_tooltip(set_btn, "Edit virtual machine settings (F2)");
    cfltk.Fl_Button_set_tooltip(cad_btn, "Send Ctrl+Alt+Del to the guest (login / unlock)");
    cfltk.Fl_Button_set_tooltip(home_btn, "Return to Home (deselect VM, Ctrl+W)");
    cfltk.Fl_Button_set_tooltip(batch_start_btn, "Power on all stopped virtual machines");
    cfltk.Fl_Button_set_tooltip(batch_stop_btn, "Force power off all running virtual machines");
    _ = tb;

    cfltk.Fl_Button_set_callback(new_btn, newVmCB, null);
    cfltk.Fl_Button_set_callback(start_btn, powerCB, null);
    cfltk.Fl_Button_set_callback(susp_btn, suspendCB, null);
    cfltk.Fl_Button_set_callback(pause_btn, pauseCB, null);
    cfltk.Fl_Button_set_callback(resume_btn, resumeCB, null);
    cfltk.Fl_Button_set_callback(sd_btn, shutdownCB, null);
    cfltk.Fl_Button_set_callback(rst_btn, resetCB, null);
    cfltk.Fl_Button_set_callback(set_btn, settingsCB, null);
    cfltk.Fl_Button_set_callback(cad_btn, cadCB, null);
    cfltk.Fl_Button_set_callback(home_btn, homeCB, null);
    cfltk.Fl_Button_set_callback(batch_start_btn, startAllCB, null);
    cfltk.Fl_Button_set_callback(batch_stop_btn, stopAllCB, null);

    const body_y: i32 = 70;
    const body_h: i32 = WH - body_y - 26;
    const SW: i32 = 200;
    const CX: i32 = SW;
    const CW: i32 = WW - SW;

    // Sidebar
    _ = cfltk.Fl_Box_new(0, body_y, SW, 20, "Library");
    const b = cfltk.Fl_Browser_new(2, body_y + 22, SW - 4, body_h - 45, "");
    app.browser = @ptrCast(b);
    cfltk.Fl_Browser_set_callback(b, browserCB, null);
    const si = cfltk.Fl_Input_new(2, body_y + body_h - 20, SW - 4, 18, "");
    app.search_input = @ptrCast(si);
    cfltk.Fl_Input_set_callback(si, searchCB, null);

    // Context menu (right-click popup on VM app.browser)
    const ctx_menu = cfltk.Fl_Menu_Button_new(0, 0, 0, 0, "");
    app.ctx_menu_handle = @ptrCast(ctx_menu);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Power On/Off", 0, @ptrCast(&powerCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Pause Guest", 0, @ptrCast(&pauseCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Resume Guest", 0, @ptrCast(&resumeCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Suspend VM", 0, @ptrCast(&suspendCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Shut Down Guest", 0, @ptrCast(&shutdownCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Reset Guest", 0, @ptrCast(&resetCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Send Ctrl+Alt+Del", 0, @ptrCast(&cadCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Settings...", 0, @ptrCast(&settingsCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Rename...", 0, @ptrCast(&renameCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Snapshot Manager...", 0, @ptrCast(&snapshotCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Clone", 0, @ptrCast(&cloneCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Toggle Favorite", 0, @ptrCast(&favCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Delete VM\tDEL", 0, @ptrCast(&deleteVmCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Start All VMs", 0, @ptrCast(&startAllCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Stop All VMs", 0, @ptrCast(&stopAllCB), null, 0);

    // Tabs
    const tabs = cfltk.Fl_Tabs_new(CX, body_y, CW, body_h, "");

    // Summary
    const sg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Summary");
    const nm = cfltk.Fl_Box_new(CX + 10, body_y + 30, CW - 20, 30, "No virtual machine selected.");
    app.sum_name = @ptrCast(nm);
    cfltk.Fl_Box_set_label_font(@ptrCast(nm), 1);
    cfltk.Fl_Box_set_label_size(@ptrCast(nm), 18);

    var ypos: i32 = body_y + 70;
    for ([_][]const u8{ "State:", "Guest OS:", "Memory:", "CPU:", "Hard Disk:", "Network:", "CD/DVD:", "Notes:", "Shared Folder:", "USB Device:", "Guest Tools:", "AutoProtect:" }, 0..) |lbl, i| {
        _ = cfltk.Fl_Box_new(CX + 10, ypos, 100, 18, @ptrCast(lbl.ptr));
        const dv = cfltk.Fl_Box_new(CX + 115, ypos, CW - 130, 18, "");
        app.detail_labels[i] = @ptrCast(dv);
        ypos += 22;
    }
    cfltk.Fl_Group_end(@ptrCast(sg));

    // Display tab
    const dg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Display");
    const db = cfltk.Fl_Box_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "VNC/SPICE display renders here when a VM is running.");
    app.display_box = @ptrCast(db);
    cfltk.Fl_Group_end(@ptrCast(dg));

    // Console tab
    const cg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Console");
    const cb = cfltk.Fl_Browser_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "");
    app.console_widget = @ptrCast(cb);
    _ = cfltk.Fl_Browser_add(cb, "Serial console — not connected.");
    cfltk.Fl_Group_end(@ptrCast(cg));

    cfltk.Fl_Group_end(@ptrCast(tabs));

    // Status bar
    const sb = cfltk.Fl_Box_new(0, WH - 26, WW, 26, "Ready — Local Mode");
    cfltk.Fl_Box_set_label_color(sb, 0x666666);
    app.status_bar = @ptrCast(sb);

    cfltk.Fl_Window_end(win);
    cfltk.Fl_Window_show(win);

    // Restore saved window position.
    if (app.prefs.win_x >= 0 and app.prefs.win_y >= 0) {
        _ = cfltk.Fl_Window_resize(win, app.prefs.win_x, app.prefs.win_y, WW, WH);
    }

    app.refreshBrowser();
    if (app.vm_count > 0) app.selected_idx = 0;
    app.refreshDetails();

    // Start periodic VM status check (every 2 seconds)
    _ = cfltk.Fl_add_timeout(2.0, timerCB, null);

    // Global keyboard shortcut handler
    _ = cfltk.Fl_add_handler(kbHandler);

    // Start display refresh timer (every 100ms for VNC framebuffer updates)
    _ = cfltk.Fl_add_timeout(0.1, display_mod.displayTimerCB, null);

    // Console poll timer (every 500ms)
    _ = cfltk.Fl_add_timeout(0.5, consoleTimerCB, null);

    _ = cfltk.Fl_run();
}
