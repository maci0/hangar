//! qemu-guest-agent query handler: report the guest's IPv4 addresses. Best-effort
//! — empty result when the VM is stopped, the agent isn't running, or it doesn't
//! answer within the read timeout (never hangs the serving thread).

const std = @import("std");
const c = std.c;
const vm = @import("vm.zig");
const appstate = @import("appstate.zig");
const usock = @import("usock.zig");
const httpreq = @import("httpreq.zig");
const qmp = @import("qmp.zig");

const parseIdx = httpreq.parseIdx;

// Socket-option constants (Linux). Kept local to avoid importing web_server.
const SOL_SOCKET: c_int = 1;
const SO_RCVTIMEO: c_int = 20;

/// Extract non-loopback IPv4 addresses from a guest-agent
/// `guest-network-get-interfaces` reply into `out` as a comma-separated list.
/// Pure (no I/O) so it is unit-testable against a captured GA response.
pub fn parseIpv4s(json: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var cur = json;
    const key = "\"ip-address\":\"";
    while (std.mem.indexOf(u8, cur, key)) |at| {
        const after = cur[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const addr = after[0..end];
        cur = after[end..];
        // IPv4 only (has '.', no ':'); skip loopback.
        if (std.mem.indexOfScalar(u8, addr, ':') != null) continue;
        if (std.mem.indexOfScalar(u8, addr, '.') == null) continue;
        if (std.mem.startsWith(u8, addr, "127.")) continue;
        // The `ip-address` field is supplied by the (untrusted) guest agent. Accept
        // strictly digit+dot bytes so a hostile value can never carry `"` `\` or
        // markup that would corrupt the emitted JSON response or, if ever rendered
        // as HTML, inject script host-side (CWE-116/CWE-79).
        {
            var ok = true;
            for (addr) |ch| {
                if (!(ch >= '0' and ch <= '9') and ch != '.') {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
        }
        if (w != 0) {
            if (w >= out.len) break;
            out[w] = ',';
            w += 1;
        }
        if (w + addr.len > out.len) break;
        @memcpy(out[w .. w + addr.len], addr);
        w += addr.len;
    }
    return out[0..w];
}

/// Query the guest's IPv4 addresses via the guest-agent socket; return
/// `{"ips":"a,b"}` (empty on any failure).
pub fn query(req: []const u8, out: []u8) []const u8 {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse return "{\"ips\":\"\"}";
        if (idx >= appstate.vm_count) return "{\"ips\":\"\"}";
        const v = &appstate.vms[idx];
        if (!v.isAlive() or !v.guest_agent) return "{\"ips\":\"\"}";
        const nm = v.getNameSlice();
        if (nm.len == 0 or nm.len > name_buf.len) return "{\"ips\":\"\"}";
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    // Defense in depth: a hand-edited config name must not traverse out of /tmp.
    if (!qmp.isPathSafeName(name_buf[0..name_len])) return "{\"ips\":\"\"}";
    var sock_buf: [128]u8 = undefined;
    const sock = std.fmt.bufPrint(&sock_buf, "/tmp/hangar-ga-{s}.sock", .{name_buf[0..name_len]}) catch return "{\"ips\":\"\"}";
    const stream = usock.UnixStream.connect(sock) catch return "{\"ips\":\"\"}";
    defer stream.close();
    // Bound the read so a missing/unresponsive agent can't pin the thread.
    const tv: c.timeval = .{ .sec = 2, .usec = 0 };
    _ = c.setsockopt(stream.fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));
    _ = stream.write("{\"execute\":\"guest-network-get-interfaces\"}\n") catch return "{\"ips\":\"\"}";
    // The reply (newline-terminated QGA JSON) can span multiple reads on a
    // multi-NIC guest; accumulate until the terminating newline, buffer full, or
    // the 2s read timeout fires.
    var resp: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len) {
        const n = stream.read(resp[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, resp[0..total], '\n') != null) break;
    }
    if (total == 0) return "{\"ips\":\"\"}";
    var ip_buf: [512]u8 = undefined;
    const ips = parseIpv4s(resp[0..total], &ip_buf);
    return std.fmt.bufPrint(out, "{{\"ips\":\"{s}\"}}", .{ips}) catch "{\"ips\":\"\"}";
}

// ── Tests ───────────────────────────────────────────────────────────

test "fuzz: parseIpv4s never panics and stays within the output buffer" {
    var prng = std.Random.DefaultPrng.init(0x6A11_0001);
    const rnd = prng.random();
    var jbuf: [2048]u8 = undefined;
    var out: [64]u8 = undefined; // deliberately small to exercise the bound
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, jbuf.len);
        for (jbuf[0..len]) |*b| b.* = rnd.int(u8);
        const r = parseIpv4s(jbuf[0..len], &out);
        std.debug.assert(r.len <= out.len);
    }
}

test "guestagent: parseIpv4s extracts non-loopback IPv4s" {
    var out: [128]u8 = undefined;
    const sample = "{\"return\":[{\"ip-address\":\"127.0.0.1\"},{\"ip-address\":\"192.168.1.5\"},{\"ip-address\":\"fe80::1\"}]}";
    try std.testing.expectEqualStrings("192.168.1.5", parseIpv4s(sample, &out));
}

test "guestagent: parseIpv4s empty when none, joins multiple" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", parseIpv4s("{\"return\":[]}", &out));
    const s = "{\"return\":[{\"ip-address\":\"192.168.1.5\"},{\"ip-address\":\"10.1.1.2\"}]}";
    try std.testing.expectEqualStrings("192.168.1.5,10.1.1.2", parseIpv4s(s, &out));
}

test "guestagent: parseIpv4s rejects non-IPv4 bytes from a hostile guest agent" {
    var out: [128]u8 = undefined;
    // Trailing backslash / quote-adjacent injection and markup must be dropped,
    // keeping only the genuine address.
    const s = "{\"return\":[{\"ip-address\":\"1.2.3\\\\\"},{\"ip-address\":\"a.<b>\"},{\"ip-address\":\"192.168.1.5\"}]}";
    try std.testing.expectEqualStrings("192.168.1.5", parseIpv4s(s, &out));
}

test "guestagent: query returns empty json for a non-matching request" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"ips\":\"\"}", query("GET /api/other HTTP/1.1", &out));
}
