//! Snapshot HTTP handlers (take / list / revert / delete) for the daemon.
//! Live VMs go through QMP (savevm/loadvm/delvm) since the qcow2 is write-locked;
//! stopped VMs use offline `qemu-img`. All disk-path/name capture happens under
//! vms_mutex, then the (blocking) QMP/qemu-img I/O runs with the lock released.

const std = @import("std");
const vm = @import("vm.zig");
const qemu = @import("qemu.zig");
const qmp = @import("qmp.zig");
const appstate = @import("appstate.zig");
const urlencode = @import("urlencode.zig");
const snapparse = @import("snapparse.zig");
const httpreq = @import("httpreq.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;

pub const MAX_TAG_LEN = 255;

/// A snapshot tag is safe if non-empty, within length, control-byte-free, and
/// contains no `..` (it reaches qemu-img / QMP HMP).
pub fn validateTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > MAX_TAG_LEN) return false;
    for (tag) |b| {
        if (b < 0x20) return false; // reject control characters
    }
    if (std.mem.indexOf(u8, tag, "..") != null) return false;
    return true;
}

/// Extract + URL-decode + validate the `tag` form field into `decode_buf`.
/// Returns the decoded tag, or an error token to return to the client.
fn parseTag(req: []const u8, decode_buf: []u8) error{Token}![]const u8 {
    const body = httpreq.getBody(req) orelse return error.Token;
    var tag: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = kv.next() orelse continue;
        const val = kv.next() orelse continue;
        if (std.mem.eql(u8, key, "tag")) tag = val;
    }
    if (tag.len == 0) return error.Token;
    const decoded = urlencode.urlDecode(decode_buf, tag);
    if (!validateTag(decoded)) return error.Token;
    return decoded;
}

pub fn take(req: []const u8) ![]const u8 {
    var decode_buf: [MAX_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var was_alive = false;
    const decoded = blk: {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        const decoded = parseTag(req, &decode_buf) catch return "no name";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "create err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        was_alive = v.isAlive();
        if (was_alive) {
            // Live VM: savevm via the running QMP monitor (qcow2 is write-locked).
            if (!qmp.isPathSafeName(nm)) return "create err";
        } else {
            const dp = v.getDiskPathSlice();
            if (dp.len == 0 or dp.len >= disk_buf.len) return "create err";
            @memcpy(disk_buf[0..dp.len], dp);
            disk_len = dp.len;
        }
        break :blk decoded;
    };

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "create err";
        client.connect(sock) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
        defer client.disconnect();
        client.saveSnapshot(decoded) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
    } else {
        qemu.snapshotCreate(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot take", e, name_buf[0..name_len]);
            return "create err";
        };
    }
    logAudit("snapshot take", name_buf[0..name_len]);
    return "ok";
}

pub fn list(req: []const u8, raw_buf: []u8) []const u8 {
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
        // Capture the disk path; run qemu-img with the lock RELEASED (it's a
        // blocking subprocess). `-U` lets it read a running VM's locked image.
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "no disk";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
    }

    const n = qemu.snapshotList(disk_buf[0..disk_len], raw_buf, std.heap.page_allocator) catch |e| blk: {
        logOpErr("snapshot list", e, name_buf[0..name_len]);
        break :blk 0;
    };
    if (n == 0 or n > raw_buf.len) return "(none)";

    const nodes = snapparse.parse(raw_buf[0..n]);
    if (nodes.count == 0) return "(none)";

    // Emit one snapshot per line into raw_buf (reused for output): the tag,
    // then: when the table carried one, a tab and the creation timestamp.
    var w: usize = 0;
    for (0..nodes.count) |i| {
        const name = nodes.nameSlice(i);
        const date = nodes.dateSlice(i);
        const need = name.len + (if (date.len > 0) date.len + 1 else 0) + 1;
        if (w + need > raw_buf.len) break;
        @memcpy(raw_buf[w..][0..name.len], name);
        w += name.len;
        if (date.len > 0) {
            raw_buf[w] = '\t';
            w += 1;
            @memcpy(raw_buf[w..][0..date.len], date);
            w += date.len;
        }
        raw_buf[w] = '\n';
        w += 1;
    }
    return raw_buf[0..w];
}

pub fn revert(req: []const u8) ![]const u8 {
    var decode_buf: [MAX_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    const decoded = blk: {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        if (v.isAlive()) return "vm running";
        const decoded = parseTag(req, &decode_buf) catch return "no name";
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
        // VM is guaranteed stopped → offline qemu-img revert with the lock released.
        const dp = v.getDiskPathSlice();
        if (dp.len == 0 or dp.len >= disk_buf.len) return "apply err";
        @memcpy(disk_buf[0..dp.len], dp);
        disk_len = dp.len;
        break :blk decoded;
    };

    qemu.snapshotApply(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
        logOpErr("snapshot revert", e, name_buf[0..name_len]);
        return "apply err";
    };
    logAudit("snapshot revert", name_buf[0..name_len]);
    return "ok";
}

pub fn delete(req: []const u8) ![]const u8 {
    var decode_buf: [MAX_TAG_LEN + 1]u8 = undefined;
    var disk_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var disk_len: usize = 0;
    var name_len: usize = 0;
    var was_alive = false;
    const decoded = blk: {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.hasDisk()) return "no disk";
        const decoded = parseTag(req, &decode_buf) catch return "no name";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len) return "delete err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
        was_alive = v.isAlive();
        if (was_alive) {
            if (!qmp.isPathSafeName(nm)) return "delete err"; // delvm via QMP
        } else {
            const dp = v.getDiskPathSlice();
            if (dp.len == 0 or dp.len >= disk_buf.len) return "delete err";
            @memcpy(disk_buf[0..dp.len], dp);
            disk_len = dp.len;
        }
        break :blk decoded;
    };

    if (was_alive) {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "delete err";
        client.connect(sock) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
        defer client.disconnect();
        client.deleteSnapshot(decoded) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
    } else {
        qemu.snapshotDelete(disk_buf[0..disk_len], decoded, std.heap.page_allocator) catch |e| {
            logOpErr("snapshot delete", e, name_buf[0..name_len]);
            return "delete err";
        };
    }
    logAudit("snapshot delete", name_buf[0..name_len]);
    return "ok";
}

// ── Tests ───────────────────────────────────────────────────────────

test "snapshots: validateTag rejects empty/control/dotdot, accepts normal" {
    try std.testing.expect(validateTag("snap1"));
    try std.testing.expect(!validateTag(""));
    try std.testing.expect(!validateTag("a\nb"));
    try std.testing.expect(!validateTag("a/../b"));
    var long: [MAX_TAG_LEN + 2]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expect(!validateTag(&long));
}

test "snapshots: handlers return 'invalid' on a non-matching request" {
    try std.testing.expect(appstate.vm_count == 0);
    try std.testing.expectEqualStrings("invalid", try take("POST /api/other HTTP/1.1"));
    try std.testing.expectEqualStrings("invalid", try revert("POST /api/other HTTP/1.1"));
    try std.testing.expectEqualStrings("invalid", try delete("POST /api/other HTTP/1.1"));
}

test "fuzz: validateTag accepts nothing it claims is unsafe" {
    // A "valid" tag reaches qemu-img / QMP HMP; a regression that whitelisted a
    // null/control byte, `..`, empty, or over-length tag must fail this check.
    var prng = std.Random.DefaultPrng.init(0x5A_AF_7A_67);
    const rnd = prng.random();
    const alphabet = "snap.0123 \t\n\x00\x1f-_ABCabc";
    var input: [MAX_TAG_LEN + 8]u8 = undefined;
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len);
        const structured = (iter & 1) == 0;
        for (input[0..len]) |*c| {
            c.* = if (structured) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const tag = input[0..len];
        if (validateTag(tag)) {
            try std.testing.expect(tag.len != 0 and tag.len <= MAX_TAG_LEN);
            for (tag) |b| try std.testing.expect(b >= 0x20);
            try std.testing.expect(std.mem.indexOf(u8, tag, "..") == null);
        }
    }
}
