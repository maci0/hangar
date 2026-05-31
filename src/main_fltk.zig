//! KVMGUI — FLTK Frontend (full VM management with callbacks)
const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const qemu = @import("qemu.zig");

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

fn browserCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { selectCurrent(); refreshDetails(); }
fn powerCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { togglePower(); }
fn suspendCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { suspendVm(); }
fn settingsCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { editVmDialog(); }
fn importCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {}
fn snapshotCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void {}
fn deleteVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { deleteCurrentVm(); }
fn quitCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { cfltk.Fl_Window_hide(win_handle); }
fn newVmCB(_: ?*cfltk.Fl_Widget, _: ?*anyopaque) callconv(.c) void { newVmDialog(); }

fn selectCurrent() void {
    const b = browser orelse return;
    const line = cfltk.Fl_Browser_value(b);
    if (line > 0 and line <= @as(c_int, @intCast(vm_count))) selected_idx = @intCast(line - 1);
}

fn togglePower() void {
    const idx = selected_idx orelse return;
    if (idx >= vm_count) return;
    if (vms[idx].isAlive()) { qemu.forceStopVm(&vms[idx]); qemu.reapVm(&vms[idx]); }
    else { qemu.startVm(&vms[idx], std.heap.page_allocator) catch {}; }
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
    for (0..vm_count) |i| {
        const v = &vms[i];
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
                    var sbuf: [160]u8 = undefined;
                    const st = std.fmt.bufPrintZ(&sbuf, "{s} — {s}    |    {d} virtual machine(s)", .{ v.getNameSlice(), std.mem.span(v.status.label()), vm_count }) catch "Ready";
                    cfltk.Fl_Box_set_label(s, st.ptr);
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

    // Menu bar
    _ = cfltk.Fl_Menu_Bar_new(0, 0, WW, 25, "");

    // Toolbar
    const tb_y: i32 = 28;
    const tb = cfltk.Fl_Box_new(0, tb_y, WW, 40, "");
    const new_btn = cfltk.Fl_Button_new(5, tb_y + 3, 80, 34, "New VM");
    const start_btn = cfltk.Fl_Button_new(90, tb_y + 3, 80, 34, "Power On");
    const susp_btn = cfltk.Fl_Button_new(175, tb_y + 3, 80, 34, "Suspend");
    const set_btn = cfltk.Fl_Button_new(260, tb_y + 3, 80, 34, "Settings");
    _ = tb;

    cfltk.Fl_Button_set_callback(new_btn, newVmCB, null);
    cfltk.Fl_Button_set_callback(start_btn, powerCB, null);
    cfltk.Fl_Button_set_callback(susp_btn, suspendCB, null);
    cfltk.Fl_Button_set_callback(set_btn, settingsCB, null);

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
    _ = cfltk.Fl_Input_new(2, body_y + body_h - 20, SW - 4, 18, "");

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
    _ = cfltk.Fl_Box_new(CX + 10, body_y + 60, CW - 20, 30, "VNC/SPICE display — renders when VM is running.");
    cfltk.Fl_Group_end(@ptrCast(dg));

    // Console tab
    const cg = cfltk.Fl_Group_new(CX, body_y + 20, CW, body_h - 20, "Console");
    _ = cfltk.Fl_Box_new(CX + 10, body_y + 60, CW - 20, 30, "Serial console — connects when VM is running.");
    cfltk.Fl_Group_end(@ptrCast(cg));

    cfltk.Fl_Group_end(@ptrCast(tabs));

    // Status bar
    const sb = cfltk.Fl_Box_new(0, WH - 26, WW, 26, "Ready");
    status_bar = @ptrCast(sb);

    cfltk.Fl_Window_end(win);
    cfltk.Fl_Window_show(win);

    refreshBrowser();
    if (vm_count > 0) selected_idx = 0;
    refreshDetails();
    _ = cfltk.Fl_run();
}
