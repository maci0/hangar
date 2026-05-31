//! Headless IUP integration smoke test (run under Xvfb via `zig build itest`).
//!
//! The GUI modules (icons.zig, dialogs.zig, display.zig, main.zig builders) link
//! IUP + GTK and cannot be exercised by `zig test` (the static IUP libs need the
//! `cc` link step, and the widgets need a mapped display). This program links
//! exactly like the real app, opens IUP against the X server Xvfb provides, then
//! drives every icon builder, the display canvas, and all four dialog builders —
//! pumping the event loop so each canvas ACTION (drawMemBar / drawSnapGraph) and
//! widget map runs. Any crash, assertion, or non-zero exit fails the test.
//!
//! It provides the `app*` extern shims that dialogs.zig expects from main.zig
//! (so we link the GUI without main.zig's own `main`).

const std = @import("std");

const iup = @cImport({
    @cInclude("iup.h");
    @cInclude("iupcontrols.h");
    @cInclude("iupdraw.h");
});

const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
const dialogs = @import("dialogs.zig");
const icons = @import("icons.zig");
const display = @import("display.zig");
const vnc = @import("vnc_client.zig");
const spice = @import("spice_client.zig");
const serial = @import("serial.zig");
const c = std.c;

var test_vm: vm.VmConfig = .{};
var test_qmp: qmp.QmpClient = .{};

// ── Shims for the symbols dialogs.zig imports from main.zig ──
export fn appRefreshAll() void {}
export fn appAddVm(cfg: *const vm.VmConfig) bool {
    _ = cfg;
    return true;
}
export fn appGetSelectedVm() ?*vm.VmConfig {
    return &test_vm;
}
export fn appStyleTabs(tabs: ?*anyopaque) void {
    _ = tabs;
}
export fn appStyleDialog(dlg: ?*anyopaque) void {
    _ = dlg;
}
export fn appQmpClientPtr() *qmp.QmpClient {
    return &test_qmp;
}
export fn appEnsureQmpConnected() bool {
    return false; // offline path; no disk set → no qemu-img spawn
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("itest FAIL: {s}\n", .{msg});
    std.process.exit(2);
}

pub fn main() void {
    if (iup.IupOpen(null, null) == iup.IUP_ERROR) fail("IupOpen failed");
    defer iup.IupClose();

    // 1) Every icon builder (covers all of icons.zig + its private make/computer).
    const built = [_]?*anyopaque{
        icons.newVm(),    icons.powerOn(),  icons.powerOff(), icons.suspend_(),
        icons.settings(), icons.vmStopped(), icons.vmRunning(),
        icons.osLinux(),  icons.osWindows(), icons.osMac(),    icons.osBsd(),
        icons.devCpu(),   icons.devMem(),    icons.devDisk(),  icons.devCd(),
        icons.devNet(),   icons.appIcon(),
    };
    for (built) |ic| if (ic == null) fail("icon builder returned null");

    // 2) Display canvas builder.
    var disp = display.Display{};
    _ = disp.createArea() catch fail("display.createArea failed");

    // Give the test VM a name (but NO disk, so the snapshot dialog takes the
    // "no disk image" branch instead of spawning qemu-img).
    test_vm.setName("itest");

    // 3) All four dialog builders (non-modal IupShowXY) — exercises the dialog
    //    construction paths, makeMemBar / makeNetworkDropdown / makeLabeled /
    //    vnetRow, and the canvas ACTION draw callbacks once mapped.
    dialogs.showNewVmDialog();
    dialogs.showEditVmDialog(&test_vm, 0);
    dialogs.showSnapshotManager();
    dialogs.showVirtualNetworkEditor();

    // 4) Pump the event loop so widgets map and canvases paint.
    var i: usize = 0;
    while (i < 80) : (i += 1) _ = iup.IupLoopStep();

    // 5) Fuzz harnesses for the C-interop + builder functions that `zig test`
    //    can't link. Fixed seed → reproducible.
    var prng = std.Random.DefaultPrng.init(0x1757_C0DE);
    const rnd = prng.random();
    fuzzIcons(rnd);
    fuzzVnc(rnd);
    fuzzSpice(rnd);
    fuzzSerial(rnd);

    std.debug.print("itest OK\n", .{});
}

/// Stress every icon builder repeatedly (no input to vary; assert each call
/// keeps returning a valid image and never crashes/leaks the IUP image cache).
fn fuzzIcons(rnd: std.Random) void {
    _ = rnd;
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        const ok = icons.newVm() != null and icons.powerOn() != null and
            icons.powerOff() != null and icons.suspend_() != null and
            icons.settings() != null and icons.vmStopped() != null and
            icons.vmRunning() != null and icons.osLinux() != null and
            icons.osWindows() != null and icons.osMac() != null and
            icons.osBsd() != null and icons.devCpu() != null and
            icons.devMem() != null and icons.devDisk() != null and
            icons.devCd() != null and icons.devNet() != null and icons.appIcon() != null;
        if (!ok) fail("icon builder returned null under stress");
    }
}

/// Fuzz the VNC client public API on unconnected clients (send*/getSize/etc are
/// guarded by the connected flag) + connect to a refused port (fast failure).
fn fuzzVnc(rnd: std.Random) void {
    var n: usize = 0;
    while (n < 150) : (n += 1) {
        const cl = vnc.VncClient.new() orelse continue;
        cl.sendKey(rnd.int(u32), rnd.boolean());
        cl.sendPointer(rnd.int(c_int), rnd.int(c_int), rnd.int(c_int));
        var w: c_int = 0;
        var h: c_int = 0;
        _ = cl.getSize(&w, &h);
        _ = cl.checkDirty();
        _ = cl.isConnected();
        _ = cl.lockFb();
        cl.unlockFb();
        if (rnd.uintLessThan(u8, 8) == 0) _ = cl.connect("127.0.0.1", rnd.int(c_int)); // refused → false
        cl.free();
    }
}

/// Fuzz the SPICE client public API on unconnected clients.
fn fuzzSpice(rnd: std.Random) void {
    var n: usize = 0;
    while (n < 100) : (n += 1) {
        const cl = spice.SpiceClient.new() orelse continue;
        cl.setInvalidateCb(null, null);
        cl.sendKey(rnd.int(u32), rnd.boolean());
        cl.sendPointer(rnd.int(c_int), rnd.int(c_int), rnd.int(c_int));
        var w: c_int = 0;
        var h: c_int = 0;
        _ = cl.getSize(&w, &h);
        _ = cl.getFb();
        _ = cl.checkDirty();
        _ = cl.isConnected();
        if (rnd.uintLessThan(u8, 16) == 0) {
            _ = cl.connect("127.0.0.1", rnd.intRangeAtMost(c_int, 1, 65535)); // refused/async
            cl.disconnect();
        }
        cl.free();
    }
}

/// Fuzz the serial reader path: a garbage AF_UNIX server streams random bytes;
/// the reader thread + ring buffer + termfilter sanitizer consume them, drained
/// via pollUpdate into the IUP widget. Exercises connect/readerThread/pollUpdate/
/// disconnect against untrusted output.
fn fuzzSerial(rnd: std.Random) void {
    var s = serial.Serial{};
    _ = s.createWidget() catch return;
    s.setSocketPath("fuzz"); // → /tmp/kvmgui-serial-fuzz.sock (what connect() dials)

    // Bind the garbage server at the EXACT path connect() will dial.
    const path = "/tmp/kvmgui-serial-fuzz.sock";
    _ = c.unlink(path);
    const srv = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (srv < 0) return;
    defer _ = c.close(srv);
    defer _ = c.unlink(path);
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    if (c.bind(srv, @ptrCast(&addr), addrlen) != 0) return;
    if (c.listen(srv, 1) != 0) return;

    var th = std.Thread.spawn(.{}, serialFuzzServer, .{ srv, rnd.int(u64) }) catch return;
    defer th.join();

    // connect() dials the server → reader thread streams the garbage bytes
    // through the ring buffer; pollUpdate drains them via termfilter.sanitize.
    _ = s.connect();
    var k: usize = 0;
    while (k < 50) : (k += 1) {
        s.pollUpdate();
        _ = iup.IupLoopStep();
    }
    s.disconnect();
}

fn serialFuzzServer(listen_fd: c.fd_t, seed: u64) void {
    const conn = c.accept(listen_fd, null, null);
    if (conn < 0) return;
    defer _ = c.close(conn);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var blob: [4096]u8 = undefined;
    var rounds: usize = 0;
    while (rounds < 30) : (rounds += 1) {
        const m = rnd.uintLessThan(usize, blob.len);
        for (blob[0..m]) |*x| x.* = rnd.int(u8); // raw guest bytes incl. control/binary
        if (c.write(conn, &blob, m) <= 0) break;
    }
}
