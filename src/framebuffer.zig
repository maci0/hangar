//! VNC framebuffer capture → BMP image. Keeps a single cached VNC connection
//! (consecutive framebuffer polls almost always hit the same running VM) behind
//! its own mutex, re-keyed on (vm index, vnc port) so a table shift can't serve
//! a stale screen. Self-contained: depends only on appstate + the VNC client.

const std = @import("std");
const appstate = @import("appstate.zig");
const vnc = @import("vnc_client.zig");
const sync = @import("sync.zig");

/// Max BMP payload: 2 MB of 32-bit pixels + the 54-byte header.
pub const BMP_BUF_SIZE = 2 * 1024 * 1024 + 54;

var fb_client: ?*vnc.VncClient = null;
// VM index the cached connection is bound to. appstate.MAX_VMS = sentinel (none).
var fb_vm_idx: usize = appstate.MAX_VMS;
// VNC port behind that index. A delete/clone can shift the table so the same
// index maps to a different VM/port; re-keying on the port closes that hole.
var fb_vnc_port: c_int = -1;
var fb_mutex: sync.SpinMutex = .{};

fn warn(msg: []const u8) void {
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// Render VM `idx`'s current framebuffer into `out` as a top-down 32-bit BMP.
/// Returns the BMP slice on success, or a short error token ("no vm", "off",
/// "no vnc", "no fb") that the caller maps to an HTTP status.
pub fn render(idx: usize, out: []u8) []const u8 {
    // Resolve the VM's VNC port under the lock, then release it before any VNC
    // I/O (never hold vms_mutex across network I/O).
    appstate.vms_mutex.lock();
    if (idx >= appstate.vm_count) {
        appstate.vms_mutex.unlock();
        return "no vm";
    }
    const v = &appstate.vms[idx];
    if (!v.isAlive()) {
        appstate.vms_mutex.unlock();
        return "off";
    }
    const vnc_port = v.vnc_port;
    appstate.vms_mutex.unlock();

    fb_mutex.lock();
    defer fb_mutex.unlock();

    if (fb_client == null) {
        fb_client = vnc.VncClient.new() orelse return "no vnc";
        fb_vm_idx = appstate.MAX_VMS; // not yet connected to any VM
    }
    const vc = fb_client.?;
    // Reconnect if the VM changed, the port behind this index changed (table
    // shifted by a delete/clone), or the connection dropped.
    if (fb_vm_idx != idx or fb_vnc_port != @as(c_int, @intCast(vnc_port)) or !vc.isConnected()) {
        if (fb_vm_idx != appstate.MAX_VMS) vc.disconnect();
        _ = vc.connect("127.0.0.1", @intCast(vnc_port));
        fb_vm_idx = idx;
        fb_vnc_port = @intCast(vnc_port);
    }
    if (vc.lockFb()) |pixels| {
        defer vc.unlockFb();
        var fw: c_int = 0;
        var fh: c_int = 0;
        if (vc.getSize(&fw, &fh) and fw > 0 and fh > 0) {
            const pixel_size: usize = @intCast(@as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4);
            if (out.len < 54) return "no fb";
            const copy_size = @min(pixel_size, out.len - 54);
            if (pixel_size > out.len - 54) {
                var wb: [128]u8 = undefined;
                warn(std.fmt.bufPrint(&wb, "[hangar] VNC framebuffer {d}x{d} ({d} bytes) truncated to {d} bytes\n", .{ fw, fh, pixel_size, out.len - 54 }) catch "[hangar] VNC framebuffer truncated\n");
            }
            const file_size: u32 = @intCast(54 + copy_size);

            // ── BITMAPFILEHEADER (14 bytes) ──────────────────────
            out[0] = 'B';
            out[1] = 'M';
            std.mem.writeInt(u32, out[2..6], file_size, .little); // bfSize
            std.mem.writeInt(u32, out[6..10], 0, .little); // bfReserved
            std.mem.writeInt(u32, out[10..14], 54, .little); // bfOffBits

            // ── BITMAPINFOHEADER (40 bytes) ──────────────────────
            @memset(out[14..54], 0); // zero-fill then set fields
            std.mem.writeInt(u32, out[14..18], 40, .little); // biSize
            std.mem.writeInt(i32, out[18..22], fw, .little); // biWidth
            std.mem.writeInt(i32, out[22..26], -fh, .little); // biHeight (negative = top-down)
            std.mem.writeInt(u16, out[26..28], 1, .little); // biPlanes
            std.mem.writeInt(u16, out[28..30], 32, .little); // biBitCount
            // biCompression = 0 (BI_RGB), biSizeImage = 0 (OK for BI_RGB)
            // biXPelsPerMeter = biYPelsPerMeter = 2835 (~72 DPI)
            std.mem.writeInt(u32, out[38..42], 2835, .little);
            std.mem.writeInt(u32, out[42..46], 2835, .little);

            // ── Pixel data ───────────────────────────────────────
            @memcpy(out[54..][0..copy_size], @as([*]const u8, @ptrCast(pixels))[0..copy_size]);
            return out[0 .. 54 + copy_size];
        }
    }
    return "no fb";
}

// ── Tests ───────────────────────────────────────────────────────────

test "framebuffer: out-of-range idx returns 'no vm'" {
    // vm_count is 0 in a fresh test binary, so any index is out of range.
    try std.testing.expectEqualStrings("no vm", render(appstate.MAX_VMS, &[_]u8{}));
}
