//! WebSocket relay proxies: bridge a browser WebSocket to a VM's VNC/SPICE TCP
//! port or serial Unix socket. Each spawns two relay threads (in/out) sharing a
//! write mutex on the WS fd. Auth is enforced by the caller (auth.wsAuthOk).

const std = @import("std");
const c = std.c;
const vm = @import("vm.zig");
const appstate = @import("appstate.zig");
const ws = @import("ws.zig");
const usock = @import("usock.zig");
const sync = @import("sync.zig");
const httpreq = @import("httpreq.zig");
const qmp = @import("qmp.zig");
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");
const netutil = @import("netutil.zig");
const appio = @import("appio.zig");

const parseIdx = httpreq.parseIdx;
const writeAll = httpresp.writeAll;
const logWarn = wlog.logWarn;
const setTcpNoDelay = netutil.setTcpNoDelay;
const AF_INET = netutil.AF_INET;
const SOCK_STREAM = netutil.SOCK_STREAM;
const SHUT_RDWR = netutil.SHUT_RDWR;

/// Shared relay state: one WebSocket fd, one peer fd (VNC/SPICE TCP or serial
/// Unix socket), and `wmtx`, which serializes writes to `ws_fd`: both the
/// data-relay thread (writeFrame) and the control path (writePong) write to
/// the same socket, and writeFrame emits the frame header and payload as two
/// separate write() calls, without the lock a concurrent pong can interleave
/// between them and corrupt the WebSocket frame stream.
const RelayCtx = struct {
    ws_fd: c.fd_t,
    peer_fd: c.fd_t,
    wmtx: sync.SpinMutex = .{},
};

const RelayThreads = struct { peer2ws: std.Thread, ws2peer: std.Thread };

/// Spawn the bidirectional relay threads between a WebSocket and a raw peer
/// fd. `ws_data` selects the WS opcode for data frames (.binary for
/// VNC/SPICE, .text for serial). On error both directions have been shut
/// down and no thread is left running; fd closing stays with the caller.
fn spawnRelayThreads(ws_data: ws.Opcode, ctx: *RelayCtx) !RelayThreads {
    const peer2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx, data_opcode: ws.Opcode) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.peer_fd, &buf, buf.len);
                if (n <= 0) break;
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, data_opcode, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{ ctx, ws_data }) catch return error.ThreadSpawnFailed;

    const ws2peer = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying: leaving it on the wire would desync the next frame.
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    ctx_ptr.wmtx.lock();
                    ws.writePong(ctx_ptr.ws_fd) catch {
                        ctx_ptr.wmtx.unlock();
                        break;
                    };
                    ctx_ptr.wmtx.unlock();
                    continue;
                }
                // A pong may also carry a payload; consume it to stay frame-aligned.
                if (hdr.opcode == .pong) {
                    _ = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                    continue;
                }
                const rlen = ws.readFramePayload(ctx_ptr.ws_fd, &buf, hdr) orelse break;
                if (rlen == 0) continue;
                if (!writeAll(ctx_ptr.peer_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.peer_fd, SHUT_RDWR);
        }
    }.run, .{ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(ctx.peer_fd, SHUT_RDWR);
        _ = c.shutdown(ctx.ws_fd, SHUT_RDWR);
        peer2ws.join();
        return error.ThreadSpawnFailed;
    };

    return .{ .peer2ws = peer2ws, .ws2peer = ws2peer };
}

/// Handle WebSocket VNC proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's VNC port,
/// and spawns bidirectional relay threads.
pub fn vnc(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/vnc/<idx>
    const idx = parseIdx(req, "GET /ws/vnc/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return;
    }
    const vnc_port = v.vnc_port;
    appstate.vms_mutex.unlock();

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key, req);

    // Connect to the VM's VNC server. QEMU reports "running" the moment it
    // forks, but its display listener comes up a beat later, a console that
    // auto-connects on the first running poll would race it and get refused.
    // Retry briefly (4s budget, 40ms steps, fresh socket per attempt: a failed
    // connect leaves the fd unusable) before failing the upgrade.
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, vnc_port);
    addr.addr = netutil.LOOPBACK_V4;

    var vnc_fd: c.fd_t = -1;
    var waited_ms: u32 = 0;
    while (true) {
        vnc_fd = c.socket(AF_INET, SOCK_STREAM, 0);
        if (vnc_fd < 0) return;
        if (c.connect(vnc_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0) break;
        _ = c.close(vnc_fd);
        if (waited_ms >= 4000) {
            var wb: [96]u8 = undefined;
            logWarn(std.fmt.bufPrint(&wb, "ws/vnc: connect failed vm[{d}] port={d}", .{ idx, vnc_port }) catch "ws/vnc: connect failed");
            try ws.writeClose(conn);
            return;
        }
        appio.sleepMs(40);
        waited_ms += 40;
    }
    setTcpNoDelay(vnc_fd);

    var ctx = RelayCtx{ .ws_fd = conn, .peer_fd = vnc_fd };
    const threads = spawnRelayThreads(.binary, &ctx) catch {
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    };
    threads.peer2ws.join();
    threads.ws2peer.join();
    _ = c.close(vnc_fd);
}

/// Handle WebSocket SPICE proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's SPICE port,
/// and spawns bidirectional relay threads.
pub fn spice(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/spice/<idx>
    const idx = parseIdx(req, "GET /ws/spice/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return;
    }
    const spice_port = v.spice_port;
    appstate.vms_mutex.unlock();

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key, req);

    // Connect to the VM's SPICE server. QEMU reports "running" the moment it
    // forks, but its display listener comes up a beat later, a console that
    // auto-connects on the first running poll would race it and get refused.
    // Retry briefly (4s budget, 40ms steps, fresh socket per attempt: a failed
    // connect leaves the fd unusable) before failing the upgrade.
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, spice_port);
    addr.addr = netutil.LOOPBACK_V4;

    var spice_fd: c.fd_t = -1;
    var waited_ms: u32 = 0;
    while (true) {
        spice_fd = c.socket(AF_INET, SOCK_STREAM, 0);
        if (spice_fd < 0) return;
        if (c.connect(spice_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0) break;
        _ = c.close(spice_fd);
        if (waited_ms >= 4000) {
            var wb: [96]u8 = undefined;
            logWarn(std.fmt.bufPrint(&wb, "ws/spice: connect failed vm[{d}] port={d}", .{ idx, spice_port }) catch "ws/spice: connect failed");
            try ws.writeClose(conn);
            return;
        }
        appio.sleepMs(40);
        waited_ms += 40;
    }
    setTcpNoDelay(spice_fd);

    var ctx = RelayCtx{ .ws_fd = conn, .peer_fd = spice_fd };
    const threads = spawnRelayThreads(.binary, &ctx) catch {
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    };
    threads.peer2ws.join();
    threads.ws2peer.join();
    _ = c.close(spice_fd);
}

/// Handle WebSocket Serial Console proxy request.
/// Upgrades the connection to WebSocket, connects to the VM's serial
/// Unix socket, and spawns bidirectional relay threads.
pub fn serialConsole(conn: c.fd_t, req: []const u8) !void {
    // Parse VM index from URL: GET /ws/serial/<idx>
    const idx = parseIdx(req, "GET /ws/serial/") orelse return;
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return;
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive() or !v.enable_serial or !v.hasName()) {
        appstate.vms_mutex.unlock();
        return;
    }
    var vm_name_buf: [vm.MAX_NAME]u8 = undefined;
    const vm_name = v.getNameSlice();
    @memcpy(vm_name_buf[0..vm_name.len], vm_name);
    appstate.vms_mutex.unlock();

    // Defense in depth: the name is interpolated into a /tmp socket path. A
    // hostile name from a hand-edited vms.json must not escape via traversal
    // (the same guard handleVmLog and the other handlers apply).
    if (!qmp.isPathSafeName(vm_name_buf[0..vm_name.len])) return;

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key, req);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/hangar-serial-{s}.sock",
        .{vm_name_buf[0..vm_name.len]},
    ) catch return;

    const serial = usock.UnixStream.connect(sock_path) catch {
        var wb: [128]u8 = undefined;
        logWarn(std.fmt.bufPrint(&wb, "ws/serial: connect failed vm[{d}] sock={s}", .{ idx, sock_path }) catch "ws/serial: connect failed");
        return;
    };

    var ctx = RelayCtx{ .ws_fd = conn, .peer_fd = serial.fd };
    const threads = spawnRelayThreads(.text, &ctx) catch {
        serial.close();
        try ws.writeClose(conn);
        return;
    };
    threads.peer2ws.join();
    threads.ws2peer.join();
    serial.close();
}

// ── Tests ───────────────────────────────────────────────────────────

test "fuzz: relay entry points never panic on random request bytes" {
    const std_t = @import("std");
    // appstate.vm_count is 0 in the hermetic test build, so every idx rejects
    // before any socket work; this asserts the parse/reject paths don't crash.
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var prng = std_t.Random.DefaultPrng.init(0x5EED_5EED);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        vnc(fds[0], buf[0..len]) catch {};
        spice(fds[0], buf[0..len]) catch {};
        serialConsole(fds[0], buf[0..len]) catch {};
    }
}

test "wsproxy: well-formed serial request for an out-of-range idx rejects cleanly" {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try serialConsole(fds[0], "GET /ws/serial/999 HTTP/1.1\r\nHost: x\r\n\r\n");
    try vnc(fds[0], "GET /ws/vnc/999 HTTP/1.1\r\nHost: x\r\n\r\n");
}
