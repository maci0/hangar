// SPDX-License-Identifier: MIT
//! Dialog functions extracted from main.zig.
//!
//! Each function creates and manages a modal FLTK dialog window.
//! They import appstate for shared globals and helpers, plus
//! the remote module for API dispatch.

const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const ovf = @import("ovf.zig");
const vnet = @import("vnet.zig");
const appio = @import("appio.zig");
const transport = @import("transport.zig");
const remote = @import("remote.zig");
const urlencode = @import("urlencode.zig");
const app = @import("appstate.zig");
const cfltk = @import("cfltk_import.zig").c;

pub fn aboutDialog() void {
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 440, 2), @divTrunc(cfltk.Fl_h() - 420, 2), 440, 420, "About Hangar");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 440, 420, 0, 0);
    const ah = cfltk.Fl_Box_new(10, 10, 420, 30, "Hangar v1.0");
    cfltk.Fl_Box_set_color(ah, app.pal.bg); cfltk.Fl_Box_set_label_font(ah, 1); cfltk.Fl_Box_set_label_color(ah, app.pal.header);
    cfltk.Fl_Box_set_label_size(ah, 18);
    const ad1 = cfltk.Fl_Box_new(10, 45, 420, 20, "Lightweight QEMU/KVM Virtual Machine Manager");
    cfltk.Fl_Box_set_color(ad1, app.pal.bg); cfltk.Fl_Box_set_label_color(ad1, app.pal.text_dim);
    const ad2 = cfltk.Fl_Box_new(10, 68, 420, 20, "Built with Zig 0.16 + FLTK 1.4");
    cfltk.Fl_Box_set_color(ad2, app.pal.bg); cfltk.Fl_Box_set_label_color(ad2, app.pal.text_dim);
    const ad3 = cfltk.Fl_Box_new(10, 95, 420, 55, "Features: VM management, VNC/SPICE display, serial console,\nsnapshots, OVF export, AutoProtect, virtual networks");
    cfltk.Fl_Box_set_color(ad3, app.pal.bg); cfltk.Fl_Box_set_label_color(ad3, app.pal.text_dim);
    // Keyboard shortcuts header
    const ksh = cfltk.Fl_Box_new(10, 158, 420, 22, "Keyboard Shortcuts");
    cfltk.Fl_Box_set_color(ksh, app.pal.bg); cfltk.Fl_Box_set_label_font(ksh, 1); cfltk.Fl_Box_set_label_color(ksh, app.pal.header);
    cfltk.Fl_Box_set_label_size(ksh, 13);
    const ks_sep = cfltk.Fl_Box_new(10, 182, 420, 2, "");
    cfltk.Fl_Box_set_box(ks_sep, 1); cfltk.Fl_Box_set_color(ks_sep, app.pal.border);
    // Two-column shortcuts layout: label col1 (x=10), key col1 (x=130), label col2 (x=230), key col2 (x=350)
    const ks_text =
        \\Ctrl+N      New VM              Ctrl+Shift+N  Clone VM
        \\F2          Settings            Ctrl+W        Home (deselect)
        \\Ctrl+Q      Quit                DEL           Delete VM
        \\Ctrl+I      Import VM           F11           Full Screen
        \\Ctrl+F      Search / Filter     F5            Refresh
    ;
    const ks_box = cfltk.Fl_Box_new(10, 190, 420, 100, ks_text);
    cfltk.Fl_Box_set_color(ks_box, app.pal.bg); cfltk.Fl_Box_set_label_font(ks_box, 4); // FL_COURIER
    cfltk.Fl_Box_set_label_color(ks_box, app.pal.text_dim);
    cfltk.Fl_Box_set_label_size(ks_box, 12);
    const ad4 = cfltk.Fl_Box_new(10, 300, 420, 20, "Pure modules: 586 tests passing");
    cfltk.Fl_Box_set_color(ad4, app.pal.bg); cfltk.Fl_Box_set_label_color(ad4, app.pal.text_dim);
    const web_hint = cfltk.Fl_Box_new(10, 324, 420, 20, "Web UI: http://localhost:9080  |  docs: docs/README.md");
    cfltk.Fl_Box_set_color(web_hint, app.pal.bg); cfltk.Fl_Box_set_label_color(web_hint, app.pal.text_dim);
    const cb = cfltk.Fl_Button_new(350, 370, 80, 30, "OK");
    cfltk.Fl_Button_set_color(cb, app.pal.accent); cfltk.Fl_Button_set_label_color(cb, app.pal.accent_text);
    const OK = struct { fn g(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
        if (d) |dd| cfltk.Fl_Window_hide(@ptrCast(@alignCast(dd)));
    }};
    cfltk.Fl_Button_set_callback(cb, &OK.g, @ptrCast(@alignCast(dlg)));
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
}

pub fn shortcutsDialog() void {
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 440, 2), @divTrunc(cfltk.Fl_h() - 380, 2), 440, 380, "Keyboard Shortcuts");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 440, 380, 0, 0);
    const title = cfltk.Fl_Box_new(10, 10, 420, 26, "Keyboard Shortcuts");
    cfltk.Fl_Box_set_color(title, app.pal.bg);
    cfltk.Fl_Box_set_label_font(title, 1);
    cfltk.Fl_Box_set_label_size(title, 16);
    cfltk.Fl_Box_set_label_color(title, app.pal.header);
    const sep = cfltk.Fl_Box_new(10, 40, 420, 2, "");
    cfltk.Fl_Box_set_box(sep, 1);
    cfltk.Fl_Box_set_color(sep, app.pal.border);
    const ks_text =
        \\\u2191\u2193         Navigate VM list       Del         Delete VM
        \\Enter      Power On/Off            Esc         Close / Deselect
        \\F2         Edit VM settings        F5          Refresh VM list
        \\F11        Full Screen toggle
        \\Ctrl+N     New VM                  Ctrl+W      Home (deselect)
        \\Ctrl+Q     Quit Hangar             Ctrl+I      Import VM
        \\Ctrl+E     Edit VM settings        Ctrl+S      Suspend VM
        \\Ctrl+P     Preferences             Ctrl+F      Focus search
        \\Ctrl+Z     Undo delete VM          Ctrl+Sh+N   Clone VM
        \\Alt+\u2191\u2193      Reorder VM in list
    ;
    const ks_box = cfltk.Fl_Box_new(10, 50, 420, 250, ks_text);
    cfltk.Fl_Box_set_color(ks_box, app.pal.bg);
    cfltk.Fl_Box_set_label_font(ks_box, 4); // FL_COURIER
    cfltk.Fl_Box_set_label_color(ks_box, app.pal.text_dim);
    cfltk.Fl_Box_set_label_size(ks_box, 12);
    const cb = cfltk.Fl_Button_new(350, 330, 80, 30, "Close");
    cfltk.Fl_Button_set_color(cb, app.pal.accent);
    cfltk.Fl_Button_set_label_color(cb, app.pal.accent_text);
    const CLOSE = struct {
        fn g(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            if (d) |dd| cfltk.Fl_Window_hide(@ptrCast(@alignCast(dd)));
        }
    };
    cfltk.Fl_Button_set_callback(cb, &CLOSE.g, @ptrCast(@alignCast(dlg)));
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
}

pub fn prefsDialog() void {
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 420, 2), @divTrunc(cfltk.Fl_h() - 350, 2), 420, 350, "Preferences");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 420, 350, 0, 0);

    const ph = cfltk.Fl_Box_new(10, 10, 400, 22, "Defaults for new VMs");
    cfltk.Fl_Box_set_color(ph, app.pal.bg);
    cfltk.Fl_Box_set_label_font(ph, 1); cfltk.Fl_Box_set_label_color(ph, app.pal.header);
    cfltk.Fl_Box_set_label_size(ph, 14);

    const pl0 = cfltk.Fl_Box_new(10, 40, 130, 20, "Default Memory (MB):");
    cfltk.Fl_Box_set_color(pl0, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pl0, 1); cfltk.Fl_Box_set_label_color(pl0, app.pal.text_dim);
    var mb: [16]u8 = undefined;
    const mem_input = cfltk.Fl_Input_new(140, 38, 270, 24, "");
    app.themeInput(@ptrCast(mem_input));
    _ = cfltk.Fl_Input_set_value(mem_input, std.fmt.bufPrintZ(&mb, "{d}", .{app.prefs.default_memory_mb}) catch "2048");
    const pl1 = cfltk.Fl_Box_new(10, 70, 130, 20, "Default CPU Cores:");
    cfltk.Fl_Box_set_color(pl1, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pl1, 1); cfltk.Fl_Box_set_label_color(pl1, app.pal.text_dim);
    var cb2: [16]u8 = undefined;
    const cpu_input = cfltk.Fl_Input_new(140, 68, 270, 24, "");
    app.themeInput(@ptrCast(cpu_input));
    _ = cfltk.Fl_Input_set_value(cpu_input, std.fmt.bufPrintZ(&cb2, "{d}", .{app.prefs.default_cpu_cores}) catch "2");

    const pl2 = cfltk.Fl_Box_new(10, 100, 130, 20, "AutoProtect:");
    cfltk.Fl_Box_set_color(pl2, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pl2, 1); cfltk.Fl_Box_set_label_color(pl2, app.pal.text_dim);
    const ap_check = cfltk.Fl_Check_Button_new(140, 98, 20, 24, "");
    app.themeCheckButton(@ptrCast(ap_check));
    cfltk.Fl_Check_Button_set_value(ap_check, if (app.prefs.autoprotect_enabled_default) 1 else 0);

    const pl3 = cfltk.Fl_Box_new(10, 130, 130, 20, "Snapshot Interval (min):");
    cfltk.Fl_Box_set_color(pl3, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pl3, 1); cfltk.Fl_Box_set_label_color(pl3, app.pal.text_dim);
    var ab: [16]u8 = undefined;
    const ap_int_input = cfltk.Fl_Input_new(140, 128, 270, 24, "");
    app.themeInput(@ptrCast(ap_int_input));
    _ = cfltk.Fl_Input_set_value(ap_int_input, std.fmt.bufPrintZ(&ab, "{d}", .{app.prefs.autoprotect_interval_min_default}) catch "60");

    const pl4 = cfltk.Fl_Box_new(10, 160, 130, 20, "Max Snapshots:");
    cfltk.Fl_Box_set_color(pl4, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pl4, 1); cfltk.Fl_Box_set_label_color(pl4, app.pal.text_dim);
    var ac: [16]u8 = undefined;
    const ap_max_input = cfltk.Fl_Input_new(140, 158, 270, 24, "");
    app.themeInput(@ptrCast(ap_max_input));
    _ = cfltk.Fl_Input_set_value(ap_max_input, std.fmt.bufPrintZ(&ac, "{d}", .{app.prefs.autoprotect_max_default}) catch "10");

    const pd0 = cfltk.Fl_Box_new(10, 190, 130, 20, "Default VM Directory:");
    cfltk.Fl_Box_set_color(pd0, app.pal.bg);
    cfltk.Fl_Box_set_label_font(pd0, 1); cfltk.Fl_Box_set_label_color(pd0, app.pal.text_dim);
    const dir_input = cfltk.Fl_Input_new(140, 188, 270, 24, "");
    app.themeInput(@ptrCast(dir_input));
    if (app.prefs.default_vm_dir_len > 0) {
        _ = cfltk.Fl_Input_set_value(dir_input, app.prefs.default_vm_dir_buf[0..app.prefs.default_vm_dir_len :0]);
    }

    const th = cfltk.Fl_Box_new(10, 225, 130, 20, "Theme:");
    cfltk.Fl_Box_set_color(th, app.pal.bg);
    cfltk.Fl_Box_set_label_font(th, 1); cfltk.Fl_Box_set_label_color(th, app.pal.text_dim);
    const theme_choice = cfltk.Fl_Choice_new(140, 222, 270, 24, "");
    app.themeChoice(@ptrCast(theme_choice));
    _ = cfltk.Fl_Choice_add_choice(theme_choice, "System");
    _ = cfltk.Fl_Choice_add_choice(theme_choice, "Light");
    _ = cfltk.Fl_Choice_add_choice(theme_choice, "Dark");
    const tval: i32 = switch (app.current_theme) { .system => 0, .light => 1, .dark => 2 };
    _ = cfltk.Fl_Choice_set_value(theme_choice, tval);

    const PData = struct {
        mem: ?*cfltk.Fl_Input,
        cpu: ?*cfltk.Fl_Input,
        ap_check: ?*cfltk.Fl_Check_Button,
        ap_int: ?*cfltk.Fl_Input,
        ap_max: ?*cfltk.Fl_Input,
        dir: ?*cfltk.Fl_Input,
        theme: ?*cfltk.Fl_Choice,
        dlg: ?*cfltk.Fl_Window,
    };
    var pd = PData{
        .mem = @ptrCast(mem_input),
        .cpu = @ptrCast(cpu_input),
        .ap_check = @ptrCast(ap_check),
        .ap_int = @ptrCast(ap_int_input),
        .ap_max = @ptrCast(ap_max_input),
        .dir = @ptrCast(dir_input),
        .theme = @ptrCast(theme_choice),
        .dlg = @ptrCast(dlg),
    };

    const SaveCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const pp: *PData = @ptrCast(@alignCast(data orelse return));
            if (pp.mem) |mi| {
                const val = std.mem.span(cfltk.Fl_Input_value(mi));
                if (val.len > 0) {
                    app.prefs.default_memory_mb = std.fmt.parseInt(u32, val, 10) catch {
                        app.setStatusErr("Invalid value for default memory — must be a number");
                        return;
                    };
                }
            }
            if (pp.cpu) |ci| {
                const val = std.mem.span(cfltk.Fl_Input_value(ci));
                if (val.len > 0) {
                    app.prefs.default_cpu_cores = std.fmt.parseInt(u32, val, 10) catch {
                        app.setStatusErr("Invalid value for default CPU cores — must be a number");
                        return;
                    };
                }
            }
            if (pp.ap_check) |apc| {
                app.prefs.autoprotect_enabled_default = cfltk.Fl_Check_Button_value(apc) != 0;
            }
            if (pp.ap_int) |ai| {
                const val = std.mem.span(cfltk.Fl_Input_value(ai));
                if (val.len > 0) {
                    app.prefs.autoprotect_interval_min_default = std.fmt.parseInt(u32, val, 10) catch {
                        app.setStatusErr("Invalid value for autoprotect interval — must be a number");
                        return;
                    };
                }
            }
            if (pp.ap_max) |am| {
                const val = std.mem.span(cfltk.Fl_Input_value(am));
                if (val.len > 0) {
                    app.prefs.autoprotect_max_default = std.fmt.parseInt(u32, val, 10) catch {
                        app.setStatusErr("Invalid value for autoprotect max — must be a number");
                        return;
                    };
                }
            }
            if (pp.dir) |di| {
                const val = std.mem.span(cfltk.Fl_Input_value(di));
                const n = @min(val.len, app.prefs.default_vm_dir_buf.len - 1);
                @memcpy(app.prefs.default_vm_dir_buf[0..n], val[0..n]);
                app.prefs.default_vm_dir_buf[n] = 0;
                app.prefs.default_vm_dir_len = @intCast(n);
            }
            if (pp.theme) |tc| {
                const v: i32 = cfltk.Fl_Choice_value(tc);
                const new_theme: vm.Theme = switch (v) { 2 => .dark, 1 => .light, else => .system };
                app.prefs.theme = new_theme;
                app.applyTheme(new_theme);
            }
            persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
            if (pp.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    const save_btn = cfltk.Fl_Button_new(230, 310, 80, 30, "Save");
    cfltk.Fl_Button_set_color(save_btn, app.pal.accent); cfltk.Fl_Button_set_label_color(save_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_callback(save_btn, &SaveCB.go, &pd);

    const CancelCB = struct {
        fn go(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void {
            const pp: *PData = @ptrCast(@alignCast(data orelse return));
            if (pp.dlg) |d| cfltk.Fl_Window_hide(d);
        }
    };
    const cancel_btn = cfltk.Fl_Button_new(320, 310, 90, 30, "Cancel");
    cfltk.Fl_Button_set_color(cancel_btn, app.pal.gray_btn); cfltk.Fl_Button_set_label_color(cancel_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_callback(cancel_btn, &CancelCB.go, &pd);

    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
}

// Find the first unused third octet in 192.168.{x}.0/24 (x in 100..254)
// by scanning existing networks' subnet fields. Prevents collisions after
// deletes/adds. If all 155 slots are taken, falls back to 240.
fn firstUnusedSubnet(ns: *const vnet.NetworkSet) u8 {
    var used: [155]bool = [_]bool{false} ** 155;
    for (ns.nets[0..ns.count]) |*n| {
        const s = n.getSubnetSlice();
        // Expect "192.168.N.0" — extract the third octet.
        if (s.len >= 11 and std.mem.startsWith(u8, s, "192.168.")) {
            const rest = s[8..];
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
            const octet_str = rest[0..dot];
            if (std.fmt.parseInt(u16, octet_str, 10)) |oct| {
                if (oct >= 100 and oct < 255) {
                    used[oct - 100] = true;
                }
            } else |_| {}
        }
    }
    var oct: u16 = 100;
    while (oct < 255) : (oct += 1) {
        if (!used[oct - 100]) return @intCast(oct);
    }
    return 240; // all full — fallback
}

pub fn vnetDialog() void {
    var net_set = vnet.load();
    if (net_set.count == 0) net_set = vnet.NetworkSet.defaults();

    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 580, 2), @divTrunc(cfltk.Fl_h() - 420, 2), 580, 420, "Virtual Network Editor");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 580, 420, 0, 0);
    const vh = cfltk.Fl_Box_new(10, 10, 560, 20, "Virtual Network switches (VMnet):");
    cfltk.Fl_Box_set_color(vh, app.pal.bg);
    cfltk.Fl_Box_set_label_font(vh, 1); cfltk.Fl_Box_set_label_color(vh, app.pal.header);
    const net_list = cfltk.Fl_Browser_new(10, 35, 560, 260, "");
    app.themeBrowser(@ptrCast(net_list));
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
            vnet.save(vdp.ns) catch {
                app.setStatus("Failed to save virtual network configuration");
                return;
            };
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
            // Find the first unused 192.168.{x}.0/24 subnet to avoid
            // collisions when networks are deleted and re-added.
            const third_octet = firstUnusedSubnet(vdp.ns);
            var subnet_buf: [16]u8 = undefined;
            const subnet = std.fmt.bufPrint(&subnet_buf, "192.168.{d}.0", .{third_octet}) catch "192.168.240.0";
            var dstart_buf: [16]u8 = undefined;
            const dstart = std.fmt.bufPrint(&dstart_buf, "192.168.{d}.128", .{third_octet}) catch "192.168.240.128";
            var dend_buf: [16]u8 = undefined;
            const dend = std.fmt.bufPrint(&dend_buf, "192.168.{d}.254", .{third_octet}) catch "192.168.240.254";
            _ = vdp.ns.add(name, .host_only, subnet, "255.255.255.0", true, dstart, dend, "");
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
    cfltk.Fl_Button_set_color(save_btn, app.pal.accent); cfltk.Fl_Button_set_label_color(save_btn, app.pal.accent_text);
    const defaults_btn = cfltk.Fl_Button_new(110, 305, 100, 30, "Use Defaults");
    cfltk.Fl_Button_set_color(defaults_btn, app.pal.gray_btn); cfltk.Fl_Button_set_label_color(defaults_btn, app.pal.accent_text);
    const add_btn = cfltk.Fl_Button_new(220, 305, 60, 30, "Add");
    cfltk.Fl_Button_set_color(add_btn, app.pal.success); cfltk.Fl_Button_set_label_color(add_btn, app.pal.accent_text);
    const remove_btn = cfltk.Fl_Button_new(285, 305, 70, 30, "Remove");
    cfltk.Fl_Button_set_color(remove_btn, app.pal.danger); cfltk.Fl_Button_set_label_color(remove_btn, app.pal.accent_text);
    const close_btn = cfltk.Fl_Button_new(480, 375, 90, 30, "Close");
    cfltk.Fl_Button_set_color(close_btn, app.pal.gray_btn); cfltk.Fl_Button_set_label_color(close_btn, app.pal.accent_text);
    cfltk.Fl_Button_set_callback(save_btn, &CloseCB.go, &vd);
    cfltk.Fl_Button_set_callback(defaults_btn, &DefaultsCB.go, &vd);
    cfltk.Fl_Button_set_callback(add_btn, &AddCB.go, &vd);
    cfltk.Fl_Button_set_callback(remove_btn, &RemoveCB.go, &vd);
    cfltk.Fl_Button_set_callback(close_btn, &CloseCB.go, &vd);
    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
}

pub fn exportOvfDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    if (ovf_conv_pid != -1) { app.setStatus("A disk conversion is already in progress — please wait"); return; }
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

    var vmdk2_name_buf: [256]u8 = undefined;
    var vmdk2_href: []const u8 = "";
    var disk2_bytes: u64 = 0;
    if (v.hasDisk2()) {
        disk2_bytes = @as(u64, v.disk2_size_gb) * 1024 * 1024 * 1024;
        vmdk2_href = std.fmt.bufPrint(&vmdk2_name_buf, "{s}-disk2.vmdk", .{base}) catch {
            app.setStatus("Path too long for OVF export (disk2)");
            return;
        };
    }

    const spec = ovf.Spec{
        .name = v.getNameSlice(),
        .cpu_cores = v.cpu_cores,
        .memory_mb = v.memory_mb,
        .disk_capacity_bytes = disk_bytes,
        .vmdk_href = vmdk_href,
        .vmdk_size_bytes = disk_bytes,
        .has_network = v.nics[0].mode != .none,
        .disk2_href = vmdk2_href,
        .disk2_capacity_bytes = disk2_bytes,
        .disk2_size_bytes = disk2_bytes,
    };

    var ovf_buf: [ovf.max_descriptor_len]u8 = undefined;
    const xml = ovf.buildDescriptor(spec, &ovf_buf) catch {
        app.setStatus("Failed to generate OVF descriptor");
        return;
    };

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
        // NOTE: vmdk_full is freed by checkOvfConversion on completion.

        if (app.getVmmHandle(idx)) |h| {
            app.g_vmm.convertDiskFn(h, disk_path, vmdk_full, @intFromEnum(v.disk_format), @intFromEnum(vm.DiskFormat.vmdk), std.heap.page_allocator) catch {
                std.heap.page_allocator.free(vmdk_full);
                app.setStatus("OVF saved, but VMDK conversion failed (qemu-img missing?)");
                return;
            };
            std.heap.page_allocator.free(vmdk_full);
            if (v.hasDisk2()) {
                const disk2_path = v.getDisk2PathSlice();
                const vmdk2_full = std.heap.page_allocator.dupeZ(u8, vmdk2_href) catch {
                    app.setStatus("OVF saved, but disk2 VMDK path buffer allocation failed");
                    return;
                };
                app.g_vmm.convertDiskFn(h, disk2_path, vmdk2_full, @intFromEnum(v.disk2_format), @intFromEnum(vm.DiskFormat.vmdk), std.heap.page_allocator) catch {
                    std.heap.page_allocator.free(vmdk2_full);
                    app.setStatus("OVF saved, but disk2 VMDK conversion failed");
                    return;
                };
                std.heap.page_allocator.free(vmdk2_full);
            }
            app.setStatus("OVF package exported successfully");
        } else {
            // Convert disk2 synchronously if present (async machinery only tracks one pid).
            if (v.hasDisk2()) {
                qemu.convertDiskImage(v.getDisk2PathSlice(), v.disk2_format, vmdk2_href, .vmdk, std.heap.page_allocator) catch {
                    app.setStatus("OVF saved, but disk2 VMDK conversion failed");
                };
            }
            // Async conversion — returns immediately so UI stays responsive.
            ovf_conv_pid = qemu.convertDiskImageNoWait(disk_path, v.disk_format, vmdk_full, .vmdk, std.heap.page_allocator) catch {
                std.heap.page_allocator.free(vmdk_full);
                app.setStatus("OVF saved, but VMDK conversion failed to start");
                return;
            };
            ovf_conv_vmdk = vmdk_full;
            _ = cfltk.Fl_add_timeout(0.5, checkOvfConversion, null);
            app.setStatus("Converting disk image for OVF export... will notify when done");
        }
    } else {
        app.setStatus("OVF package exported successfully");
    }
}

// ── Async OVF conversion state ──────────────────────────────────────

var ovf_conv_pid: std.c.pid_t = -1;
var ovf_conv_vmdk: ?[*:0]u8 = null;

fn checkOvfConversion(_: ?*anyopaque) callconv(.c) void {
    if (ovf_conv_pid == -1) return;

    const result = qemu.tryReapChild(ovf_conv_pid);
    if (result == null) {
        // Still running — poll again in 0.5 s.
        _ = cfltk.Fl_repeat_timeout(0.5, checkOvfConversion, null);
        return;
    }

    if (ovf_conv_vmdk) |p| {
        std.heap.page_allocator.free(std.mem.span(p));
        ovf_conv_vmdk = null;
    }

    if (result.? == true) {
        app.setStatus("OVF package exported successfully");
    } else {
        app.setStatus("OVF saved, but VMDK conversion failed");
    }

    ovf_conv_pid = -1;
}

pub fn remoteConnectDialog() void {
    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 420, 2), @divTrunc(cfltk.Fl_h() - 220, 2), 420, 220, "Connect to Remote Server");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 420, 220, 0, 0);
    const rl0 = cfltk.Fl_Box_new(10, 10, 400, 20, "Server URL: unix:///path | http://host:port | shm:///name");
    cfltk.Fl_Box_set_color(rl0, app.pal.bg);
    cfltk.Fl_Box_set_label_font(rl0, 1); cfltk.Fl_Box_set_label_color(rl0, app.pal.text_dim);
    const url_input = cfltk.Fl_Input_new(10, 35, 400, 24, "");
    app.themeInput(@ptrCast(url_input));
    cfltk.Fl_Input_set_text_font(url_input, 4); // monospace URL
    const rl1 = cfltk.Fl_Box_new(10, 70, 400, 20, "Auth token (optional):");
    cfltk.Fl_Box_set_color(rl1, app.pal.bg);
    cfltk.Fl_Box_set_label_font(rl1, 1); cfltk.Fl_Box_set_label_color(rl1, app.pal.text_dim);
    const token_input = cfltk.Fl_Input_new(10, 95, 400, 24, "");
    app.themeInput(@ptrCast(token_input));
    cfltk.Fl_Input_set_text_font(token_input, 4); // monospace token
    const connect_btn = cfltk.Fl_Button_new(170, 175, 110, 30, "Connect");
    cfltk.Fl_Button_set_color(connect_btn, app.pal.accent); cfltk.Fl_Button_set_label_color(connect_btn, app.pal.accent_text);
    const local_btn = cfltk.Fl_Button_new(290, 175, 110, 30, "Local Mode");
    cfltk.Fl_Button_set_color(local_btn, app.pal.gray_btn); cfltk.Fl_Button_set_label_color(local_btn, app.pal.accent_text);
    const status_label = cfltk.Fl_Box_new(10, 135, 400, 20, "Currently: Local Mode");
    cfltk.Fl_Box_set_color(status_label, app.pal.bg);
    cfltk.Fl_Box_set_label_color(status_label, app.pal.text_dim);

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
                    cfltk.Fl_Box_set_label_color(sb2, app.pal.accent);
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
                cfltk.Fl_Box_set_label_color(s, app.pal.text_dim);
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
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
}

pub fn migrateDialog() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    const v = &app.vms[idx];

    const dlg = cfltk.Fl_Window_new(@divTrunc(cfltk.Fl_w() - 460, 2), @divTrunc(cfltk.Fl_h() - 240, 2), 460, 240, "Live Migrate VM");
    cfltk.Fl_Window_make_modal(dlg, 1);
    cfltk.Fl_Window_set_color(dlg, app.pal.bg);
    cfltk.Fl_Window_size_range(dlg, 460, 240, 0, 0);

    const vm_name = cfltk.Fl_Box_new(10, 10, 440, 20, "");
    {
        var buf: [512]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "Migrating: {s}", .{v.getNameSlice()}) catch "Migrating VM";
        cfltk.Fl_Box_set_label(vm_name, label.ptr);
    }
    cfltk.Fl_Box_set_color(vm_name, app.pal.bg);
    cfltk.Fl_Box_set_label_font(vm_name, 1);
    cfltk.Fl_Box_set_label_color(vm_name, app.pal.header);

    const uri_label = cfltk.Fl_Box_new(10, 40, 440, 20, "Destination URI (e.g. tcp:host:4444, unix:/path/socket, exec:cmd):");
    cfltk.Fl_Box_set_color(uri_label, app.pal.bg);
    cfltk.Fl_Box_set_label_font(uri_label, 1);
    cfltk.Fl_Box_set_label_color(uri_label, app.pal.text_dim);

    const uri_input = cfltk.Fl_Input_new(10, 65, 440, 24, "");
    app.themeInput(@ptrCast(uri_input));
    cfltk.Fl_Input_set_text_font(uri_input, 4);

    const migrate_btn = cfltk.Fl_Button_new(100, 195, 110, 30, "Migrate");
    cfltk.Fl_Button_set_color(migrate_btn, app.pal.accent);
    cfltk.Fl_Button_set_label_color(migrate_btn, app.pal.accent_text);

    const cancel_btn = cfltk.Fl_Button_new(250, 195, 110, 30, "Cancel Migration");
    cfltk.Fl_Button_set_color(cancel_btn, app.pal.danger);
    cfltk.Fl_Button_set_label_color(cancel_btn, app.pal.accent_text);

    const status_label = cfltk.Fl_Box_new(10, 155, 440, 20, "Enter a destination URI and click Migrate.");
    cfltk.Fl_Box_set_color(status_label, app.pal.bg);
    cfltk.Fl_Box_set_label_color(status_label, app.pal.text_dim);

    const MD = struct {
        uri: ?*cfltk.Fl_Input,
        status: ?*cfltk.Fl_Box,
        dlg: ?*cfltk.Fl_Window,
        idx: usize,
        qc: qmp.QmpClient,
        done: bool,
    };
    var md = MD{
        .uri = @ptrCast(uri_input),
        .status = @ptrCast(status_label),
        .dlg = @ptrCast(dlg),
        .idx = idx,
        .qc = qmp.QmpClient{},
        .done = false,
    };

    const MigrateFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const mdp: *MD = @ptrCast(@alignCast(d orelse return));
            if (mdp.uri) |u| {
                const dest = std.mem.span(cfltk.Fl_Input_value(u));
                if (dest.len == 0) {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: enter a destination URI");
                    return;
                }
                // Validate URI: reject empty, exec: (arbitrary command execution), and
                // require a recognised transport prefix.
                const valid_prefixes = [_][]const u8{ "tcp:", "unix:", "file:", "fd:" };
                var prefix_ok = false;
                for (valid_prefixes) |pfx| {
                    if (std.mem.startsWith(u8, dest, pfx)) {
                        prefix_ok = true;
                        break;
                    }
                }
                if (!prefix_ok) {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: invalid URI — must start with tcp:, unix:, file:, or fd:");
                    return;
                }
                // Reject path traversal in file:/unix: paths.
                if (std.mem.indexOf(u8, dest, "..") != null) {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: path traversal (..) not allowed in URI");
                    return;
                }

                // Connect QMP
                var sock_buf: [256]u8 = undefined;
                const sock = qmp.socketPath(app.vms[mdp.idx].getNameSlice(), &sock_buf) orelse {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: failed to build QMP socket path");
                    return;
                };
                mdp.qc.connect(sock) catch {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: failed to connect QMP — VM may not be running");
                    return;
                };

                // Start live migration
                mdp.qc.liveMigrate(dest) catch {
                    if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: migration command failed");
                    mdp.qc.disconnect();
                    return;
                };

                if (mdp.status) |sl| {
                    cfltk.Fl_Box_set_label(sl, "Migration started — polling status...");
                    cfltk.Fl_Box_set_label_color(sl, app.pal.accent);
                }

                // Poll migration status every 500ms (non-blocking via Fl::wait)
                var timeout: usize = 600; // 5 minutes max (600 * 500ms)
                while (!mdp.done and timeout > 0) : (timeout -= 1) {
                    _ = cfltk.Fl_wait_for(0.5);
                    var out_buf: [64]u8 = undefined;
                    const status = mdp.qc.queryMigrateStatus(&out_buf) catch break;
                    if (std.mem.eql(u8, status, "completed")) {
                        if (mdp.status) |sl| {
                            cfltk.Fl_Box_set_label(sl, "Migration completed successfully.");
                            cfltk.Fl_Box_set_label_color(sl, app.pal.success);
                        }
                        mdp.done = true;
                    } else if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) {
                        if (mdp.status) |sl| {
                            var buf: [128]u8 = undefined;
                            const lbl = std.fmt.bufPrintZ(&buf, "Migration {s}.", .{status}) catch "Migration finished.";
                            cfltk.Fl_Box_set_label(sl, lbl.ptr);
                            cfltk.Fl_Box_set_label_color(sl, app.pal.danger);
                        }
                        mdp.done = true;
                    } else {
                        if (mdp.status) |sl| {
                            var buf: [128]u8 = undefined;
                            const lbl = std.fmt.bufPrintZ(&buf, "Migration status: {s}...", .{status}) catch "Migrating...";
                            cfltk.Fl_Box_set_label(sl, lbl.ptr);
                        }
                    }
                }
                if (!mdp.done) {
                    if (mdp.status) |sl| {
                        cfltk.Fl_Box_set_label(sl, "Migration timed out.");
                        cfltk.Fl_Box_set_label_color(sl, app.pal.danger);
                    }
                }
                mdp.qc.disconnect();
            }
        }
    };

    const CancelFn = struct {
        fn go(_: ?*cfltk.Fl_Widget, d: ?*anyopaque) callconv(.c) void {
            const mdp: *MD = @ptrCast(@alignCast(d orelse return));
            mdp.done = true;
            // Disconnect any in-progress connection before reconnecting.
            mdp.qc.disconnect();
            var sock_buf: [256]u8 = undefined;
            const sock = qmp.socketPath(app.vms[mdp.idx].getNameSlice(), &sock_buf) orelse return;
            mdp.qc.connect(sock) catch {
                if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: failed to connect QMP to cancel");
                return;
            };
            mdp.qc.cancelMigrate() catch {
                if (mdp.status) |sl| cfltk.Fl_Box_set_label(sl, "Error: cancel command failed");
                mdp.qc.disconnect();
                return;
            };
            if (mdp.status) |sl| {
                cfltk.Fl_Box_set_label(sl, "Migration cancelled.");
                cfltk.Fl_Box_set_label_color(sl, app.pal.amber);
            }
            mdp.qc.disconnect();
        }
    };

    cfltk.Fl_Button_set_callback(migrate_btn, &MigrateFn.go, &md);
    cfltk.Fl_Button_set_callback(cancel_btn, &CancelFn.go, &md);

    cfltk.Fl_Window_end(dlg);
    cfltk.Fl_Window_show(dlg);
    app.modal_active = true;
    while (cfltk.Fl_Window_shown(dlg) != 0) { _ = cfltk.Fl_wait(); }
    app.modal_active = false;
    cfltk.Fl_delete_widget(@ptrCast(dlg));
    md.qc.disconnect();
}

pub fn toggleFavorite() void {
    const idx = app.selected_idx orelse return;
    if (idx >= app.vm_count) return;
    app.vms[idx].favorite = !app.vms[idx].favorite;
    app.refreshBrowser();
    persist.save(&app.vms, app.vm_count, app.prefs) catch { app.setStatus("Failed to save VM configuration"); };
}

// ── Tests for firstUnusedSubnet ──────────────────────────────────────

test "firstUnusedSubnet: empty set returns 100" {
    const ns = vnet.NetworkSet{};
    try std.testing.expectEqual(@as(u8, 100), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: single used octet 100 -> 101" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.100.0", "255.255.255.0", false, "", "", "");
    try std.testing.expectEqual(@as(u8, 101), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: contiguous block -> first free after gap" {
    var ns = vnet.NetworkSet{};
    for (100..105) |oct| {
        var subnet: [16]u8 = undefined;
        const s = try std.fmt.bufPrintZ(&subnet, "192.168.{d}.0", .{oct});
        _ = ns.add("VMnet", .nat, s, "255.255.255.0", false, "", "", "");
    }
    try std.testing.expectEqual(@as(u8, 105), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: non-192.168 subnets are ignored" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.100.0", "255.255.255.0", false, "", "", "");
    _ = ns.add("VMnet1", .bridged, "10.0.0.0", "255.255.255.0", false, "", "", "");
    _ = ns.add("VMnet2", .nat, "172.16.0.0", "255.255.0.0", false, "", "", "");
    // Only 192.168.100.0 counts; 101 should be free
    try std.testing.expectEqual(@as(u8, 101), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: octet below 100 is ignored" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.50.0", "255.255.255.0", false, "", "", "");
    // 50 is below 100, so it doesn't count; 100 is still first free
    try std.testing.expectEqual(@as(u8, 100), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: octet boundary (octet >= 255 ignored)" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.255.0", "255.255.255.0", false, "", "", "");
    // 255 is not < 255, so it doesn't count; 100 is first free
    try std.testing.expectEqual(@as(u8, 100), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: malformed subnet does not block" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.a", "255.255.255.0", false, "", "", "");
    // "a" is not a valid uint, so parse fail -> no block
    try std.testing.expectEqual(@as(u8, 100), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: short subnet (< 11 chars) is ignored" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.1", "255.255.255.0", false, "", "", "");
    // "192.168.1" has len 9 < 11, so it's skipped
    try std.testing.expectEqual(@as(u8, 100), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: max networks filled -> returns next unused" {
    var ns = vnet.NetworkSet{};
    // Fill all 20 available slots with contiguous 100..119
    for (100..120) |oct| {
        var subnet: [16]u8 = undefined;
        const s = try std.fmt.bufPrintZ(&subnet, "192.168.{d}.0", .{oct});
        _ = ns.add("VMnet", .nat, s, "255.255.255.0", false, "", "", "");
    }
    try std.testing.expectEqual(@as(u8, 120), firstUnusedSubnet(&ns));
}

test "firstUnusedSubnet: fallback to 240 is unreachable (kept as safety) — function exists" {
    // The 240 fallback can't be hit with MAX_VNETS=20, but the code
    // path is present. Verify the function still compiles and runs.
    const ns = vnet.NetworkSet{};
    _ = firstUnusedSubnet(&ns); // just ensure it doesn't crash
}

test "firstUnusedSubnet: sparse allocation -> first gap found" {
    var ns = vnet.NetworkSet{};
    _ = ns.add("VMnet0", .nat, "192.168.100.0", "255.255.255.0", false, "", "", "");
    _ = ns.add("VMnet1", .nat, "192.168.102.0", "255.255.255.0", false, "", "", "");
    _ = ns.add("VMnet2", .nat, "192.168.105.0", "255.255.255.0", false, "", "", "");
    // 100 used, 101 free, 102 used -> first free is 101
    try std.testing.expectEqual(@as(u8, 101), firstUnusedSubnet(&ns));
}

test "fuzz: firstUnusedSubnet never panics and returns in [100,240]" {
    var prng = std.Random.DefaultPrng.init(0x5AB_D00);
    const rnd = prng.random();
    var oct_buf: [16]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        var ns = vnet.NetworkSet{};
        const count = rnd.uintLessThan(usize, 25);
        for (0..count) |_| {
            const oct = rnd.intRangeAtMost(u8, 1, 254);
            const subnet = std.fmt.bufPrintZ(&oct_buf, "192.168.{d}.0", .{oct}) catch continue;
            const vtype: vnet.VNetType = if (rnd.boolean()) .nat else if (rnd.boolean()) .bridged else .host_only;
            _ = ns.add("VMnet", vtype, subnet, "255.255.255.0", rnd.boolean(), "", "", "");
        }
        // Also add some non-192.168 subnets sometimes
        if (rnd.boolean()) {
            _ = ns.add("VMnetX", .nat, "10.0.0.0", "255.255.255.0", false, "", "", "");
        }
        if (rnd.boolean()) {
            _ = ns.add("VMnetY", .nat, "172.16.0.0", "255.255.0.0", false, "", "", "");
        }
        // Add a malformed subnet occasionally
        if (rnd.uintLessThan(u8, 10) < 2) {
            _ = ns.add("VMnetB", .nat, "bad", "255.255.255.0", false, "", "", "");
        }
        const result = firstUnusedSubnet(&ns);
        try std.testing.expect(result >= 100);
        try std.testing.expect(result <= 240);
    }
}
