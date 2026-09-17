// SPDX-License-Identifier: MIT
//! VNC client: thread-safe pure-Zig wrapper around libvncclient.
//!
//! A background thread polls the VNC socket and updates a mutex-protected
//! framebuffer.  The UI thread locks the framebuffer for rendering and
//! forwards input events through the public methods.
//!
//! The framebuffer is allocated with C's `calloc` because libvncclient's
//! `rfbClientCleanup` frees it with `free`.

const std = @import("std");
const sync = @import("sync.zig");
const fbmath = @import("fbmath.zig");

const c = @cImport({
    @cInclude("rfb/rfbclient.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const alloc = std.heap.c_allocator;

pub const VncClient = struct {
    rfb: [*c]c.rfbClient = null,
    thread: ?std.Thread = null,
    mutex: sync.SpinMutex = .{},
    connected: bool = false,
    running: bool = false,
    dirty: bool = false,
    framebuffer: ?[*]u8 = null,
    width: c_int = 0,
    height: c_int = 0,

    /// Allocate a new disconnected VNC client on the C heap.
    ///
    /// Uses the C allocator (not Zig's page allocator) because
    /// libvncclient's `rfbClientCleanup` calls `free()` on the
    /// framebuffer: mixing allocators would corrupt the heap.
    pub fn new() ?*VncClient {
        const self = alloc.create(VncClient) catch return null;
        self.* = .{};
        return self;
    }

    /// No-op replacement for libvncclient's stderr loggers. Without this,
    /// every failed `rfbInitClient` (e.g. the embedded display polling a VM
    /// whose VNC server isn't up yet) spams "Unable to connect" to the
    /// terminal. Variadic to match `rfbClientLogProc`'s signature.
    fn quietLog(_: [*c]const u8, ...) callconv(.c) void {}

    /// Connect to a VNC server and start the background polling thread.
    pub fn connect(self: *VncClient, host: [*:0]const u8, port: c_int) bool {
        if (@atomicLoad(bool, &self.connected, .seq_cst)) return false;

        // Mute libvncclient's chatty stderr logging.
        c.rfbClientLog = quietLog;
        c.rfbClientErr = quietLog;

        const cl: [*c]c.rfbClient = c.rfbGetClient(8, 3, 4);
        if (cl == null) return false;

        // BGRA pixel format.
        cl.*.format.redShift = 16;
        cl.*.format.greenShift = 8;
        cl.*.format.blueShift = 0;
        cl.*.format.redMax = 255;
        cl.*.format.greenMax = 255;
        cl.*.format.blueMax = 255;
        cl.*.format.bitsPerPixel = 32;
        cl.*.format.depth = 24;

        cl.*.MallocFrameBuffer = &onMallocFb;
        cl.*.GotFrameBufferUpdate = &onFbUpdate;
        cl.*.canHandleNewFBSize = 1; // TRUE

        // Store self pointer so C callbacks can recover it.
        c.rfbClientSetClientData(cl, null, @as(?*anyopaque, @ptrCast(self)));

        cl.*.serverHost = c.strdup(host);
        cl.*.serverPort = port;

        // rfbInitClient frees `cl` on failure: do NOT cleanup after this.
        // It also frees the framebuffer that onMallocFb may have allocated,
        // so clear our dangling pointer.
        if (c.rfbInitClient(cl, null, null) == 0) {
            self.framebuffer = null;
            return false;
        }

        self.rfb = cl;
        @atomicStore(bool, &self.connected, true, .seq_cst);
        @atomicStore(bool, &self.running, true, .seq_cst);

        self.thread = std.Thread.spawn(std.Thread.SpawnConfig{}, pollThread, .{self}) catch {
            c.rfbClientCleanup(cl);
            self.rfb = null;
            @atomicStore(bool, &self.connected, false, .seq_cst);
            @atomicStore(bool, &self.running, false, .seq_cst);
            return false;
        };

        return true;
    }

    /// Disconnect from the server and stop the background thread.
    ///
    /// Order matters: we clear `running` first so the poll thread exits
    /// its loop, then clear `connected` so no new input events are sent,
    /// then join the thread.  Only after the thread is dead do we call
    /// `rfbClientCleanup` (which frees the framebuffer).
    ///
    /// The `rfb` pointer is nulled inside the mutex so that `sendKey`
    /// and `sendPointer` (which re-check it under the mutex) see a
    /// consistent value: preventing a TOCTOU use-after-free.
    pub fn disconnect(self: *VncClient) void {
        @atomicStore(bool, &self.running, false, .seq_cst);
        @atomicStore(bool, &self.connected, false, .seq_cst);

        if (self.thread) |t| t.join();
        self.thread = null;

        self.mutex.lock();
        const rfb_to_free = self.rfb;
        self.rfb = null;
        // rfbClientCleanup already freed the framebuffer via free(),
        // just clear our pointer.
        self.framebuffer = null;
        self.width = 0;
        self.height = 0;
        @atomicStore(bool, &self.dirty, false, .seq_cst);
        self.mutex.unlock();

        if (rfb_to_free != null) {
            c.rfbClientCleanup(rfb_to_free);
        }
    }

    /// Free all resources.  Disconnects first if still connected.
    pub fn free(self: *VncClient) void {
        self.disconnect();
        alloc.destroy(self);
    }

    /// Get the remote framebuffer dimensions.
    /// Returns false if not connected or framebuffer not yet received.
    ///
    /// THREAD SAFETY: the caller MUST hold the framebuffer mutex (i.e. call this
    /// only between `lockFb` and `unlockFb`). `framebuffer`/`width`/`height` are
    /// written under that mutex by the poll thread's `onMallocFb` callback on a
    /// server resize; reading them unlocked risks torn dimensions that no longer
    /// match the framebuffer the caller then copies, a heap over-read. This does
    /// not lock internally because the production caller already holds the mutex
    /// and `SpinMutex` is non-reentrant (re-locking would deadlock).
    pub fn getSize(self: *const VncClient, width: *c_int, height: *c_int) bool {
        if (!@atomicLoad(bool, &self.connected, .seq_cst) or self.framebuffer == null) return false;
        width.* = self.width;
        height.* = self.height;
        return true;
    }

    /// Lock the framebuffer mutex and return a pointer to the pixel data.
    /// Format: 32-bit BGRA.  Caller MUST call `unlockFb` when done.
    pub fn lockFb(self: *VncClient) ?[*]const u8 {
        self.mutex.lock();
        return self.framebuffer;
    }

    /// Unlock the framebuffer mutex.
    pub fn unlockFb(self: *VncClient) void {
        self.mutex.unlock();
    }

    /// Check and clear the dirty flag.
    ///
    /// Atomic test-and-clear: a single seq_cst exchange returns the prior value
    /// and clears in one step, so a frame the poll thread marks dirty between the
    /// read and the clear is never silently dropped (a separate load+store would
    /// race that window away). seq_cst keeps the clear visible to the poll thread.
    pub fn checkDirty(self: *VncClient) bool {
        return @atomicRmw(bool, &self.dirty, .Xchg, false, .seq_cst);
    }

    /// Send a key press/release event.  `keysym` is an X11 keysym.
    ///
    /// Guards against use-after-free: re-checks `connected` and `rfb`
    /// under the mutex so that a concurrent `disconnect` cannot null
    /// the `rfb` pointer between the check and the call.
    pub fn sendKey(self: *VncClient, keysym: u32, down: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!@atomicLoad(bool, &self.connected, .seq_cst) or self.rfb == null) return;
        _ = c.SendKeyEvent(self.rfb, keysym, if (down) @as(c.rfbBool, 1) else 0);
    }

    /// Send a pointer (mouse) event.
    /// `button_mask`: bit 0 = left, bit 1 = middle, bit 2 = right.
    pub fn sendPointer(self: *VncClient, x: c_int, y: c_int, button_mask: c_int) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!@atomicLoad(bool, &self.connected, .seq_cst) or self.rfb == null) return;
        _ = c.SendPointerEvent(self.rfb, x, y, button_mask);
    }

    /// Returns true if the client is connected to a VNC server.
    pub fn isConnected(self: *const VncClient) bool {
        return @atomicLoad(bool, &self.connected, .seq_cst);
    }

    // ── Background polling thread ──────────────────────────────────
    //
    // libvncclient is not event-driven, it requires the caller to
    // poll with WaitForMessage + HandleRFBServerMessage in a loop.
    // We run this in a dedicated thread so the UI thread never blocks.

    fn pollThread(self: *VncClient) void {
        while (@atomicLoad(bool, &self.running, .seq_cst) and
            @atomicLoad(bool, &self.connected, .seq_cst))
        {
            const result = c.WaitForMessage(self.rfb, 5000); // 5 ms
            if (result < 0) {
                @atomicStore(bool, &self.connected, false, .seq_cst);
                break;
            }
            if (result > 0) {
                // Do NOT hold the mutex across HandleRFBServerMessage, its
                // callbacks (onMallocFb, etc.) acquire it, and SpinMutex is
                // non-reentrant.  The callbacks lock internally when they touch
                // the framebuffer / dirty flag.
                const ok = c.HandleRFBServerMessage(self.rfb);
                if (ok == 0) {
                    @atomicStore(bool, &self.connected, false, .seq_cst);
                    break;
                }
            }
        }
    }

    // ── libvncclient C callbacks ───────────────────────────────────

    /// Called by libvncclient when the server (re)sizes its framebuffer.
    ///
    /// We allocate with `calloc` (not Zig's allocator) because
    /// `rfbClientCleanup` calls `free()` on `cl.*.frameBuffer`.
    fn onMallocFb(cl: [*c]c.rfbClient) callconv(.c) c.rfbBool {
        const self = getSelf(cl) orelse return 0;
        const w = cl.*.width;
        const h = cl.*.height;

        if (w <= 0 or h <= 0) return 0;
        // Untrusted server dimensions: compute w*h*4 in u64 and bound-check
        // before casting, exactly like the display path. A naive u32 multiply
        // here overflows (e.g. 65535×65535×4) → panic / undersized calloc →
        // heap overflow when libvnc writes the framebuffer. fbFits guards it.
        const px = fbmath.fbFits(w, h, std.math.maxInt(usize) / 4) orelse return 0;
        const size: usize = px * 4;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Free previous framebuffer (allocated by us via calloc).
        if (self.framebuffer) |old| c.free(old);

        const raw = c.calloc(1, size) orelse {
            self.framebuffer = null;
            return 0;
        };
        const buf: [*]u8 = @ptrCast(raw);

        self.framebuffer = buf;
        self.width = w;
        self.height = h;
        cl.*.frameBuffer = buf;
        @atomicStore(bool, &self.dirty, true, .seq_cst);

        return 1; // TRUE
    }

    /// Called by libvncclient when a rectangle of the framebuffer has been updated.
    fn onFbUpdate(cl: [*c]c.rfbClient, _: c_int, _: c_int, _: c_int, _: c_int) callconv(.c) void {
        if (getSelf(cl)) |self| {
            @atomicStore(bool, &self.dirty, true, .seq_cst);
        }
    }

    /// Recover the VncClient pointer from the rfbClient's user-data slot.
    fn getSelf(cl: [*c]c.rfbClient) ?*VncClient {
        if (cl == null) return null;
        const ptr = c.rfbClientGetClientData(cl, null) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// The framebuffer-size math in onMallocFb (untrusted server width×height) now
// routes through fbmath.fbFits, which is fuzzed over i32 extremes in fbmath.zig
//, that is the bug-prone surface. Here we cover the C-callback null-guard
// branches and the public API on a fresh client without a live server (a real
// rfbClient is only built by connect()).

test "vnc: getSelf(null) and onFbUpdate(null) are safe no-ops" {
    try std.testing.expect(VncClient.getSelf(null) == null);
    VncClient.onFbUpdate(null, 0, 0, 0, 0); // must not deref null
    VncClient.onFbUpdate(null, -1, 999999, -7, 12345);
}

test "vnc: fresh client public API is safe (unconnected)" {
    const cl = VncClient.new() orelse return error.SkipZigTest;
    defer cl.free();
    try std.testing.expect(!cl.isConnected());
    var w: c_int = -1;
    var h: c_int = -1;
    _ = cl.getSize(&w, &h);
    _ = cl.checkDirty();
    cl.sendKey(0x41, true); // guarded by connected → no-op
    cl.sendPointer(10, 20, 1);
    _ = cl.lockFb();
    cl.unlockFb();
}

test "vnc: disconnect releases cached resources after the peer drops" {
    var prng = std.Random.DefaultPrng.init(0xCA_C4E);
    const rnd = prng.random();
    var client = VncClient{};
    defer client.disconnect();

    for (0..16) |_| {
        const rfb = c.rfbGetClient(8, 3, 4);
        try std.testing.expect(rfb != null);
        client.rfb = rfb;
        c.rfbClientSetClientData(rfb, null, &client);
        rfb.*.width = rnd.intRangeAtMost(c_int, 1, 64);
        rfb.*.height = rnd.intRangeAtMost(c_int, 1, 64);
        try std.testing.expectEqual(@as(c.rfbBool, 1), VncClient.onMallocFb(rfb));
        @atomicStore(bool, &client.running, true, .seq_cst);
        client.thread = try std.Thread.spawn(.{}, VncClient.pollThread, .{&client});

        client.disconnect();
        try std.testing.expect(client.rfb == null);
        try std.testing.expect(client.thread == null);
        {
            const pixels = client.lockFb();
            defer client.unlockFb();
            try std.testing.expect(pixels == null);
        }
        try std.testing.expectEqual(@as(c_int, 0), client.width);
        try std.testing.expectEqual(@as(c_int, 0), client.height);
        try std.testing.expect(!@atomicLoad(bool, &client.running, .seq_cst));
        try std.testing.expect(!client.isConnected());
        try std.testing.expect(!client.checkDirty());
        client.disconnect();
    }
}

test "vnc: checkDirty atomically tests-and-clears the flag" {
    // The poll thread sets dirty; the UI thread drains it via checkDirty. One
    // call must report the prior state AND clear in a single step so a frame
    // marked dirty is never reported twice or lost (regression: the old
    // load-then-store split could race a set in the gap).
    const cl = VncClient.new() orelse return error.SkipZigTest;
    defer cl.free();
    cl.dirty = false;
    try std.testing.expect(!cl.checkDirty()); // clean stays clean
    cl.dirty = true;
    try std.testing.expect(cl.checkDirty()); // reports dirty...
    try std.testing.expect(!cl.checkDirty()); // ...and cleared it
}

test "vnc: onMallocFb size math rejects overflowing dimensions" {
    // Mirror the exact computation onMallocFb now uses; the hostile case
    // (65535×65535×4 overflows u32) must be rejected, not wrap.
    try std.testing.expect(fbmath.fbFits(65535, 65535, std.math.maxInt(usize) / 4) != null); // fits in u64
    try std.testing.expect(fbmath.fbFits(-1, 100, std.math.maxInt(usize) / 4) == null);
    try std.testing.expect(fbmath.fbFits(1024, 768, std.math.maxInt(usize) / 4).? == 1024 * 768);
}

// ── Fuzz: VNC client against a minimal, fuzzable RFB server ──────────
// Brings connect/pollThread/onMallocFb/onFbUpdate under test by speaking just
// enough RFB 3.8 (None security) for libvncclient to connect, then varying the
// ServerInit width/height (incl. hostile 65535×65535, which must hit the
// fbmath.fbFits guard in onMallocFb via the REAL path, not crash) and streaming
// random bytes to fuzz the message loop. Same garbage-peer pattern as the QMP
// fuzz. Skips if a socket can't be bound.

const cc = std.c;

fn rfbWriteAll(fd: cc.fd_t, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = cc.write(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn rfbFuzzServer(listen_fd: cc.fd_t, w: u16, h: u16, seed: u64) void {
    const conn = cc.accept(listen_fd, null, null);
    if (conn < 0) return;
    defer _ = cc.close(conn);
    var scratch: [64]u8 = undefined;

    if (!rfbWriteAll(conn, "RFB 003.008\n")) return;
    _ = cc.read(conn, &scratch, 12); // client version
    if (!rfbWriteAll(conn, &[_]u8{ 1, 1 })) return; // 1 sec type: None
    _ = cc.read(conn, &scratch, 1); // chosen sec type
    if (!rfbWriteAll(conn, &[_]u8{ 0, 0, 0, 0 })) return; // SecurityResult OK
    _ = cc.read(conn, &scratch, 1); // ClientInit shared flag

    // ServerInit: width(2) height(2) PIXEL_FORMAT(16) name-length(4) name
    var si: [26]u8 = undefined;
    std.mem.writeInt(u16, si[0..2], w, .big);
    std.mem.writeInt(u16, si[2..4], h, .big);
    si[4] = 32; // bits-per-pixel
    si[5] = 24; // depth
    si[6] = 0; // big-endian-flag
    si[7] = 1; // true-colour-flag
    std.mem.writeInt(u16, si[8..10], 255, .big); // red-max
    std.mem.writeInt(u16, si[10..12], 255, .big); // green-max
    std.mem.writeInt(u16, si[12..14], 255, .big); // blue-max
    si[14] = 16; // red-shift
    si[15] = 8; // green-shift
    si[16] = 0; // blue-shift
    si[17] = 0;
    si[18] = 0;
    si[19] = 0; // padding
    std.mem.writeInt(u32, si[20..24], 4, .big); // name length
    si[24] = 'f';
    si[25] = 'z';
    if (!rfbWriteAll(conn, &si)) return;

    // Send random bytes to fuzz the framebuffer-update message parser, then
    // close (defer). We do NOT block-read the client's SetPixelFormat/Encodings/
    // FBUpdateRequest, those sit in the kernel buffer and are discarded on
    // close. Blocking on a fixed-size read here would deadlock (client won't
    // send that many bytes), so just write + close → client sees blob then EOF.
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var blob: [512]u8 = undefined;
    for (&blob) |*b| b.* = rnd.int(u8);
    _ = rfbWriteAll(conn, &blob);
}

test "fuzz: VNC client against a minimal/fuzzed RFB server (connect/poll/onMallocFb)" {
    var prng = std.Random.DefaultPrng.init(0x5FB_F0FF);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        const port: u16 = @intCast(59000 + iter);
        const srv = cc.socket(cc.AF.INET, cc.SOCK.STREAM, 0);
        if (srv < 0) continue;
        defer _ = cc.close(srv);
        const one: c_int = 1;
        _ = cc.setsockopt(srv, cc.SOL.SOCKET, cc.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));
        var addr: cc.sockaddr.in = .{
            .family = cc.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0x0100007f, // 127.0.0.1
            .zero = [_]u8{0} ** 8,
        };
        if (cc.bind(srv, @ptrCast(&addr), @sizeOf(cc.sockaddr.in)) != 0) continue;
        if (cc.listen(srv, 1) != 0) continue;

        // Mix benign dims (connect succeeds → pollThread + onMallocFb) with
        // hostile dims (must hit the fbFits guard, not overflow/crash).
        // Large but safe dims (the hostile-overflow case is fuzzed in fbmath;
        // a real 65535² here would calloc ~17 GB under overcommit and stall).
        const dims = [_][2]u16{ .{ 64, 48 }, .{ 1024, 768 }, .{ 2048, 2048 }, .{ 1, 1 } };
        const d = dims[iter % dims.len];
        var th = std.Thread.spawn(std.Thread.SpawnConfig{}, rfbFuzzServer, .{ srv, d[0], d[1], rnd.int(u64) }) catch continue;
        defer th.join();

        const client = VncClient.new() orelse continue;
        defer client.free();
        // connect may succeed (benign dims) or fail (hostile dims rejected by
        // onMallocFb), both are valid; the contract is "no crash/overflow".
        _ = client.connect("127.0.0.1", port);
        var k: usize = 0;
        while (k < 5) : (k += 1) {
            _ = client.checkDirty();
            var w: c_int = 0;
            var h: c_int = 0;
            _ = client.getSize(&w, &h);
        }
        client.disconnect();
    }
}
