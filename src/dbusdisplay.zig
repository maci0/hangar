// SPDX-License-Identifier: MIT
//! Phase-1 QEMU dbus-display capture (docs/VIDEO-PIPELINE.md).
//!
//! Attaches to a VM launched with `-display dbus,p2p=yes`: passes one end of a
//! socketpair to QEMU via QMP `getfd` + `add_client` (SCM_RIGHTS), performs the
//! client side of the D-Bus AUTH EXTERNAL handshake, registers a Listener via
//! `org.qemu.Display1.Console.RegisterListener(fd)`, then serves the listener
//! connection: parses incoming method calls (Scanout/Update/ScanoutMap/...),
//! replies METHOD_RETURN, harvests+closes any passed fds, and logs frame
//! cadence. The hand-rolled D-Bus marshal/parse below covers exactly the
//! subset this needs — no libdbus/glib (project constraint).

const std = @import("std");
const c = std.c;
const appio = @import("appio.zig");
const wlog = @import("wlog.zig");
const qmp = @import("qmp.zig");
const sync = @import("sync.zig");
const vm = @import("vm.zig");
const qemu = @import("qemu.zig");
const ws = @import("ws.zig");

const SOL_SOCKET: c_int = 1;
const SCM_RIGHTS: c_int = 1;

// ── D-Bus wire format (subset) ──────────────────────────────────────
// Little-endian messages only ('l'); QEMU emits LE on x86_64.

pub const MsgHead = struct {
    msg_type: u8, // 1 call, 2 return, 3 error, 4 signal
    flags: u8, // bit0 = NO_REPLY_EXPECTED
    body_len: u32,
    serial: u32,
    fields_len: u32,

    pub fn totalLen(self: MsgHead) usize {
        return 16 + alignUp(self.fields_len, 8) + self.body_len;
    }
};

pub fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) & ~(a - 1);
}

/// Parse the fixed 16-byte message header. Null on anything that is not a
/// little-endian protocol-1 D-Bus message.
pub fn parseHead(b: []const u8) ?MsgHead {
    if (b.len < 16) return null;
    if (b[0] != 'l') return null; // big-endian peers unsupported (and unused by QEMU here)
    if (b[3] != 1) return null;
    return .{
        .msg_type = b[1],
        .flags = b[2],
        .body_len = std.mem.readInt(u32, b[4..8], .little),
        .serial = std.mem.readInt(u32, b[8..12], .little),
        .fields_len = std.mem.readInt(u32, b[12..16], .little),
    };
}

pub const Fields = struct {
    member: [64]u8 = undefined,
    member_len: u8 = 0,
    error_name: [128]u8 = undefined,
    error_name_len: u8 = 0,
    unix_fds: u32 = 0,
    reply_serial: u32 = 0,

    pub fn memberSlice(self: *const Fields) []const u8 {
        return self.member[0..self.member_len];
    }
};

/// Parse the header-field array (starts at offset 16). Tolerant: unknown
/// field codes and value types are skipped; returns what it understood.
pub fn parseFields(fields: []const u8) Fields {
    var out = Fields{};
    var p: usize = 0;
    while (p + 4 <= fields.len) {
        p = alignUp(p, 8);
        if (p + 2 > fields.len) break;
        const code = fields[p];
        const sig_len = fields[p + 1];
        const sig_start = p + 2;
        const sig_end = sig_start + sig_len;
        if (sig_end + 1 > fields.len) break; // +1 for the nul
        const sig = fields[sig_start..sig_end];
        var vp = sig_end + 1;
        if (sig.len == 0) break;
        switch (sig[0]) {
            's', 'o' => {
                vp = alignUp(vp, 4);
                if (vp + 4 > fields.len) break;
                const slen = std.mem.readInt(u32, fields[vp..][0..4], .little);
                const sstart = vp + 4;
                const send = sstart + slen;
                if (send + 1 > fields.len) break;
                if (code == 3) { // MEMBER
                    const n: u8 = @intCast(@min(slen, out.member.len));
                    @memcpy(out.member[0..n], fields[sstart .. sstart + n]);
                    out.member_len = n;
                }
                if (code == 4) { // ERROR_NAME
                    const n: u8 = @intCast(@min(slen, out.error_name.len));
                    @memcpy(out.error_name[0..n], fields[sstart .. sstart + n]);
                    out.error_name_len = n;
                }
                vp = send + 1;
            },
            'u' => {
                vp = alignUp(vp, 4);
                if (vp + 4 > fields.len) break;
                const val = std.mem.readInt(u32, fields[vp..][0..4], .little);
                if (code == 9) out.unix_fds = val; // UNIX_FDS
                if (code == 5) out.reply_serial = val; // REPLY_SERIAL
                vp += 4;
            },
            'g' => {
                if (vp + 1 > fields.len) break;
                const gl = fields[vp];
                vp += 1 + gl + 1;
            },
            else => return out, // unknown value type: stop (we have what we need)
        }
        if (vp <= p) break;
        p = vp;
    }
    return out;
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn pad(self: *Writer, a: usize) void {
        const target = alignUp(self.pos, a);
        while (self.pos < target) : (self.pos += 1) self.buf[self.pos] = 0;
    }
    fn byte(self: *Writer, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }
    fn u32le(self: *Writer, v: u32) void {
        self.pad(4);
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    fn bytes(self: *Writer, s: []const u8) void {
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
    /// D-Bus string value: aligned u32 length, bytes, nul.
    fn str(self: *Writer, s: []const u8) void {
        self.u32le(@intCast(s.len));
        self.bytes(s);
        self.byte(0);
    }
    /// Signature value: u8 length, bytes, nul.
    fn sig(self: *Writer, s: []const u8) void {
        self.byte(@intCast(s.len));
        self.bytes(s);
        self.byte(0);
    }
};

/// Marshal `org.qemu.Display1.Console.RegisterListener(h)` carrying one fd
/// (index 0; the fd itself rides SCM_RIGHTS on the same sendmsg).
pub fn marshalRegisterListener(buf: []u8, serial: u32, console_path: []const u8) []const u8 {
    var w = Writer{ .buf = buf };
    w.byte('l');
    w.byte(1); // METHOD_CALL
    w.byte(0);
    w.byte(1);
    w.u32le(4); // body length: one u32 fd-index
    w.u32le(serial);
    const fields_len_at = w.pos;
    w.u32le(0); // patched below
    const fields_start = w.pos;
    // PATH (1, 'o')
    w.pad(8);
    w.byte(1);
    w.sig("o");
    w.str(console_path);
    // INTERFACE (2, 's')
    w.pad(8);
    w.byte(2);
    w.sig("s");
    w.str("org.qemu.Display1.Console");
    // MEMBER (3, 's')
    w.pad(8);
    w.byte(3);
    w.sig("s");
    w.str("RegisterListener");
    // SIGNATURE (8, 'g')
    w.pad(8);
    w.byte(8);
    w.sig("g");
    w.sig("h");
    // UNIX_FDS (9, 'u')
    w.pad(8);
    w.byte(9);
    w.sig("u");
    w.u32le(1);
    const fields_end = w.pos;
    std.mem.writeInt(u32, buf[fields_len_at..][0..4], @intCast(fields_end - fields_start), .little);
    w.pad(8); // body starts 8-aligned
    w.u32le(0); // fd index 0
    return buf[0..w.pos];
}

/// Marshal an empty METHOD_RETURN for `reply_serial`.
pub fn marshalReturn(buf: []u8, serial: u32, reply_serial: u32) []const u8 {
    var w = Writer{ .buf = buf };
    w.byte('l');
    w.byte(2); // METHOD_RETURN
    w.byte(1); // NO_REPLY_EXPECTED
    w.byte(1);
    w.u32le(0); // empty body
    w.u32le(serial);
    const fields_len_at = w.pos;
    w.u32le(0);
    const fields_start = w.pos;
    w.pad(8);
    w.byte(5); // REPLY_SERIAL
    w.sig("u");
    w.u32le(reply_serial);
    const fields_end = w.pos;
    std.mem.writeInt(u32, buf[fields_len_at..][0..4], @intCast(fields_end - fields_start), .little);
    w.pad(8);
    return buf[0..w.pos];
}

// ── fd passing ──────────────────────────────────────────────────────

const Cmsghdr = extern struct {
    len: usize,
    level: c_int,
    typ: c_int,
};

fn sendWithFd(sock: c.fd_t, data: []const u8, fd: c.fd_t) bool {
    var iov = [1]c.iovec_const{.{ .base = data.ptr, .len = data.len }};
    var cbuf: [@sizeOf(Cmsghdr) + 8]u8 align(@alignOf(Cmsghdr)) = undefined;
    const hdr: *Cmsghdr = @ptrCast(&cbuf);
    hdr.* = .{ .len = @sizeOf(Cmsghdr) + @sizeOf(c.fd_t), .level = SOL_SOCKET, .typ = SCM_RIGHTS };
    const fdp: *c.fd_t = @ptrFromInt(@intFromPtr(&cbuf) + @sizeOf(Cmsghdr));
    fdp.* = fd;
    var msg: c.msghdr_const = std.mem.zeroes(c.msghdr_const);
    msg.iov = &iov;
    msg.iovlen = 1;
    msg.control = &cbuf;
    msg.controllen = @intCast(hdr.len);
    return c.sendmsg(sock, &msg, 0) > 0;
}

/// recvmsg that harvests (and immediately closes) any SCM_RIGHTS fds — phase 1
/// only observes cadence; dmabuf/memfd payloads are not consumed yet, and
/// leaking them would exhaust the fd table within seconds at 60 fps.
fn recvClosingFds(sock: c.fd_t, buf: []u8) isize {
    var iov = [1]c.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cbuf: [256]u8 align(@alignOf(Cmsghdr)) = undefined;
    var msg: c.msghdr = std.mem.zeroes(c.msghdr);
    msg.iov = &iov;
    msg.iovlen = 1;
    msg.control = &cbuf;
    msg.controllen = cbuf.len;
    const n = c.recvmsg(sock, &msg, 0);
    if (n <= 0) return n;
    // Walk control messages; close every passed fd.
    var off: usize = 0;
    const clen: usize = @intCast(msg.controllen);
    while (off + @sizeOf(Cmsghdr) <= clen) {
        const hdr: *const Cmsghdr = @alignCast(@ptrCast(&cbuf[off]));
        if (hdr.len < @sizeOf(Cmsghdr) or off + hdr.len > clen) break;
        if (hdr.level == SOL_SOCKET and hdr.typ == SCM_RIGHTS) {
            const nfds = (hdr.len - @sizeOf(Cmsghdr)) / @sizeOf(c.fd_t);
            var i: usize = 0;
            while (i < nfds) : (i += 1) {
                const fdp: *const c.fd_t = @ptrFromInt(@intFromPtr(&cbuf[off]) + @sizeOf(Cmsghdr) + i * @sizeOf(c.fd_t));
                _ = c.close(fdp.*);
            }
        }
        off += alignUp(hdr.len, @alignOf(Cmsghdr));
    }
    return n;
}

// ── line IO for the AUTH phase ──────────────────────────────────────

fn readLine(fd: c.fd_t, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n + 1 < buf.len) {
        const r = c.read(fd, buf[n..].ptr, 1);
        if (r <= 0) return null;
        if (buf[n] == '\n') return buf[0..n];
        n += 1;
    }
    return null;
}

fn writeAllFd(fd: c.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Client side of AUTH EXTERNAL (we connect to QEMU's bus end).
fn authClient(fd: c.fd_t) bool {
    var line: [256]u8 = undefined;
    var out: [128]u8 = undefined;
    const uid = c.getuid();
    var dec: [16]u8 = undefined;
    const dec_s = std.fmt.bufPrint(&dec, "{d}", .{uid}) catch return false;
    var hexbuf: [32]u8 = undefined;
    const hex_s = std.fmt.bufPrint(&hexbuf, "{x}", .{dec_s}) catch return false;
    const auth = std.fmt.bufPrint(&out, "\x00AUTH EXTERNAL {s}\r\n", .{hex_s}) catch return false;
    if (!writeAllFd(fd, auth)) return false;
    const ok = readLine(fd, &line) orelse return false;
    if (!std.mem.startsWith(u8, ok, "OK")) return false;
    if (!writeAllFd(fd, "NEGOTIATE_UNIX_FD\r\n")) return false;
    const agree = readLine(fd, &line) orelse return false;
    if (!std.mem.startsWith(u8, agree, "AGREE_UNIX_FD")) return false;
    return writeAllFd(fd, "BEGIN\r\n");
}

// ── H.264 Annex-B access-unit splitter ─────────────────────────────
// The encoder's byte stream arrives at arbitrary pipe boundaries; WebCodecs
// must be fed whole access units. Group NALs: non-VCL (SPS/PPS/SEI/AUD)
// prefix + one VCL slice (type 1/5) closes an AU.

pub const AuSplitter = struct {
    buf: []u8,
    len: usize = 0,

    /// Append encoder bytes; for each complete AU found, calls
    /// emit(ctx, au_bytes, is_key). Returns false if the buffer overflowed
    /// (stream hopeless — caller should tear down).
    pub fn feed(self: *AuSplitter, data: []const u8, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const u8, bool) bool) bool {
        if (self.len + data.len > self.buf.len) return false;
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
        var emitted_until: usize = 0;
        var have_vcl = false;
        var key = false;
        var au_start: usize = 0;
        var i: usize = 0;
        while (i + 3 < self.len) {
            const sc3 = self.buf[i] == 0 and self.buf[i + 1] == 0 and self.buf[i + 2] == 1;
            const sc4 = i + 4 < self.len and self.buf[i] == 0 and self.buf[i + 1] == 0 and self.buf[i + 2] == 0 and self.buf[i + 3] == 1;
            if (!(sc3 or sc4)) {
                i += 1;
                continue;
            }
            const nal_off = i + (if (sc4) @as(usize, 4) else 3);
            if (nal_off >= self.len) break;
            const nal_type = self.buf[nal_off] & 0x1f;
            const is_vcl = nal_type == 1 or nal_type == 5;
            if (have_vcl) {
                // This start code begins the NEXT AU.
                if (!emit(ctx, self.buf[au_start..i], key)) return false;
                emitted_until = i;
                au_start = i;
                have_vcl = false;
                key = false;
            }
            if (is_vcl) {
                have_vcl = true;
                if (nal_type == 5) key = true;
            }
            i = nal_off;
        }
        if (emitted_until > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.len - emitted_until], self.buf[emitted_until..self.len]);
            self.len -= emitted_until;
        }
        return true;
    }
};

// ── per-VM capture session ──────────────────────────────────────────

pub const Session = struct {
    name_buf: [vm.MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
    alive: bool = true,
    // Reference count guarded by sessions_mutex: the owning listener thread
    // holds one ref, each attached video client holds one. The Session (and
    // its framebuffer) is destroyed only at the final unref — a VM power-off
    // mid-stream must not free memory under the video client's feet (that
    // exact use-after-free panicked in serveVideoClient's deferred cleanup).
    refs: u32 = 1,

    // Assembled BGRX framebuffer (heap; (re)allocated on Scanout).
    fb_mutex: sync.SpinMutex = .{},
    fb: ?[]u8 = null,
    fb_w: u32 = 0,
    fb_h: u32 = 0,

    // Encoder child + the single attached video client.
    enc_mutex: sync.SpinMutex = .{},
    enc_pid: c.pid_t = -1,
    enc_in: c.fd_t = -1,
    enc_out: c.fd_t = -1,
    last_push_ms: u64 = 0,
    fb_dirty: bool = false,
    bitrate_kbps: u32 = 0,
    // Attached video clients (fan-out: one encoder, N viewers). Slots are
    // -1 when free; client_wmtx guards the array AND all WS writes to them.
    clients: [MAX_VIDEO_CLIENTS]c.fd_t = [_]c.fd_t{-1} ** MAX_VIDEO_CLIENTS,
    client_count: u8 = 0,
    client_wmtx: sync.SpinMutex = .{},
    pump_running: bool = false,

    fn nameSlice(self: *const Session) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const MAX_FB_BYTES: usize = 32 * 1024 * 1024; // 2900x2900 BGRX ceiling
pub const MAX_VIDEO_CLIENTS: usize = 8;

var sessions_mutex: sync.SpinMutex = .{};
var sessions: [vm.MAX_VMS]?*Session = [_]?*Session{null} ** vm.MAX_VMS;

fn registerSession(name: []const u8) ?*Session {
    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    var free_slot: ?usize = null;
    for (0..vm.MAX_VMS) |i| {
        if (sessions[i]) |sess| {
            if (std.mem.eql(u8, sess.nameSlice(), name)) return null; // already attached
        } else if (free_slot == null) free_slot = i;
    }
    const slot = free_slot orelse return null;
    const sess = std.heap.page_allocator.create(Session) catch return null;
    sess.* = .{};
    const n: u8 = @intCast(@min(name.len, vm.MAX_NAME - 1));
    @memcpy(sess.name_buf[0..n], name[0..n]);
    sess.name_len = n;
    sessions[slot] = sess;
    return sess;
}

fn sessionRefInc(sess: *Session) void {
    sessions_mutex.lock();
    sess.refs += 1;
    sessions_mutex.unlock();
}

fn sessionUnref(sess: *Session) void {
    sessions_mutex.lock();
    sess.refs -= 1;
    const dead = sess.refs == 0;
    sessions_mutex.unlock();
    if (!dead) return;
    if (sess.fb) |fb| std.heap.page_allocator.free(fb);
    sess.fb = null;
    std.heap.page_allocator.destroy(sess);
}

fn unregisterSession(sess: *Session) void {
    sessions_mutex.lock();
    for (0..vm.MAX_VMS) |i| {
        if (sessions[i] == sess) sessions[i] = null;
    }
    sessions_mutex.unlock();
    stopEncoder(sess);
    sessionUnref(sess);
}

/// Find a session by VM name and take a reference. Caller must sessionUnref.
pub fn findSessionRef(name: []const u8) ?*Session {
    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    for (0..vm.MAX_VMS) |i| {
        if (sessions[i]) |sess| {
            if (std.mem.eql(u8, sess.nameSlice(), name)) {
                sess.refs += 1;
                return sess;
            }
        }
    }
    return null;
}

pub const AttachCtx = struct {
    name_buf: [vm.MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
};

/// Detached-thread entry: wait for QEMU to settle, then attach and serve the
/// listener until the VM goes away. All failures log-and-return; this path
/// must never affect VM lifecycle.
pub fn attachThread(ctx: *AttachCtx) void {
    defer std.heap.page_allocator.destroy(ctx);
    const name = ctx.name_buf[0..ctx.name_len];
    appio.sleepMs(900); // let QEMU bring up QMP + the dbus display
    const sess = registerSession(name) orelse return;
    defer unregisterSession(sess);
    // Under load (parallel test suites, many simultaneous boots) QEMU may not
    // have its QMP socket or dbus display up at the first try — retry the
    // handshake stages before giving up.
    var tries: u32 = 0;
    while (true) {
        attach(sess) catch |e| {
            tries += 1;
            if (tries < 6) {
                appio.sleepMs(1500);
                continue;
            }
            var msg: [160]u8 = undefined;
            wlog.logWarn(std.fmt.bufPrint(&msg, "dbusdisplay: attach failed vm=\"{s}\": {s}", .{ name, @errorName(e) }) catch "dbusdisplay: attach failed");
            return;
        };
        return; // listener served until EOF: normal detach
    }
}

fn attach(sess: *Session) !void {
    const name = sess.nameSlice();
    var path_buf: [256]u8 = undefined;
    const qmp_path = qmp.socketPath(name, &path_buf) orelse return error.BadName;

    // socketpair: our D-Bus control connection vs the end handed to QEMU.
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    const ctrl = fds[0];
    var ctrl_remote: c.fd_t = fds[1];
    // Single owner of ctrl's close on every path. A previous errdefer-plus-defer
    // pair double-closed ctrl on errors after the second was registered; in a
    // threaded daemon the freed fd number can be reused by another connection
    // between the two closes, killing an unrelated client.
    defer _ = c.close(ctrl);
    defer if (ctrl_remote >= 0) {
        _ = c.close(ctrl_remote);
    };

    // Pass the remote end through QMP: getfd (fd rides SCM_RIGHTS) + add_client.
    var client = qmp.QmpClient{};
    client.connect(qmp_path) catch return error.QmpConnect;
    defer client.disconnect();
    const qfd = client.rawFd() orelse return error.QmpConnect;
    if (!sendWithFd(qfd, "{\"execute\":\"getfd\",\"arguments\":{\"fdname\":\"hangar-dbus\"}}\n", ctrl_remote)) return error.GetFd;
    try client.expectReturn();
    _ = c.close(ctrl_remote);
    ctrl_remote = -1;
    client.execExpectReturn("{\"execute\":\"add_client\",\"arguments\":{\"protocol\":\"@dbus-display\",\"fdname\":\"hangar-dbus\"}}") catch return error.AddClient;

    // D-Bus handshake on our control end.
    if (!authClient(ctrl)) return error.Auth;

    // Listener socketpair: register the remote end with the Console object.
    var lfds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &lfds) != 0) return error.SocketPair;
    const lst = lfds[0];
    defer _ = c.close(lst);
    var mbuf: [512]u8 = undefined;
    const call = marshalRegisterListener(&mbuf, 1, "/org/qemu/Display1/Console_0");
    const sent = sendWithFd(ctrl, call, lfds[1]);
    _ = c.close(lfds[1]);
    if (!sent) return error.Register;

    // Read the RegisterListener reply: a METHOD_RETURN means QEMU accepted the
    // fd and will serve it; an ERROR tells us why not.
    {
        var rb: [4096]u8 = undefined;
        var got: usize = 0;
        while (got < 16) {
            const n = c.read(ctrl, rb[got..].ptr, rb.len - got);
            if (n <= 0) return error.RegisterReply;
            got += @intCast(n);
        }
        const h = parseHead(rb[0..got]) orelse return error.RegisterReply;
        const total = @min(h.totalLen(), rb.len);
        while (got < total) {
            const n = c.read(ctrl, rb[got..].ptr, rb.len - got);
            if (n <= 0) break;
            got += @intCast(n);
        }
        if (h.msg_type == 3) {
            const fl = parseFields(rb[16..@min(16 + h.fields_len, got)]);
            var msg: [220]u8 = undefined;
            wlog.logWarn(std.fmt.bufPrint(&msg, "dbusdisplay: RegisterListener error: {s}", .{fl.error_name[0..fl.error_name_len]}) catch "dbusdisplay: RegisterListener error");
            return error.RegisterRejected;
        }
    }

    // On the listener connection QEMU is the AUTH SERVER (it method-calls us
    // after auth, but the handshake roles are independent of call direction —
    // verified: it sat silent waiting for our AUTH until the VM died).
    if (!authClient(lst)) return error.ListenerAuth;
    {
        var msg: [128]u8 = undefined;
        wlog.logAt(.info, std.fmt.bufPrint(&msg, "dbusdisplay: attached vm=\"{s}\"", .{name}) catch "dbusdisplay: attached");
    }
    serveListener(lst, sess);
}

// ── frame assembly ──────────────────────────────────────────────────

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Body: Scanout(u width, u height, u stride, u pixman_format, ay data).
fn applyScanout(sess: *Session, body: []const u8) void {
    if (body.len < 20) return;
    const w = readU32(body, 0);
    const h = readU32(body, 4);
    const stride = readU32(body, 8);
    const arr_len = readU32(body, 16);
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return;
    if (20 + @as(usize, arr_len) > body.len) return;
    if (@as(usize, stride) * h > arr_len) return;
    const need = @as(usize, w) * h * 4;
    if (need > MAX_FB_BYTES) return;
    sess.fb_mutex.lock();
    defer sess.fb_mutex.unlock();
    if (sess.fb == null or sess.fb_w != w or sess.fb_h != h) {
        if (sess.fb) |fb| std.heap.page_allocator.free(fb);
        sess.fb = std.heap.page_allocator.alloc(u8, need) catch {
            sess.fb = null;
            return;
        };
        sess.fb_w = w;
        sess.fb_h = h;
        // Resolution change invalidates the encoder.
        stopEncoderLocked(sess);
    }
    const fb = sess.fb.?;
    const data = body[20 .. 20 + arr_len];
    var row: usize = 0;
    while (row < h) : (row += 1) {
        @memcpy(fb[row * w * 4 ..][0 .. w * 4], data[row * stride ..][0 .. w * 4]);
    }
    pushFrameLocked(sess);
}

/// Body: Update(i x, i y, i width, i height, u stride, u pixman_format, ay data).
fn applyUpdate(sess: *Session, body: []const u8) void {
    if (body.len < 28) return;
    const x = readU32(body, 0);
    const y = readU32(body, 4);
    const w = readU32(body, 8);
    const h = readU32(body, 12);
    const stride = readU32(body, 16);
    const arr_len = readU32(body, 24);
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return;
    if (28 + @as(usize, arr_len) > body.len) return;
    if (@as(usize, stride) * h > arr_len) return;
    sess.fb_mutex.lock();
    defer sess.fb_mutex.unlock();
    const fb = sess.fb orelse return;
    if (x + w > sess.fb_w or y + h > sess.fb_h) return;
    const data = body[28 .. 28 + arr_len];
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const dst_off = (@as(usize, y) + row) * sess.fb_w * 4 + @as(usize, x) * 4;
        @memcpy(fb[dst_off..][0 .. @as(usize, w) * 4], data[row * stride ..][0 .. @as(usize, w) * 4]);
    }
    pushFrameLocked(sess);
}

/// Feed the current framebuffer to the encoder (caller holds fb_mutex), paced
/// to ~30 fps: damage often arrives in 60-80/s bursts and each push is a full
/// frame, so unpaced feeding shoves ~80MB/s of redundant pixels into ffmpeg.
/// Skipped pushes mark the frame dirty; flushFrame sends the trailing state.
fn pushFrameLocked(sess: *Session) void {
    const now = nowMs();
    if (now - sess.last_push_ms < 33) {
        sess.fb_dirty = true;
        return;
    }
    pushFrameNowLocked(sess, now);
}

fn pushFrameNowLocked(sess: *Session, now: u64) void {
    const fb = sess.fb orelse return;
    sess.enc_mutex.lock();
    const fd = sess.enc_in;
    sess.enc_mutex.unlock();
    if (fd < 0) return;
    sess.last_push_ms = now;
    sess.fb_dirty = false;
    if (!writeAllFd(fd, fb)) {
        // Encoder died (pipe closed): tear it down so a client reconnect restarts it.
        stopEncoder(sess);
    }
}

/// Send the trailing frame of a damage burst once the pacing window has passed.
fn flushFrame(sess: *Session) void {
    sess.fb_mutex.lock();
    defer sess.fb_mutex.unlock();
    if (!sess.fb_dirty) return;
    const now = nowMs();
    if (now - sess.last_push_ms < 33) return;
    pushFrameNowLocked(sess, now);
}

// ── encoder lifecycle ───────────────────────────────────────────────

fn startEncoder(sess: *Session, w: u32, h: u32) bool {
    sess.enc_mutex.lock();
    defer sess.enc_mutex.unlock();
    if (sess.enc_pid >= 0) return true;
    var size_buf: [32]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ w, h }) catch return false;
    var rate_buf: [16]u8 = undefined;
    const kbps = if (sess.bitrate_kbps == 0) 4000 else sess.bitrate_kbps;
    const rate = std.fmt.bufPrint(&rate_buf, "{d}k", .{kbps}) catch return false;
    const have_vaapi = blk: {
        const fd = c.open("/dev/dri/renderD128", .{ .ACCMODE = .RDWR });
        if (fd < 0) break :blk false;
        _ = c.close(fd);
        break :blk true;
    };
    const common = [_][]const u8{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "bgr0", "-video_size", size, "-framerate", "30", "-i", "-" };
    const vaapi = common ++ [_][]const u8{ "-init_hw_device", "vaapi=va:/dev/dri/renderD128", "-filter_hw_device", "va", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-profile:v", "constrained_baseline", "-b:v", rate, "-maxrate", rate, "-bf", "0", "-g", "60", "-bsf:v", "dump_extra=freq=keyframe", "-f", "h264", "-" };
    const x264 = common ++ [_][]const u8{ "-vf", "format=yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-profile:v", "baseline", "-b:v", rate, "-maxrate", rate, "-bufsize", rate, "-bf", "0", "-g", "60", "-bsf:v", "dump_extra=freq=keyframe", "-f", "h264", "-" };
    const child = (if (have_vaapi)
        qemu.forkExecPiped(&vaapi, std.heap.page_allocator)
    else
        qemu.forkExecPiped(&x264, std.heap.page_allocator)) catch return false;
    sess.enc_pid = child.pid;
    sess.enc_in = child.stdin_fd;
    sess.enc_out = child.stdout_fd;
    var msg: [128]u8 = undefined;
    wlog.logAt(.info, std.fmt.bufPrint(&msg, "dbusdisplay: encoder started vm=\"{s}\" {d}x{d} {s}", .{ sess.nameSlice(), w, h, if (have_vaapi) "h264_vaapi" else "libx264" }) catch "dbusdisplay: encoder started");
    return true;
}

fn stopEncoderLocked(sess: *Session) void {
    sess.enc_mutex.lock();
    defer sess.enc_mutex.unlock();
    if (sess.enc_pid < 0) return;
    _ = c.close(sess.enc_in);
    // enc_out belongs to the pump while it runs: closing it here while the
    // pump is blocked in read() would free the fd number for reuse and the
    // pump could end up reading some unrelated socket. Killing ffmpeg makes
    // the pump's read return 0; the pump closes its fd itself on exit.
    if (!sess.pump_running) {
        _ = c.close(sess.enc_out);
    }
    _ = c.kill(sess.enc_pid, .KILL);
    var status: c_int = 0;
    _ = c.waitpid(sess.enc_pid, &status, 0);
    sess.enc_pid = -1;
    sess.enc_in = -1;
    sess.enc_out = -1;
}

fn stopEncoder(sess: *Session) void {
    stopEncoderLocked(sess);
}

// ── /ws/video client ────────────────────────────────────────────────

/// Serve one video WebSocket client (the route handler's thread). The WS
/// upgrade has already been written by the caller.
pub fn serveVideoClient(conn: c.fd_t, name: []const u8, bitrate_kbps: u32) void {
    // The session appears ~1s after power-on (attach settle + D-Bus
    // handshake); a fast client connecting right at the running flip must
    // wait for it, not bounce.
    var sess_wait: u32 = 0;
    const sess = blk: {
        while (sess_wait < 8000) : (sess_wait += 200) {
            if (findSessionRef(name)) |found| break :blk found;
            appio.sleepMs(200);
        }
        ws.writeClose(conn) catch {};
        return;
    };
    defer sessionUnref(sess);
    sess.bitrate_kbps = bitrate_kbps;
    // Wait for the first Scanout so the encoder knows its dimensions.
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        sess.fb_mutex.lock();
        const ready = sess.fb != null;
        sess.fb_mutex.unlock();
        if (ready) break;
        appio.sleepMs(100);
    }
    sess.fb_mutex.lock();
    const w = sess.fb_w;
    const h = sess.fb_h;
    const ready = sess.fb != null;
    sess.fb_mutex.unlock();
    if (!ready) {
        ws.writeClose(conn) catch {};
        return;
    }
    // Claim a viewer slot.
    sess.client_wmtx.lock();
    var slot: ?usize = null;
    for (0..MAX_VIDEO_CLIENTS) |i| {
        if (sess.clients[i] < 0) {
            slot = i;
            break;
        }
    }
    if (slot) |i| {
        sess.clients[i] = conn;
        sess.client_count += 1;
    }
    sess.client_wmtx.unlock();
    if (slot == null) {
        ws.writeClose(conn) catch {};
        return;
    }
    defer {
        sess.client_wmtx.lock();
        sess.clients[slot.?] = -1;
        sess.client_count -= 1;
        const last = sess.client_count == 0;
        sess.client_wmtx.unlock();
        // Last viewer gone: stop the encoder (the pump exits on its closed
        // stdout and drops its session ref).
        if (last) stopEncoder(sess);
    }
    if (!startEncoder(sess, w, h)) return;
    // One pump per encoder, spawned by whichever client started it. The pump
    // holds its own session ref and broadcasts to every attached client.
    {
        sess.enc_mutex.lock();
        const need_pump = !sess.pump_running and sess.enc_out >= 0;
        if (need_pump) sess.pump_running = true;
        sess.enc_mutex.unlock();
        if (need_pump) {
            sessionRefInc(sess);
            if (std.Thread.spawn(std.Thread.SpawnConfig{}, encoderPump, .{sess})) |th| {
                th.detach();
            } else |_| {
                sess.enc_mutex.lock();
                sess.pump_running = false;
                sess.enc_mutex.unlock();
                sessionUnref(sess);
                return;
            }
        }
    }

    // Config frame: 0x01, u16le width, u16le height, u8 codec(0=h264).
    var cfg: [6]u8 = undefined;
    cfg[0] = 1;
    std.mem.writeInt(u16, cfg[1..3], @intCast(w), .little);
    std.mem.writeInt(u16, cfg[3..5], @intCast(h), .little);
    cfg[5] = 0;
    sess.client_wmtx.lock();
    const cfg_ok = blk: {
        ws.writeFrame(conn, .binary, &cfg) catch break :blk false;
        break :blk true;
    };
    sess.client_wmtx.unlock();
    if (!cfg_ok) return;

    // Drain client input (ping/close) like the other relays; the shared pump
    // broadcasts encoder output to every client.
    var buf: [4096]u8 = undefined;
    while (true) {
        const hdr = ws.readFrameHeader(conn) orelse break;
        if (hdr.opcode == .close) break;
        if (hdr.opcode == .ping) {
            _ = ws.readFramePayload(conn, &buf, hdr) orelse break;
            sess.client_wmtx.lock();
            ws.writePong(conn) catch {
                sess.client_wmtx.unlock();
                break;
            };
            sess.client_wmtx.unlock();
            continue;
        }
        _ = ws.readFramePayload(conn, &buf, hdr) orelse break;
    }
}

fn emitAu(sess: *Session, au: []const u8, key: bool) bool {
    var hdr_byte: [1]u8 = .{if (key) 0x03 else 0x02};
    // Frame: 0x02|0x03 marker byte then the Annex-B access unit. (0x03 = key.)
    // Broadcast to every attached client; a failed write shuts that client's
    // socket down (its drain loop then exits and frees the slot) without
    // affecting the others.
    sess.client_wmtx.lock();
    defer sess.client_wmtx.unlock();
    for (0..MAX_VIDEO_CLIENTS) |i| {
        const fd = sess.clients[i];
        if (fd < 0) continue;
        ws.writeFrame2(fd, .binary, &hdr_byte, au) catch {
            _ = c.shutdown(fd, netutilShut());
        };
    }
    return true;
}

fn encoderPump(sess: *Session) void {
    defer {
        sess.enc_mutex.lock();
        sess.pump_running = false;
        sess.enc_mutex.unlock();
        // Encoder gone: force every remaining client's drain loop to exit.
        sess.client_wmtx.lock();
        for (0..MAX_VIDEO_CLIENTS) |i| {
            if (sess.clients[i] >= 0) _ = c.shutdown(sess.clients[i], netutilShut());
        }
        sess.client_wmtx.unlock();
        sessionUnref(sess);
    }
    sess.enc_mutex.lock();
    const out = sess.enc_out;
    sess.enc_mutex.unlock();
    if (out < 0) return;
    defer _ = c.close(out); // pump owns the read end (see stopEncoderLocked)
    const au_buf = std.heap.page_allocator.alloc(u8, 4 * 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(au_buf);
    var splitter = AuSplitter{ .buf = au_buf };
    var rbuf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(out, &rbuf, rbuf.len);
        if (n <= 0) break;
        if (!splitter.feed(rbuf[0..@intCast(n)], sess, emitAu)) break;
    }
}

fn netutilShut() c_int {
    return 2; // SHUT_RDWR
}

fn serveListener(fd: c.fd_t, sess: *Session) void {
    const name = sess.nameSlice();
    const acc = std.heap.page_allocator.alloc(u8, 16 * 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(acc);
    var acc_len: usize = 0;
    var msg_have: usize = 0;
    var need: usize = 16;
    var head: ?MsgHead = null;
    var reply_serial_counter: u32 = 100;
    var frames: u64 = 0;
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var window_start = nowMs();
    var rbuf: [64 * 1024]u8 = undefined;

    while (true) {
        const n = recvClosingFds(fd, &rbuf);
        if (n <= 0) break;
        var chunk: []const u8 = rbuf[0..@intCast(n)];
        defer flushFrame(sess);
        while (chunk.len > 0) {
            const store = @min(chunk.len, acc.len - @min(acc_len, acc.len));
            if (store > 0 and acc_len < acc.len) {
                const take = @min(store, acc.len - acc_len);
                @memcpy(acc[acc_len..][0..take], chunk[0..take]);
                acc_len += take;
            }
            msg_have += chunk.len;
            chunk = chunk[chunk.len..];
            while (true) {
                if (head == null) {
                    if (acc_len < 16) break;
                    head = parseHead(acc[0..acc_len]) orelse return; // protocol desync
                    need = head.?.totalLen();
                }
                const h = head.?;
                if (msg_have < need) break;
                const stored = @min(need, acc_len);
                if (stored >= 16 + h.fields_len) {
                    const fl = parseFields(acc[16 .. 16 + h.fields_len]);
                    const member = fl.memberSlice();
                    const body_off = 16 + alignUp(h.fields_len, 8);
                    const body_end = @min(body_off + h.body_len, stored);
                    const body = if (body_end > body_off) acc[body_off..body_end] else acc[0..0];
                    if (std.mem.eql(u8, member, "Scanout")) {
                        frames += 1;
                        applyScanout(sess, body);
                        if (body.len >= 8) {
                            last_w = readU32(body, 0);
                            last_h = readU32(body, 4);
                        }
                    } else if (std.mem.eql(u8, member, "Update")) {
                        frames += 1;
                        applyUpdate(sess, body);
                        if (body.len >= 16) {
                            last_w = readU32(body, 8);
                            last_h = readU32(body, 12);
                        }
                    }
                    if (h.msg_type == 1 and (h.flags & 0x1) == 0) {
                        var ret_buf: [128]u8 = undefined;
                        reply_serial_counter += 1;
                        const ret = marshalReturn(&ret_buf, reply_serial_counter, h.serial);
                        if (!writeAllFd(fd, ret)) return;
                    }
                }
                const extra_stored = if (acc_len > need) acc_len - need else 0;
                if (extra_stored > 0) std.mem.copyForwards(u8, acc[0..extra_stored], acc[need .. need + extra_stored]);
                acc_len = extra_stored;
                msg_have = msg_have - need;
                head = null;
                need = 16;
                const now = nowMs();
                if (now - window_start >= 5000) {
                    var msg: [192]u8 = undefined;
                    const fps10 = frames * 10000 / @max(1, now - window_start);
                    wlog.logAt(.info, std.fmt.bufPrint(&msg, "dbusdisplay: vm=\"{s}\" frames={d} (~{d}.{d} fps) last={d}x{d}", .{ name, frames, fps10 / 10, fps10 % 10, last_w, last_h }) catch "dbusdisplay: cadence");
                    frames = 0;
                    window_start = now;
                }
            }
        }
    }
    var msg: [128]u8 = undefined;
    wlog.logAt(.info, std.fmt.bufPrint(&msg, "dbusdisplay: detached vm=\"{s}\"", .{name}) catch "dbusdisplay: detached");
}

fn nowMs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "dbus: marshalReturn round-trips through parseHead/parseFields" {
    var buf: [128]u8 = undefined;
    const m = marshalReturn(&buf, 7, 42);
    const h = parseHead(m).?;
    try t.expectEqual(@as(u8, 2), h.msg_type);
    try t.expectEqual(@as(u32, 7), h.serial);
    try t.expectEqual(@as(u32, 0), h.body_len);
    try t.expectEqual(m.len, h.totalLen());
    const fl = parseFields(m[16 .. 16 + h.fields_len]);
    try t.expectEqual(@as(u32, 42), fl.reply_serial);
}

test "dbus: marshalRegisterListener parses back with member + unix_fds" {
    var buf: [512]u8 = undefined;
    const m = marshalRegisterListener(&buf, 3, "/org/qemu/Display1/Console_0");
    const h = parseHead(m).?;
    try t.expectEqual(@as(u8, 1), h.msg_type);
    try t.expectEqual(@as(u32, 3), h.serial);
    try t.expectEqual(@as(u32, 4), h.body_len);
    try t.expectEqual(m.len, h.totalLen());
    const fl = parseFields(m[16 .. 16 + h.fields_len]);
    try t.expectEqualStrings("RegisterListener", fl.memberSlice());
    try t.expectEqual(@as(u32, 1), fl.unix_fds);
}

test "dbus: parseHead rejects junk" {
    try t.expect(parseHead("short") == null);
    var bad: [16]u8 = [_]u8{0} ** 16;
    bad[0] = 'B'; // big-endian unsupported
    bad[3] = 1;
    try t.expect(parseHead(&bad) == null);
}

test "fuzz: parseHead/parseFields never panic on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xD1B5_0001);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        if (parseHead(buf[0..len])) |h| {
            _ = h.totalLen();
            const fl_end = @min(@as(usize, 16) + h.fields_len, len);
            if (fl_end > 16) {
                const fl = parseFields(buf[16..fl_end]);
                try t.expect(fl.member_len <= 64);
            }
        }
    }
}

test "dbus: session registry prevents duplicates and releases" {
    const s1 = registerSession("dup-test-vm").?;
    try t.expect(registerSession("dup-test-vm") == null);
    const ref = findSessionRef("dup-test-vm").?;
    try t.expect(ref == s1);
    unregisterSession(s1); // owner drops; ref keeps it alive
    try t.expect(findSessionRef("dup-test-vm") == null); // no longer findable
    sessionUnref(ref); // final unref destroys
    const s2 = registerSession("dup-test-vm").?;
    unregisterSession(s2);
}

fn collectAu(list: *std.ArrayListUnmanaged(u8), au: []const u8, key: bool) bool {
    list.append(std.heap.page_allocator, if (key) @as(u8, 1) else 0) catch return false;
    list.append(std.heap.page_allocator, @intCast(au.len)) catch return false;
    return true;
}

test "dbus: AuSplitter groups NALs into access units with key detection" {
    // SPS(7) PPS(8) IDR(5) | non-IDR(1) | non-IDR(1)  → 3 AUs, first is key.
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(std.heap.page_allocator);
    const sc = [_]u8{ 0, 0, 0, 1 };
    for ([_]struct { typ: u8, len: u8 }{
        .{ .typ = 7, .len = 4 }, .{ .typ = 8, .len = 2 }, .{ .typ = 5, .len = 9 },
        .{ .typ = 1, .len = 6 }, .{ .typ = 1, .len = 7 },
    }) |nal| {
        stream.appendSlice(std.heap.page_allocator, &sc) catch unreachable;
        stream.append(std.heap.page_allocator, nal.typ) catch unreachable;
        var i: u8 = 0;
        while (i < nal.len) : (i += 1) stream.append(std.heap.page_allocator, 0xAA) catch unreachable;
    }
    var buf: [4096]u8 = undefined;
    var sp = AuSplitter{ .buf = &buf };
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(std.heap.page_allocator);
    // Feed in awkward 3-byte chunks to prove boundary independence.
    var off: usize = 0;
    while (off < stream.items.len) {
        const end = @min(off + 3, stream.items.len);
        try t.expect(sp.feed(stream.items[off..end], &got, collectAu));
        off = end;
    }
    // Two complete AUs emitted (the third stays buffered until more data).
    try t.expectEqual(@as(usize, 4), got.items.len);
    try t.expectEqual(@as(u8, 1), got.items[0]); // first AU is a key (has IDR)
    try t.expectEqual(@as(u8, 0), got.items[2]); // second is delta
}

test "fuzz: AuSplitter never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xA0_5EED);
    const rnd = prng.random();
    var buf: [8192]u8 = undefined;
    var sp = AuSplitter{ .buf = &buf };
    var sink: std.ArrayListUnmanaged(u8) = .empty;
    defer sink.deinit(std.heap.page_allocator);
    var i: usize = 0;
    var chunk: [257]u8 = undefined;
    while (i < 2000) : (i += 1) {
        const len = rnd.uintLessThan(usize, chunk.len);
        for (chunk[0..len]) |*b| b.* = rnd.int(u8);
        if (!sp.feed(chunk[0..len], &sink, collectAu)) {
            sp.len = 0; // overflow: reset like the pump would
        }
        sink.clearRetainingCapacity();
    }
}

test "dbus: alignUp" {
    try t.expectEqual(@as(usize, 0), alignUp(0, 8));
    try t.expectEqual(@as(usize, 8), alignUp(1, 8));
    try t.expectEqual(@as(usize, 8), alignUp(8, 8));
    try t.expectEqual(@as(usize, 16), alignUp(9, 8));
}
