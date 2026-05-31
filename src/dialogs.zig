//! Dialog functions extracted from main.zig.
//!
//! Each function creates and manages a modal FLTK dialog window.
//! They import appstate for shared globals and helpers, plus
//! the remote module for API dispatch.

const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const ovf = @import("ovf.zig");
const vnet = @import("vnet.zig");
const appio = @import("appio.zig");
const transport = @import("transport.zig");
const remote = @import("remote.zig");
const app = @import("appstate.zig");
const cfltk = @import("cfltk_import.zig").c;

pub fn aboutDialog() void {
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

pub fn prefsDialog() void {
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

pub fn vnetDialog() void {
    var net_set = vnet.load();
    if (net_set.count == 0) net_set = vnet.NetworkSet.defaults();

    const dlg = cfltk.Fl_Window_new_wh(580, 420, "Virtual Network Editor");
    cfltk.Fl_Window_make_modal(dlg, 0);
    _ = cfltk.Fl_Box_new(10, 10, 560, 20, "Virtual Network switches (VMnet):");
    const net_list = cfltk.Fl_Browser_new(10, 35, 560, 260, "");
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

pub fn exportOvfDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const v = &app.vms[idx];
    if (!v.hasDisk()) { app.setStatus("VM has no disk — cannot export OVF"); return; }

    var suggest_buf: [256]u8 = undefined;
    const suggest = std.fmt.bufPrintZ(&suggest_buf, "{s}.ovf", .{v.getNameSlice()}) catch "vm.ovf";

    const path_ptr = cfltk.Fl_file_chooser("Save OVF Package", "*.ovf", suggest, 0);
    if (path_ptr == null or path_ptr[0] == 0) return;
    const save_path = std.mem.sliceTo(path_ptr, 0);

    const disk_bytes: u64 = @as(u64, v.disk_size_gb) * 1024 * 1024 * 1024;
    var vmdk_name_buf: [256]u8 = undefined;
    const dot = std.mem.lastIndexOfScalar(u8, save_path, '.');
    const base = if (dot) |d| save_path[0..d] else save_path;
    const vmdk_href = std.fmt.bufPrint(&vmdk_name_buf, "{s}-disk1.vmdk", .{base}) catch {
        app.setStatus("Path too long for OVF export");
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
        app.setStatus("Failed to generate OVF descriptor");
        return;
    };
    defer std.heap.page_allocator.free(xml);

    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = save_path, .data = xml }) catch {
        app.setStatus("Failed to write OVF file");
        return;
    };

    const disk_path = v.getDiskPathSlice();
    if (disk_path.len > 0) {
        const vmdk_full = std.heap.page_allocator.dupeZ(u8, vmdk_href) catch {
            app.setStatus("OVF saved, but VMDK path buffer allocation failed");
            return;
        };
        defer std.heap.page_allocator.free(vmdk_full);
        if (app.getVmmHandle(idx)) |h| {
            app.g_vmm.convertDiskFn(h, disk_path, vmdk_full, @intFromEnum(v.disk_format), std.heap.page_allocator) catch {
                app.setStatus("OVF saved, but VMDK conversion failed (qemu-img missing?)");
                return;
            };
        } else {
            qemu.convertDiskImage(disk_path, v.disk_format, vmdk_full, std.heap.page_allocator) catch {
                app.setStatus("OVF saved, but VMDK conversion failed (qemu-img missing?)");
                return;
            };
        }
    }

    app.setStatus("OVF package exported successfully");
}

pub fn remoteConnectDialog() void {
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
                if (s.len == 0 or s.len >= app.remote_url.len) {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: invalid URL");
                    return;
                }
                const parsed = transport.Url.parse(s) orelse {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: failed to parse URL");
                    return;
                };
                var conn = transport.Connection.connect(&parsed) orelse {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: connection failed — server unreachable");
                    return;
                };
                defer conn.close();

                var auth_header: [128]u8 = undefined;
                const body: ?[]const u8 = if (rdp.token) |t| blk: {
                    const tok = std.mem.span(cfltk.Fl_Input_value(t));
                    if (tok.len > 0 and tok.len < 64) {
                        const h = std.fmt.bufPrint(&auth_header, "Authorization: Bearer {s}\r\n", .{tok}) catch "";
                        break :blk h;
                    }
                    break :blk null;
                } else null;

                var out_buf: [256]u8 = undefined;
                const n = conn.request("GET", "/api/health", body, &out_buf);
                if (n == 0) {
                    if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: health check failed — bad response");
                    return;
                }

                std.mem.copyForwards(u8, &app.remote_url, s);
                app.remote_url_len = s.len;
                app.remote_mode = true;
                if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Connected (remote mode)");
                if (app.status_bar) |sb2| {
                    var sbb: [160]u8 = undefined;
                    const txt = std.fmt.bufPrintZ(&sbb, "Connected to {s} — Remote Mode", .{s}) catch "Remote Mode";
                    cfltk.Fl_Box_set_label(sb2, txt.ptr);
                    cfltk.Fl_Box_set_label_color(sb2, 0x0088CC);
                }
                remote.remoteRefreshVmList();
                app.refreshBrowser();
                app.refreshDetails();
                if (rdp.dlg) |dl| cfltk.Fl_Window_hide(dl);
            }
        }
    };
    const LocalFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const rdp: *RD = @ptrCast(@alignCast(d orelse return));
            app.remote_mode = false;
            app.remote_url_len = 0;
            if (rdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Switched to Local Mode");
            if (app.status_bar) |s| {
                cfltk.Fl_Box_set_label(s, "Ready — Local Mode");
                cfltk.Fl_Box_set_label_color(s, 0x666666);
            }
            app.vm_count = persist.load(&app.vms, std.heap.page_allocator, &app.prefs);
            app.refreshBrowser();
            app.refreshDetails();
            if (rdp.dlg) |dl| cfltk.Fl_Window_hide(dl);
        }
    };
    cfltk.Fl_Button_set_callback(connect_btn, &ConnectFn.go, &rd);
    cfltk.Fl_Button_set_callback(local_btn, &LocalFn.go, &rd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
}

pub fn toggleFavorite() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    app.vms[idx].favorite = !app.vms[idx].favorite;
    app.refreshBrowser();
    persist.save(&app.vms, app.vm_count, app.prefs) catch {};
}

/// Build URL-encoded body for remote VM save requests from FLTK input fields.
pub fn buildSaveBody(buf: []u8, dd: *const anyopaque) ![]const u8 {
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
