//! Shared global state for the FLTK frontend.
//!
//! All widgets, VM arrays, session state, VNC/SPICE clients, serial state,
//! remote mode flags, and small cross-cutting helpers live here so that
//! dialogs, display, serial_console, and remote modules can share them
//! without circular imports.

const std = @import("std");
const vm = @import("vm.zig");
const sync = @import("sync.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const hv_iface = @import("hv/interface.zig");
const hv_backend = @import("hv/qemu_backend.zig");
const cfltk = @import("cfltk_import.zig").c;

pub const MAX_VMS = 64;

pub var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
pub var vm_count: usize = 0;
pub var selected_idx: ?usize = null;
pub var prefs: vm.Prefs = .{};
pub var browser: ?*cfltk.Fl_Browser = null;
pub var status_bar: ?*cfltk.Fl_Box = null;
pub var detail_labels: [12]?*cfltk.Fl_Box = [_]?*cfltk.Fl_Box{null} ** 12;
pub var sum_name: ?*cfltk.Fl_Box = null;
pub var win_handle: ?*cfltk.Fl_Window = null;
pub var ctx_menu_handle: ?*cfltk.Fl_Menu_Button = null;
pub var console_widget: ?*cfltk.Fl_Browser = null;
pub var display_box: ?*cfltk.Fl_Box = null;
pub var search_input: ?*cfltk.Fl_Input = null;
pub var filter_text: [64]u8 = [_]u8{0} ** 64;
pub var filter_len: usize = 0;
pub var vm_started: [MAX_VMS]i64 = [_]i64{0} ** MAX_VMS;
pub var g_vmm: hv_iface.Vmm = undefined;
pub var g_vmm_handles: [MAX_VMS]?hv_iface.VmmHandle = .{null} ** MAX_VMS;
pub var vnc_client: ?*vnc.VncClient = null;
pub var spice_client: ?*spice.SpiceClient = null;
pub const SERIAL_BUF_SIZE = 64 * 1024;
pub var serial_buf: [SERIAL_BUF_SIZE]u8 = undefined;
pub var serial_len: usize = 0;
pub var serial_mutex: sync.SpinMutex = .{};
pub var serial_running: bool = false;
pub var serial_thread: ?std.Thread = null;
pub var serial_fd: ?std.c.fd_t = null;
pub var remote_mode: bool = false;
pub var remote_url: [128]u8 = [_]u8{0} ** 128;
pub var remote_url_len: usize = 0;

/// Set the status bar text.
pub fn setStatus(msg: []const u8) void {
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

/// Set a detail label value by index (used by refreshDetails).
pub fn setDetail(i: usize, value: []const u8) void {
    if (i < detail_labels.len) {
        if (detail_labels[i]) |dl| {
            cfltk.Fl_Box_set_label(dl, @ptrCast(value.ptr));
        }
    }
}

/// Get or create the Vmm handle for VM at index idx.
pub fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        const mode: hv_backend.AccelMode = if (vms[idx].enable_kvm) .auto else .force_tcg;
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], mode, std.heap.page_allocator) catch return null;
    }
    return g_vmm_handles[idx];
}

/// Destroy the Vmm handle for VM at index idx.
pub fn destroyVmmHandle(idx: usize) void {
    if (g_vmm_handles[idx]) |h| {
        g_vmm.deinitFn(h);
        g_vmm_handles[idx] = null;
    }
}

/// Check whether a VM matches the current filter string (case-insensitive).
pub fn filterMatch(v: *const vm.VmConfig, filter: []const u8) bool {
    if (filter.len == 0) return true;
    const name = v.getNameSlice();
    var lower_buf: [128]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, name);
    return std.mem.indexOf(u8, lower, filter) != null;
}

/// Select the VM at the clicked browser line (handles favorites + separator).
pub fn selectCurrent() void {
    const b = browser orelse return;
    const line = cfltk.Fl_Browser_value(b);
    if (line <= 0) { selected_idx = null; return; }
    const target: usize = @intCast(line - 1);

    const filter: []const u8 = if (filter_len > 0) filter_text[0..filter_len] else "";
    var cursor: usize = 0;
    selected_idx = null;

    // Determine if separator is present: at least one fav AND one non-fav visible.
    var has_favs = false;
    var has_nonfavs = false;
    for (0..vm_count) |i| {
        if (filterMatch(&vms[i], filter)) {
            if (vms[i].favorite) has_favs = true else has_nonfavs = true;
        }
    }
    const has_sep = has_favs and has_nonfavs;

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

/// Rebuild the VM browser list from vms[] applying the current filter.
pub fn refreshBrowser() void {
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

/// Refresh the detail panel for the currently selected VM.
pub fn refreshDetails() void {
    if (sum_name) |l| {
        if (selected_idx) |idx| {
            if (idx < vm_count) {
                const v = &vms[idx];
                cfltk.Fl_Box_set_label(l, v.getName());
                setDetail(0, std.mem.span(v.status.label()));
                // Color-code the state label
                if (detail_labels[0]) |dl| {
                    const color: u32 = switch (v.status) {
                        .running => 0x00AA00,
                        .paused => 0xFF8800,
                        .suspended => 0xCC6600,
                        .stopped => 0x888888,
                    };
                    cfltk.Fl_Box_set_label_color(dl, color);
                }
                setDetail(1, std.mem.span(v.guest_os.label()));
                var mbuf: [32]u8 = undefined;
                const mt = std.fmt.bufPrintZ(&mbuf, "{d} MB", .{v.memory_mb}) catch "---";
                setDetail(2, mt);
                var cbuf: [32]u8 = undefined;
                const ct = std.fmt.bufPrintZ(&cbuf, "{d}", .{v.cpu_cores}) catch "---";
                setDetail(3, ct);
                setDetail(4, if (v.hasDisk()) v.getDiskPathSlice() else "(none)");
                setDetail(5, std.mem.span(v.nics[0].mode.label()));
                setDetail(6, if (v.hasIso()) v.getIsoPathSlice() else "Auto detect");
                setDetail(7, if (v.hasNotes()) v.getNotesSlice() else "");
                setDetail(8, if (v.hasSharedFolder()) v.getSharedFolderSlice() else "(none)");
                setDetail(9, if (v.hasUsbDevice()) v.getUsbDeviceSlice() else "(none)");
                setDetail(10, if (v.guest_tools) "Enabled" else "Disabled");
                if (v.autoprotect) {
                    var ap_buf: [64]u8 = undefined;
                    const ap_str = std.fmt.bufPrintZ(&ap_buf, "Every {d} min, keep {d}", .{ v.autoprotect_interval_min, v.autoprotect_max }) catch "Enabled";
                    setDetail(11, ap_str);
                } else {
                    setDetail(11, "Disabled");
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
