// SPDX-License-Identifier: MIT
//! SPICE display client — pure-Zig wrapper around spice-client-glib-2.0.
//!
//! Runs on the GLib main loop, so all callbacks fire on the main thread.
//! No additional threading or mutexes are needed for framebuffer access.
//!
//! GObject macros (`SPICE_IS_DISPLAY_CHANNEL`, `G_CALLBACK`, `g_signal_connect`)
//! are replaced with their underlying C functions: `g_type_check_instance_is_a`,
//! `g_signal_connect_data`, and `@ptrCast`.

const std = @import("std");
const sync = @import("sync.zig");

/// Hand-written bindings for the few spice-client-glib / GLib symbols we use.
///
/// Zig 0.16's C importer (aro) cannot translate GLib's headers because they
/// emit `_Pragma("GCC diagnostic ...")` at file scope, which aro rejects.
/// Rather than translate the headers, we declare the exact symbols we need by
/// hand and link against the libraries directly (added in build.zig).
const c = struct {
    // ── GLib scalar typedefs ────────────────────────────────────────
    pub const gint = c_int;
    pub const guint = c_uint;
    pub const gboolean = c_int;
    pub const gpointer = ?*anyopaque;
    pub const gulong = c_ulong;
    /// `GType` is `gsize` (`unsigned long`).
    pub const GType = c_ulong;
    pub const GCallback = ?*const fn () callconv(.c) void;
    pub const GClosureNotify = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
    pub const GConnectFlags = c_uint;

    // ── Opaque GObject / SPICE types ────────────────────────────────
    pub const GTypeInstance = opaque {};
    pub const SpiceSession = opaque {};
    pub const SpiceChannel = opaque {};
    pub const SpiceInputsChannel = opaque {};

    /// Mirrors `struct _SpiceDisplayPrimary` from channel-display.h.
    pub const SpiceDisplayPrimary = extern struct {
        format: c_int, // enum SpiceSurfaceFmt
        width: gint,
        height: gint,
        stride: gint,
        shmid: gint,
        data: [*c]u8, // guint8 *
        marked: gboolean,
    };

    // ── GLib / GObject functions ────────────────────────────────────
    pub extern fn g_object_set(object: gpointer, ...) void;
    pub extern fn g_object_unref(object: gpointer) void;
    pub extern fn g_signal_connect_data(
        instance: gpointer,
        detailed_signal: [*:0]const u8,
        c_handler: GCallback,
        data: gpointer,
        destroy_data: GClosureNotify,
        connect_flags: GConnectFlags,
    ) gulong;
    pub extern fn g_type_check_instance_is_a(instance: ?*GTypeInstance, iface_type: GType) gboolean;

    // ── SPICE functions ─────────────────────────────────────────────
    // Pointer params are optional to mirror C's nullable pointers and accept
    // the (statically non-null) call sites without extra unwrapping.
    pub extern fn spice_session_new() ?*SpiceSession;
    pub extern fn spice_session_connect(session: ?*SpiceSession) gboolean;
    /// Construct a channel GObject of `channel_type` (used in tests to build a
    /// real, unconnected SpiceChannel for the signal callbacks).
    pub extern fn spice_channel_new(session: ?*SpiceSession, channel_type: gint, id: gint) ?*SpiceChannel;
    pub extern fn spice_session_disconnect(session: ?*SpiceSession) void;
    pub extern fn spice_channel_connect(channel: ?*SpiceChannel) gboolean;
    pub extern fn spice_display_channel_get_type() GType;
    pub extern fn spice_display_channel_get_primary(channel: ?*SpiceChannel, surface_id: u32, primary: *SpiceDisplayPrimary) gboolean;
    pub extern fn spice_inputs_channel_get_type() GType;
    pub extern fn spice_inputs_channel_key_press(channel: ?*SpiceInputsChannel, scancode: guint) void;
    pub extern fn spice_inputs_channel_key_release(channel: ?*SpiceInputsChannel, scancode: guint) void;
    pub extern fn spice_inputs_channel_position(channel: ?*SpiceInputsChannel, x: gint, y: gint, display: gint, button_state: gint) void;
};

const alloc = std.heap.c_allocator;

pub const InvalidateCb = *const fn (?*anyopaque) callconv(.c) void;

pub const SpiceClient = struct {
    session: ?*c.SpiceSession = null,
    inputs: ?*c.SpiceInputsChannel = null,
    fb_data: ?[*]const u8 = null,
    width: c_int = 0,
    height: c_int = 0,
    stride: c_int = 0,
    connected: bool = false,
    dirty: bool = false,
    mutex: sync.SpinMutex = .{},
    invalidate_cb: ?InvalidateCb = null,
    invalidate_userdata: ?*anyopaque = null,

    /// Allocate a new disconnected SPICE client.
    pub fn new() ?*SpiceClient {
        const self = alloc.create(SpiceClient) catch return null;
        self.* = .{};
        return self;
    }

    /// Connect to a SPICE server.
    /// The connection proceeds asynchronously on the GLib main loop.
    ///
    /// We use `g_object_set` to set session properties because SPICE
    /// exposes host/port as GObject properties rather than constructor
    /// arguments.  The port is formatted as a string because that's
    /// what the "port" property expects (GObject string property).
    pub fn connect(self: *SpiceClient, host: [*:0]const u8, port: c_int) bool {
        if (self.connected) return false;

        const session = c.spice_session_new();
        if (session == null) return false;
        self.session = session;

        // Set host/port properties via g_object_set (variadic).
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return false;
        c.g_object_set(
            @as(c.gpointer, @ptrCast(session)),
            "host",
            host,
            "port",
            @as([*:0]const u8, port_str.ptr),
            @as(?*anyopaque, null),
        );

        // Connect GObject signals — replaces the g_signal_connect() macro
        // with the underlying g_signal_connect_data() function.
        connectSignal(session, "channel-new", @ptrCast(&onChannelNew), self);
        connectSignal(session, "channel-destroy", @ptrCast(&onChannelDestroy), self);

        if (c.spice_session_connect(session) == 0) {
            c.g_object_unref(@as(c.gpointer, @ptrCast(session)));
            self.session = null;
            return false;
        }

        self.connected = true;
        return true;
    }

    /// Disconnect from the SPICE server.
    ///
    /// Nulls `inputs` and clears `connected` inside the mutex so that
    /// `sendKey` / `sendPointer` (which check them under the mutex)
    /// see a consistent state — preventing a TOCTOU use-after-free.
    pub fn disconnect(self: *SpiceClient) void {
        if (!self.connected) return;

        if (self.session) |s| {
            c.spice_session_disconnect(s);
            c.g_object_unref(@as(c.gpointer, @ptrCast(s)));
        }
        self.session = null;

        self.mutex.lock();
        self.inputs = null;
        self.fb_data = null;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
        self.connected = false;
        @atomicStore(bool, &self.dirty, false, .seq_cst);
        self.mutex.unlock();
    }

    /// Free all resources.  Disconnects first if still connected.
    pub fn free(self: *SpiceClient) void {
        self.disconnect();
        alloc.destroy(self);
    }

    /// Set a callback for display invalidation events.
    pub fn setInvalidateCb(self: *SpiceClient, cb: ?InvalidateCb, userdata: ?*anyopaque) void {
        self.invalidate_cb = cb;
        self.invalidate_userdata = userdata;
    }

    /// Get the display surface dimensions.
    pub fn getSize(self: *const SpiceClient, width: *c_int, height: *c_int) bool {
        if (self.fb_data == null) return false;
        width.* = self.width;
        height.* = self.height;
        return true;
    }

    /// Get a pointer to the display pixel data (32-bit BGRA).
    /// Prefer `lockFb`/`unlockFb` for thread-safe access.
    pub fn getFb(self: *const SpiceClient) ?[*]const u8 {
        return self.fb_data;
    }

    /// Lock the framebuffer mutex and return a pointer to the pixel data.
    /// Format: 32-bit BGRA.  Caller MUST call `unlockFb` when done.
    pub fn lockFb(self: *SpiceClient) ?[*]const u8 {
        self.mutex.lock();
        return self.fb_data;
    }

    /// Unlock the framebuffer mutex.
    pub fn unlockFb(self: *SpiceClient) void {
        self.mutex.unlock();
    }

    /// Check and clear the dirty flag.
    ///
    /// Uses seq_cst atomics so writes from the GLib callbacks are visible
    /// to the UI thread without acquiring the framebuffer mutex.  The
    /// worst case of a lost dirty flag is a single skipped frame.
    pub fn checkDirty(self: *SpiceClient) bool {
        const was = @atomicLoad(bool, &self.dirty, .seq_cst);
        if (was) @atomicStore(bool, &self.dirty, false, .seq_cst);
        return was;
    }

    /// Send a key press/release.  `scancode` is a PC AT scancode.
    ///
    /// Protected by the mutex so that a concurrent `disconnect` cannot
    /// null `inputs` between the null-check and the channel call.
    pub fn sendKey(self: *SpiceClient, scancode: u32, down: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const inp = self.inputs orelse return;
        if (!self.connected) return;
        if (down) {
            c.spice_inputs_channel_key_press(inp, scancode);
        } else {
            c.spice_inputs_channel_key_release(inp, scancode);
        }
    }

    /// Send a pointer position + button state.
    pub fn sendPointer(self: *SpiceClient, x: c_int, y: c_int, button_state: c_int) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const inp = self.inputs orelse return;
        if (!self.connected) return;
        c.spice_inputs_channel_position(inp, x, y, 0, button_state);
    }

    /// Returns true if connected to a SPICE server.
    pub fn isConnected(self: *const SpiceClient) bool {
        return self.connected;
    }

    // ── GObject signal callbacks ───────────────────────────────────

    fn onChannelNew(_: ?*c.SpiceSession, channel: ?*c.SpiceChannel, data: ?*anyopaque) callconv(.c) void {
        const self: *SpiceClient = @ptrCast(@alignCast(data orelse return));
        const ch = channel orelse return;

        // SPICE multiplexes many channel types (display, inputs, cursor,
        // main, playback, etc.) over a single session.  We only need
        // special handling for display and inputs; all others are
        // connected automatically so the session stays healthy.
        if (isDisplayChannel(ch)) {
            connectSignal(ch, "display-primary-create", @ptrCast(&onPrimaryCreate), self);
            connectSignal(ch, "display-invalidate", @ptrCast(&onInvalidate), self);
            connectSignal(ch, "display-primary-destroy", @ptrCast(&onPrimaryDestroy), self);
            _ = c.spice_channel_connect(ch);
        } else if (isInputsChannel(ch)) {
            // Replace SPICE_INPUTS_CHANNEL() cast macro with @ptrCast.
            self.inputs = @ptrCast(@alignCast(ch));
            _ = c.spice_channel_connect(ch);
        } else {
            // Connect other channels (cursor, main, etc.) automatically.
            _ = c.spice_channel_connect(ch);
        }
    }

    fn onChannelDestroy(_: ?*c.SpiceSession, channel: ?*c.SpiceChannel, data: ?*anyopaque) callconv(.c) void {
        const self: *SpiceClient = @ptrCast(@alignCast(data orelse return));
        const ch = channel orelse return;
        if (isInputsChannel(ch)) {
            self.inputs = null;
        }
    }

    fn onPrimaryCreate(
        channel: ?*c.SpiceChannel,
        _: c.gint,
        width: c.gint,
        height: c.gint,
        stride: c.gint,
        _: c.gint,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *SpiceClient = @ptrCast(@alignCast(data orelse return));
        const ch = channel orelse return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Prefer `spice_display_channel_get_primary` because it gives us the
        // actual pixel data pointer.  The signal parameters only carry the
        // dimensions — the fb_data would be null without this call.
        var primary: c.SpiceDisplayPrimary = undefined;
        if (c.spice_display_channel_get_primary(ch, 0, &primary) != 0) {
            self.fb_data = primary.data;
            self.width = primary.width;
            self.height = primary.height;
            self.stride = primary.stride;
        } else {
            // Fallback: use the signal parameters directly.
            self.width = width;
            self.height = height;
            self.stride = stride;
        }
        @atomicStore(bool, &self.dirty, true, .seq_cst);
    }

    fn onInvalidate(
        _: ?*c.SpiceChannel,
        _: c.gint,
        _: c.gint,
        _: c.gint,
        _: c.gint,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *SpiceClient = @ptrCast(@alignCast(data orelse return));
        self.mutex.lock();
        @atomicStore(bool, &self.dirty, true, .seq_cst);
        self.mutex.unlock();
        if (self.invalidate_cb) |cb| {
            cb(self.invalidate_userdata);
        }
    }

    fn onPrimaryDestroy(_: ?*c.SpiceChannel, data: ?*anyopaque) callconv(.c) void {
        const self: *SpiceClient = @ptrCast(@alignCast(data orelse return));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fb_data = null;
        self.width = 0;
        self.height = 0;
        self.stride = 0;
    }

    // ── Helpers ────────────────────────────────────────────────────

    /// Replaces `SPICE_IS_DISPLAY_CHANNEL()` macro.
    fn isDisplayChannel(ch: *c.SpiceChannel) bool {
        const inst: *c.GTypeInstance = @ptrCast(@alignCast(ch));
        return c.g_type_check_instance_is_a(inst, c.spice_display_channel_get_type()) != 0;
    }

    /// Replaces `SPICE_IS_INPUTS_CHANNEL()` macro.
    fn isInputsChannel(ch: *c.SpiceChannel) bool {
        const inst: *c.GTypeInstance = @ptrCast(@alignCast(ch));
        return c.g_type_check_instance_is_a(inst, c.spice_inputs_channel_get_type()) != 0;
    }

    /// Replaces `g_signal_connect()` macro with the underlying function.
    ///
    /// The GLib macro expands to `g_signal_connect_data(obj, signal, cb, data, NULL, 0)`.
    /// We call the C function directly because Zig's `@cImport` cannot
    /// translate C macros that cast function pointers.
    fn connectSignal(obj: anytype, signal: [*:0]const u8, callback: c.GCallback, self: *SpiceClient) void {
        _ = c.g_signal_connect_data(
            @as(c.gpointer, @ptrCast(obj)),
            signal,
            callback,
            @as(c.gpointer, @ptrCast(self)),
            null,
            0,
        );
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// SpiceClient.new() is a plain struct alloc (no GLib init), and every public
// method + GLib signal callback guards its inputs (`orelse return` / null
// checks), so the safe surface is directly testable/fuzzable headless. The
// only un-reachable paths need a live SPICE server + GObject channels.

const testing = std.testing;

test "spice: fresh client public API is safe (unconnected)" {
    const cl = SpiceClient.new() orelse return;
    defer cl.free();
    try testing.expect(!cl.isConnected());
    var w: c_int = -1;
    var h: c_int = -1;
    try testing.expect(!cl.getSize(&w, &h)); // no fb yet
    try testing.expect(cl.getFb() == null);
    _ = cl.checkDirty();
    cl.setInvalidateCb(null, null);
    cl.sendKey(0x1c, true); // guarded by inputs==null → no-op
    cl.sendPointer(1, 2, 3);
}

test "spice: GLib signal callbacks guard null data (no deref)" {
    SpiceClient.onChannelNew(null, null, null);
    SpiceClient.onChannelDestroy(null, null, null);
    SpiceClient.onPrimaryCreate(null, 0, 0, 0, 0, 0, null);
    SpiceClient.onPrimaryDestroy(null, null);
    SpiceClient.onInvalidate(null, 0, 0, 0, 0, null);
}

test "fuzz: spice onInvalidate/onPrimaryDestroy self-side over random coords" {
    const cl = SpiceClient.new() orelse return;
    defer cl.free();
    var fired: bool = false;
    const Cb = struct {
        fn go(_: ?*anyopaque) callconv(.c) void {}
    };
    var prng = std.Random.DefaultPrng.init(0x5717_CE0F);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        cl.dirty = false;
        if (rnd.boolean()) cl.setInvalidateCb(&Cb.go, null) else cl.setInvalidateCb(null, null);
        SpiceClient.onInvalidate(null, rnd.int(c_int), rnd.int(c_int), rnd.int(c_int), rnd.int(c_int), @ptrCast(cl));
        try testing.expect(cl.dirty); // must mark dirty regardless of coords
        SpiceClient.onPrimaryDestroy(null, @ptrCast(cl));
        try testing.expect(cl.width == 0 and cl.height == 0 and cl.fb_data == null);
        fired = true;
    }
    try testing.expect(fired);
}

test "fuzz: spice channel callbacks against real (unconnected) channels" {
    // Build a real SpiceSession + SpiceChannels of each type WITHOUT a network
    // connection (like the vnc test uses a real rfbClient). This drives the
    // real branches of onChannelNew/onChannelDestroy/onPrimaryCreate —
    // isDisplayChannel/isInputsChannel g_type dispatch, spice_channel_connect
    // (returns FALSE on an unconnected session), and get_primary (no primary →
    // else branch) — rather than only the null-guard paths.
    const session = c.spice_session_new() orelse return;
    defer c.g_object_unref(session);
    const cl = SpiceClient.new() orelse return;
    defer cl.free();

    var prng = std.Random.DefaultPrng.init(0x5717_C0DE);
    const rnd = prng.random();
    // MAIN=1 DISPLAY=2 INPUTS=3 CURSOR=4 PLAYBACK=5 RECORD=6
    const types = [_]c.gint{ 1, 2, 3, 4, 5, 6 };
    for (types) |ct| {
        const ch = c.spice_channel_new(session, ct, 0) orelse continue;
        defer c.g_object_unref(ch);
        SpiceClient.onChannelNew(session, ch, @ptrCast(cl));
        // onPrimaryCreate only on the display channel (ct==2); get_primary on a
        // non-display channel just trips a benign libspice assertion warning.
        if (ct == 2) SpiceClient.onPrimaryCreate(ch, 0, rnd.int(c.gint), rnd.int(c.gint), rnd.int(c.gint), 0, @ptrCast(cl));
        SpiceClient.onChannelDestroy(session, ch, @ptrCast(cl));
    }
}
