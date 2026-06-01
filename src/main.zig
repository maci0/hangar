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
const urlencode = @import("urlencode.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const web_server = @import("web_server.zig");
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
fn fullScreenCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {
    if (app.win_handle) |w| {
        const cur = cfltk.Fl_Window_fullscreen_active(w);
        _ = cfltk.Fl_Window_fullscreen(w, if (cur != 0) @as(c_uint, 0) else 1);
    }
}
fn exportOvfCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.exportOvfDialog(); }
fn homeCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); }
fn connectRemoteCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { dialogs.remoteConnectDialog(); }
fn webStartCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { startWebServer(); }
fn webStopCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { stopWebServer(); }

fn newVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { newVmDialog(); }

/// Create a bold section heading label.
fn sectionLabel(text: [*:0]const u8, x: c_int, y: c_int, w: c_int) ?*cfltk.Fl_Box {
    const h = cfltk.Fl_Box_new(x, y, w, 22, text);
    cfltk.Fl_Box_set_label_font(h, 1); // FL_HELVETICA_BOLD
    cfltk.Fl_Box_set_label_size(h, 14);
    cfltk.Fl_Box_set_label_color(h, app.pal.header);
    cfltk.Fl_Box_set_align(h, 20); // FL_ALIGN_LEFT | FL_ALIGN_INSIDE
    return @ptrCast(h);
}

/// Create a thin horizontal separator line.
fn sectionSep(x: c_int, y: c_int, w: c_int) ?*cfltk.Fl_Box {
    const s = cfltk.Fl_Box_new(x, y, w, 2, "");
    cfltk.Fl_Box_set_box(s, 1); // FL_FLAT_BOX
    cfltk.Fl_Box_set_color(s, app.pal.border);
    return @ptrCast(s);
}

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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
    // Clean up all Vmm handles.
    for (0..app.vm_count) |i| app.destroyVmmHandle(i);
    if (app.vnc_client) |vc| { vc.disconnect(); vc.free(); app.vnc_client = null; }
    if (app.spice_client) |sc| { sc.disconnect(); sc.free(); app.spice_client = null; }
    display_mod.clearDisplay();
    serial.serialDisconnect();
    if (app.win_handle) |w| cfltk.Fl_Window_hide(w);
}

/// Start the embedded web server in a background thread.
fn startWebServer() void {
    if (app.web_running) {
        app.setStatus("Web server is already running on http://localhost:9080");
        return;
    }
    app.web_running = true;
    // Run web_server.main() in its own thread since it blocks on accept().
    app.web_thread = std.Thread.spawn(.{}, webServerThreadMain, .{}) catch {
        app.web_running = false;
        app.setStatus("Failed to start web server thread");
        return;
    };
    app.setStatus("Web server started on http://localhost:9080");
}

fn webServerThreadMain() void {
    web_server.main() catch |err| {
        std.debug.print("Web server error: {}\n", .{err});
    };
    app.web_running = false;
}

/// Stop the embedded web server (signals shutdown on the listen socket).
fn stopWebServer() void {
    if (!app.web_running) {
        app.setStatus("Web server is not running");
        return;
    }
    app.web_running = false;
    web_server.shutdownSignal();
    app.setStatus("Web server stopped");
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
        const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 320, 2), @divTrunc(cfltk.Fl_h() - 120, 2), 320, 120, "Clone Type");
        cfltk.Fl_Window_make_modal(dlg, 1);
        _ = cfltk.Fl_Box_new(10, 10, 300, 20, "Choose clone type:");

        const link_check = cfltk.Fl_Check_Button_new(10, 40, 300, 24, "Linked clone (COW, needs source disk)");
        cfltk.Fl_Check_Button_set_label_color(link_check, app.pal.text);
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
        cfltk.Fl_Button_set_color(full_btn, app.pal.accent); cfltk.Fl_Button_set_label_color(full_btn, app.pal.accent_text);
        cfltk.Fl_Button_set_callback(full_btn, &FullCB.go, &cd);
        const linked_btn = cfltk.Fl_Button_new(170, 75, 90, 30, "Linked Clone");
        cfltk.Fl_Button_set_color(linked_btn, app.pal.warn); cfltk.Fl_Button_set_label_color(linked_btn, app.pal.accent_text);
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
    app.setStatus("VM imported from disk image");
}

fn deleteCurrentVm() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;

    // Confirmation dialog
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&msg_buf, "Delete VM '{s}'?", .{app.vms[idx].getNameSlice()}) catch "Delete this VM?";
    const choice = cfltk.Fl_choice2(msg.ptr, "Cancel", "Delete", null);
    if (choice != 1) return;

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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    if (ed.na) |n| try urlencode.appendPair(buf, &pos, "name", std.mem.span(cfltk.Fl_Input_value(n)));
    if (ed.me) |m| try urlencode.appendPair(buf, &pos, "mem", std.mem.span(cfltk.Fl_Input_value(m)));
    if (ed.cp) |c| try urlencode.appendPair(buf, &pos, "cpu", std.mem.span(cfltk.Fl_Input_value(c)));
    if (ed.dk) |d2| try urlencode.appendPair(buf, &pos, "disk", std.mem.span(cfltk.Fl_Input_value(d2)));
    if (ed.nt) |ni| try urlencode.appendPair(buf, &pos, "network", std.mem.span(cfltk.Fl_Input_value(ni)));
    if (ed.fw) |fi| try urlencode.appendPair(buf, &pos, "firmware", std.mem.span(cfltk.Fl_Input_value(fi)));
    if (ed.sh) |si| try urlencode.appendPair(buf, &pos, "shared_folder", std.mem.span(cfltk.Fl_Input_value(si)));
    if (ed.us) |ui| try urlencode.appendPair(buf, &pos, "usb", std.mem.span(cfltk.Fl_Input_value(ui)));
    if (ed.gt) |gti| try urlencode.appendPair(buf, &pos, "guest_tools", if (cfltk.Fl_Check_Button_is_checked(gti) != 0) "1" else "0");
    if (ed.ap) |api| try urlencode.appendPair(buf, &pos, "autoprotect", if (cfltk.Fl_Check_Button_is_checked(api) != 0) "1" else "0");
    if (ed.ai) |aii| try urlencode.appendPair(buf, &pos, "ap_interval", std.mem.span(cfltk.Fl_Input_value(aii)));
    if (ed.am) |ami| try urlencode.appendPair(buf, &pos, "ap_max", std.mem.span(cfltk.Fl_Input_value(ami)));
    if (ed.no) |notes_val| try urlencode.appendPair(buf, &pos, "notes", std.mem.span(cfltk.Fl_Input_value(notes_val)));
    if (ed.d2p) |dp| try urlencode.appendPair(buf, &pos, "disk2_path", std.mem.span(cfltk.Fl_Input_value(dp)));
    if (ed.d2s) |ds| try urlencode.appendPair(buf, &pos, "disk2_size", std.mem.span(cfltk.Fl_Input_value(ds)));
    if (ed.flp) |fp| try urlencode.appendPair(buf, &pos, "floppy", std.mem.span(cfltk.Fl_Input_value(fp)));
    if (ed.n2m) |nm| try urlencode.appendPair(buf, &pos, "nic2", std.mem.span(cfltk.Fl_Input_value(nm)));
    if (ed.n3m) |nm| try urlencode.appendPair(buf, &pos, "nic3", std.mem.span(cfltk.Fl_Input_value(nm)));
    if (ed.pf) |pfi| try urlencode.appendPair(buf, &pos, "portfw", std.mem.span(cfltk.Fl_Input_value(pfi)));
    if (ed.cs) |csi| try urlencode.appendPair(buf, &pos, "cpu_sockets", std.mem.span(cfltk.Fl_Input_value(csi)));
    if (ed.kv) |kvi| try urlencode.appendPair(buf, &pos, "enable_kvm", if (cfltk.Fl_Check_Button_is_checked(kvi) != 0) "1" else "0");
    if (ed.os) |osi| try urlencode.appendPair(buf, &pos, "guest_os", std.mem.span(cfltk.Fl_Input_value(osi)));
    if (ed.bo) |boi| try urlencode.appendPair(buf, &pos, "boot_order", std.mem.span(cfltk.Fl_Input_value(boi)));
    if (ed.dp) |dpi| try urlencode.appendPair(buf, &pos, "display", std.mem.span(cfltk.Fl_Input_value(dpi)));
    if (ed.rs) |rsi| try urlencode.appendPair(buf, &pos, "display_resolution", std.mem.span(cfltk.Fl_Input_value(rsi)));
    if (ed.e3) |e3i| try urlencode.appendPair(buf, &pos, "enable_3d", if (cfltk.Fl_Check_Button_is_checked(e3i) != 0) "1" else "0");
    if (ed.gp) |gpi| try urlencode.appendPair(buf, &pos, "gpu_device", std.mem.span(cfltk.Fl_Input_value(gpi)));
    if (ed.em) |emi| try urlencode.appendPair(buf, &pos, "embed_display", if (cfltk.Fl_Check_Button_is_checked(emi) != 0) "1" else "0");
    if (ed.sr) |sri| try urlencode.appendPair(buf, &pos, "enable_serial", if (cfltk.Fl_Check_Button_is_checked(sri) != 0) "1" else "0");
    if (ed.vn) |vni| try urlencode.appendPair(buf, &pos, "vnc_port", std.mem.span(cfltk.Fl_Input_value(vni)));
    if (ed.sp) |spi| try urlencode.appendPair(buf, &pos, "spice_port", std.mem.span(cfltk.Fl_Input_value(spi)));
    if (ed.df) |dfi| try urlencode.appendPair(buf, &pos, "disk_format", std.mem.span(cfltk.Fl_Input_value(dfi)));
    if (ed.ma) |mai| try urlencode.appendPair(buf, &pos, "mac_address", std.mem.span(cfltk.Fl_Input_value(mai)));
    if (ed.au) |aui| try urlencode.appendPair(buf, &pos, "audio", std.mem.span(cfltk.Fl_Input_value(aui)));
    if (ed.fv) |fvi| try urlencode.appendPair(buf, &pos, "favorite", if (cfltk.Fl_Check_Button_is_checked(fvi) != 0) "1" else "0");
    return buf[0..pos];
}

fn editVmDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const cfg = &app.vms[idx];
    // Use a fixed-height scrollable dialog so it fits on any screen.
    const DIALOG_W = 500;
    const DIALOG_H = @min(cfltk.Fl_h() - 40, 720);
    const SCROLL_H = DIALOG_H - 75;
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - DIALOG_W, 2), @max(0, @divTrunc(cfltk.Fl_h() - DIALOG_H, 2)), DIALOG_W, DIALOG_H, "Virtual Machine Settings");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, DIALOG_W, 400, 0, 0);

    // Scrollable content area
    const scroll = cfltk.Fl_Scroll_new(0, 0, DIALOG_W, SCROLL_H, "");
    cfltk.Fl_Scroll_begin(scroll);

    // ── Section: Basic ─────────────────────────────────────────────
    _ = sectionLabel("Basic", 10, 10, 200);
    _ = sectionSep(10, 34, 470);

    const lb0 = cfltk.Fl_Box_new(10, 44, 120, 20, "VM Name:");
    cfltk.Fl_Box_set_label_font(lb0, 1); cfltk.Fl_Box_set_label_color(lb0, app.pal.text_dim);
    const name_input = cfltk.Fl_Input_new(140, 42, 350, 24, cfg.getName());
    const lb1 = cfltk.Fl_Box_new(10, 74, 120, 20, "Memory (MB):");
    cfltk.Fl_Box_set_label_font(lb1, 1); cfltk.Fl_Box_set_label_color(lb1, app.pal.text_dim);
    var mbuf: [16]u8 = undefined;
    const mstr = std.fmt.bufPrintZ(&mbuf, "{d}", .{cfg.memory_mb}) catch "2048";
    const mem_input = cfltk.Fl_Input_new(140, 72, 350, 24, mstr);
    const lb2 = cfltk.Fl_Box_new(10, 104, 120, 20, "CPU Cores:");
    cfltk.Fl_Box_set_label_font(lb2, 1); cfltk.Fl_Box_set_label_color(lb2, app.pal.text_dim);
    var cbuf: [16]u8 = undefined;
    const cstr = std.fmt.bufPrintZ(&cbuf, "{d}", .{cfg.cpu_cores}) catch "2";
    const cpu_input = cfltk.Fl_Input_new(140, 102, 350, 24, cstr);
    const lb3 = cfltk.Fl_Box_new(10, 134, 120, 20, "Disk Size (GB):");
    cfltk.Fl_Box_set_label_font(lb3, 1); cfltk.Fl_Box_set_label_color(lb3, app.pal.text_dim);
    var dbuf: [16]u8 = undefined;
    const dstr = std.fmt.bufPrintZ(&dbuf, "{d}", .{cfg.disk_size_gb}) catch "20";
    const disk_input = cfltk.Fl_Input_new(140, 132, 350, 24, dstr);
    const lb4 = cfltk.Fl_Box_new(10, 164, 120, 20, "ISO Path:");
    cfltk.Fl_Box_set_label_font(lb4, 1); cfltk.Fl_Box_set_label_color(lb4, app.pal.text_dim);
    const iso_input = cfltk.Fl_Input_new(140, 162, 350, 24, if (cfg.hasIso()) cfg.getIsoPath() else "");
    cfltk.Fl_Input_set_text_font(iso_input, 4); // monospace

    // ── Section: Network & Boot ────────────────────────────────────
    _ = sectionLabel("Network & Boot", 10, 200, 200);
    _ = sectionSep(10, 224, 470);

    const lb5 = cfltk.Fl_Box_new(10, 234, 120, 20, "Network:");
    cfltk.Fl_Box_set_label_font(lb5, 1); cfltk.Fl_Box_set_label_color(lb5, app.pal.text_dim);
    const net_input = cfltk.Fl_Input_new(140, 232, 350, 24, std.mem.span(cfg.nics[0].mode.label()));
    const lb6 = cfltk.Fl_Box_new(10, 264, 120, 20, "Firmware:");
    cfltk.Fl_Box_set_label_font(lb6, 1); cfltk.Fl_Box_set_label_color(lb6, app.pal.text_dim);
    const fw_input = cfltk.Fl_Input_new(140, 262, 350, 24, std.mem.span(cfg.firmware.label()));

    // ── Section: Sharing ───────────────────────────────────────────
    _ = sectionLabel("Sharing", 10, 300, 200);
    _ = sectionSep(10, 324, 470);

    const lb7 = cfltk.Fl_Box_new(10, 334, 120, 20, "Shared Folder:");
    cfltk.Fl_Box_set_label_font(lb7, 1); cfltk.Fl_Box_set_label_color(lb7, app.pal.text_dim);
    const shared_input = cfltk.Fl_Input_new(140, 332, 350, 24, if (cfg.hasSharedFolder()) cfg.getSharedFolder() else "");
    cfltk.Fl_Input_set_text_font(shared_input, 4); // monospace
    const lb8 = cfltk.Fl_Box_new(10, 364, 120, 20, "USB Device:");
    cfltk.Fl_Box_set_label_font(lb8, 1); cfltk.Fl_Box_set_label_color(lb8, app.pal.text_dim);
    const usb_input = cfltk.Fl_Input_new(140, 362, 350, 24, if (cfg.hasUsbDevice()) cfg.getUsbDevice() else "");
    cfltk.Fl_Input_set_text_font(usb_input, 4); // monospace
    const lb9 = cfltk.Fl_Box_new(10, 394, 120, 20, "Guest Tools ISO:");
    cfltk.Fl_Box_set_label_font(lb9, 1); cfltk.Fl_Box_set_label_color(lb9, app.pal.text_dim);
    const gt_input = cfltk.Fl_Check_Button_new(140, 392, 350, 24, "Auto-mount virtio-win");
    cfltk.Fl_Check_Button_set_label_color(gt_input, app.pal.text);
    if (cfg.guest_tools) cfltk.Fl_Check_Button_set_checked(gt_input, 1);

    // ── Section: AutoProtect ───────────────────────────────────────
    _ = sectionLabel("AutoProtect", 10, 430, 200);
    _ = sectionSep(10, 454, 470);

    const lb10 = cfltk.Fl_Box_new(10, 464, 120, 20, "AutoProtect:");
    cfltk.Fl_Box_set_label_font(lb10, 1); cfltk.Fl_Box_set_label_color(lb10, app.pal.text_dim);
    const ap_input = cfltk.Fl_Check_Button_new(140, 463, 100, 24, "Enabled");
    cfltk.Fl_Check_Button_set_label_color(ap_input, app.pal.text);
    if (cfg.autoprotect) cfltk.Fl_Check_Button_set_checked(ap_input, 1);
    const lb11 = cfltk.Fl_Box_new(250, 464, 80, 20, "Interval (min):");
    cfltk.Fl_Box_set_label_font(lb11, 1); cfltk.Fl_Box_set_label_color(lb11, app.pal.text_dim);
    var ap_int_buf: [16]u8 = undefined;
    const ap_int_str = std.fmt.bufPrintZ(&ap_int_buf, "{d}", .{cfg.autoprotect_interval_min}) catch "1440";
    const ap_int_input = cfltk.Fl_Input_new(335, 462, 155, 24, ap_int_str);
    const lb12 = cfltk.Fl_Box_new(10, 494, 120, 20, "Max Snapshots:");
    cfltk.Fl_Box_set_label_font(lb12, 1); cfltk.Fl_Box_set_label_color(lb12, app.pal.text_dim);
    var ap_max_buf: [16]u8 = undefined;
    const ap_max_str = std.fmt.bufPrintZ(&ap_max_buf, "{d}", .{cfg.autoprotect_max}) catch "3";
    const ap_max_input = cfltk.Fl_Input_new(140, 492, 150, 24, ap_max_str);
    const lb13 = cfltk.Fl_Box_new(10, 524, 120, 20, "Notes:");
    cfltk.Fl_Box_set_label_font(lb13, 1); cfltk.Fl_Box_set_label_color(lb13, app.pal.text_dim);
    const notes_input = cfltk.Fl_Input_new(140, 522, 350, 80, if (cfg.hasNotes()) cfg.getNotes() else "");

    // ── Section: Display & Video ───────────────────────────────────
    _ = sectionLabel("Display & Video", 10, 614, 200);
    _ = sectionSep(10, 638, 470);

    const lb14 = cfltk.Fl_Box_new(10, 648, 120, 20, "Displays:");
    cfltk.Fl_Box_set_label_font(lb14, 1); cfltk.Fl_Box_set_label_color(lb14, app.pal.text_dim);
    var nd_buf: [16]u8 = undefined;
    const nd_str = std.fmt.bufPrintZ(&nd_buf, "{d}", .{cfg.num_displays}) catch "1";
    const nd_input = cfltk.Fl_Input_new(140, 646, 150, 24, nd_str);

    const lb15 = cfltk.Fl_Box_new(10, 678, 110, 20, "Display:");
    cfltk.Fl_Box_set_label_font(lb15, 1); cfltk.Fl_Box_set_label_color(lb15, app.pal.text_dim);
    const disp_input = cfltk.Fl_Input_new(130, 676, 150, 24, std.mem.span(cfg.display.label()));
    const lb16 = cfltk.Fl_Box_new(300, 678, 60, 20, "Res:");
    cfltk.Fl_Box_set_label_font(lb16, 1); cfltk.Fl_Box_set_label_color(lb16, app.pal.text_dim);
    const res_input = cfltk.Fl_Input_new(360, 676, 110, 24, std.mem.span(cfg.display_resolution.label()));

    const e3d_input = cfltk.Fl_Check_Button_new(130, 707, 160, 24, "3D Acceleration");
    cfltk.Fl_Check_Button_set_label_color(e3d_input, app.pal.text);
    if (cfg.enable_3d) cfltk.Fl_Check_Button_set_checked(e3d_input, 1);
    const lb17 = cfltk.Fl_Box_new(300, 709, 60, 20, "GPU:");
    cfltk.Fl_Box_set_label_font(lb17, 1); cfltk.Fl_Box_set_label_color(lb17, app.pal.text_dim);
    const gpu_input = cfltk.Fl_Input_new(360, 707, 110, 24, std.mem.span(cfg.gpu_device.label()));

    const emb_input = cfltk.Fl_Check_Button_new(130, 737, 160, 24, "Embed Display");
    cfltk.Fl_Check_Button_set_label_color(emb_input, app.pal.text);
    if (cfg.embed_display) cfltk.Fl_Check_Button_set_checked(emb_input, 1);
    const ser_input = cfltk.Fl_Check_Button_new(300, 737, 170, 24, "Enable Serial");
    cfltk.Fl_Check_Button_set_label_color(ser_input, app.pal.text);
    if (cfg.enable_serial) cfltk.Fl_Check_Button_set_checked(ser_input, 1);

    const lb18 = cfltk.Fl_Box_new(10, 766, 110, 20, "VNC Port:");
    cfltk.Fl_Box_set_label_font(lb18, 1); cfltk.Fl_Box_set_label_color(lb18, app.pal.text_dim);
    var vncbuf: [16]u8 = undefined;
    const vnc_str = std.fmt.bufPrintZ(&vncbuf, "{d}", .{cfg.vnc_port}) catch "5900";
    const vnc_input = cfltk.Fl_Input_new(130, 764, 150, 24, vnc_str);
    const lb19 = cfltk.Fl_Box_new(300, 766, 60, 20, "SPICE:");
    cfltk.Fl_Box_set_label_font(lb19, 1); cfltk.Fl_Box_set_label_color(lb19, app.pal.text_dim);
    var spcbuf: [16]u8 = undefined;
    const spc_str = std.fmt.bufPrintZ(&spcbuf, "{d}", .{cfg.spice_port}) catch "5901";
    const spc_input = cfltk.Fl_Input_new(360, 764, 110, 24, spc_str);

    // ── Section: Storage ───────────────────────────────────────────
    _ = sectionLabel("Storage", 10, 806, 200);
    _ = sectionSep(10, 830, 470);

    const lb20 = cfltk.Fl_Box_new(10, 840, 110, 20, "Disk2 Path:");
    cfltk.Fl_Box_set_label_font(lb20, 1); cfltk.Fl_Box_set_label_color(lb20, app.pal.text_dim);
    const d2p_input = cfltk.Fl_Input_new(130, 838, 340, 24, if (cfg.hasDisk2()) cfg.getDisk2Path() else "");
    cfltk.Fl_Input_set_text_font(d2p_input, 4); // monospace
    const lb21 = cfltk.Fl_Box_new(10, 870, 110, 20, "Disk2 Size (GB):");
    cfltk.Fl_Box_set_label_font(lb21, 1); cfltk.Fl_Box_set_label_color(lb21, app.pal.text_dim);
    var d2s_buf: [16]u8 = undefined;
    const d2s_str = std.fmt.bufPrintZ(&d2s_buf, "{d}", .{cfg.disk2_size_gb}) catch "0";
    const d2s_input = cfltk.Fl_Input_new(130, 868, 150, 24, d2s_str);
    const lb22 = cfltk.Fl_Box_new(300, 870, 60, 20, "Format:");
    cfltk.Fl_Box_set_label_font(lb22, 1); cfltk.Fl_Box_set_label_color(lb22, app.pal.text_dim);
    const d2f_input = cfltk.Fl_Input_new(360, 868, 110, 24, std.mem.span(cfg.disk2_format.label()));

    const lb23 = cfltk.Fl_Box_new(10, 900, 110, 20, "Floppy Path:");
    cfltk.Fl_Box_set_label_font(lb23, 1); cfltk.Fl_Box_set_label_color(lb23, app.pal.text_dim);
    const flp_input = cfltk.Fl_Input_new(130, 898, 340, 24, if (cfg.hasFloppy()) cfg.getFloppyPath() else "");
    cfltk.Fl_Input_set_text_font(flp_input, 4); // monospace

    // ── Section: NICs & Port Forwards ──────────────────────────────
    _ = sectionLabel("NICs & Port Forwards", 10, 940, 250);
    _ = sectionSep(10, 964, 470);

    const lb24 = cfltk.Fl_Box_new(10, 974, 110, 20, "NIC2 Mode:");
    cfltk.Fl_Box_set_label_font(lb24, 1); cfltk.Fl_Box_set_label_color(lb24, app.pal.text_dim);
    const n2m_input = cfltk.Fl_Input_new(130, 972, 150, 24, std.mem.span(cfg.nics[1].mode.label()));
    const lb25 = cfltk.Fl_Box_new(300, 974, 60, 20, "MAC:");
    cfltk.Fl_Box_set_label_font(lb25, 1); cfltk.Fl_Box_set_label_color(lb25, app.pal.text_dim);
    const n2mac_input = cfltk.Fl_Input_new(360, 972, 110, 24, if (cfg.nics[1].mac_len > 0) cfg.getNic2Mac() else "");
    cfltk.Fl_Input_set_text_font(n2mac_input, 4); // monospace MAC

    const lb26 = cfltk.Fl_Box_new(10, 1004, 110, 20, "NIC3 Mode:");
    cfltk.Fl_Box_set_label_font(lb26, 1); cfltk.Fl_Box_set_label_color(lb26, app.pal.text_dim);
    const n3m_input = cfltk.Fl_Input_new(130, 1002, 150, 24, std.mem.span(cfg.nics[2].mode.label()));
    const lb27 = cfltk.Fl_Box_new(300, 1004, 60, 20, "MAC:");
    cfltk.Fl_Box_set_label_font(lb27, 1); cfltk.Fl_Box_set_label_color(lb27, app.pal.text_dim);
    const n3mac_input = cfltk.Fl_Input_new(360, 1002, 110, 24, if (cfg.nics[2].mac_len > 0) cfg.getNic3Mac() else "");
    cfltk.Fl_Input_set_text_font(n3mac_input, 4); // monospace MAC

    const lb28 = cfltk.Fl_Box_new(10, 1034, 110, 20, "Port Forwards:");
    cfltk.Fl_Box_set_label_font(lb28, 1); cfltk.Fl_Box_set_label_color(lb28, app.pal.text_dim);
    const pf_input = cfltk.Fl_Input_new(130, 1032, 340, 24, if (cfg.hasPortForwards()) cfg.getPortForwards() else "");
    cfltk.Fl_Input_set_text_font(pf_input, 4); // monospace port forwards

    // ── Section: Advanced ──────────────────────────────────────────
    _ = sectionLabel("Advanced", 10, 1074, 200);
    _ = sectionSep(10, 1098, 470);

    const lb29 = cfltk.Fl_Box_new(10, 1108, 110, 20, "CPU Sockets:");
    cfltk.Fl_Box_set_label_font(lb29, 1); cfltk.Fl_Box_set_label_color(lb29, app.pal.text_dim);
    var csbuf: [16]u8 = undefined;
    const cs_str = std.fmt.bufPrintZ(&csbuf, "{d}", .{cfg.cpu_sockets}) catch "1";
    const cs_input = cfltk.Fl_Input_new(130, 1106, 150, 24, cs_str);
    const kvm_input = cfltk.Fl_Check_Button_new(300, 1111, 170, 24, "Enable KVM");
    cfltk.Fl_Check_Button_set_label_color(kvm_input, app.pal.text);
    if (cfg.enable_kvm) cfltk.Fl_Check_Button_set_checked(kvm_input, 1);

    const lb30 = cfltk.Fl_Box_new(10, 1138, 110, 20, "Guest OS:");
    cfltk.Fl_Box_set_label_font(lb30, 1); cfltk.Fl_Box_set_label_color(lb30, app.pal.text_dim);
    const os_input = cfltk.Fl_Input_new(130, 1136, 150, 24, std.mem.span(cfg.guest_os.label()));
    const lb31 = cfltk.Fl_Box_new(300, 1138, 60, 20, "Boot:");
    cfltk.Fl_Box_set_label_font(lb31, 1); cfltk.Fl_Box_set_label_color(lb31, app.pal.text_dim);
    const boot_input = cfltk.Fl_Input_new(360, 1136, 110, 24, std.mem.span(cfg.boot_order.label()));

    const lb32 = cfltk.Fl_Box_new(10, 1168, 110, 20, "Disk Format:");
    cfltk.Fl_Box_set_label_font(lb32, 1); cfltk.Fl_Box_set_label_color(lb32, app.pal.text_dim);
    const df_input = cfltk.Fl_Input_new(130, 1166, 150, 24, std.mem.span(cfg.disk_format.label()));
    const lb33 = cfltk.Fl_Box_new(300, 1168, 60, 20, "MAC:");
    cfltk.Fl_Box_set_label_font(lb33, 1); cfltk.Fl_Box_set_label_color(lb33, app.pal.text_dim);
    const mac_input = cfltk.Fl_Input_new(360, 1166, 110, 24, if (cfg.nics[0].mac_len > 0) cfg.getMacAddress() else "");
    cfltk.Fl_Input_set_text_font(mac_input, 4); // monospace MAC

    const lb34 = cfltk.Fl_Box_new(10, 1198, 110, 20, "Audio:");
    cfltk.Fl_Box_set_label_font(lb34, 1); cfltk.Fl_Box_set_label_color(lb34, app.pal.text_dim);
    const aud_input = cfltk.Fl_Input_new(130, 1196, 150, 24, std.mem.span(cfg.audio.label()));
    const fav_input = cfltk.Fl_Check_Button_new(300, 1201, 170, 24, "Favorite");
    cfltk.Fl_Check_Button_set_label_color(fav_input, app.pal.text);
    if (cfg.favorite) cfltk.Fl_Check_Button_set_checked(fav_input, 1);

    cfltk.Fl_Scroll_end(scroll);

    // Fixed button bar below the scroll area
    const btn_y = SCROLL_H + 10;
    _ = sectionSep(10, btn_y, DIALOG_W - 20);

    const save_btn = cfltk.Fl_Button_new(DIALOG_W - 200, btn_y + 8, 85, 28, "Save");
    cfltk.Fl_Button_set_color(save_btn, app.pal.accent);
    cfltk.Fl_Button_set_label_color(save_btn, app.pal.accent_text);
    const cancel_btn = cfltk.Fl_Button_new(DIALOG_W - 105, btn_y + 8, 85, 28, "Cancel");
    cfltk.Fl_Button_set_color(cancel_btn, app.pal.gray_btn);
    cfltk.Fl_Button_set_label_color(cancel_btn, app.pal.accent_text);

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
        persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
}

fn snapDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const vc = &app.vms[idx];
    if (!vc.hasDisk()) return;
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 480, 2), @divTrunc(cfltk.Fl_h() - 200, 2), 480, 200, "Snapshot Manager");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    const snl = cfltk.Fl_Box_new(10, 10, 460, 20, "Snapshot name:");
    cfltk.Fl_Box_set_label_font(snl, 1); cfltk.Fl_Box_set_label_color(snl, app.pal.text_dim);
    const ni = cfltk.Fl_Input_new(10, 30, 460, 24, "snapshot1");
    const tb = cfltk.Fl_Button_new(10, 70, 80, 30, "Take");
    cfltk.Fl_Button_set_color(tb, app.pal.accent); cfltk.Fl_Button_set_label_color(tb, app.pal.accent_text);
    const lb = cfltk.Fl_Button_new(100, 70, 80, 30, "List");
    cfltk.Fl_Button_set_color(lb, app.pal.accent); cfltk.Fl_Button_set_label_color(lb, app.pal.accent_text);
    const rb = cfltk.Fl_Button_new(190, 70, 80, 30, "Revert");
    cfltk.Fl_Button_set_color(rb, app.pal.warn); cfltk.Fl_Button_set_label_color(rb, app.pal.accent_text);
    const db = cfltk.Fl_Button_new(280, 70, 80, 30, "Delete");
    cfltk.Fl_Button_set_color(db, app.pal.danger); cfltk.Fl_Button_set_label_color(db, app.pal.accent_text);
    const cb = cfltk.Fl_Button_new(10, 160, 80, 30, "Close");
    cfltk.Fl_Button_set_color(cb, app.pal.gray_btn); cfltk.Fl_Button_set_label_color(cb, app.pal.accent_text);
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
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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

    const rw = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 340, 2), @divTrunc(cfltk.Fl_h() - 110, 2), 340, 110, "Rename VM");
    cfltk.Fl_Window_make_modal(rw, 0);
    cfltk.Fl_Window_set_color(rw, app.pal.bg);
    const rnl = cfltk.Fl_Box_new(10, 10, 320, 20, "Enter new name for the virtual machine:");
    cfltk.Fl_Box_set_label_font(rnl, 1); cfltk.Fl_Box_set_label_color(rnl, app.pal.text_dim);

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
    cfltk.Fl_Button_set_color(ok_btn, app.pal.accent);
    cfltk.Fl_Button_set_label_color(ok_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_callback(ok_btn, &RDlg.okCB, &rd);
    const cancel_btn = cfltk.Fl_Button_new(180, 75, 70, 25, "Cancel");
    cfltk.Fl_Button_set_color(cancel_btn, app.pal.gray_btn);
    cfltk.Fl_Button_set_label_color(cancel_btn, app.pal.accent_text);
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
    app.setStatus("VM suspended to file — ready to resume on power-on");
}

fn newVmDialog() void {
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 460, 2), @divTrunc(cfltk.Fl_h() - 260, 2), 460, 260, "New Virtual Machine");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);

    _ = sectionLabel("Basic", 10, 10, 440);

    const nlb0 = cfltk.Fl_Box_new(10, 40, 100, 20, "VM Name:");
    cfltk.Fl_Box_set_label_font(nlb0, 1); cfltk.Fl_Box_set_label_color(nlb0, app.pal.text_dim);
    const name_input = cfltk.Fl_Input_new(120, 38, 330, 24, "");
    const nlb1 = cfltk.Fl_Box_new(10, 70, 100, 20, "Guest OS:");
    cfltk.Fl_Box_set_label_font(nlb1, 1); cfltk.Fl_Box_set_label_color(nlb1, app.pal.text_dim);
    const os_input = cfltk.Fl_Input_new(120, 68, 330, 24, "Linux");
    const nlb2 = cfltk.Fl_Box_new(10, 100, 100, 20, "Memory (MB):");
    cfltk.Fl_Box_set_label_font(nlb2, 1); cfltk.Fl_Box_set_label_color(nlb2, app.pal.text_dim);
    const mem_input = cfltk.Fl_Input_new(120, 98, 330, 24, "2048");
    const nlb3 = cfltk.Fl_Box_new(10, 130, 100, 20, "CPU Cores:");
    cfltk.Fl_Box_set_label_font(nlb3, 1); cfltk.Fl_Box_set_label_color(nlb3, app.pal.text_dim);
    const cpu_input = cfltk.Fl_Input_new(120, 128, 330, 24, "2");
    const nlb4 = cfltk.Fl_Box_new(10, 160, 100, 20, "Disk (GB):");
    cfltk.Fl_Box_set_label_font(nlb4, 1); cfltk.Fl_Box_set_label_color(nlb4, app.pal.text_dim);
    const disk_input = cfltk.Fl_Input_new(120, 158, 330, 24, "20");

    _ = sectionSep(10, 195, 440);

    const create_btn = cfltk.Fl_Button_new(280, 215, 80, 30, "Create");
    cfltk.Fl_Button_set_color(create_btn, app.pal.accent);
    cfltk.Fl_Button_set_label_color(create_btn, app.pal.accent_text);
    const cancel_btn = cfltk.Fl_Button_new(370, 215, 80, 30, "Cancel");
    cfltk.Fl_Button_set_color(cancel_btn, app.pal.gray_btn);
    cfltk.Fl_Button_set_label_color(cancel_btn, app.pal.accent_text);

    // Store pointers for the callback to use
    // Use a struct to pass data to callbacks
    const DlgData = struct {
        name: ?*cfltk.Fl_Input,
        os: ?*cfltk.Fl_Input,
        mem: ?*cfltk.Fl_Input,
        cpu: ?*cfltk.Fl_Input,
        disk: ?*cfltk.Fl_Input,
        dlg: ?*cfltk.Fl_Window,
    };
    var ddata = DlgData{ .name = @ptrCast(name_input), .os = @ptrCast(os_input), .mem = @ptrCast(mem_input), .cpu = @ptrCast(cpu_input), .disk = @ptrCast(disk_input), .dlg = @ptrCast(dlg) };

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
            if (dd.os) |o| {
                const os_str = std.mem.span(cfltk.Fl_Input_value(o));
                cfg.guest_os = vm.GuestOs.fromStr(os_str);
            }

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
            persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
}




// Global event handler — intercepts keyboard shortcuts + right-clicks
fn kbHandler(event: c_int) callconv(.c) c_int {
    if (event == 1) { // FL_PUSH = 1 (mouse button press)
        if (cfltk.Fl_event_button() == 3) { // Right click
            app.selectCurrent();
            _ = cfltk.Fl_event_x();
            _ = cfltk.Fl_event_y();
            // Show context menu
            if (app.ctx_menu_handle) |cm| _ = cfltk.Fl_Menu_Button_popup(cm);
            return 1;
        }
    }
    if (event == 12) { // FL_SHORTCUT = 12
        // Esc closes the window by default — block when no modal is open
        if (cfltk.Fl_event_key() == 0xff1b and cfltk.Fl_modal() == null) return 1;
        return 0;
    }
    if (event != 8) return 0; // FL_KEYDOWN = 8
    const key = cfltk.Fl_event_key();
    const ctrl = cfltk.Fl_event_ctrl() != 0;
    const shift = cfltk.Fl_event_shift() != 0;
    if (ctrl and key == 'n') { if (shift) { cloneVm(); } else { newVmDialog(); } return 1; }
    if (ctrl and key == 'q') { shutdown(); return 1; }
    if (ctrl and key == 'e') { editVmDialog(); return 1; }
    if (ctrl and key == 'i') { importVm(); return 1; }
    if (ctrl and key == 's') { suspendVm(); return 1; }
    if (ctrl and key == 'p') { dialogs.prefsDialog(); return 1; }
    if (key == 0xffbf) { editVmDialog(); return 1; } // F2
    if (key == 0xffff) { deleteCurrentVm(); return 1; } // DEL
    if (key == 0xffc8) { if (app.win_handle) |w| { const cur = cfltk.Fl_Window_fullscreen_active(w); cfltk.Fl_Window_fullscreen(w, if (cur != 0) @as(c_uint, 0) else 1); } return 1; } // F11 toggle
    if (ctrl and key == 'w') { app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); return 1; }
    if (ctrl and key == 'f') { if (app.search_input) |si| _ = cfltk.Fl_Input_take_focus(si); return 1; }
    if (key == 0xff0d) { togglePower(); return 1; } // Enter → Power On/Off
    if (key == 0xff1b) { // Escape
        if (cfltk.Fl_modal() != null) return 0; // let modal dialog handle Escape
        app.selected_idx = null; app.refreshBrowser(); app.refreshDetails(); return 1;
    }
    if (key == 0xffc2) { app.refreshBrowser(); app.refreshDetails(); return 1; } // F5 → Refresh
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
        const n = @min(sv.len, app.filter_text.len - 1);
        @memcpy(app.filter_text[0..n], sv[0..n]);
        _ = std.ascii.lowerString(app.filter_text[0..n], app.filter_text[0..n]);
        app.filter_len = n;
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
                        var auto_names: [16][]const u8 = @splat("");
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
                        const to_delete = @min(excess, auto_count);
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
                persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
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
    app.applyTheme(app.prefs.theme);
    _ = cfltk.Fl_set_scheme("gtk+");

    // Initialize the HV abstraction dispatch table (QEMU backend).
    app.g_vmm = hv_backend.createVmm(.auto);

    // Global FLTK color scheme is already set by applyTheme() above.
    // Do NOT hardcode Fl_background/Fl_foreground etc. here — that would
    // overwrite the palette chosen by applyTheme() and break dark mode.

    const WW: i32 = if (app.prefs.win_w > 0) app.prefs.win_w else 1200;
    const WH: i32 = if (app.prefs.win_h > 0) app.prefs.win_h else 700;
    const win = cfltk.Fl_Window_new_wh(WW, WH, "KVMGUI");
    app.win_handle = @ptrCast(win);

    // Menu bar with working submenus
    const menu_bar = cfltk.Fl_Menu_Bar_new(0, 0, WW, 25, "");
    app.menu_bar = @ptrCast(menu_bar);

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
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "View/Full Screen\tF11", 0, @ptrCast(&fullScreenCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(menu_bar, "Help/About KVMGUI", 0, @ptrCast(&aboutCB), null, 0);

    // Toolbar with styled background
    const tb_y: i32 = 28;
    const tb = cfltk.Fl_Box_new(0, tb_y, WW, 40, "");
    app.toolbar_bg = @ptrCast(tb);
    cfltk.Fl_Box_set_box(tb, 4); // FL_THIN_UP_BOX
    cfltk.Fl_Box_set_color(tb, app.pal.border);
    const new_btn = cfltk.Fl_Button_new(5, tb_y + 3, 80, 34, "New VM");
    const start_btn = cfltk.Fl_Button_new(90, tb_y + 3, 80, 34, "Power On");
    const susp_btn = cfltk.Fl_Button_new(175, tb_y + 3, 80, 34, "Suspend");
    const pause_btn = cfltk.Fl_Button_new(260, tb_y + 3, 80, 34, "Pause");
    const resume_btn = cfltk.Fl_Button_new(345, tb_y + 3, 80, 34, "Resume");
    const sd_btn = cfltk.Fl_Button_new(430, tb_y + 3, 80, 34, "Shut Down");
    const rst_btn = cfltk.Fl_Button_new(515, tb_y + 3, 80, 34, "Reset");
    const set_btn = cfltk.Fl_Button_new(600, tb_y + 3, 80, 34, "Settings");
    const export_ovf_btn = cfltk.Fl_Button_new(685, tb_y + 3, 75, 34, "Export");
    const clone_btn = cfltk.Fl_Button_new(765, tb_y + 3, 70, 34, "Clone");
    const snap_btn = cfltk.Fl_Button_new(840, tb_y + 3, 75, 34, "Snapshot");
    const cad_btn = cfltk.Fl_Button_new(920, tb_y + 3, 80, 34, "Ctrl+Alt+Del");
    const home_btn = cfltk.Fl_Button_new(1005, tb_y + 3, 70, 34, "Home");
    const batch_start_btn = cfltk.Fl_Button_new(1080, tb_y + 3, 55, 34, "Start All");
    const batch_stop_btn = cfltk.Fl_Button_new(1140, tb_y + 3, 55, 34, "Stop All");

    // Tooltips
    cfltk.Fl_Button_set_tooltip(new_btn, "Create a new virtual machine (Ctrl+N)");
    cfltk.Fl_Button_set_tooltip(start_btn, "Power on or off the selected virtual machine");
    cfltk.Fl_Button_set_tooltip(susp_btn, "Suspend the selected virtual machine to disk");
    cfltk.Fl_Button_set_tooltip(pause_btn, "Freeze guest execution (QMP stop)");
    cfltk.Fl_Button_set_tooltip(resume_btn, "Resume paused guest execution (QMP cont)");
    cfltk.Fl_Button_set_tooltip(sd_btn, "Send ACPI shutdown to the guest (graceful power off)");
    cfltk.Fl_Button_set_tooltip(rst_btn, "Hard reset the guest via QMP system_reset");
    cfltk.Fl_Button_set_tooltip(set_btn, "Edit virtual machine settings (F2)");
    cfltk.Fl_Button_set_tooltip(export_ovf_btn, "Export VM as OVF 1.0 (VMDK disk + descriptor)");
    cfltk.Fl_Button_set_tooltip(clone_btn, "Clone the selected VM (full or linked copy, Ctrl+Shift+N)");
    cfltk.Fl_Button_set_tooltip(snap_btn, "Manage snapshots for the selected VM");
    cfltk.Fl_Button_set_tooltip(cad_btn, "Send Ctrl+Alt+Del to the guest (login / unlock)");
    cfltk.Fl_Button_set_tooltip(home_btn, "Return to Home (deselect VM, Ctrl+W)");
    cfltk.Fl_Button_set_tooltip(batch_start_btn, "Power on all stopped virtual machines");
    cfltk.Fl_Button_set_tooltip(batch_stop_btn, "Force power off all running virtual machines");

    // Toolbar button colors: action-coded
    cfltk.Fl_Button_set_color(new_btn, app.pal.accent);        cfltk.Fl_Button_set_label_color(new_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(start_btn, app.pal.success);      cfltk.Fl_Button_set_label_color(start_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(susp_btn, app.pal.warn);       cfltk.Fl_Button_set_label_color(susp_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(pause_btn, app.pal.amber);      cfltk.Fl_Button_set_label_color(pause_btn, app.pal.dark_text);
    cfltk.Fl_Button_set_color(resume_btn, app.pal.success);     cfltk.Fl_Button_set_label_color(resume_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(sd_btn, app.pal.danger);         cfltk.Fl_Button_set_label_color(sd_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(rst_btn, app.pal.danger);        cfltk.Fl_Button_set_label_color(rst_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(set_btn, app.pal.accent);        cfltk.Fl_Button_set_label_color(set_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(export_ovf_btn, app.pal.accent);  cfltk.Fl_Button_set_label_color(export_ovf_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(clone_btn, app.pal.accent);         cfltk.Fl_Button_set_label_color(clone_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(snap_btn, app.pal.accent);         cfltk.Fl_Button_set_label_color(snap_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(cad_btn, app.pal.accent);        cfltk.Fl_Button_set_label_color(cad_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(home_btn, app.pal.gray_btn);       cfltk.Fl_Button_set_label_color(home_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(batch_start_btn, app.pal.success); cfltk.Fl_Button_set_label_color(batch_start_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(batch_stop_btn, app.pal.danger); cfltk.Fl_Button_set_label_color(batch_stop_btn, app.pal.accent_text);

    cfltk.Fl_Button_set_callback(new_btn, newVmCB, null);
    cfltk.Fl_Button_set_callback(start_btn, powerCB, null);
    cfltk.Fl_Button_set_callback(susp_btn, suspendCB, null);
    cfltk.Fl_Button_set_callback(pause_btn, pauseCB, null);
    cfltk.Fl_Button_set_callback(resume_btn, resumeCB, null);
    cfltk.Fl_Button_set_callback(sd_btn, shutdownCB, null);
    cfltk.Fl_Button_set_callback(rst_btn, resetCB, null);
    cfltk.Fl_Button_set_callback(set_btn, settingsCB, null);
    cfltk.Fl_Button_set_callback(export_ovf_btn, exportOvfCB, null);
    cfltk.Fl_Button_set_callback(clone_btn, cloneCB, null);
    cfltk.Fl_Button_set_callback(snap_btn, snapshotCB, null);
    cfltk.Fl_Button_set_callback(cad_btn, cadCB, null);
    cfltk.Fl_Button_set_callback(home_btn, homeCB, null);
    cfltk.Fl_Button_set_callback(batch_start_btn, startAllCB, null);
    cfltk.Fl_Button_set_callback(batch_stop_btn, stopAllCB, null);

    // ── Utility toolbar (row 2) ── Import · Rename · Delete | VNet · Prefs | Web Start · Web Stop
    const utb_y: i32 = 68;
    const utb = cfltk.Fl_Box_new(0, utb_y, WW, 42, "");
    cfltk.Fl_Box_set_box(utb, 4);
    cfltk.Fl_Box_set_color(utb, app.pal.border);

    const import_btn = cfltk.Fl_Button_new(5, utb_y + 3, 70, 34, "Import");
    const rename_btn = cfltk.Fl_Button_new(80, utb_y + 3, 70, 34, "Rename");
    const del_btn = cfltk.Fl_Button_new(155, utb_y + 3, 70, 34, "Delete");
    const fav_btn = cfltk.Fl_Button_new(230, utb_y + 3, 65, 34, "★ Fav");

    const vnet_btn = cfltk.Fl_Button_new(300, utb_y + 3, 70, 34, "VNet");
    const pref_btn = cfltk.Fl_Button_new(375, utb_y + 3, 70, 34, "Prefs");

    const ws_start_btn = cfltk.Fl_Button_new(450, utb_y + 3, 70, 34, "Web Start");
    const ws_stop_btn = cfltk.Fl_Button_new(525, utb_y + 3, 70, 34, "Web Stop");

    // Tooltips
    cfltk.Fl_Button_set_tooltip(import_btn, "Import a VM from a .vmdk or .qcow2 disk image");
    cfltk.Fl_Button_set_tooltip(rename_btn, "Rename the selected virtual machine");
    cfltk.Fl_Button_set_tooltip(del_btn, "Delete the selected virtual machine (DEL key)");
    cfltk.Fl_Button_set_tooltip(fav_btn, "Toggle favorite (pin to top of VM Library)");
    cfltk.Fl_Button_set_tooltip(vnet_btn, "Virtual Network Editor (manage VMnet switch configurations)");
    cfltk.Fl_Button_set_tooltip(pref_btn, "Preferences (theme, default folder, display, audio)");
    cfltk.Fl_Button_set_tooltip(ws_start_btn, "Start the web UI server on http://localhost:9080");
    cfltk.Fl_Button_set_tooltip(ws_stop_btn, "Stop the web UI server");

    // Button colors
    cfltk.Fl_Button_set_color(import_btn, app.pal.accent);      cfltk.Fl_Button_set_label_color(import_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(rename_btn, app.pal.accent);      cfltk.Fl_Button_set_label_color(rename_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(del_btn, app.pal.danger);          cfltk.Fl_Button_set_label_color(del_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(fav_btn, app.pal.gray_btn);       cfltk.Fl_Button_set_label_color(fav_btn, app.pal.amber);
    cfltk.Fl_Button_set_color(vnet_btn, app.pal.gray_btn);       cfltk.Fl_Button_set_label_color(vnet_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(pref_btn, app.pal.gray_btn);       cfltk.Fl_Button_set_label_color(pref_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(ws_start_btn, app.pal.success);    cfltk.Fl_Button_set_label_color(ws_start_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_color(ws_stop_btn, app.pal.danger);       cfltk.Fl_Button_set_label_color(ws_stop_btn, app.pal.accent_text);

    // Callbacks
    cfltk.Fl_Button_set_callback(import_btn, importCB, null);
    cfltk.Fl_Button_set_callback(rename_btn, renameCB, null);
    cfltk.Fl_Button_set_callback(del_btn, deleteVmCB, null);
    cfltk.Fl_Button_set_callback(fav_btn, favCB, null);
    cfltk.Fl_Button_set_callback(vnet_btn, vnetCB, null);
    cfltk.Fl_Button_set_callback(pref_btn, prefsCB, null);
    cfltk.Fl_Button_set_callback(ws_start_btn, webStartCB, null);
    cfltk.Fl_Button_set_callback(ws_stop_btn, webStopCB, null);

    const body_y: i32 = 112;
    const body_h: i32 = WH - body_y - 26;
    const SW: i32 = 200;
    const CX: i32 = SW;
    const CW: i32 = WW - SW;

    // Sidebar header
    const lib_hdr = cfltk.Fl_Box_new(0, body_y, SW, 22, "VM Library");
    app.lib_hdr = @ptrCast(lib_hdr);
    cfltk.Fl_Box_set_box(lib_hdr, 4); // FL_THIN_UP_BOX
    cfltk.Fl_Box_set_label_font(lib_hdr, 1); // bold
    cfltk.Fl_Box_set_label_color(lib_hdr, app.pal.header);
    cfltk.Fl_Box_set_label_size(lib_hdr, 13);
    const b = cfltk.Fl_Browser_new(2, body_y + 22, SW - 4, body_h - 45, "");
    app.browser = @ptrCast(b);
    cfltk.Fl_Browser_set_callback(b, browserCB, null);
    const si = cfltk.Fl_Input_new(2, body_y + body_h - 20, SW - 4, 18, "");
    app.search_input = @ptrCast(si);
    cfltk.Fl_Input_set_callback(si, searchCB, null);
    cfltk.Fl_Input_set_tooltip(si, "Filter VMs by name (Ctrl+F)");

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
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Export OVF...", 0, @ptrCast(&exportOvfCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Clone", 0, @ptrCast(&cloneCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Toggle Favorite", 0, @ptrCast(&favCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Delete VM\tDEL", 0, @ptrCast(&deleteVmCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Start All VMs", 0, @ptrCast(&startAllCB), null, 0);
    _ = cfltk.Fl_Menu_Bar_add(@ptrCast(ctx_menu), "Stop All VMs", 0, @ptrCast(&stopAllCB), null, 0);

    // Tabs
    const tabs = cfltk.Fl_Tabs_new(CX, body_y, CW, body_h, "");
    app.tab_bar = @ptrCast(tabs);

    // Summary
    const sg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Summary");
    const nm = cfltk.Fl_Box_new(CX + 10, body_y + 30, CW - 20, 30, "No virtual machine selected.");
    app.sum_name = @ptrCast(nm);
    cfltk.Fl_Box_set_label_font(@ptrCast(nm), 1);
    cfltk.Fl_Box_set_label_size(@ptrCast(nm), 18);
    // Separator under VM name
    const ss = cfltk.Fl_Box_new(CX + 10, body_y + 65, CW - 20, 2, "");
    cfltk.Fl_Box_set_box(ss, 1); // FL_FLAT_BOX
    cfltk.Fl_Box_set_color(ss, app.pal.border);

    var ypos: i32 = body_y + 75;
    for ([_][]const u8{ "State:", "Guest OS:", "Memory:", "CPU:", "Hard Disk:", "Network:", "CD/DVD:", "Notes:", "Shared Folder:", "USB Device:", "Guest Tools:", "AutoProtect:" }, 0..) |lbl, i| {
        const kl = cfltk.Fl_Box_new(CX + 10, ypos, 100, 18, @ptrCast(lbl.ptr));
        cfltk.Fl_Box_set_label_font(kl, 1); // bold keys
        cfltk.Fl_Box_set_label_color(kl, app.pal.text_dim);
        const dv = cfltk.Fl_Box_new(CX + 115, ypos, CW - 130, 22, "");
        cfltk.Fl_Box_set_box(dv, 4); // FL_THIN_UP_BOX — card-like raised border
        cfltk.Fl_Box_set_color(dv, app.pal.surface);
        cfltk.Fl_Box_set_align(dv, 20); // FL_ALIGN_LEFT | FL_ALIGN_INSIDE
        app.detail_labels[i] = @ptrCast(dv);
        ypos += 24;
    }
    // Monospace font for path-like detail values (FL_COURIER = 4)
    cfltk.Fl_Box_set_label_font(@ptrCast(app.detail_labels[4]), 4); // Hard Disk path
    cfltk.Fl_Box_set_label_font(@ptrCast(app.detail_labels[6]), 4); // CD/DVD path
    cfltk.Fl_Box_set_label_font(@ptrCast(app.detail_labels[8]), 4); // Shared Folder path
    cfltk.Fl_Box_set_label_font(@ptrCast(app.detail_labels[9]), 4); // USB Device path
    cfltk.Fl_Group_end(@ptrCast(sg));

    // Display tab
    const dg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Display");
    const db = cfltk.Fl_Box_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "VNC/SPICE display renders here when a VM is running.");
    cfltk.Fl_Box_set_box(db, 8); // FL_BORDER_BOX
    cfltk.Fl_Box_set_color(db, app.pal.surface);
    cfltk.Fl_Box_set_label_color(db, app.pal.text_dim);
    app.display_box = @ptrCast(db);
    cfltk.Fl_Group_end(@ptrCast(dg));

    // Console tab
    const cg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Console");
    const cb = cfltk.Fl_Browser_new(CX + 5, body_y + 25, CW - 10, body_h - 30, "");
    app.console_widget = @ptrCast(cb);
    _ = cfltk.Fl_Browser_add(cb, "Serial console — not connected.");
    cfltk.Fl_Group_end(@ptrCast(cg));

    cfltk.Fl_Group_end(@ptrCast(tabs));

    // Status bar with distinct styling
    const sb = cfltk.Fl_Box_new(0, WH - 26, WW, 26, "Ready — Local Mode");
    cfltk.Fl_Box_set_box(sb, 4); // FL_THIN_UP_BOX
    cfltk.Fl_Box_set_color(sb, app.pal.border);
    cfltk.Fl_Box_set_label_color(sb, app.pal.text_dim);
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
