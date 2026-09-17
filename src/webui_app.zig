// SPDX-License-Identifier: MIT
//! Hangar WebUI Desktop App: native WebView wrapper for the web frontend.
//!
//! Spawns the hangar-web HTTP backend as a child process, then opens
//! a zig-webui native window showing the web UI. The existing HTML/CSS/JS
//! frontend communicates with the backend via fetch() to loopback on the
//! resolved port (KV_PORT, default 9080, see resolvePort), no frontend
//! changes needed.

const std = @import("std");
const webui = @import("webui");
const appio = @import("appio.zig");
const transport = @import("transport.zig");
const wlog = @import("wlog.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;
const WNOHANG: c_int = 1;

fn resolvePort() !u16 {
    return transport.configPort(appio.getenv("KV_PORT"));
}

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

/// Spawn the hangar-web backend process and wait until it accepts connections
/// on `port` (the port the child binds via inherited KV_PORT).
/// Open `url` in the system default browser via xdg-open (fire-and-forget).
/// Used when the native WebView backend is unavailable, instead of webui's own
/// browser-show path, which drives the GTK/webkit loop and crashes on some hosts.
fn openInBrowser(url: [:0]const u8) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const prog: [*:0]const u8 = "xdg-open";
        const argv: [3:null]?[*:0]const u8 = .{ prog, url.ptr, null };
        _ = execvp(prog, @ptrCast(&argv));
        std.c._exit(1);
    }
    // Parent doesn't track xdg-open: it returns promptly after launching.
}

/// Block until the spawned backend exits (used when running in browser-fallback
/// mode, where there's no webui window to wait on). Keeps the daemon serving.
fn waitForBackend() void {
    if (g_child_pid <= 0) return;
    var status: c_int = 0;
    _ = waitpid(g_child_pid, &status, 0);
    g_child_pid = -1;
}

fn spawnBackend(port: u16) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child process: exec the hangar-web binary.
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

    // Parent: store child PID for cleanup.
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
            .port = std.mem.nativeToBig(u16, port),
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

const usage =
    \\hangar-webui: Hangar native desktop app (WebView wrapper)
    \\
    \\Usage: hangar-webui [--help] [--version]
    \\
    \\Launches the hangar-web backend as a child process and opens it in a
    \\native window. Honors KV_PORT (default 9080) to match the backend.
    \\
    \\Options:
    \\  -h, --help     Show this help and exit
    \\  -v, --version  Show version and exit
    \\
    \\Environment (passed through to the spawned hangar-web backend):
    \\  KV_API_KEY           X-API-Key secret (1-64 bytes). Setting a non-default
    \\                       key also exposes the backend on all interfaces (::);
    \\                       unset or the built-in default stays loopback-only.
    \\  KV_PORT              TCP listen port (default 9080; must be 1-65535).
    \\  HANGAR_CONFIG_HOME   Base dir for ~/.config/hangar/* state (default $HOME).
    \\
    \\Exit codes: 0 success, 1 runtime error, 2 usage error.
    \\
;

const version_str = "hangar-webui 0.1.0\n";

/// Argument classes for the desktop wrapper's minimal flag set. It takes no
/// positional arguments, so a bare word is `.other` and the app launches; a
/// dash-prefixed token that is not help/version is `.unknown` (a mistyped
/// flag) and is rejected rather than silently ignored.
const CliArg = enum { help, version, unknown, other };

/// Classify a single command-line argument. Matches `vmrun`/`hangar-web`
/// spellings so all three tools accept the same help/version flags.
fn classifyCliArg(arg: []const u8) CliArg {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) return .help;
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) return .version;
    if (arg.len > 0 and arg[0] == '-') return .unknown;
    return .other;
}

pub fn main(init: std.process.Init) !void {
    // Handle --help/--version before spawning the backend or opening a window.
    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        _ = args_iter.next(); // program name
        while (args_iter.next()) |arg| switch (classifyCliArg(arg)) {
            .help => {
                _ = std.c.write(1, usage.ptr, usage.len);
                std.process.exit(0);
            },
            .version => {
                _ = std.c.write(1, version_str.ptr, version_str.len);
                std.process.exit(0);
            },
            .unknown => {
                // argv crosses a trust boundary: sanitize before echoing it.
                var safe_buf: [64]u8 = undefined;
                const safe = wlog.sanitizeLogText(&safe_buf, arg[0..@min(arg.len, safe_buf.len)]);
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Error: unknown option '{s}' (run with --help for usage)\n", .{safe}) catch "Error: unknown option\n";
                _ = std.c.write(2, msg.ptr, msg.len);
                std.process.exit(2);
            },
            .other => {},
        };
    }

    // Start the web backend on the configured port (KV_PORT or default).
    const port = resolvePort() catch {
        const msg = "Error: KV_PORT must be 1-65535\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        std.process.exit(1);
    };
    if (appio.getenv("KV_API_KEY")) |key| {
        if (!transport.validApiKey(key)) {
            const msg = "Error: KV_API_KEY must be 1-64 bytes of printable ASCII (no spaces or control characters)\n";
            _ = std.c.write(2, msg.ptr, msg.len);
            std.process.exit(1);
        }
    }
    try spawnBackend(port);
    defer stopBackend();

    var w = webui.newWindow();

    w.setSize(1280, 800);
    w.setMinimumSize(800, 500);
    w.setCenter();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}", .{port});

    // Show the window using WebView for a native desktop experience.
    w.showWv(url) catch {
        // The embedded WebView is unavailable on this host. Do NOT fall back to
        // webui's own browser-show: it drives the same GTK/webkit event loop and
        // segfaults on some webkit2gtk builds (a null webView in the title-change
        // signal handler). Open the system browser directly and keep the daemon
        // alive until it exits, so the UI still works.
        openInBrowser(url) catch {
            const msg = "Error: failed to open hangar-webui window\n";
            _ = std.c.write(2, msg.ptr, msg.len);
            stopBackend();
            std.process.exit(1);
        };
        const note = "hangar-webui: native WebView unavailable; opened the UI in your browser.\nPress Ctrl-C to stop.\n";
        _ = std.c.write(2, note.ptr, note.len);
        waitForBackend();
        return;
    };

    // Block until the window is closed.
    webui.wait();

    webui.clean();
}

// ── Tests ───────────────────────────────────────────────────────────

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "classifyCliArg: help and version spellings" {
    try std.testing.expectEqual(CliArg.help, classifyCliArg("-h"));
    try std.testing.expectEqual(CliArg.help, classifyCliArg("--help"));
    try std.testing.expectEqual(CliArg.help, classifyCliArg("help"));
    try std.testing.expectEqual(CliArg.version, classifyCliArg("-v"));
    try std.testing.expectEqual(CliArg.version, classifyCliArg("--version"));
}

test "classifyCliArg: mistyped flags are unknown, bare words are other" {
    try std.testing.expectEqual(CliArg.other, classifyCliArg(""));
    try std.testing.expectEqual(CliArg.unknown, classifyCliArg("--versionx"));
    try std.testing.expectEqual(CliArg.other, classifyCliArg("HELP"));
}

test "fuzz: classifyCliArg never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0x1CEB00DA);
    const rnd = prng.random();
    var buf: [32]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = classifyCliArg(buf[0..len]);
    }
}

test "resolvePort: unset falls back to default" {
    const saved = appio.getenv("KV_PORT");
    defer {
        if (saved) |v| _ = setenv("KV_PORT", @ptrCast(v.ptr), 1) else _ = unsetenv("KV_PORT");
    }
    _ = unsetenv("KV_PORT");
    try std.testing.expectEqual(transport.DEFAULT_PORT, try resolvePort());
}

test "resolvePort: valid KV_PORT is honored" {
    const saved = appio.getenv("KV_PORT");
    defer {
        if (saved) |v| _ = setenv("KV_PORT", @ptrCast(v.ptr), 1) else _ = unsetenv("KV_PORT");
    }
    _ = setenv("KV_PORT", "12345", 1);
    try std.testing.expectEqual(@as(u16, 12345), try resolvePort());
}

test "resolvePort: invalid values do not fall back to default" {
    const saved = appio.getenv("KV_PORT");
    defer {
        if (saved) |v| _ = setenv("KV_PORT", @ptrCast(v.ptr), 1) else _ = unsetenv("KV_PORT");
    }
    for ([_][:0]const u8{ "", "0", "not-a-port", "99999999" }) |value| {
        _ = setenv("KV_PORT", value.ptr, 1);
        try std.testing.expectError(error.InvalidPort, resolvePort());
    }
}

test "fuzz: resolvePort never panics on random KV_PORT" {
    const saved = appio.getenv("KV_PORT");
    defer {
        if (saved) |v| _ = setenv("KV_PORT", @ptrCast(v.ptr), 1) else _ = unsetenv("KV_PORT");
    }
    var prng = std.Random.DefaultPrng.init(0xC0FFEE42);
    const rnd = prng.random();
    var buf: [16:0]u8 = undefined;
    for (0..1000) |_| {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        buf[len] = 0;
        _ = setenv("KV_PORT", &buf, 1);
        const p = resolvePort() catch |err| {
            try std.testing.expectEqual(error.InvalidPort, err);
            continue;
        };
        try std.testing.expect(p != 0);
    }
}

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
