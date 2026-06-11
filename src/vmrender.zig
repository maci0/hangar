//! VM -> JSON rendering: the list payload (GET /api/vms) and the detail payload
//! (GET /api/vms/<id>, also the settings form source). Pure formatting — reads
//! VMs under vms_mutex, writes JSON into a caller buffer. String fields are
//! escaped via httpresp.jsonEscape.

const std = @import("std");
const vm = @import("vm.zig");
const appstate = @import("appstate.zig");
const httpreq = @import("httpreq.zig");
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const jsonEscape = httpresp.jsonEscape;
const logErr = wlog.logErr;

/// Wrapper around jsonEscape that logs truncation. Returns only the escaped slice
/// so call sites remain concise: escapeJson(&esc, s, "field_name")
/// When truncation occurs, returns "" to avoid embedding broken JSON in the response.
fn escapeJson(buf: []u8, s: []const u8, field: []const u8) []const u8 {
    const result = jsonEscape(buf, s);
    if (result.truncated) {
        _ = field; // field name is for debugging; log a concise message
        logErr("jsonEscape truncated");
        return "";
    }
    return result.escaped;
}

pub fn renderVmDetail(req: []const u8, buf: []u8) ![]const u8 {
    const idx = parseIdx(req, "GET /api/vms/") orelse return error.RenderFailed;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx >= appstate.vm_count) return "{}";
    const v = &appstate.vms[idx];
    var w: usize = 0;

    // Pre-escape user-controlled strings. Each needs its own buffer because
    // bufPrint tuple args are evaluated left-to-right, and each escapeJson
    // call overwrites the same buffer — earlier slices would dangle.
    var name_buf: [vm.MAX_NAME * 2 + 64]u8 = undefined;
    const name_e = escapeJson(&name_buf, v.getNameSlice(), "name");

    var iso_buf: [vm.MAX_PATH]u8 = undefined;
    const iso_e = if (v.hasIso()) escapeJson(&iso_buf, v.getIsoPathSlice(), "iso_path") else "";

    var notes_buf: [4096 * 6]u8 = undefined; // 6x: worst-case \u00XX escape of every byte
    const notes_e = if (v.hasNotes()) escapeJson(&notes_buf, v.getNotesSlice(), "notes") else "";
    var tags_buf: [256 * 6]u8 = undefined; // 6x: worst-case \u00XX escape of every byte
    const tags_e = if (v.tags_len > 0) escapeJson(&tags_buf, v.getTagsSlice(), "tags") else "";
    var folder_buf: [128 * 6]u8 = undefined;
    const folder_e = if (v.folder_len > 0) escapeJson(&folder_buf, v.getFolderSlice(), "folder") else "";
    var id_buf: [64]u8 = undefined;
    const id_e = escapeJson(&id_buf, v.getIdSlice(), "id");
    var vnet_buf: [256]u8 = undefined;
    const vnet_e = if (v.vnet_len > 0) escapeJson(&vnet_buf, v.getVnetSlice(), "vnet") else "";

    var sf_buf: [vm.MAX_PATH]u8 = undefined;
    const sf_e = if (v.hasSharedFolder()) escapeJson(&sf_buf, v.getSharedFolderSlice(), "shared_folder") else "";

    var usb_buf: [128]u8 = undefined;
    const usb_e = if (v.hasUsbDevice()) escapeJson(&usb_buf, v.getUsbDeviceSlice(), "usb_device") else "";

    var d2_buf: [vm.MAX_PATH]u8 = undefined;
    const d2_e = if (v.hasDisk2()) escapeJson(&d2_buf, v.getDisk2PathSlice(), "disk2_path") else "";

    var flp_buf: [vm.MAX_PATH]u8 = undefined;
    const flp_e = if (v.hasFloppy()) escapeJson(&flp_buf, v.getFloppyPathSlice(), "floppy_path") else "";

    var pf_buf: [1024]u8 = undefined;
    const pf_e = if (v.hasPortForwards()) escapeJson(&pf_buf, v.getPortForwardsSlice(), "port_forwards") else "";

    // First 32 fields
    const part1 = std.fmt.bufPrint(buf[w..],
        \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}","tags":"{s}","folder":"{s}"
    , .{
        idx,                                    name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
        v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
        v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
        if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
        sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
        if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
        v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
        flp_e,                                  pf_e,                                 tags_e,                               folder_e,
    }) catch return error.RenderFailed;
    w += part1.len;

    // Remaining fields — split to stay under 32-arg limit
    const part2a = std.fmt.bufPrint(buf[w..],
        \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"virtio_rng":{s},"guest_agent":{s},"watchdog":{d},"tpm":{s},"secure_boot":{s},"hyperv_enlightenments":{s},"hugepages":{s},"io_threads":{d},"disk_bps_throttle":{d},"disk_iops_throttle":{d}
    , .{
        if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
        std.mem.span(v.nics[1].mode.toStr()),
        if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
        std.mem.span(v.nics[2].mode.toStr()),
        if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
        v.num_displays,
        if (v.enable_serial) "true" else "false",
        if (v.virtio_rng) "true" else "false",
        if (v.guest_agent) "true" else "false",
        v.watchdog.toIndex(),
        if (v.tpm) "true" else "false",
        if (v.secure_boot) "true" else "false",
        if (v.hyperv_enlightenments) "true" else "false",
        if (v.hugepages) "true" else "false",
        v.io_threads,
        v.disk_bps_throttle,
        v.disk_iops_throttle,
    }) catch return error.RenderFailed;
    w += part2a.len;

    const part2b = std.fmt.bufPrint(buf[w..],
        \\,"ballooning":{s},"host_autostart":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"rtc":{d},"cpu_model":"{s}","accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s},"started":{d}
    , .{
        if (v.ballooning) "true" else "false",
        if (v.host_autostart) "true" else "false",
        if (v.enable_3d) "true" else "false",
        v.gpu_device.toIndex(),
        v.display.toIndex(),
        v.display_resolution.toIndex(),
        v.guest_os.toIndex(),
        v.audio.toIndex(),
        v.boot_order.toIndex(),
        v.rtc.toIndex(),
        std.mem.span(v.cpu_model.toStr()),
        std.mem.span(v.accel.toStr()),
        if (v.embed_display) "true" else "false",
        v.vnc_port,
        v.spice_port,
        if (v.favorite) "true" else "false",
        appstate.vm_started[idx],
    }) catch return error.RenderFailed;
    w += part2b.len;

    // Per-NIC vnet names are user-controlled; escape each into its own buffer.
    var nv_bufs: [7][96]u8 = undefined;
    var nv_e: [7][]const u8 = undefined;
    for (0..7) |ni| nv_e[ni] = if (v.nics[ni + 1].vnet_len > 0) escapeJson(&nv_bufs[ni], v.getNicVnetSliceAny(ni + 1), "nic_vnet") else "";
    const part2c = std.fmt.bufPrint(buf[w..],
        \\,"nic4_mode":"{s}","nic4_mac":"{s}","nic5_mode":"{s}","nic5_mac":"{s}","nic6_mode":"{s}","nic6_mac":"{s}","nic7_mode":"{s}","nic7_mac":"{s}","nic8_mode":"{s}","nic8_mac":"{s}","nic2_vnet":"{s}","nic3_vnet":"{s}","nic4_vnet":"{s}","nic5_vnet":"{s}","nic6_vnet":"{s}","nic7_vnet":"{s}","nic8_vnet":"{s}"
    , .{
        std.mem.span(v.nics[3].mode.toStr()),
        if (v.nics[3].mac_len > 0) v.getNicMacSliceAny(3) else "",
        std.mem.span(v.nics[4].mode.toStr()),
        if (v.nics[4].mac_len > 0) v.getNicMacSliceAny(4) else "",
        std.mem.span(v.nics[5].mode.toStr()),
        if (v.nics[5].mac_len > 0) v.getNicMacSliceAny(5) else "",
        std.mem.span(v.nics[6].mode.toStr()),
        if (v.nics[6].mac_len > 0) v.getNicMacSliceAny(6) else "",
        std.mem.span(v.nics[7].mode.toStr()),
        if (v.nics[7].mac_len > 0) v.getNicMacSliceAny(7) else "",
        nv_e[0], nv_e[1], nv_e[2], nv_e[3], nv_e[4], nv_e[5], nv_e[6],
    }) catch return error.RenderFailed;
    w += part2c.len;

    // Extra-disk paths are user-controlled; escape each into its own buffer
    // so a path containing a quote/backslash can't break the JSON document.
    var ex0_buf: [vm.MAX_PATH]u8 = undefined;
    const ex0_e = if (v.hasExtraDisk(0)) escapeJson(&ex0_buf, v.getExtraDiskPathSlice(0), "extra0_path") else "";
    var ex1_buf: [vm.MAX_PATH]u8 = undefined;
    const ex1_e = if (v.hasExtraDisk(1)) escapeJson(&ex1_buf, v.getExtraDiskPathSlice(1), "extra1_path") else "";
    var ex2_buf: [vm.MAX_PATH]u8 = undefined;
    const ex2_e = if (v.hasExtraDisk(2)) escapeJson(&ex2_buf, v.getExtraDiskPathSlice(2), "extra2_path") else "";
    var ex3_buf: [vm.MAX_PATH]u8 = undefined;
    const ex3_e = if (v.hasExtraDisk(3)) escapeJson(&ex3_buf, v.getExtraDiskPathSlice(3), "extra3_path") else "";

    const part2d = std.fmt.bufPrint(buf[w..],
        \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d}
    , .{
        ex0_e,
        v.extra_disks[0].size_gb,
        v.extra_disks[0].format.toIndex(),
        ex1_e,
        v.extra_disks[1].size_gb,
        v.extra_disks[1].format.toIndex(),
        ex2_e,
        v.extra_disks[2].size_gb,
        v.extra_disks[2].format.toIndex(),
        ex3_e,
        v.extra_disks[3].size_gb,
        v.extra_disks[3].format.toIndex(),
    }) catch return error.RenderFailed;
    w += part2d.len;

    // cloud-init user-data can be multi-KB and contain quotes/newlines — escape
    // it into its own buffer. This part closes the JSON object.
    var ci_esc: [vm.MAX_CLOUD_INIT * 3]u8 = undefined;
    const ci_e = if (v.hasCloudInit()) escapeJson(&ci_esc, v.getCloudInitSlice(), "cloud_init") else "";
    const part2e = std.fmt.bufPrint(buf[w..], ",\"cloud_init\":\"{s}\",\"id\":\"{s}\",\"vnet\":\"{s}\"}}", .{ ci_e, id_e, vnet_e }) catch return error.RenderFailed;
    w += part2e.len;

    return buf[0..w];
}

/// Render JSON into caller-provided buffer. Returns bytes written, or 0 on overflow.
pub fn renderJson(buf: []u8) usize {
    if (buf.len == 0) return 0;
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    var w: usize = 0;
    buf[w] = '[';
    w += 1;

    for (0..appstate.vm_count) |i| {
        if (i > 0) {
            if (w >= buf.len) return 0;
            buf[w] = ',';
            w += 1;
        }
        const v = &appstate.vms[i];

        // Pre-escape user-controlled strings into dedicated buffers so
        // later escapeJson calls don't overwrite slices captured by earlier ones.
        var name_buf: [vm.MAX_NAME * 2 + 64]u8 = undefined;
        const name_e = escapeJson(&name_buf, v.getNameSlice(), "name");

        var iso_buf: [vm.MAX_PATH]u8 = undefined;
        const iso_e = if (v.hasIso()) escapeJson(&iso_buf, v.getIsoPathSlice(), "iso_path") else "";

        // List is display-only (settings form reads the detail endpoint), so keep
        // the per-VM list buffers modest; over-long escaped notes truncate here
        // (cosmetic) rather than inflating the per-VM list-overflow budget.
        var notes_buf: [4096 * 2]u8 = undefined;
        const notes_e = if (v.hasNotes()) escapeJson(&notes_buf, v.getNotesSlice(), "notes") else "";

        var sf_buf: [vm.MAX_PATH]u8 = undefined;
        const sf_e = if (v.hasSharedFolder()) escapeJson(&sf_buf, v.getSharedFolderSlice(), "shared_folder") else "";

        var usb_buf: [128]u8 = undefined;
        const usb_e = if (v.hasUsbDevice()) escapeJson(&usb_buf, v.getUsbDeviceSlice(), "usb_device") else "";

        var d2_buf: [vm.MAX_PATH]u8 = undefined;
        const d2_e = if (v.hasDisk2()) escapeJson(&d2_buf, v.getDisk2PathSlice(), "disk2_path") else "";

        var flp_buf: [vm.MAX_PATH]u8 = undefined;
        const flp_e = if (v.hasFloppy()) escapeJson(&flp_buf, v.getFloppyPathSlice(), "floppy_path") else "";

        var pf_buf: [1024]u8 = undefined;
        const pf_e = if (v.hasPortForwards()) escapeJson(&pf_buf, v.getPortForwardsSlice(), "port_forwards") else "";

        var tags_buf: [512]u8 = undefined; // display-only (see notes_buf above)
        const tags_e = if (v.tags_len > 0) escapeJson(&tags_buf, v.getTagsSlice(), "tags") else "";
        var folder_buf: [256]u8 = undefined;
        const folder_e = if (v.folder_len > 0) escapeJson(&folder_buf, v.getFolderSlice(), "folder") else "";
        var id_buf: [64]u8 = undefined;
        const id_e = escapeJson(&id_buf, v.getIdSlice(), "id");
        var vnet_buf: [256]u8 = undefined;
        const vnet_e = if (v.vnet_len > 0) escapeJson(&vnet_buf, v.getVnetSlice(), "vnet") else "";

        // First block: up through tags
        const part1 = std.fmt.bufPrint(buf[w..],
            \\{{"idx":{d},"name":"{s}","status":"{s}","os":"{s}","mem":{d},"cpu":{d},"cpu_sockets":{d},"disk":{d},"disk_format":{d},"disk_cache":{d},"net":"{s}","fw":"{s}","hasIso":{s},"hasDisk":{s},"iso_path":"{s}","notes":"{s}","shared_folder":"{s}","usb_device":"{s}","usb_policy":{d},"guest_tools":{s},"autoprotect":{s},"autoprotect_interval":{d},"autoprotect_max":{d},"hasDisk2":{s},"disk2_size":{d},"disk2_path":"{s}","disk2_format":{d},"hasFloppy":{s},"floppy_path":"{s}","port_forwards":"{s}","tags":"{s}","folder":"{s}"
        , .{
            i,                                      name_e,                               std.mem.span(v.status.toStr()),       std.mem.span(v.guest_os.label()),
            v.memory_mb,                            v.cpu_cores,                          v.cpu_sockets,                        v.disk_size_gb,
            v.disk_format.toIndex(),                v.disk_cache.toIndex(),               std.mem.span(v.nics[0].mode.toStr()), std.mem.span(v.firmware.toStr()),
            if (v.hasIso()) "true" else "false",    if (v.hasDisk()) "true" else "false", iso_e,                                notes_e,
            sf_e,                                   usb_e,                                v.usb_policy.toIndex(),               if (v.guest_tools) "true" else "false",
            if (v.autoprotect) "true" else "false", v.autoprotect_interval_min,           v.autoprotect_max,                    if (v.hasDisk2()) "true" else "false",
            v.disk2_size_gb,                        d2_e,                                 v.disk2_format.toIndex(),             if (v.hasFloppy()) "true" else "false",
            flp_e,                                  pf_e,                                 tags_e,                               folder_e,
        }) catch {
            w = buf.len;
            break;
        };
        w += part1.len;

        // Remaining fields — split to stay under 32-arg limit
        const part2a = std.fmt.bufPrint(buf[w..],
            \\,"mac":"{s}","nic2_mode":"{s}","nic2_mac":"{s}","nic3_mode":"{s}","nic3_mac":"{s}","num_displays":{d},"hasSerial":{s},"virtio_rng":{s},"guest_agent":{s},"watchdog":{d},"tpm":{s},"secure_boot":{s},"hyperv_enlightenments":{s},"hugepages":{s},"io_threads":{d},"disk_bps_throttle":{d},"disk_iops_throttle":{d}
        , .{
            if (v.nics[0].mac_len > 0) v.getMacAddressSlice() else "",
            std.mem.span(v.nics[1].mode.toStr()),
            if (v.nics[1].mac_len > 0) v.getNic2MacSlice() else "",
            std.mem.span(v.nics[2].mode.toStr()),
            if (v.nics[2].mac_len > 0) v.getNic3MacSlice() else "",
            v.num_displays,
            if (v.enable_serial) "true" else "false",
            if (v.virtio_rng) "true" else "false",
            if (v.guest_agent) "true" else "false",
            v.watchdog.toIndex(),
            if (v.tpm) "true" else "false",
            if (v.secure_boot) "true" else "false",
            if (v.hyperv_enlightenments) "true" else "false",
            if (v.hugepages) "true" else "false",
            v.io_threads,
            v.disk_bps_throttle,
            v.disk_iops_throttle,
        }) catch {
            w = buf.len;
            break;
        };
        w += part2a.len;

        const part2b = std.fmt.bufPrint(buf[w..],
            \\,"ballooning":{s},"host_autostart":{s},"enable_3d":{s},"gpu_device":{d},"display":{d},"display_resolution":{d},"guest_os":{d},"audio":{d},"boot_order":{d},"rtc":{d},"cpu_model":"{s}","accel":"{s}","embed_display":{s},"vnc_port":{d},"spice_port":{d},"favorite":{s},"started":{d}
        , .{
            if (v.ballooning) "true" else "false",
            if (v.host_autostart) "true" else "false",
            if (v.enable_3d) "true" else "false",
            v.gpu_device.toIndex(),
            v.display.toIndex(),
            v.display_resolution.toIndex(),
            v.guest_os.toIndex(),
            v.audio.toIndex(),
            v.boot_order.toIndex(),
            v.rtc.toIndex(),
            std.mem.span(v.cpu_model.toStr()),
            std.mem.span(v.accel.toStr()),
            if (v.embed_display) "true" else "false",
            v.vnc_port,
            v.spice_port,
            if (v.favorite) "true" else "false",
            appstate.vm_started[i],
        }) catch {
            w = buf.len;
            break;
        };
        w += part2b.len;

        // Per-NIC vnet names are user-controlled; escape each into its own buffer.
        var nv_bufs: [7][96]u8 = undefined;
        var nv_e: [7][]const u8 = undefined;
        for (0..7) |ni| nv_e[ni] = if (v.nics[ni + 1].vnet_len > 0) escapeJson(&nv_bufs[ni], v.getNicVnetSliceAny(ni + 1), "nic_vnet") else "";
        const part2c = std.fmt.bufPrint(buf[w..],
            \\,"nic4_mode":"{s}","nic4_mac":"{s}","nic5_mode":"{s}","nic5_mac":"{s}","nic6_mode":"{s}","nic6_mac":"{s}","nic7_mode":"{s}","nic7_mac":"{s}","nic8_mode":"{s}","nic8_mac":"{s}","nic2_vnet":"{s}","nic3_vnet":"{s}","nic4_vnet":"{s}","nic5_vnet":"{s}","nic6_vnet":"{s}","nic7_vnet":"{s}","nic8_vnet":"{s}"
        , .{
            std.mem.span(v.nics[3].mode.toStr()),
            if (v.nics[3].mac_len > 0) v.getNicMacSliceAny(3) else "",
            std.mem.span(v.nics[4].mode.toStr()),
            if (v.nics[4].mac_len > 0) v.getNicMacSliceAny(4) else "",
            std.mem.span(v.nics[5].mode.toStr()),
            if (v.nics[5].mac_len > 0) v.getNicMacSliceAny(5) else "",
            std.mem.span(v.nics[6].mode.toStr()),
            if (v.nics[6].mac_len > 0) v.getNicMacSliceAny(6) else "",
            std.mem.span(v.nics[7].mode.toStr()),
            if (v.nics[7].mac_len > 0) v.getNicMacSliceAny(7) else "",
            nv_e[0], nv_e[1], nv_e[2], nv_e[3], nv_e[4], nv_e[5], nv_e[6],
        }) catch {
            w = buf.len;
            break;
        };
        w += part2c.len;

        // Escape user-controlled extra-disk paths (each own buffer) so a quote
        // or backslash in a path cannot corrupt the JSON for the whole list.
        var ex0_buf: [vm.MAX_PATH]u8 = undefined;
        const ex0_e = if (v.hasExtraDisk(0)) escapeJson(&ex0_buf, v.getExtraDiskPathSlice(0), "extra0_path") else "";
        var ex1_buf: [vm.MAX_PATH]u8 = undefined;
        const ex1_e = if (v.hasExtraDisk(1)) escapeJson(&ex1_buf, v.getExtraDiskPathSlice(1), "extra1_path") else "";
        var ex2_buf: [vm.MAX_PATH]u8 = undefined;
        const ex2_e = if (v.hasExtraDisk(2)) escapeJson(&ex2_buf, v.getExtraDiskPathSlice(2), "extra2_path") else "";
        var ex3_buf: [vm.MAX_PATH]u8 = undefined;
        const ex3_e = if (v.hasExtraDisk(3)) escapeJson(&ex3_buf, v.getExtraDiskPathSlice(3), "extra3_path") else "";

        const part2d = std.fmt.bufPrint(buf[w..],
            \\,"extra0_path":"{s}","extra0_size":{d},"extra0_format":{d},"extra1_path":"{s}","extra1_size":{d},"extra1_format":{d},"extra2_path":"{s}","extra2_size":{d},"extra2_format":{d},"extra3_path":"{s}","extra3_size":{d},"extra3_format":{d},"id":"{s}","vnet":"{s}"}}
        , .{
            ex0_e,
            v.extra_disks[0].size_gb,
            v.extra_disks[0].format.toIndex(),
            ex1_e,
            v.extra_disks[1].size_gb,
            v.extra_disks[1].format.toIndex(),
            ex2_e,
            v.extra_disks[2].size_gb,
            v.extra_disks[2].format.toIndex(),
            ex3_e,
            v.extra_disks[3].size_gb,
            v.extra_disks[3].format.toIndex(),
            id_e,
            vnet_e,
        }) catch {
            w = buf.len;
            break;
        };
        w += part2d.len;
    }
    if (w >= buf.len) return 0;
    buf[w] = ']';
    w += 1;
    return w;
}

// ── Tests ───────────────────────────────────────────────────────────

test "vmrender: renderJson emits a JSON array for an empty inventory" {
    // appstate starts with vm_count == 0 in a fresh test binary.
    var buf: [256]u8 = undefined;
    const n = renderJson(&buf);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqual(@as(u8, '['), buf[0]);
}

test "vmrender: renderVmDetail rejects a non-matching request" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.RenderFailed, renderVmDetail("GET /api/other HTTP/1.1", &buf));
}
