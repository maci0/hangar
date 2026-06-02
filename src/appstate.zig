// SPDX-License-Identifier: MIT
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
const persist = @import("persist.zig");
const filter_ = @import("filter.zig");
const vmlist = @import("vmlist.zig");

// ── Visual palette ─────────────────────────────────────────────────
pub const Palette = struct {
    bg: c_uint,
    surface: c_uint,
    text: c_uint,
    text_dim: c_uint,
    accent: c_uint,
    accent_text: c_uint,
    danger: c_uint,
    warn: c_uint,
    amber: c_uint,
    gray_btn: c_uint,
    border: c_uint,
    header: c_uint,
    success: c_uint,
    dark_text: c_uint,
};

pub const pal_light: Palette = .{
    .bg = 0xf8f9fc00,
    .surface = 0xffffff00,
    .text = 0x11131800,
    .text_dim = 0x88909e00,
    .accent = 0x3b6eeb00,
    .accent_text = 0xffffff00,
    .danger = 0xe02d4200,
    .warn = 0xffc53d00,
    .amber = 0xf59e4400,
    .gray_btn = 0x6b728000,
    .border = 0xe2e5ec00,
    .header = 0x11131800,
    .success = 0x16a34a00,
    .dark_text = 0x00000000,
};

pub const pal_dark: Palette = .{
    .bg = 0x090b1000,
    .surface = 0x11131a00,
    .text = 0xe8eaef00,
    .text_dim = 0x5e647400,
    .accent = 0x4f8cff00,
    .accent_text = 0x090b1000,
    .danger = 0xf44b5e00,
    .warn = 0xffc53d00,
    .amber = 0xf59e4400,
    .gray_btn = 0x25283300,
    .border = 0x25283300,
    .header = 0xe8eaef00,
    .success = 0x3dd68c00,
    .dark_text = 0xe8eaef00,
};

pub var pal: Palette = pal_light;
pub var current_theme: vm.Theme = .light;

pub fn applyTheme(t: vm.Theme) void {
    current_theme = t;
    pal = switch (t) {
        .light, .system => pal_light,
        .dark => pal_dark,
    };

    // Update global FLTK color scheme so menus, scrollbars, and
    // FLTK-native chrome match the selected theme.
    const bg_r: u8 = @truncate((pal.bg >> 24) & 0xff);
    const bg_g: u8 = @truncate((pal.bg >> 16) & 0xff);
    const bg_b: u8 = @truncate((pal.bg >> 8) & 0xff);
    const sfc_r: u8 = @truncate((pal.surface >> 24) & 0xff);
    const sfc_g: u8 = @truncate((pal.surface >> 16) & 0xff);
    const sfc_b: u8 = @truncate((pal.surface >> 8) & 0xff);
    const txt_r: u8 = @truncate((pal.text >> 24) & 0xff);
    const txt_g: u8 = @truncate((pal.text >> 16) & 0xff);
    const txt_b: u8 = @truncate((pal.text >> 8) & 0xff);
    const acc_r: u8 = @truncate((pal.accent >> 24) & 0xff);
    const acc_g: u8 = @truncate((pal.accent >> 16) & 0xff);
    const acc_b: u8 = @truncate((pal.accent >> 8) & 0xff);
    const dim_r: u8 = @truncate((pal.text_dim >> 24) & 0xff);
    const dim_g: u8 = @truncate((pal.text_dim >> 16) & 0xff);
    const dim_b: u8 = @truncate((pal.text_dim >> 8) & 0xff);
    cfltk.Fl_background(bg_r, bg_g, bg_b);
    cfltk.Fl_background2(sfc_r, sfc_g, sfc_b);
    cfltk.Fl_foreground(txt_r, txt_g, txt_b);
    cfltk.Fl_selection_color(acc_r, acc_g, acc_b);
    cfltk.Fl_inactive_color(dim_r, dim_g, dim_b);

    updateWidgetColors();
}

/// Cycle through system → light → dark → system themes.
pub fn cycleTheme() void {
    const next: vm.Theme = switch (current_theme) {
        .system => .light,
        .light => .dark,
        .dark => .system,
    };
    applyTheme(next);
    prefs.theme = next;
    // Persist immediately so the choice survives restart.
    persist.save(&vms, vm_count, prefs) catch {};
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Theme: {s}", .{next.label()}) catch "Theme changed";
    setStatus(msg);
}

/// Re-apply colors to all registered widgets. Called after theme change.
fn updateWidgetColors() void {
    // Menu bar
    if (menu_bar) |mb| {
        cfltk.Fl_Menu_Bar_set_color(mb, pal.surface);
    }
    // Toolbar background strip
    if (toolbar_bg) |tb| {
        cfltk.Fl_Box_set_color(tb, pal.border);
    }
    // Sidebar header
    if (lib_hdr) |hdr| {
        cfltk.Fl_Box_set_label_color(hdr, pal.header);
    }
    // Tab bar
    if (tab_bar) |tb| {
        cfltk.Fl_Tabs_set_color(tb, pal.surface);
    }
    // Status bar
    if (status_bar) |sb| {
        cfltk.Fl_Box_set_color(sb, pal.border);
        cfltk.Fl_Box_set_label_color(sb, pal.text_dim);
    }
    // Browser (VM list) — also covered by themed_browsers loop,
    // but kept as direct reference for boot-time before registration expands.
    if (browser) |b| {
        cfltk.Fl_Browser_set_color(b, pal.surface);
        cfltk.Fl_Browser_set_text_size(b, 13);
    }
    // Search input
    if (search_input) |si| {
        cfltk.Fl_Input_set_color(si, pal.surface);
        cfltk.Fl_Input_set_text_color(si, pal.text);
    }
    // Detail labels
    for (&detail_labels) |*dl| {
        if (dl.*) |l| {
            cfltk.Fl_Box_set_color(l, pal.surface);
            cfltk.Fl_Box_set_label_color(l, pal.text);
        }
    }
    // Summary name
    if (sum_name) |l| {
        cfltk.Fl_Box_set_label_color(l, pal.header);
    }
    // Console widget
    if (console_widget) |w| {
        cfltk.Fl_Browser_set_color(w, pal.surface);
    }
    // Display box
    if (display_box) |db| {
        cfltk.Fl_Box_set_color(db, pal.surface);
        cfltk.Fl_Box_set_label_color(db, pal.text_dim);
    }
    // Registered themeable widgets
    for (themed_inputs[0..themed_inputs_len]) |inp| {
        cfltk.Fl_Input_set_color(inp, pal.surface);
        cfltk.Fl_Input_set_text_color(inp, pal.text);
    }
    for (themed_choices[0..themed_choices_len]) |ch| {
        cfltk.Fl_Choice_set_color(ch, pal.surface);
        cfltk.Fl_Choice_set_text_color(ch, pal.text);
    }
    for (themed_browsers[0..themed_browsers_len]) |br| {
        cfltk.Fl_Browser_set_color(br, pal.surface);
        cfltk.Fl_Browser_set_text_size(br, 13);
    }
    for (themed_checkbuttons[0..themed_checkbuttons_len]) |cb| {
        cfltk.Fl_Check_Button_set_color(cb, pal.surface);
        cfltk.Fl_Check_Button_set_label_color(cb, pal.text);
    }
    for (themed_scrolls[0..themed_scrolls_len]) |sc| {
        cfltk.Fl_Scroll_set_color(sc, pal.surface);
    }
    if (toolbar_theme_cb) |cb| cb();
}

/// Theme a Fl_Input and register it for live theme updates.
pub fn themeInput(w: ?*cfltk.Fl_Input) void {
    const inp = w orelse return;
    cfltk.Fl_Input_set_color(inp, pal.surface);
    cfltk.Fl_Input_set_text_color(inp, pal.text);
    if (themed_inputs_len < themed_inputs.len) {
        themed_inputs[themed_inputs_len] = inp;
        themed_inputs_len += 1;
    } else {
        _ = std.c.write(2, "themeInput: MAX_THEMED exceeded\n", 31);
    }
}

/// Theme a Fl_Choice and register it for live theme updates.
pub fn themeChoice(w: ?*cfltk.Fl_Choice) void {
    const ch = w orelse return;
    cfltk.Fl_Choice_set_color(ch, pal.surface);
    cfltk.Fl_Choice_set_text_color(ch, pal.text);
    if (themed_choices_len < themed_choices.len) {
        themed_choices[themed_choices_len] = ch;
        themed_choices_len += 1;
    } else {
        _ = std.c.write(2, "themeChoice: MAX_THEMED exceeded\n", 32);
    }
}

/// Theme a Fl_Browser and register it for live theme updates.
pub fn themeBrowser(w: ?*cfltk.Fl_Browser) void {
    const b = w orelse return;
    cfltk.Fl_Browser_set_color(b, pal.surface);
    cfltk.Fl_Browser_set_text_size(b, 13);
    if (themed_browsers_len < themed_browsers.len) {
        themed_browsers[themed_browsers_len] = b;
        themed_browsers_len += 1;
    } else {
        _ = std.c.write(2, "themeBrowser: MAX_THEMED exceeded\n", 33);
    }
}

/// Theme a Fl_Check_Button background for the current palette
/// and register it for live theme updates.
pub fn themeCheckButton(w: ?*cfltk.Fl_Check_Button) void {
    const cb = w orelse return;
    cfltk.Fl_Check_Button_set_color(cb, pal.surface);
    cfltk.Fl_Check_Button_set_label_color(cb, pal.text);
    if (themed_checkbuttons_len < themed_checkbuttons.len) {
        themed_checkbuttons[themed_checkbuttons_len] = cb;
        themed_checkbuttons_len += 1;
    } else {
        _ = std.c.write(2, "themeCheckButton: MAX_THEMED exceeded\n", 38);
    }
}

/// Theme a Fl_Scroll background and register it for live theme updates.
pub fn themeScroll(w: ?*cfltk.Fl_Scroll) void {
    const sc = w orelse return;
    cfltk.Fl_Scroll_set_color(sc, pal.surface);
    if (themed_scrolls_len < themed_scrolls.len) {
        themed_scrolls[themed_scrolls_len] = sc;
        themed_scrolls_len += 1;
    } else {
        _ = std.c.write(2, "themeScroll: MAX_THEMED exceeded\n", 33);
    }
}

/// Unregister a Fl_Input from themed tracking. Safe to call with null or
/// unregistered widgets (no-op). Swap-removes to keep the array dense.
pub fn unthemeInput(w: ?*cfltk.Fl_Input) void {
    const inp = w orelse return;
    for (0..themed_inputs_len) |i| {
        if (themed_inputs[i] == inp) {
            themed_inputs_len -= 1;
            if (i < themed_inputs_len) {
                themed_inputs[i] = themed_inputs[themed_inputs_len];
            }
            themed_inputs[themed_inputs_len] = null;
            return;
        }
    }
}

/// Unregister a Fl_Choice from themed tracking.
pub fn unthemeChoice(w: ?*cfltk.Fl_Choice) void {
    const ch = w orelse return;
    for (0..themed_choices_len) |i| {
        if (themed_choices[i] == ch) {
            themed_choices_len -= 1;
            if (i < themed_choices_len) {
                themed_choices[i] = themed_choices[themed_choices_len];
            }
            themed_choices[themed_choices_len] = null;
            return;
        }
    }
}

/// Unregister a Fl_Browser from themed tracking.
pub fn unthemeBrowser(w: ?*cfltk.Fl_Browser) void {
    const b = w orelse return;
    for (0..themed_browsers_len) |i| {
        if (themed_browsers[i] == b) {
            themed_browsers_len -= 1;
            if (i < themed_browsers_len) {
                themed_browsers[i] = themed_browsers[themed_browsers_len];
            }
            themed_browsers[themed_browsers_len] = null;
            return;
        }
    }
}

/// Unregister a Fl_Check_Button from themed tracking.
pub fn unthemeCheckButton(w: ?*cfltk.Fl_Check_Button) void {
    const cb = w orelse return;
    for (0..themed_checkbuttons_len) |i| {
        if (themed_checkbuttons[i] == cb) {
            themed_checkbuttons_len -= 1;
            if (i < themed_checkbuttons_len) {
                themed_checkbuttons[i] = themed_checkbuttons[themed_checkbuttons_len];
            }
            themed_checkbuttons[themed_checkbuttons_len] = null;
            return;
        }
    }
}

/// Unregister a Fl_Scroll from themed tracking.
pub fn unthemeScroll(w: ?*cfltk.Fl_Scroll) void {
    const sc = w orelse return;
    for (0..themed_scrolls_len) |i| {
        if (themed_scrolls[i] == sc) {
            themed_scrolls_len -= 1;
            if (i < themed_scrolls_len) {
                themed_scrolls[i] = themed_scrolls[themed_scrolls_len];
            }
            themed_scrolls[themed_scrolls_len] = null;
            return;
        }
    }
}

pub const MAX_VMS = vm.MAX_VMS;

pub var vms: [MAX_VMS]vm.VmConfig = [_]vm.VmConfig{.{}} ** MAX_VMS;
pub var vm_count: usize = 0;
pub var vms_mutex: sync.SpinMutex = .{};
pub var selected_idx: ?usize = null;
pub var prefs: vm.Prefs = .{};
pub var browser: ?*cfltk.Fl_Browser = null;
pub var status_bar: ?*cfltk.Fl_Box = null;
pub var menu_bar: ?*cfltk.Fl_Menu_Bar = null;
pub var toolbar_bg: ?*cfltk.Fl_Box = null;
pub var toolbar_util_bg: ?*cfltk.Fl_Box = null;
pub var lib_hdr: ?*cfltk.Fl_Box = null;
pub var tab_bar: ?*cfltk.Fl_Tabs = null;
pub var detail_labels: [12]?*cfltk.Fl_Box = [_]?*cfltk.Fl_Box{null} ** 12;
pub var sum_name: ?*cfltk.Fl_Box = null;
pub var win_handle: ?*cfltk.Fl_Window = null;
pub var ctx_menu_handle: ?*cfltk.Fl_Menu_Button = null;
pub var console_widget: ?*cfltk.Fl_Browser = null;
pub var display_box: ?*cfltk.Fl_Box = null;
pub var gl_display: ?*cfltk.Fl_Gl_Window = null;
pub var display_group: ?*cfltk.Fl_Group = null;
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
pub var web_running: bool = false;
pub var web_thread: ?std.Thread = null;
pub var modal_active: bool = false;

/// Callback invoked on theme switch to re-color toolbar buttons.
/// Set by main.zig after toolbar creation.
pub var toolbar_theme_cb: ?*const fn () void = null;

/// Registered widgets for live theme updates.
const MAX_THEMED = 256;
var themed_inputs: [MAX_THEMED]?*cfltk.Fl_Input = [_]?*cfltk.Fl_Input{null} ** MAX_THEMED;
var themed_inputs_len: usize = 0;
var themed_choices: [MAX_THEMED]?*cfltk.Fl_Choice = [_]?*cfltk.Fl_Choice{null} ** MAX_THEMED;
var themed_choices_len: usize = 0;
var themed_browsers: [MAX_THEMED]?*cfltk.Fl_Browser = [_]?*cfltk.Fl_Browser{null} ** MAX_THEMED;
var themed_browsers_len: usize = 0;
var themed_checkbuttons: [MAX_THEMED]?*cfltk.Fl_Check_Button = [_]?*cfltk.Fl_Check_Button{null} ** MAX_THEMED;
var themed_checkbuttons_len: usize = 0;
var themed_scrolls: [MAX_THEMED]?*cfltk.Fl_Scroll = [_]?*cfltk.Fl_Scroll{null} ** MAX_THEMED;
var themed_scrolls_len: usize = 0;

/// Persistent buffers for FLTK labels — FLTK's label() stores pointers
/// directly, so values must outlive the call site.
var status_buf: [256]u8 = [_]u8{0} ** 256;
var detail_buf: [12][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 12;
var status_detail_buf: [200]u8 = [_]u8{0} ** 200;
var status_err: bool = false;

/// Set the status bar text. Clears any error flag.
pub fn setStatus(msg: []const u8) void {
    status_err = false;
    if (status_bar) |sb| {
        const max_msg = status_buf.len - 1;
        const truncated = if (msg.len <= max_msg) msg else msg[0..max_msg];
        @memcpy(status_buf[0..truncated.len], truncated);
        status_buf[truncated.len] = 0;
        cfltk.Fl_Box_set_label(sb, @ptrCast(&status_buf));
    }
}

/// Set status with a Unicode icon prefix.
pub fn setStatusIcon(icon: []const u8, msg: []const u8) void {
    if (status_bar) |sb| {
        const icon_len = icon.len;
        const max_msg = status_buf.len - 1 - icon_len;
        const msg_len = if (msg.len <= max_msg) msg.len else max_msg;
        var offset: usize = 0;
        @memcpy(status_buf[0..icon_len], icon);
        offset += icon_len;
        @memcpy(status_buf[offset .. offset + msg_len], msg[0..msg_len]);
        offset += msg_len;
        status_buf[offset] = 0;
        cfltk.Fl_Box_set_label(sb, @ptrCast(&status_buf));
    }
}

pub fn setStatusErr(msg: []const u8) void {
    status_err = true;
    setStatusIcon("✗ ", msg);
}
pub fn setStatusOk(msg: []const u8) void {
    status_err = false;
    setStatusIcon("✓ ", msg);
}

/// Set a detail label value by index (used by refreshDetails).
pub fn setDetail(i: usize, value: []const u8) void {
    if (i < detail_labels.len and i < detail_buf.len) {
        if (detail_labels[i]) |dl| {
            const max_detail = detail_buf[i].len - 1;
            const truncated = if (value.len <= max_detail) value else value[0..max_detail];
            @memcpy(detail_buf[i][0..truncated.len], truncated);
            detail_buf[i][truncated.len] = 0;
            cfltk.Fl_Box_set_label(dl, @ptrCast(&detail_buf[i]));
        }
    }
}

/// Get or create the Vmm handle for VM at index idx.
pub fn getVmmHandle(idx: usize) ?hv_iface.VmmHandle {
    if (idx >= vm_count) return null;
    if (g_vmm_handles[idx] == null) {
        g_vmm_handles[idx] = hv_backend.createHandle(&vms[idx], vms[idx].accel, std.heap.page_allocator) catch return null;
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
/// Delegates to the pure-logic filter.zig module.
pub fn filterMatch(v: *const vm.VmConfig, filter: []const u8) bool {
    return filter_.filterMatch(v, filter);
}

/// Select the VM at the clicked browser line (handles favorites + separator).
pub fn selectCurrent() void {
    const b = browser orelse return;
    const line = cfltk.Fl_Browser_value(b);
    if (line <= 0) { selected_idx = null; return; }
    const target: usize = @intCast(line - 1);

    const filter: []const u8 = if (filter_len > 0) filter_text[0..filter_len] else "";
    selected_idx = vmlist.lineToVmIndex(target, vms[0..vm_count], filter);
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
                // Color-code the state card: bg + fg
                if (detail_labels[0]) |dl| {
                    const color: u32 = switch (v.status) {
                        .running => pal.success,
                        .paused => pal.amber,
                        .suspended => pal.warn,
                        .stopped => pal.text_dim,
                    };
                    const fg: u32 = switch (v.status) {
                        .paused => pal.dark_text,
                        else => pal.accent_text,
                    };
                    cfltk.Fl_Box_set_label_color(dl, fg);
                    cfltk.Fl_Box_set_color(dl, color);
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
                if (!status_err) {
                    if (status_bar) |s| {
                        if (v.isAlive() and vm_started[idx] > 0) {
                            const elapsed: u64 = @intCast(vm_started[idx]);
                            const hrs = elapsed / 3600;
                            const mins = (elapsed % 3600) / 60;
                            const secs = elapsed % 60;
                            _ = std.fmt.bufPrintZ(&status_detail_buf, "{s} — {s} | Uptime: {d}:{d:0>2}:{d:0>2} | {d} VM(s)", .{ v.getNameSlice(), std.mem.span(v.status.label()), hrs, mins, secs, vm_count }) catch {};
                            cfltk.Fl_Box_set_label(s, @ptrCast(&status_detail_buf));
                        } else {
                            _ = std.fmt.bufPrintZ(&status_detail_buf, "{s} — {s}    |    {d} virtual machine(s)", .{ v.getNameSlice(), std.mem.span(v.status.label()), vm_count }) catch {};
                            cfltk.Fl_Box_set_label(s, @ptrCast(&status_detail_buf));
                        }
                    }
                }
                return;
            }
        }
        cfltk.Fl_Box_set_label(l, "No virtual machine selected.");
        for (&detail_labels) |*dl| { if (dl.*) |d| cfltk.Fl_Box_set_label(d, ""); }
        if (!status_err) {
            if (status_bar) |s| {
                _ = std.fmt.bufPrintZ(&status_detail_buf, "{d} virtual machine(s)", .{vm_count}) catch {};
                cfltk.Fl_Box_set_label(s, @ptrCast(&status_detail_buf));
            }
        }
    }
}
