//! Live-migration HTTP handlers (start / status / cancel) for the daemon. Each
//! captures the VM name under vms_mutex, then issues the (fast) QMP command with
//! the lock released — never holding the lock across socket I/O.

const std = @import("std");
const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
const appstate = @import("appstate.zig");
const urlencode = @import("urlencode.zig");
const httpreq = @import("httpreq.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;

const httpresp = @import("httpresp.zig");
const HTTP_OK = httpresp.HTTP_OK;
const HTTP_NOT_FOUND = httpresp.HTTP_NOT_FOUND;
const HTTP_CONFLICT = httpresp.HTTP_CONFLICT;
const HTTP_INTERNAL_ERROR = httpresp.HTTP_INTERNAL_ERROR;

/// A migration destination must be a `tcp:` URI free of `..`, control bytes, and
/// JSON-breaking quotes/backslashes (it is echoed into a QMP command + a JSON
/// response).
pub fn isValidDest(dest: []const u8) bool {
    if (!std.mem.startsWith(u8, dest, "tcp:")) return false;
    if (std.mem.indexOf(u8, dest, "..") != null) return false;
    for (dest) |ch| {
        if (ch < 0x20) return false; // control characters
        if (ch == '"' or ch == '\\') return false; // JSON string break-out
    }
    return true;
}

/// Start a live migration to the `dest=` URI in the body.
pub fn start(req: []const u8) ![]const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var dest_buf: [512]u8 = undefined;
    var name_len: usize = 0;
    var dest: []const u8 = "";
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.isAlive()) return "not running";
        const body = httpreq.getBody(req) orelse return "no body";
        var raw_buf: [512]u8 = undefined;
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const raw = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "dest")) {
                const d = if (raw.len <= raw_buf.len) urlencode.urlDecode(&raw_buf, raw) else raw;
                const n = @min(d.len, dest_buf.len);
                @memcpy(dest_buf[0..n], d[0..n]);
                dest = dest_buf[0..n];
            }
        }
        if (dest.len == 0) return "no dest";
        if (!isValidDest(dest)) return "bad dest";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len or !qmp.isPathSafeName(nm)) return "sock err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "sock err";
    client.connect(sock) catch |e| {
        logOpErr("migrate", e, name_buf[0..name_len]);
        return "qmp err";
    };
    defer client.disconnect();
    logAudit("migrate", name_buf[0..name_len]);
    client.liveMigrate(dest) catch |e| {
        logOpErr("migrate", e, name_buf[0..name_len]);
        return "migrate err";
    };
    return "{\"status\":\"started\"}";
}

/// Map a `status` JSON body to an HTTP code (success stays 200; error payloads
/// get the same 4xx/5xx the text/plain mapper assigns the equivalent tokens).
pub fn statusHttpCode(body: []const u8) u16 {
    if (std.mem.indexOf(u8, body, "\"status\":\"error\"") == null) return HTTP_OK;
    if (std.mem.indexOf(u8, body, "invalid idx") != null or std.mem.indexOf(u8, body, "bad idx") != null) return HTTP_NOT_FOUND;
    if (std.mem.indexOf(u8, body, "not running") != null) return HTTP_CONFLICT;
    return HTTP_INTERNAL_ERROR;
}

/// Query current migration status; returns a JSON body into `buf`.
pub fn status(req: []const u8, buf: []u8) []const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"status\":\"error\",\"error\":\"invalid idx\"}";
        if (idx >= appstate.vm_count) return "{\"status\":\"error\",\"error\":\"bad idx\"}";
        const v = &appstate.vms[idx];
        if (!v.isAlive()) return "{\"status\":\"error\",\"error\":\"not running\"}";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len or !qmp.isPathSafeName(nm)) return "{\"status\":\"error\",\"error\":\"no socket\"}";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "{\"status\":\"error\",\"error\":\"no socket\"}";
    client.connect(sock) catch return "{\"status\":\"error\",\"error\":\"qmp connect\"}";
    defer client.disconnect();

    var status_buf: [128]u8 = undefined;
    const s = client.queryMigrateStatus(&status_buf) catch return "{\"status\":\"error\",\"error\":\"qmp query\"}";
    const resp = std.fmt.bufPrint(buf, "{{\"status\":\"{s}\"}}", .{s}) catch return "{\"status\":\"error\"}";
    return buf[0..resp.len];
}

/// Cancel an active migration.
pub fn cancel(req: []const u8) ![]const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "POST /api/vms/") orelse return "invalid";
        if (idx >= appstate.vm_count) return "invalid idx";
        const v = &appstate.vms[idx];
        if (!v.isAlive()) return "not running";
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len or !qmp.isPathSafeName(nm)) return "sock err";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var client = qmp.QmpClient{};
    var sock_buf: [256]u8 = undefined;
    const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse return "sock err";
    client.connect(sock) catch |e| {
        logOpErr("migrate cancel", e, name_buf[0..name_len]);
        return "qmp err";
    };
    defer client.disconnect();
    client.cancelMigrate() catch |e| {
        logOpErr("migrate cancel", e, name_buf[0..name_len]);
        return "cancel err";
    };
    logAudit("migrate cancel", name_buf[0..name_len]);
    return "ok";
}

// ── Tests ───────────────────────────────────────────────────────────

test "migrate: isValidDest enforces tcp + rejects injection" {
    try std.testing.expect(isValidDest("tcp:1.2.3.4:4444"));
    try std.testing.expect(!isValidDest("exec:nc evil"));
    try std.testing.expect(!isValidDest("tcp:a\"b"));
    try std.testing.expect(!isValidDest("tcp:../x"));
}

test "migrate: statusHttpCode maps error payloads" {
    try std.testing.expectEqual(@as(u16, 200), statusHttpCode("{\"status\":\"active\"}"));
    try std.testing.expectEqual(@as(u16, 404), statusHttpCode("{\"status\":\"error\",\"error\":\"bad idx\"}"));
    try std.testing.expectEqual(@as(u16, 409), statusHttpCode("{\"status\":\"error\",\"error\":\"not running\"}"));
    try std.testing.expectEqual(@as(u16, 500), statusHttpCode("{\"status\":\"error\",\"error\":\"qmp query\"}"));
}

test "migrate: start/cancel return 'invalid' on non-matching request" {
    try std.testing.expect(appstate.vm_count == 0);
    try std.testing.expectEqualStrings("invalid", try start("POST /api/other HTTP/1.1"));
    try std.testing.expectEqualStrings("invalid", try cancel("POST /api/other HTTP/1.1"));
}

test "fuzz: isValidDest accepts nothing it claims is unsafe" {
    // A "valid" dest is echoed into a QMP command + a JSON response; a regression
    // that admitted a quote/backslash/control byte or `..` must fail this check.
    var prng = std.Random.DefaultPrng.init(0x7C_9D_E5_70);
    const rnd = prng.random();
    const alphabet = "tcp:0123.9 \t\n\x00\x1f\"\\/:ABCabc-";
    var input: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, input.len);
        const structured = (iter & 1) == 0;
        for (input[0..len]) |*c| {
            c.* = if (structured) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const dest = input[0..len];
        if (isValidDest(dest)) {
            try std.testing.expect(std.mem.startsWith(u8, dest, "tcp:"));
            try std.testing.expect(std.mem.indexOf(u8, dest, "..") == null);
            for (dest) |ch| try std.testing.expect(ch >= 0x20 and ch != '"' and ch != '\\');
        }
    }
}
