//! Remote API transport helpers for the FLTK frontend.
//!
//! Thin wrappers around transport.Connection that parse the remote URL,
//! send HTTP requests, and refresh the local VM list from a remote server.

const std = @import("std");
const vm = @import("vm.zig");
const persist = @import("persist.zig");
const transport = @import("transport.zig");
const app = @import("appstate.zig");

/// GET from the remote server. Returns bytes read.
pub fn apiGet(path: []const u8, out: []u8) usize {
    if (!app.remote_mode or app.remote_url_len == 0) return 0;
    const url = transport.Url.parse(app.remote_url[0..app.remote_url_len]) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("GET", path, null, out);
}

/// POST to the remote server. Returns bytes read.
pub fn apiPost(path: []const u8, body: []const u8, out: []u8) usize {
    if (!app.remote_mode or app.remote_url_len == 0) return 0;
    const url = transport.Url.parse(app.remote_url[0..app.remote_url_len]) orelse return 0;
    var conn = transport.Connection.connect(&url) orelse return 0;
    defer conn.close();
    return conn.request("POST", path, body, out);
}

/// Fetch the full vms.json config from the remote server and load it locally.
pub fn remoteRefreshVmList() void {
    if (!app.remote_mode or app.remote_url_len == 0) return;
    const url = transport.Url.parse(app.remote_url[0..app.remote_url_len]) orelse return;
    var conn = transport.Connection.connect(&url) orelse return;
    defer conn.close();

    var buf: [64 * 1024]u8 = undefined;
    const n = conn.request("GET", "/api/config", null, &buf);
    if (n == 0) return;
    var tmp_prefs: vm.Prefs = .{};
    app.vm_count = persist.loadFromSlice(&app.vms, buf[0..n], &tmp_prefs);
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
