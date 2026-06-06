// SPDX-License-Identifier: MIT
//! Remote API transport helpers for the web frontend.
//!
//! Thin wrappers around transport.Connection that parse the remote URL,
//! send HTTP requests, and refresh the local VM list from a remote server.

const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const transport = @import("transport.zig");
const app = @import("appstate.zig");

fn clearVmmHandleSlotsLocked() void {
    for (&app.g_vmm_handles) |*slot| {
        slot.* = null;
    }
}

fn remoteUrlSlice() ?[]const u8 {
    if (!@atomicLoad(bool, &app.remote_mode, .seq_cst)) return null;
    const len = @atomicLoad(usize, &app.remote_url_len, .seq_cst);
    if (len == 0 or len > app.remote_url.len) return null;
    return app.remote_url[0..len];
}

/// GET from the remote server. Returns bytes read.
pub fn apiGet(path: []const u8, out: []u8) usize {
    const url_slice = remoteUrlSlice() orelse return 0;
    const url = transport.Url.parse(url_slice) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("GET", path, null, out);
}

/// POST to the remote server. Returns bytes read.
pub fn apiPost(path: []const u8, body: []const u8, out: []u8) usize {
    const url_slice = remoteUrlSlice() orelse return 0;
    const url = transport.Url.parse(url_slice) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("POST", path, body, out);
}

/// Fetch the full vms.json config from the remote server and load it locally.
pub fn remoteRefreshVmList() void {
    const url_slice = remoteUrlSlice() orelse return;
    const url = transport.Url.parse(url_slice) orelse return;
    var conn = transport.Connection.connect(&url) orelse return;
    defer conn.close();

    var buf: [64 * 1024]u8 = undefined;
    const n = conn.request("GET", "/api/config", null, &buf);
    if (n == 0) return;
    var tmp_prefs: vm.Prefs = .{};
    app.vms_mutex.lock();
    clearVmmHandleSlotsLocked();
    app.vm_count = persist.loadFromSlice(&app.vms, buf[0..n], &tmp_prefs);
    app.prefs = tmp_prefs;
    app.vms_mutex.unlock();
}

// ── tests ──────────────────────────────────────────────────────────
const testing = std.testing;

test "apiGet: returns 0 when remote_mode is false" {
    app.remote_mode = false;
    var buf: [256]u8 = undefined;
    const n = apiGet("/api/vms", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "apiGet: returns 0 when remote_url_len is 0" {
    app.remote_mode = true;
    app.remote_url_len = 0;
    var buf: [256]u8 = undefined;
    const n = apiGet("/api/vms", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "apiGet: returns 0 when remote_url_len exceeds buffer" {
    app.remote_mode = true;
    app.remote_url_len = app.remote_url.len + 1;
    defer app.remote_url_len = 0;
    var buf: [256]u8 = undefined;
    const n = apiGet("/api/vms", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "apiPost: returns 0 when remote_mode is false" {
    app.remote_mode = false;
    var buf: [256]u8 = undefined;
    const n = apiPost("/api/power/0", "body", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "apiPost: returns 0 when remote_url_len is 0" {
    app.remote_mode = true;
    app.remote_url_len = 0;
    var buf: [256]u8 = undefined;
    const n = apiPost("/api/power/0", "body", &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "remoteRefreshVmList: no-op when not in remote mode" {
    app.remote_mode = false;
    const before = app.vm_count;
    remoteRefreshVmList();
    try testing.expectEqual(before, app.vm_count);
}

test "remoteRefreshVmList: no-op when remote_url_len is 0" {
    app.remote_mode = true;
    app.remote_url_len = 0;
    const before = app.vm_count;
    remoteRefreshVmList();
    try testing.expectEqual(before, app.vm_count);
}

test "fuzz: apiGet/apiPost/remoteRefreshVmList never panic with random URLs" {
    var prng = std.Random.DefaultPrng.init(0x8E0_7E57);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        app.remote_mode = true;
        // Use unix:// scheme so connections fail fast (no DNS blocking).
        const prefix = "unix:///";
        @memcpy(app.remote_url[0..prefix.len], prefix);
        const tail = rnd.uintLessThan(usize, @min(60, app.remote_url.len - prefix.len));
        for (app.remote_url[prefix.len..][0..tail]) |*c| c.* = rnd.intRangeAtMost(u8, 33, 126);
        app.remote_url_len = prefix.len + tail;
        // apiGet -- should return 0 or some valid usize, never panic
        const gn = apiGet("/api/vms", &buf);
        try testing.expect(gn <= buf.len);
        // apiPost -- should return 0 or some valid usize, never panic
        @memset(buf[0..32], 'x');
        const pn = apiPost("/api/save/0", buf[0..@min(32, buf.len - 1)], &buf);
        try testing.expect(pn <= buf.len);
        // remoteRefreshVmList -- should never panic
        const before = app.vm_count;
        remoteRefreshVmList();
        _ = before;
    }
}
