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
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");
const netutil = @import("netutil.zig");

const parseIdx = httpreq.parseIdx;
const writeAll = httpresp.writeAll;
const logWarn = wlog.logWarn;
const setTcpNoDelay = netutil.setTcpNoDelay;
const AF_INET = netutil.AF_INET;
const SOCK_STREAM = netutil.SOCK_STREAM;
const SHUT_RDWR = netutil.SHUT_RDWR;

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
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's VNC server.
    const vnc_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (vnc_fd < 0) return;

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, vnc_port);
    addr.addr = netutil.LOOPBACK_V4;

    if (c.connect(vnc_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        logWarn("ws/vnc: connect to VM VNC port failed");
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    }
    setTcpNoDelay(vnc_fd);

    // Spawn threads for bidirectional relay.
    // `wmtx` serializes writes to `ws_fd`: both the data-relay thread
    // (writeFrame) and the control thread (writePong) write to the same
    // socket, and writeFrame emits the frame header and payload as two
    // separate write() calls — without the lock a concurrent pong can
    // interleave between them and corrupt the WebSocket frame stream.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        vnc_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .vnc_fd = vnc_fd };

    // Thread: VNC → WebSocket
    const vnc2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.vnc_fd, &buf, buf.len);
                if (n <= 0) break;
                // Relay VNC bytes to the WebSocket client as a binary frame.
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → VNC
    const ws2vnc = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
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
                if (!writeAll(ctx_ptr.vnc_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.vnc_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(vnc_fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        vnc2ws.join();
        _ = c.close(vnc_fd);
        try ws.writeClose(conn);
        return;
    };

    vnc2ws.join();
    ws2vnc.join();
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
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's SPICE server.
    const spice_fd = c.socket(AF_INET, SOCK_STREAM, 0);
    if (spice_fd < 0) return;

    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.port = std.mem.nativeToBig(u16, spice_port);
    addr.addr = netutil.LOOPBACK_V4;

    if (c.connect(spice_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
        logWarn("ws/spice: connect to VM SPICE port failed");
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    }
    setTcpNoDelay(spice_fd);

    // Spawn threads for bidirectional relay. `wmtx` serializes writes to
    // `ws_fd` (writeFrame vs writePong) — see handleWsVnc for the rationale.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        spice_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .spice_fd = spice_fd };

    // Thread: SPICE → WebSocket
    const spice2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.spice_fd, &buf, buf.len);
                if (n <= 0) break;
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .binary, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → SPICE
    const ws2spice = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
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
                if (!writeAll(ctx_ptr.spice_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.spice_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(spice_fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        spice2ws.join();
        _ = c.close(spice_fd);
        try ws.writeClose(conn);
        return;
    };

    spice2ws.join();
    ws2spice.join();
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

    // Perform WebSocket upgrade handshake.
    const accept_key = ws.parseUpgrade(req) orelse return;
    try ws.writeUpgradeResponse(conn, accept_key);

    // Connect to the VM's serial Unix socket.
    var sock_buf: [256]u8 = undefined;
    const sock_path = std.fmt.bufPrintZ(
        &sock_buf,
        "/tmp/hangar-serial-{s}.sock",
        .{vm_name_buf[0..vm_name.len]},
    ) catch return;

    const serial = usock.UnixStream.connect(sock_path) catch {
        logWarn("ws/serial: connect to VM serial socket failed");
        return;
    };

    // Spawn threads for bidirectional relay.
    const RelayCtx = struct {
        ws_fd: c.fd_t,
        serial_fd: c.fd_t,
        wmtx: sync.SpinMutex = .{},
    };
    var ctx = RelayCtx{ .ws_fd = conn, .serial_fd = serial.fd };

    // Thread: serial → WebSocket. `wmtx` serializes writes to `ws_fd`
    // (writeFrame vs writePong) — see handleWsVnc for the rationale.
    const ser2ws = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const n = c.read(ctx_ptr.serial_fd, &buf, buf.len);
                if (n <= 0) break;
                ctx_ptr.wmtx.lock();
                ws.writeFrame(ctx_ptr.ws_fd, .text, buf[0..@intCast(n)]) catch {
                    ctx_ptr.wmtx.unlock();
                    break;
                };
                ctx_ptr.wmtx.unlock();
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.ws_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        serial.close();
        try ws.writeClose(conn);
        return;
    };

    // Thread: WebSocket → serial
    const ws2ser = std.Thread.spawn(std.Thread.SpawnConfig{}, struct {
        fn run(ctx_ptr: *RelayCtx) void {
            var buf: [65536]u8 = undefined;
            while (true) {
                const hdr = ws.readFrameHeader(ctx_ptr.ws_fd) orelse break;
                if (hdr.opcode == .close) break;
                if (hdr.opcode == .ping) {
                    // Drain the ping's payload (RFC 6455 allows ≤125 bytes) before
                    // replying — leaving it on the wire would desync the next frame.
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
                if (!writeAll(ctx_ptr.serial_fd, buf[0..rlen].ptr, rlen)) break;
            }
            // Shutdown both directions so the peer thread unblocks.
            _ = c.shutdown(ctx_ptr.serial_fd, SHUT_RDWR);
        }
    }.run, .{&ctx}) catch {
        // First thread is running; shut down both FDs to unblock it.
        _ = c.shutdown(serial.fd, SHUT_RDWR);
        _ = c.shutdown(conn, SHUT_RDWR);
        ser2ws.join();
        serial.close();
        try ws.writeClose(conn);
        return;
    };

    ser2ws.join();
    ws2ser.join();
    serial.close();
}
