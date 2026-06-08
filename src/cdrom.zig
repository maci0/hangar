//! CD/ISO media HTTP handlers: change / eject. A running VM swaps or ejects media
//! live via QMP (with vms_mutex released); a stopped VM records iso_path and
//! persists it (mounted on next boot).

const std = @import("std");
const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
const persist = @import("persist.zig");
const appstate = @import("appstate.zig");
const urlencode = @import("urlencode.zig");
const httpreq = @import("httpreq.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;
const logSaveErr = wlog.logSaveErr;

/// Reject a CD/ISO path that could inject `-drive` options (comma) or carry
/// control bytes; `..` is rejected too. Empty is the caller's "eject" signal.
pub fn isSafePath(p: []const u8) bool {
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    for (p) |ch| {
        if (ch == ',' or ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Change the mounted CD/ISO. Running VM swaps live via QMP; stopped VM records
/// the new iso_path (mounted next boot).
pub fn change(req: []const u8) ![]const u8 {
    var decode_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var was_alive = false;
    var decoded: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        const body = httpreq.getBody(req) orelse return "no body";
        var path: []const u8 = "";
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const val = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "path")) path = val;
        }
        if (path.len == 0) return "no path";
        decoded = urlencode.urlDecode(&decode_buf, path);
        if (decoded.len == 0 or !isSafePath(decoded)) return "bad path";
        was_alive = v.isAlive();
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "change err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
        if (was_alive and !qmp.isPathSafeName(nm)) return "change err";
    }

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "change err";
        client.connect(sock) catch |e| {
            logOpErr("cdrom change", e, name_buf[0..name_len]);
            return "change err";
        };
        defer client.disconnect();
        client.changeCdrom(decoded) catch |e| {
            logOpErr("cdrom change", e, name_buf[0..name_len]);
            return "change err";
        };
    } else {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx_saved].setIsoPath(decoded);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("cdrom.change: ", e);
                return "save failed";
            };
        }
    }
    logAudit("cdrom change", name_buf[0..name_len]);
    return "ok";
}

/// Eject the mounted CD/ISO. Running VM ejects live via QMP; stopped VM clears
/// its iso_path.
pub fn eject(req: []const u8) ![]const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var idx_saved: usize = 0;
    var was_alive = false;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        was_alive = v.isAlive();
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "eject err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        idx_saved = idx;
        if (was_alive and !qmp.isPathSafeName(nm)) return "eject err";
    }

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "eject err";
        client.connect(sock) catch |e| {
            logOpErr("cdrom eject", e, name_buf[0..name_len]);
            return "eject err";
        };
        defer client.disconnect();
        client.ejectCdrom() catch |e| {
            logOpErr("cdrom eject", e, name_buf[0..name_len]);
            return "eject err";
        };
    } else {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx_saved < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx_saved].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx_saved].clearIsoPath();
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("cdrom.eject: ", e);
                return "save failed";
            };
        }
    }
    logAudit("cdrom eject", name_buf[0..name_len]);
    return "ok";
}

// ── Tests ───────────────────────────────────────────────────────────

test "cdrom: isSafePath rejects comma/control/dotdot" {
    try std.testing.expect(isSafePath("/iso/x.iso"));
    try std.testing.expect(!isSafePath("/a,b.iso"));
    try std.testing.expect(!isSafePath("/a/../b"));
    try std.testing.expect(!isSafePath("a\x01b"));
}

test "cdrom: change/eject reject a non-matching request" {
    try std.testing.expect(appstate.vm_count == 0);
    try std.testing.expectEqualStrings("invalid", try change("POST /api/other HTTP/1.1"));
    try std.testing.expectEqualStrings("invalid", try eject("POST /api/other HTTP/1.1"));
}
