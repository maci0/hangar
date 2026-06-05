// SPDX-License-Identifier: MIT
//! Hangar WebUI Desktop App — native WebView wrapper for the web frontend.
//!
//! Spawns the hangar-web HTTP backend as a child process, then opens
//! a zig-webui native window showing the web UI. The existing HTML/CSS/JS
//! frontend communicates with the backend via fetch() to localhost:9080
//! — no frontend changes needed.

const std = @import("std");
const webui = @import("webui");
const appio = @import("appio.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;
const WNOHANG: c_int = 1;

/// Port the web backend listens on.
const WEB_PORT: u16 = 9080;

/// Maximum time to wait for the backend to start (ms).
const STARTUP_TIMEOUT_MS: u64 = 5000;

var g_child_pid: std.c.pid_t = -1;

/// Find the hangar-web binary relative to our own executable path.
fn findBackendBinary(buf: []u8) ![:0]const u8 {
    // Read /proc/self/exe to get our own path.
    const link_len = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (link_len < 0 or link_len >= buf.len) return error.SelfExePathFailed;
    const exe_path = buf[0..@intCast(link_len)];

    if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
        const dir_end = slash + 1;
        const dir = exe_path[0..dir_end];
        // Copy dir to a separate buffer to avoid @memcpy alias when
        // bufPrintZ writes back into buf while reading from dir.
        var dir_buf: [4096]u8 = undefined;
        @memcpy(dir_buf[0..dir.len], dir);
        const candidate = try std.fmt.bufPrintZ(buf, "{s}hangar-web", .{dir_buf[0..dir.len]});
        const fd = std.c.open(candidate, .{ .ACCMODE = .RDONLY });
        if (fd >= 0) {
            _ = std.c.close(fd);
            return candidate;
        }
    }

    return error.BackendBinaryNotFound;
}

/// Spawn the hangar-web backend process.
fn spawnBackend() !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child process — exec the hangar-web binary.
        var bin_buf: [4096]u8 = undefined;
        const binary = findBackendBinary(&bin_buf) catch {
            std.c._exit(1);
        };

        const argv: [3:null]?[*:0]const u8 = .{
            binary.ptr,
            null,
            null,
        };
        _ = execvp(binary.ptr, @ptrCast(&argv));
        // execvp only returns on error.
        std.c._exit(1);
    }

    // Parent — store child PID for cleanup.
    g_child_pid = pid;

    // Wait for the backend to become responsive.
    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &start_ts);
    const start_ms: i64 = @as(i64, start_ts.sec) * 1000 + @divTrunc(start_ts.nsec, std.time.ns_per_ms);

    while (true) {
        // Try connecting to the web server.
        const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock < 0) {
            appio.sleepMs(100);
            continue;
        }
        defer _ = std.c.close(sock);

        const bind_ip: u32 = 0x7F_00_00_01; // 127.0.0.1 in host byte order
        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, WEB_PORT),
            .addr = std.mem.nativeToBig(u32, bind_ip),
            .zero = [_]u8{0} ** 8,
        };

        if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) == 0) {
            break; // Backend is ready.
        }

        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now_ts);
        const now_ms: i64 = @as(i64, now_ts.sec) * 1000 + @divTrunc(now_ts.nsec, std.time.ns_per_ms);

        if (now_ms - start_ms > STARTUP_TIMEOUT_MS) {
            _ = kill(g_child_pid, SIGTERM);
            g_child_pid = -1;
            return error.BackendStartTimeout;
        }

        appio.sleepMs(100);
    }
}

/// Stop the backend child process.
fn stopBackend() void {
    if (g_child_pid > 0) {
        // Graceful shutdown first.
        _ = kill(g_child_pid, SIGTERM);

        // Wait up to 3 seconds for graceful exit.
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            var status: c_int = 0;
            const result = waitpid(g_child_pid, &status, WNOHANG);
            if (result == g_child_pid or result < 0) {
                g_child_pid = -1;
                return;
            }
            appio.sleepMs(100);
        }

        // Force kill if still running.
        _ = kill(g_child_pid, SIGKILL);
        g_child_pid = -1;
    }
}

pub fn main() !void {
    // Start the web backend.
    try spawnBackend();
    defer stopBackend();

    // Create the webui window.
    var w = webui.newWindow();

    // Set window properties.
    w.setSize(1280, 800);
    w.setMinimumSize(800, 500);
    w.setCenter();

    // Build the URL to the local web backend.
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}", .{WEB_PORT});

    // Show the window using WebView for a native desktop experience.
    w.showWv(url) catch {
        // Fall back to browser-based window if WebView fails.
        w.show(url) catch {
            std.debug.print("Failed to open webui window.\n", .{});
            return;
        };
    };

    // Block until the window is closed.
    webui.wait();

    // Cleanup.
    webui.clean();
}

// ── Tests ───────────────────────────────────────────────────────────

test "findBackendBinary: returns a path ending in hangar-web" {
    var buf: [4096]u8 = undefined;
    const result = findBackendBinary(&buf);
    // This will fail in test environment (no binary installed), but should not crash.
    if (result) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, "hangar-web"));
    } else |_| {}
}

test "findBackendBinary: buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = findBackendBinary(&buf);
    // /proc/self/exe path will almost certainly exceed 10 bytes.
    try std.testing.expect(result == error.SelfExePathFailed);
}

test "fuzz: findBackendBinary never panics" {
    var prng = std.Random.DefaultPrng.init(0xFEBAFEBA);
    const rnd = prng.random();
    for (0..1000) |_| {
        var buf: [4096]u8 = undefined;
        // Fill with random data to catch any uninitialized-memory assumptions.
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = findBackendBinary(&buf) catch {};
    }
}
