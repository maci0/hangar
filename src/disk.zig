//! Primary-disk maintenance HTTP handlers: info / compact / resize. All run the
//! blocking qemu-img with vms_mutex released (capture disk path under the lock,
//! act unlocked); stopped VMs only for the mutating ops (the image is rewritten).

const std = @import("std");
const vm = @import("vm.zig");
const qemu = @import("qemu.zig");
const persist = @import("persist.zig");
const appstate = @import("appstate.zig");
const httpreq = @import("httpreq.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;
const logSaveErr = wlog.logSaveErr;

/// Primary-disk virtual + actual (on-disk allocated) byte sizes via qemu-img.
/// Returns a JSON object (or `{"error":...}`) into `out`.
pub fn info(req: []const u8, out: []u8) []const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"error\":\"invalid\"}";
        if (idx >= appstate.vm_count) return "{\"error\":\"invalid idx\"}";
        const dp = appstate.vms[idx].getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "{\"error\":\"no disk\"}";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
    }
    const di = qemu.diskInfo(disk_buf[0..disk_len], std.heap.page_allocator) orelse return "{\"error\":\"unavailable\"}";
    return std.fmt.bufPrint(out, "{{\"virtual_bytes\":{d},\"actual_bytes\":{d}}}", .{ di.virtual_bytes, di.actual_bytes }) catch "{\"error\":\"render\"}";
}

/// Compact the primary disk in place (qemu-img convert). Stopped VMs only;
/// reclaims qcow2 space freed inside the guest, virtual size unchanged.
pub fn compact(req: []const u8) ![]const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var fmt: vm.DiskFormat = .qcow2;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        if (v.isAlive()) return "vm running";
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "compact err";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
        const nm = v.getNameSlice();
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        fmt = v.disk_format;
    }
    qemu.compactDiskImage(disk_buf[0..disk_len], fmt, std.heap.page_allocator) catch |e| {
        logOpErr("disk compact", e, name_buf[0..name_len]);
        return "compact err";
    };
    logAudit("disk compact", name_buf[0..name_len]);
    return "ok";
}

/// Grow the primary disk (qemu-img resize). Stopped VMs only, grow-only.
/// Records the new size after re-validating the VM under the lock.
pub fn resize(req: []const u8) ![]const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var new_gb: u32 = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        if (v.isAlive()) return "vm running";
        const body = httpreq.getBody(req) orelse return "no body";
        var size_str: []const u8 = "";
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const val = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "size")) size_str = val;
        }
        const parsed = std.fmt.parseInt(u32, size_str, 10) catch return "bad size";
        new_gb = vm.clampDiskSize(parsed);
        if (new_gb <= v.disk_size_gb) return "shrink not allowed"; // grow only
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "resize err";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
        const nm = v.getNameSlice();
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
    }

    qemu.resizeDiskImage(disk_buf[0..disk_len], new_gb, std.heap.page_allocator) catch |e| {
        logOpErr("disk resize", e, name_buf[0..name_len]);
        return "resize err";
    };

    // Record the new size, re-validating the VM didn't move/disappear while
    // unlocked. If it did, the image is already grown, report success.
    appstate.vms_mutex.lock();
    defer appstate.vms_mutex.unlock();
    if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
        appstate.vms[idx_saved].disk_size_gb = new_gb;
        persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
            logSaveErr("disk.resize: ", e);
            return "save failed";
        };
    }
    logAudit("disk resize", name_buf[0..name_len]);
    return "ok";
}

// ── Tests ───────────────────────────────────────────────────────────

test "disk: handlers reject a non-matching request" {
    try std.testing.expect(appstate.vm_count == 0);
    try std.testing.expectEqualStrings("invalid", try compact("POST /api/other HTTP/1.1"));
    try std.testing.expectEqualStrings("invalid", try resize("POST /api/other HTTP/1.1"));
    var buf: [160]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, info("GET /api/other HTTP/1.1", &buf), "error") != null);
}
