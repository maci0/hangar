// SPDX-License-Identifier: MIT
//! QEMU Machine Protocol (QMP) client.
//!
//! Connects to QEMU's QMP Unix domain socket and provides a high-level API
//! for VM control: pause, resume, power down, reset, quit, suspend-to-file,
//! live migration, and snapshot management (via HMP tunneling).
//!
//! Protocol: JSON-based, line-delimited.  Connection flow:
//!   1. Connect to Unix socket
//!   2. Read greeting ({"QMP": ...})
//!   3. Send {"execute": "qmp_capabilities"}
//!   4. Read success response ({"return": {}})
//!   5. Send commands, read responses
//!
//! Snapshot operations use `human-monitor-command` to tunnel HMP commands
//! (savevm, loadvm, delvm, info snapshots) because QMP lacks native
//! internal snapshot commands.
//!
//! The JSON builder and parser are hand-rolled to avoid `std.json`, which
//! pulls in f128 float math that causes linker errors with the system `cc`
//! link step.

const std = @import("std");
const vm = @import("vm.zig");
const usock = @import("usock.zig");
const appio = @import("appio.zig");

/// Maximum line length for a QMP JSON message.
const MAX_LINE = 16384;

/// Per-read/write socket timeout. A frozen QEMU monitor must not be able to
/// wedge the calling thread indefinitely; commands fail fast instead.
const QMP_IO_TIMEOUT_MS = 10_000;

/// Build the QMP Unix socket path for a VM.
///
/// The VM name is used directly as a filesystem-path key, so it must be
/// path-safe. The web input boundary enforces this (`vm.isValidVmName`), but
/// names loaded from `vms.json` or supplied by the remote daemon do not pass
/// through that check — enforce the invariant here so a name containing a path
/// separator or NUL can never escape the `/tmp` socket namespace.
///
/// Returns `null` if the name is not path-safe or is too long to fit.
pub fn socketPath(vm_name: []const u8, buf: *[256]u8) ?[]const u8 {
    if (!isPathSafeName(vm_name)) return null;
    return std.fmt.bufPrint(buf, "/tmp/hangar-qmp-{s}.sock", .{vm_name}) catch null;
}

/// Returns true when `name` contains no path separators or NUL, so it is safe
/// to interpolate into a single `/tmp/...` socket path component. Mirrors the
/// path-safety subset of `vm.isValidVmName` without pulling in `vm.zig`.
pub fn isPathSafeName(name: []const u8) bool {
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

/// QMP client for communicating with a single QEMU instance.
///
/// Usage:
///   var client = QmpClient{};
///   try client.connect("/tmp/hangar-qmp-MyVM.sock");
///   defer client.disconnect();
///   try client.pause();
///   try client.cont();
pub const QmpClient = struct {
    stream: ?usock.UnixStream = null,
    connected: bool = false,

    /// Internal line-read buffer.
    line_buf: [MAX_LINE]u8 = undefined,

    /// Socket read buffer. readLine pulls bytes from here, refilling with a
    /// single read() per buffer rather than one syscall per byte — QMP
    /// responses (query-block, snapshot lists) run to many KB.
    rbuf: [MAX_LINE]u8 = undefined,
    rbuf_pos: usize = 0,
    rbuf_len: usize = 0,

    // ── Connection management ───────────────────────────────────

    /// Connect to a QEMU QMP Unix socket and perform the capability
    /// negotiation handshake.
    pub fn connect(self: *QmpClient, socket_path_arg: []const u8) !void {
        if (self.connected) self.disconnect();

        const stream = usock.UnixStream.connect(socket_path_arg) catch
            return error.ConnectionFailed;
        // Guard every QMP read/write against a wedged QEMU: without this a
        // single-byte read in readLine blocks the calling (web request) thread
        // forever when the guest/monitor stops responding.
        stream.setTimeout(QMP_IO_TIMEOUT_MS);
        self.stream = stream;

        // Read greeting ({"QMP": ...})
        _ = self.readLine() catch {
            self.closeStream();
            return error.HandshakeFailed;
        };

        // Send qmp_capabilities
        self.writeAll("{\"execute\": \"qmp_capabilities\"}\n") catch {
            self.closeStream();
            return error.HandshakeFailed;
        };

        // Read response — skip any async events
        const resp = self.readResponse() catch {
            self.closeStream();
            return error.HandshakeFailed;
        };

        if (std.mem.indexOf(u8, resp, "\"return\"") == null) {
            self.closeStream();
            return error.HandshakeFailed;
        }

        self.connected = true;
    }

    /// Raw socket fd — used by dbusdisplay to sendmsg(SCM_RIGHTS) a file
    /// descriptor alongside the QMP `getfd` command.
    pub fn rawFd(self: *QmpClient) ?std.c.fd_t {
        const s = self.stream orelse return null;
        return s.fd;
    }

    /// Read one response and require a "return" key (skipping async events).
    pub fn expectReturn(self: *QmpClient) !void {
        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"return\"") == null) return error.CommandFailed;
    }

    /// Send a raw command line and require a successful "return" response.
    pub fn execExpectReturn(self: *QmpClient, cmd: []const u8) !void {
        try self.writeAll(cmd);
        try self.writeAll("\n");
        try self.expectReturn();
    }

    /// Disconnect from the QMP socket.
    pub fn disconnect(self: *QmpClient) void {
        self.closeStream();
        self.connected = false;
    }

    fn closeStream(self: *QmpClient) void {
        if (self.stream) |s| s.close();
        self.stream = null;
        self.rbuf_pos = 0;
        self.rbuf_len = 0;
    }

    // ── Low-level I/O ───────────────────────────────────────────

    /// Read a single line (up to `\n`) from the socket.
    /// Returns a slice into `self.line_buf`; valid until the next call.
    fn readLine(self: *QmpClient) ![]const u8 {
        var pos: usize = 0;
        while (pos < self.line_buf.len - 1) {
            if (self.rbuf_pos >= self.rbuf_len) {
                const stream = self.stream orelse return error.SocketClosed;
                const n = stream.read(&self.rbuf) catch return error.SocketClosed;
                if (n == 0) return error.SocketClosed;
                self.rbuf_len = n;
                self.rbuf_pos = 0;
            }
            const ch = self.rbuf[self.rbuf_pos];
            self.rbuf_pos += 1;
            if (ch == '\n') {
                // Strip trailing \r if present
                const end = if (pos > 0 and self.line_buf[pos - 1] == '\r') pos - 1 else pos;
                return self.line_buf[0..end];
            }
            self.line_buf[pos] = ch;
            pos += 1;
        }
        return self.line_buf[0..pos];
    }

    /// Read a command response, skipping any async event messages.
    /// Returns the line containing `"return"` or `"error"`.
    ///
    /// QEMU sends unsolicited event messages (BLOCK_IO_ERROR, SHUTDOWN,
    /// etc.) on the same socket.  We must skip them to find the actual
    /// command response; the 100-iteration cap prevents infinite loops
    /// if the server floods events.
    fn readResponse(self: *QmpClient) ![]const u8 {
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            const line = try self.readLine();
            if (std.mem.indexOf(u8, line, "\"return\"") != null or
                std.mem.indexOf(u8, line, "\"error\"") != null)
            {
                // QEMU replies to a failed command with
                // {"error":{"class":"...","desc":"..."}}. Callers collapse this
                // to a generic error.CommandFailed, discarding QEMU's reason —
                // log the raw error reply here (the single response funnel) so an
                // operator can tell *why* a power/snapshot/migrate op failed.
                if (std.mem.indexOf(u8, line, "\"error\"") != null) logErrorReply(line);
                return line;
            }
            // Otherwise it's an async event — skip and read again.
        }
        return error.CommandFailed;
    }

    /// Best-effort: write a QMP error reply to stderr (truncated). Used to
    /// preserve QEMU's failure reason that callers otherwise drop.
    fn logErrorReply(line: []const u8) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "qmp: command failed: {s}\n", .{
            line[0..@min(line.len, 400)],
        }) catch "qmp: command failed\n";
        _ = std.c.write(2, msg.ptr, msg.len);
    }

    /// Write all bytes to the socket, looping on partial writes.
    fn writeAll(self: *QmpClient, data: []const u8) !void {
        const stream = self.stream orelse return error.SocketClosed;
        var remaining = data;
        while (remaining.len > 0) {
            const written = stream.write(remaining) catch return error.SocketClosed;
            if (written == 0) return error.SocketClosed;
            remaining = remaining[written..];
        }
    }

    // ── Simple commands (no arguments) ──────────────────────────

    /// Send a simple QMP command (no arguments) and verify success.
    fn execSimple(self: *QmpClient, command: []const u8) !void {
        if (!self.connected) return error.ConnectionFailed;

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "{{\"execute\": \"{s}\"}}\n", .{command}) catch
            return error.BufferTooSmall;

        try self.writeAll(cmd);

        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) {
            return error.CommandFailed;
        }
    }

    // ── High-level VM control ───────────────────────────────────

    /// Pause the VM.
    pub fn pause(self: *QmpClient) !void {
        return self.execSimple("stop");
    }

    /// Resume a paused VM.
    pub fn cont(self: *QmpClient) !void {
        return self.execSimple("cont");
    }

    /// Send ACPI power button event (graceful guest shutdown).
    pub fn powerdown(self: *QmpClient) !void {
        return self.execSimple("system_powerdown");
    }

    /// Hard reset the VM.
    pub fn systemReset(self: *QmpClient) !void {
        return self.execSimple("system_reset");
    }

    /// Terminate the QEMU process cleanly.
    ///
    /// Unlike other commands, `quit` may close the socket before we
    /// can read the response — this is expected, so we swallow errors
    /// and mark ourselves disconnected either way.
    pub fn quit(self: *QmpClient) !void {
        self.execSimple("quit") catch {
            // "quit" may close the socket before we read the response.
            self.connected = false;
            return;
        };
        self.connected = false;
    }

    /// Suspend VM state to a file.
    pub fn suspendToFile(self: *QmpClient, path: []const u8) !void {
        var hmp_buf: [vm.MAX_PATH + 128]u8 = undefined;
        // The `exec:` migration target is run through `/bin/sh -c`, so quote
        // escaping alone is insufficient — backticks, `$()`, `;`, `|`, `&` and
        // friends would still be interpreted. Reject any path containing shell
        // metacharacters before it reaches the shell.
        if (!isShellSafePath(path)) return error.UnsafeStatePath;
        var esc_buf: [vm.MAX_PATH + 64]u8 = undefined;
        const escaped = escapeHmpArg(path, &esc_buf);
        const hmp_cmd = std.fmt.bufPrint(&hmp_buf, "migrate \"exec:cat > {s}\"", .{escaped}) catch
            return error.BufferTooSmall;

        var out: [1024]u8 = undefined;
        const result = try self.execHmp(hmp_cmd, &out);
        if (hmpReportedError(result)) return error.CommandFailed;
    }

    /// Block until migration finishes or timeout (30s).
    /// Polls `info migrate` every 500ms. Fails fast (instead of waiting out the
    /// full timeout) if QEMU reports the migration failed or was cancelled.
    pub fn waitMigrateComplete(self: *QmpClient) !void {
        var out: [2048]u8 = undefined;
        var attempts: u32 = 0;
        while (attempts < 60) : (attempts += 1) {
            const result = try self.execHmp("info migrate", &out);
            if (std.mem.indexOf(u8, result, "completed") != null) return;
            if (std.mem.indexOf(u8, result, "failed") != null) return error.MigrateFailed;
            if (std.mem.indexOf(u8, result, "cancelled") != null) return error.MigrateCancelled;
            appio.sleepMs(500);
        }
        return error.MigrateTimeout;
    }

    /// Start live migration to a destination URI (e.g. "tcp:10.0.0.2:4444").
    /// Uses QMP's native `migrate` command; returns immediately (detached).
    pub fn liveMigrate(self: *QmpClient, dest_uri: []const u8) !void {
        if (!self.connected) return error.ConnectionFailed;

        // dest_uri is embedded as a JSON string value, so it MUST be
        // JSON-escaped; a raw '"' or '\\' would otherwise produce a malformed
        // QMP object that QEMU rejects (same hazard as execHmp).
        var esc_buf: [200]u8 = undefined;
        const esc_uri = jsonEscapeString(dest_uri, &esc_buf) orelse return error.BufferTooSmall;

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "{{\"execute\":\"migrate\",\"arguments\":{{\"uri\":\"{s}\"}}}}\n",
            .{esc_uri},
        ) catch return error.BufferTooSmall;

        try self.writeAll(cmd);
        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) {
            return error.CommandFailed;
        }
    }

    /// Query live migration status via QMP `query-migrate`.
    /// Returns the status string (e.g. "active", "completed", "failed", "cancelled")
    /// in the caller-provided output buffer.
    pub fn queryMigrateStatus(self: *QmpClient, out: []u8) ![]const u8 {
        if (!self.connected) return error.ConnectionFailed;
        try self.writeAll("{\"execute\":\"query-migrate\"}\n");
        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) {
            return error.CommandFailed;
        }
        return extractJsonString(resp, "status", out);
    }

    /// Cancel an active live migration via QMP `migrate_cancel`.
    pub fn cancelMigrate(self: *QmpClient) !void {
        if (!self.connected) return error.ConnectionFailed;
        try self.writeAll("{\"execute\":\"migrate_cancel\"}\n");
        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) {
            return error.CommandFailed;
        }
    }

    // ── HMP tunneling (for snapshot management) ─────────────────
    //
    // QMP has no native internal snapshot commands, so we tunnel HMP
    // commands (savevm, loadvm, delvm, info snapshots) through the
    // `human-monitor-command` QMP method.

    /// Execute an HMP command via QMP's `human-monitor-command`.
    /// Returns the HMP output string in the caller-provided buffer.
    fn execHmp(self: *QmpClient, hmp_cmd: []const u8, out: []u8) ![]const u8 {
        if (!self.connected) return error.ConnectionFailed;

        // The HMP command is embedded as a JSON string value. It can itself
        // contain '"' and '\\' (e.g. a quoted, quote-escaped CD-ROM path from
        // changeCdrom, or the `migrate "exec:..."` target from suspendToFile),
        // so it MUST be JSON-escaped here. Interpolating it raw produces a
        // malformed QMP object that QEMU rejects, silently breaking every HMP
        // command whose argument carries a quote.
        var esc_buf: [1024]u8 = undefined;
        const esc_cmd = jsonEscapeString(hmp_cmd, &esc_buf) orelse return error.BufferTooSmall;

        // Build: {"execute":"human-monitor-command","arguments":{"command-line":"<cmd>"}}
        var cmd_buf: [1280]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "{{\"execute\": \"human-monitor-command\", \"arguments\": {{\"command-line\": \"{s}\"}}}}\n",
            .{esc_cmd},
        ) catch return error.BufferTooSmall;

        try self.writeAll(cmd);

        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) {
            return error.CommandFailed;
        }

        // Extract "return" string value (HMP output)
        return extractJsonString(resp, "return", out);
    }

    /// Run an HMP snapshot verb (`savevm`/`loadvm`/`delvm`) for `name`.
    /// HMP returns "" on success, or text containing "Error" on failure.
    fn execSnapshotHmp(self: *QmpClient, verb: []const u8, name: []const u8) !void {
        if (!isValidSnapshotTag(name)) return error.InvalidTag;
        var hmp_buf: [300]u8 = undefined;
        const hmp_cmd = std.fmt.bufPrint(&hmp_buf, "{s} {s}", .{ verb, name }) catch
            return error.BufferTooSmall;

        var out: [2048]u8 = undefined;
        const result = try self.execHmp(hmp_cmd, &out);

        if (hmpReportedError(result)) {
            // Snapshot ops are data-integrity critical (a failed loadvm can
            // leave the guest in an unexpected state). Surface HMP's reason
            // instead of swallowing it behind a bare error.CommandFailed.
            logErrorReply(result);
            return error.CommandFailed;
        }
    }

    /// Create an internal snapshot (VM must have a qcow2 disk).
    pub fn saveSnapshot(self: *QmpClient, name: []const u8) !void {
        return self.execSnapshotHmp("savevm", name);
    }

    /// Delete an internal snapshot.
    pub fn deleteSnapshot(self: *QmpClient, name: []const u8) !void {
        return self.execSnapshotHmp("delvm", name);
    }

    /// List internal snapshots.  Returns the tabular HMP output
    /// from `info snapshots` in the caller-provided buffer.
    pub fn listSnapshots(self: *QmpClient, out: []u8) ![]const u8 {
        return self.execHmp("info snapshots", out);
    }

    /// Send Ctrl+Alt+Delete key combination to the guest via HMP.
    pub fn sendCtrlAltDel(self: *QmpClient) !void {
        var out: [256]u8 = undefined;
        _ = try self.execHmp("sendkey ctrl-alt-delete", &out);
    }

    /// Change CD-ROM media via HMP.
    ///
    /// Uses the stable device id "ide2-cd0" that `qemu.zig` creates with
    /// an explicit `-device ide-cd,drive=cdrom0,id=ide2-cd0` argument.
    pub fn changeCdrom(self: *QmpClient, path: []const u8) !void {
        var hmp_buf: [vm.MAX_PATH * 2 + 128]u8 = undefined;
        // Escape double-quotes in the path to prevent HMP injection. Size for the
        // worst case (every byte a quote → doubled) so paths never truncate silently.
        var esc_buf: [vm.MAX_PATH * 2 + 1]u8 = undefined;
        const escaped = escapeHmpArg(path, &esc_buf);
        const hmp_cmd = std.fmt.bufPrint(&hmp_buf, "change ide2-cd0 \"{s}\"", .{escaped}) catch
            return error.BufferTooSmall;

        var out: [1024]u8 = undefined;
        const result = try self.execHmp(hmp_cmd, &out);

        if (hmpReportedError(result)) return error.CommandFailed;
    }

    /// Eject CD-ROM media via HMP.
    pub fn ejectCdrom(self: *QmpClient) !void {
        var out: [256]u8 = undefined;
        const result = try self.execHmp("eject ide2-cd0", &out);

        if (hmpReportedError(result)) return error.CommandFailed;
    }

    /// Capture the guest's display to a PNG at `path` (native QMP `screendump`).
    /// PNG support requires QEMU 7.1+. Caller serves/reads the file afterward.
    pub fn screenshotPng(self: *QmpClient, path: []const u8) !void {
        if (!self.connected) return error.ConnectionFailed;
        var esc_buf: [vm.MAX_PATH * 2 + 1]u8 = undefined;
        const esc = jsonEscapeString(path, &esc_buf) orelse return error.BufferTooSmall;
        var cmd_buf: [vm.MAX_PATH * 2 + 128]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "{{\"execute\": \"screendump\", \"arguments\": {{\"filename\": \"{s}\", \"format\": \"png\"}}}}\n",
            .{esc},
        ) catch return error.BufferTooSmall;
        try self.writeAll(cmd);
        const resp = try self.readResponse();
        if (std.mem.indexOf(u8, resp, "\"error\"") != null) return error.CommandFailed;
    }
};

/// True if an HMP command reply indicates failure.
/// HMP prints "" on success; failures contain "Error" (and sometimes "Could not").
fn hmpReportedError(result: []const u8) bool {
    return result.len > 0 and
        (std.mem.indexOf(u8, result, "Could not") != null or
            std.mem.indexOf(u8, result, "Error") != null);
}

// ── JSON string extraction helper ───────────────────────────────────
// Minimal parser that finds `"key": "value"` in a JSON string.
// Handles standard JSON escape sequences.

/// Decode a single hex digit to its 4-bit value, or null if not hex.
fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Encode a Unicode code point as UTF-8 into `out` at position `out_len`.
/// Returns BufferTooSmall if the output buffer is exhausted.
fn encodeUtf8(codepoint: u21, out: []u8, out_len: *usize) !void {
    if (codepoint <= 0x7F) {
        if (out_len.* >= out.len) return error.BufferTooSmall;
        out[out_len.*] = @intCast(codepoint);
        out_len.* += 1;
    } else if (codepoint <= 0x7FF) {
        if (out_len.* + 1 >= out.len) return error.BufferTooSmall;
        out[out_len.*] = @intCast(0xC0 | (codepoint >> 6));
        out[out_len.* + 1] = @intCast(0x80 | (codepoint & 0x3F));
        out_len.* += 2;
    } else if (codepoint <= 0xFFFF) {
        if (out_len.* + 2 >= out.len) return error.BufferTooSmall;
        out[out_len.*] = @intCast(0xE0 | (codepoint >> 12));
        out[out_len.* + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        out[out_len.* + 2] = @intCast(0x80 | (codepoint & 0x3F));
        out_len.* += 3;
    } else {
        if (out_len.* + 3 >= out.len) return error.BufferTooSmall;
        out[out_len.*] = @intCast(0xF0 | (codepoint >> 18));
        out[out_len.* + 1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
        out[out_len.* + 2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        out[out_len.* + 3] = @intCast(0x80 | (codepoint & 0x3F));
        out_len.* += 4;
    }
}

/// Parse a `\uXXXX` escape starting at `json[i]` (the backslash).
/// Returns the decoded code point and advances `i` past the escape.
/// Returns `error.CommandFailed` on malformed input.
fn parseUnicodeEscape(json: []const u8, i: *usize) !u21 {
    // Expect: \ u X X X X  (6 chars)
    if (i.* + 5 >= json.len) return error.CommandFailed;
    if (json[i.*] != '\\' or json[i.* + 1] != 'u') return error.CommandFailed;

    var cp: u21 = 0;
    var d: usize = 0;
    while (d < 4) : (d += 1) {
        const h = hexDigit(json[i.* + 2 + d]) orelse return error.CommandFailed;
        cp = (cp << 4) | @as(u21, h);
    }
    i.* += 6; // consumed \uXXXX

    // Handle UTF-16 surrogate pairs: high surrogate followed by \u + low.
    // A lone surrogate (high without a valid low, or a bare low) is not a valid
    // Unicode scalar and would encode to invalid UTF-8 (WTF-8) — reject it so we
    // never emit a malformed byte sequence into status/error strings.
    if (cp >= 0xD800 and cp <= 0xDBFF) {
        if (i.* + 5 >= json.len or json[i.*] != '\\' or json[i.* + 1] != 'u')
            return error.CommandFailed;
        var lo: u21 = 0;
        var d2: usize = 0;
        while (d2 < 4) : (d2 += 1) {
            const h2 = hexDigit(json[i.* + 2 + d2]) orelse return error.CommandFailed;
            lo = (lo << 4) | @as(u21, h2);
        }
        if (lo < 0xDC00 or lo > 0xDFFF) return error.CommandFailed;
        i.* += 6; // consumed the low surrogate
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
    } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
        return error.CommandFailed; // bare low surrogate
    }

    return cp;
}

/// Extract a JSON string value for the given key.
///
/// Searches the input for `"key": "..."` and writes the unescaped value
/// to `out`.  Returns a slice of `out` containing the result.
///
/// Works for both flat objects (`{"status": "running"}`) and the first
/// match in nested objects (`{"return": {"status": "paused"}}`).
pub fn extractJsonString(json: []const u8, key: []const u8, out: []u8) ![]const u8 {
    // Build the search needle: "key"
    var needle_buf: [130]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch
        return error.BufferTooSmall;

    // Find `"key"` used as an object key — an occurrence followed (after
    // optional whitespace) by ':'. A bare `indexOf` would also match the needle
    // inside a string *value* (e.g. an error reply whose "desc" mentions the
    // queried key), returning the wrong field or a spurious failure. Skip such
    // value matches and continue scanning for the real key.
    var i: usize = blk: {
        var base: usize = 0;
        while (std.mem.indexOfPos(u8, json, base, needle)) |kp| {
            var j = kp + needle.len;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) : (j += 1) {}
            if (j < json.len and json[j] == ':') break :blk j + 1;
            base = kp + needle.len;
        }
        return error.CommandFailed;
    };

    // Skip whitespace before the value.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len or json[i] != '"') return error.CommandFailed;
    i += 1; // skip opening quote

    // Read characters until closing quote, unescaping as we go.
    var out_len: usize = 0;
    while (i < json.len) {
        if (json[i] == '"') {
            return out[0..out_len];
        }
        // Output buffer full but string continues — fail rather than truncate.
        if (out_len >= out.len) {
            return error.BufferTooSmall;
        }
        if (json[i] == '\\' and i + 1 < json.len) {
            if (json[i + 1] == 'u') {
                const cp = try parseUnicodeEscape(json, &i);
                try encodeUtf8(cp, out, &out_len);
                continue;
            }
            const esc: u8 = switch (json[i + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '/' => '/',
                else => json[i + 1],
            };
            out[out_len] = esc;
            out_len += 1;
            i += 2;
        } else {
            out[out_len] = json[i];
            out_len += 1;
            i += 1;
        }
    }
    return error.CommandFailed; // unterminated string
}

// ── Tests ───────────────────────────────────────────────────────────

test "extractJsonString: extracts simple value" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"status": "running", "other": true}
    , "status", &out);
    try std.testing.expectEqualStrings("running", result);
}

test "extractJsonString: extracts from nested object" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"return": {"status": "paused"}}
    , "status", &out);
    try std.testing.expectEqualStrings("paused", result);
}

test "extractJsonString: handles escape sequences" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"return": "hello\nworld"}
    , "return", &out);
    try std.testing.expectEqualStrings("hello\nworld", result);
}

test "extractJsonString: ignores key needle inside a string value" {
    // The word "status" appears inside the "desc" value but is not a key there;
    // the extractor must return the real "status" field, not bail on the value.
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"desc": "bad status value", "status": "running"}
    , "status", &out);
    try std.testing.expectEqualStrings("running", result);
}

test "extractJsonString: returns error for missing key" {
    var out: [64]u8 = undefined;
    const result = extractJsonString(
        \\{"other": "value"}
    , "status", &out);
    try std.testing.expectError(error.CommandFailed, result);
}

test "extractJsonString: empty string value" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"return": ""}
    , "return", &out);
    try std.testing.expectEqualStrings("", result);
}

test "extractJsonString: value with escaped quotes" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "say \"hello\""}
    , "msg", &out);
    try std.testing.expectEqualStrings("say \"hello\"", result);
}

test "socketPath: builds correct path" {
    var buf: [256]u8 = undefined;
    const path = socketPath("TestVM", &buf) orelse unreachable;
    try std.testing.expectEqualStrings("/tmp/hangar-qmp-TestVM.sock", path);
}

test "socketPath: rejects path-unsafe names" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(socketPath("../../etc/x", &buf) == null);
    try std.testing.expect(socketPath("a/b", &buf) == null);
    try std.testing.expect(socketPath("a\\b", &buf) == null);
    try std.testing.expect(socketPath("a\x00b", &buf) == null);
    // A literal ".." with no separator is harmless and still allowed.
    const ok = socketPath("v1..v2", &buf) orelse unreachable;
    try std.testing.expectEqualStrings("/tmp/hangar-qmp-v1..v2.sock", ok);
}

test "isPathSafeName: separators and NUL" {
    try std.testing.expect(isPathSafeName("ubuntu-22.04"));
    try std.testing.expect(!isPathSafeName("a/b"));
    try std.testing.expect(!isPathSafeName("a\\b"));
    try std.testing.expect(!isPathSafeName("a\x00b"));
}

test "extractJsonString: handles tab escape" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "col1\tcol2"}
    , "msg", &out);
    try std.testing.expectEqualStrings("col1\tcol2", result);
}

test "extractJsonString: handles slash escape" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"path": "a\/b"}
    , "path", &out);
    try std.testing.expectEqualStrings("a/b", result);
}

test "extractJsonString: handles carriage return escape" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "line\r\n"}
    , "msg", &out);
    try std.testing.expectEqualStrings("line\r\n", result);
}

test "extractJsonString: unknown escape passes through literal" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "test\x"}
    , "msg", &out);
    // Unknown escape \x should pass through the 'x' literally.
    try std.testing.expectEqualStrings("testx", result);
}

test "extractJsonString: lone surrogate rejected (no invalid UTF-8)" {
    var out: [64]u8 = undefined;
    // Lone high surrogate — must fail rather than emit WTF-8 (ED A0 80).
    try std.testing.expectError(error.CommandFailed, extractJsonString(
        \\{"msg": "\uD800"}
    , "msg", &out));
    // High surrogate followed by a non-low-surrogate escape.
    try std.testing.expectError(error.CommandFailed, extractJsonString(
        \\{"msg": "\uD800A"}
    , "msg", &out));
    // Bare low surrogate.
    try std.testing.expectError(error.CommandFailed, extractJsonString(
        \\{"msg": "\uDC00"}
    , "msg", &out));
}

test "extractJsonString: extra whitespace around colon" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"status"  :  "ok"}
    , "status", &out);
    try std.testing.expectEqualStrings("ok", result);
}

test "extractJsonString: key not at start of JSON" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"first": 1, "second": "found"}
    , "second", &out);
    try std.testing.expectEqualStrings("found", result);
}

test "extractJsonString: output buffer exactly fits" {
    var out: [5]u8 = undefined;
    const result = try extractJsonString(
        \\{"k": "hello"}
    , "k", &out);
    try std.testing.expectEqualStrings("hello", result);
}

test "extractJsonString: unterminated string returns error" {
    var out: [64]u8 = undefined;
    const result = extractJsonString(
        \\{"k": "no end
    , "k", &out);
    try std.testing.expectError(error.CommandFailed, result);
}

test "extractJsonString: unicode escape basic ascii" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "A\u0042C"}
    , "msg", &out);
    try std.testing.expectEqualStrings("ABC", result);
}

test "extractJsonString: unicode escape 2-byte utf8" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "caf\u00e9"}
    , "msg", &out);
    try std.testing.expectEqualStrings("café", result);
}

test "extractJsonString: unicode escape 3-byte utf8" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "\u4e16\u754c"}
    , "msg", &out);
    try std.testing.expectEqualStrings("世界", result);
}

test "extractJsonString: unicode surrogate pair" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "\uD83D\uDE00"}
    , "msg", &out);
    try std.testing.expectEqualStrings("😀", result);
}

test "socketPath: returns null for overly long name" {
    // A name so long it overflows the 256-byte buffer.
    const long_name = "A" ** 256;
    var buf: [256]u8 = undefined;
    const result = socketPath(long_name, &buf);
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

// ── Fuzz tests ──────────────────────────────────────────────────────
//
// `extractJsonString` parses untrusted QMP/HMP responses into a fixed buffer,
// and `socketPath` formats a VM name into one. Feed both tens of thousands of
// random + adversarial inputs and assert they never crash, never write past
// the output buffer, and only return slices that live inside it. Reproducible
// via the fixed seed.

fn qmpFuzzFill(rnd: std.Random, buf: []u8) void {
    const toks = "{}[]\":,\\ \tstatusrunge0123456789";
    for (buf) |*b| {
        b.* = if (rnd.boolean()) toks[rnd.uintLessThan(usize, toks.len)] else rnd.int(u8);
    }
}

test "fuzz: extractJsonString never crashes or overflows" {
    var prng = std.Random.DefaultPrng.init(0x9911_2244);
    const rnd = prng.random();
    var json: [1024]u8 = undefined;
    var key: [160]u8 = undefined;
    var out: [256]u8 = undefined;

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        const jlen = rnd.uintLessThan(usize, json.len + 1);
        const klen = rnd.uintLessThan(usize, key.len + 1);
        qmpFuzzFill(rnd, json[0..jlen]);
        qmpFuzzFill(rnd, key[0..klen]);
        // Must never crash; erroring on garbage is fine.
        if (extractJsonString(json[0..jlen], key[0..klen], &out)) |res| {
            // On success the result must be a view inside `out`.
            const base = @intFromPtr(&out);
            const p = @intFromPtr(res.ptr);
            try std.testing.expect(p >= base and p + res.len <= base + out.len);
        } else |_| {}
    }
}

// Structure-aware fuzz: the random-byte fuzzer above essentially never forms a
// well-shaped `"k":"...\uXXXX..."` value, so the `\u` decoder (parseUnicodeEscape),
// its UTF-16 surrogate-pair handling, and the multi-byte UTF-8 encoder (encodeUtf8)
// stay unexercised. Build valid-shaped JSON carrying random `\uXXXX` escapes —
// including high/low surrogate combinations, both valid and broken — and assert
// the decoder never panics, never overflows `out`, and only ever emits valid UTF-8.
test "fuzz: extractJsonString unicode-escape decoding stays valid and bounded" {
    var prng = std.Random.DefaultPrng.init(0xCAFE_F00D);
    const rnd = prng.random();
    var json: [1024]u8 = undefined;
    var out: [512]u8 = undefined;
    const hex = "0123456789abcdefABCDEF";

    var iter: usize = 0;
    while (iter < 8000) : (iter += 1) {
        var n: usize = 0;
        const prefix = "{\"k\":\"";
        @memcpy(json[0..prefix.len], prefix);
        n += prefix.len;

        const escapes = rnd.uintLessThan(usize, 12);
        var e: usize = 0;
        while (e < escapes and n + 16 < json.len) : (e += 1) {
            switch (rnd.uintLessThan(u8, 5)) {
                // A valid surrogate pair: high (D800-DBFF) then low (DC00-DFFF).
                0 => {
                    const hi: u16 = 0xD800 + rnd.uintLessThan(u16, 0x400);
                    const lo: u16 = 0xDC00 + rnd.uintLessThan(u16, 0x400);
                    n += (std.fmt.bufPrint(json[n..], "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo }) catch break).len;
                },
                // A lone high surrogate (the decoder must reject — no broken UTF-8).
                1 => {
                    const hi: u16 = 0xD800 + rnd.uintLessThan(u16, 0x400);
                    n += (std.fmt.bufPrint(json[n..], "\\u{x:0>4}", .{hi}) catch break).len;
                },
                // A random BMP code point (covers 1/2/3-byte UTF-8 encoder paths).
                2 => {
                    const cp: u16 = rnd.int(u16);
                    n += (std.fmt.bufPrint(json[n..], "\\u{x:0>4}", .{cp}) catch break).len;
                },
                // A `\u` with possibly-garbage hex digits (some non-hex).
                3 => {
                    json[n] = '\\';
                    json[n + 1] = 'u';
                    var d: usize = 0;
                    while (d < 4) : (d += 1) {
                        json[n + 2 + d] = if (rnd.boolean())
                            hex[rnd.uintLessThan(usize, hex.len)]
                        else
                            rnd.int(u8);
                    }
                    n += 6;
                },
                // A plain literal ASCII byte mixed in with the escapes. Kept to
                // printable ASCII (minus quote/backslash) so the only non-ASCII
                // bytes in a successful result come from the `\u` decoder — that
                // lets us assert UTF-8 validity below (literal bytes are copied
                // through verbatim and are not otherwise validated).
                else => {
                    json[n] = 0x20 + rnd.uintLessThan(u8, 0x5F); // 0x20..0x7E
                    if (json[n] != '"' and json[n] != '\\') n += 1;
                },
            }
        }
        // Close the string + object (truncation also exercised: see below).
        if (n + 2 <= json.len and rnd.boolean()) {
            json[n] = '"';
            json[n + 1] = '}';
            n += 2;
        }

        if (extractJsonString(json[0..n], "k", &out)) |res| {
            const base = @intFromPtr(&out);
            const p = @intFromPtr(res.ptr);
            try std.testing.expect(p >= base and p + res.len <= base + out.len);
            // On success the decoder must only ever have emitted valid UTF-8.
            try std.testing.expect(std.unicode.utf8ValidateSlice(res));
        } else |_| {}
    }
}

test "fuzz: socketPath never crashes" {
    var prng = std.Random.DefaultPrng.init(0x3344_5566);
    const rnd = prng.random();
    var name: [400]u8 = undefined;
    var buf: [256]u8 = undefined;

    var iter: usize = 0;
    while (iter < 5000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, name.len + 1);
        for (name[0..n]) |*b| b.* = rnd.int(u8);
        if (socketPath(name[0..n], &buf)) |path| {
            try std.testing.expect(path.len <= buf.len);
        }
    }
}

// ── Fuzz: QMP client against a malformed/garbage server ──────────────
// QmpClient I/O methods (connect/readLine/readResponse/execSimple/execHmp and
// every command wrapper) can't run without a peer — so we bind a real AF_UNIX
// listener and a server thread that replies with random bytes (sometimes with
// newlines / "return" / oversized no-newline lines). The client must never
// crash, overflow line_buf, or hang. readLine is byte-bounded and readResponse
// caps at 100 attempts, so termination is guaranteed; this asserts it.

const c_qmp = std.c;

fn qmpFuzzServer(listen_fd: c_qmp.fd_t, seed: u64) void {
    const conn = c_qmp.accept(listen_fd, null, null);
    if (conn < 0) return;
    defer _ = c_qmp.close(conn);

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var blob: [MAX_LINE]u8 = undefined;

    // Every reply is ONE newline-terminated line that always contains the
    // "return"/"error" token readResponse scans for — otherwise readResponse
    // would call readLine again and block (the client and this single-blob
    // server would deadlock). The random bytes BETWEEN the markers are what
    // actually fuzzes extractJsonString / the per-method response parsing. The
    // line is bounded < MAX_LINE so readLine never has to fall back to its
    // buffer-full path (which also needs no newline and would re-loop).
    const sendBlob = struct {
        fn go(fd: c_qmp.fd_t, r: std.Random, b: []u8) void {
            const tok = if (r.boolean()) "{\"return\":" else "{\"error\":";
            @memcpy(b[0..tok.len], tok);
            // Random middle (no newline byte — keep it on one line).
            const mid_max = b.len - tok.len - 2; // room for "}\n"
            const mid = r.uintLessThan(usize, mid_max);
            for (b[tok.len..][0..mid]) |*x| {
                var c: u8 = r.int(u8);
                if (c == '\n') c = ' '; // never terminate early
                x.* = c;
            }
            b[tok.len + mid] = '}';
            b[tok.len + mid + 1] = '\n';
            _ = c_qmp.write(fd, b.ptr, tok.len + mid + 2);
        }
    }.go;

    // Greeting first (client's connect reads a line before anything).
    sendBlob(conn, rnd, &blob);

    // Then reply to each client request until it disconnects.
    var rounds: usize = 0;
    while (rounds < 40) : (rounds += 1) {
        var rb: [4096]u8 = undefined;
        const got = c_qmp.read(conn, &rb, rb.len);
        if (got <= 0) break; // client closed
        sendBlob(conn, rnd, &blob);
    }
}

test "fuzz: QmpClient survives a malformed/garbage server" {
    var prng = std.Random.DefaultPrng.init(0x9119_2244);
    const rnd = prng.random();
    var connected_sessions: usize = 0;
    var command_batches: usize = 0;

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var path_buf: [108]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-qmpfuzz-{d}-{d}.sock", .{ c_qmp.getpid(), iter });
        _ = c_qmp.unlink(path.ptr);

        const srv = c_qmp.socket(c_qmp.AF.UNIX, c_qmp.SOCK.STREAM, 0);
        if (srv < 0) continue;
        defer _ = c_qmp.close(srv);
        defer _ = c_qmp.unlink(path.ptr);

        var addr: c_qmp.sockaddr.un = .{ .family = c_qmp.AF.UNIX, .path = undefined };
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        const addrlen: c_qmp.socklen_t = @intCast(@offsetOf(c_qmp.sockaddr.un, "path") + path.len + 1);
        if (c_qmp.bind(srv, @ptrCast(&addr), addrlen) != 0) continue;
        if (c_qmp.listen(srv, 1) != 0) continue;

        var th = try std.Thread.spawn(std.Thread.SpawnConfig{}, qmpFuzzServer, .{ srv, rnd.int(u64) });
        defer th.join();

        var client = QmpClient{};
        // connect drives readLine + readResponse against the garbage greeting.
        client.connect(path) catch {
            client.disconnect();
            continue;
        };
        connected_sessions += 1;

        // Every command wrapper → execSimple/execHmp → writeAll + readResponse
        // against random replies. Ignore errors; we only assert no crash/hang.
        var out: [4096]u8 = undefined;
        client.pause() catch {};
        client.cont() catch {};
        client.powerdown() catch {};
        client.systemReset() catch {};
        _ = client.listSnapshots(&out) catch {};
        client.saveSnapshot("snap") catch {};
        client.deleteSnapshot("snap") catch {};
        client.sendCtrlAltDel() catch {};
        client.changeCdrom("/tmp/x.iso") catch {};
        client.ejectCdrom() catch {};
        client.suspendToFile("/tmp/x.state") catch {};
        _ = client.queryMigrateStatus(&out) catch {};
        client.liveMigrate("tcp:localhost:4444") catch {};
        client.cancelMigrate() catch {};
        client.quit() catch {};
        client.disconnect();
        command_batches += 1;
    }
    try std.testing.expect(connected_sessions > 0);
    try std.testing.expectEqual(connected_sessions, command_batches);
}

test "readLine: splits multiple lines delivered in a single read" {
    var fds: [2]c_qmp.fd_t = undefined;
    if (c_qmp.socketpair(c_qmp.AF.UNIX, c_qmp.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = c_qmp.close(fds[0]);

    var client = QmpClient{ .stream = usock.UnixStream{ .fd = fds[1] }, .connected = true };
    defer client.disconnect();

    // Three lines (one with a trailing \r) in a single write — the buffered
    // reader must hand them back one at a time without extra syscalls.
    const blob = "first\r\nsecond\nthird\n";
    try std.testing.expectEqual(@as(isize, @intCast(blob.len)), c_qmp.write(fds[0], blob.ptr, blob.len));

    try std.testing.expectEqualStrings("first", try client.readLine());
    try std.testing.expectEqualStrings("second", try client.readLine());
    try std.testing.expectEqualStrings("third", try client.readLine());
}

// ── Missing standalone coverage ─────────────────────────────────────

test "extractJsonString: output buffer too small returns BufferTooSmall" {
    var out: [4]u8 = undefined;
    const result = extractJsonString(
        \\{"k": "hello"}
    , "k", &out);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "extractJsonString: empty key resolves first empty-string key" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"": "empty_key"}
    , "", &out);
    try std.testing.expectEqualStrings("empty_key", result);
}

test "extractJsonString: value with embedded colon+whitespace" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "a: b"}
    , "msg", &out);
    try std.testing.expectEqualStrings("a: b", result);
}

test "extractJsonString: first key in a multi-key object" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"a":"first","a":"second"}
    , "a", &out);
    try std.testing.expectEqualStrings("first", result);
}

test "socketPath: zero-length name" {
    var buf: [256]u8 = undefined;
    const path = socketPath("", &buf) orelse unreachable;
    try std.testing.expectEqualStrings("/tmp/hangar-qmp-.sock", path);
}

test "extractJsonString: slash escape handled" {
    var out: [64]u8 = undefined;
    const result = try extractJsonString(
        \\{"msg": "a\/b\/c"}
    , "msg", &out);
    try std.testing.expectEqualStrings("a/b/c", result);
}

// ── Input validation helpers ────────────────────────────────────

/// Validate a snapshot tag for HMP safety.
/// Only allows alphanumeric, hyphen, and underscore characters.
fn isValidSnapshotTag(tag: []const u8) bool {
    if (tag.len == 0) return false;
    for (tag) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_')) return false;
    }
    return true;
}

/// Return true if `path` is safe to embed in an `exec:`/`/bin/sh -c` context.
/// Rejects shell metacharacters and control characters.
fn isShellSafePath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| {
        switch (c) {
            ' ', ';', '|', '&', '$', '`', '(', ')', '<', '>', '\'', '"',
            '\\', '~', '#', '!', '*', '?', '\n', '\r', '\t', 0 => return false,
            else => {},
        }
    }
    return true;
}

/// Escape `s` so it is a valid JSON string body: backslash and double-quote are
/// backslash-escaped, control characters (< 0x20) become `\u00XX`, everything
/// else passes through. Returns `null` if the escaped form does not fit in
/// `out` (callers treat that as `error.BufferTooSmall`).
fn jsonEscapeString(s: []const u8, out: []u8) ?[]const u8 {
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                if (pos + 2 > out.len) return null;
                out[pos] = '\\';
                out[pos + 1] = c;
                pos += 2;
            },
            else => {
                if (c < 0x20) {
                    if (pos + 6 > out.len) return null;
                    out[pos] = '\\';
                    out[pos + 1] = 'u';
                    out[pos + 2] = '0';
                    out[pos + 3] = '0';
                    out[pos + 4] = hex[(c >> 4) & 0xf];
                    out[pos + 5] = hex[c & 0xf];
                    pos += 6;
                } else {
                    if (pos >= out.len) return null;
                    out[pos] = c;
                    pos += 1;
                }
            },
        }
    }
    return out[0..pos];
}

/// Escape double-quote characters in an HMP argument string.
/// Returns a slice of `out` guaranteed to contain no unescaped `"`.
fn escapeHmpArg(arg: []const u8, out: []u8) []const u8 {
    var pos: usize = 0;
    for (arg) |c| {
        if (c == '"') {
            if (pos + 2 > out.len) break;
            out[pos] = '\\';
            out[pos + 1] = '"';
            pos += 2;
        } else {
            if (pos >= out.len) break;
            out[pos] = c;
            pos += 1;
        }
    }
    return out[0..pos];
}

test "isValidSnapshotTag: valid and invalid tags" {
    try std.testing.expect(isValidSnapshotTag("snap1"));
    try std.testing.expect(isValidSnapshotTag("my-snapshot_2024"));
    try std.testing.expect(!isValidSnapshotTag(""));
    try std.testing.expect(!isValidSnapshotTag("bad tag"));
    try std.testing.expect(!isValidSnapshotTag("bad\"tag"));
    try std.testing.expect(!isValidSnapshotTag("bad;tag"));
}

test "isShellSafePath: rejects shell metacharacters" {
    try std.testing.expect(isShellSafePath("/tmp/hangar-state-myvm.bin"));
    try std.testing.expect(!isShellSafePath(""));
    try std.testing.expect(!isShellSafePath("/tmp/hangar-state-`id`.bin"));
    try std.testing.expect(!isShellSafePath("/tmp/state-$(id).bin"));
    try std.testing.expect(!isShellSafePath("/tmp/state;rm -rf /.bin"));
    try std.testing.expect(!isShellSafePath("/tmp/state|cat.bin"));
    try std.testing.expect(!isShellSafePath("/tmp/state with space.bin"));
}

test "fuzz: isShellSafePath accepts only metacharacter-free, non-empty paths" {
    var seed: u64 = 0x9e3779b97f4a7c15;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var buf: [64]u8 = undefined;
        const n = seed % buf.len;
        var j: usize = 0;
        var s = seed;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            buf[j] = @truncate(s);
        }
        const path = buf[0..n];
        if (isShellSafePath(path)) {
            // The shell-injection guard must never accept an empty path nor any
            // byte that could break out of an `exec:`/`/bin/sh -c` context. A
            // regression that drops a char from the reject set fails here.
            try std.testing.expect(path.len > 0);
            for (path) |c| {
                switch (c) {
                    ' ', ';', '|', '&', '$', '`', '(', ')', '<', '>', '\'', '"',
                    '\\', '~', '#', '!', '*', '?', '\n', '\r', '\t', 0 => {
                        try std.testing.expect(false);
                    },
                    else => {},
                }
            }
        }
    }
}

test "escapeHmpArg: no special chars" {
    var buf: [128]u8 = undefined;
    const r = escapeHmpArg("/path/to/iso", &buf);
    try std.testing.expectEqualStrings("/path/to/iso", r);
}

test "escapeHmpArg: quote escaping" {
    var buf: [128]u8 = undefined;
    const r = escapeHmpArg("path\"with\"quotes", &buf);
    try std.testing.expectEqualStrings("path\\\"with\\\"quotes", r);
}

test "jsonEscapeString: escapes quotes, backslashes and control chars" {
    var buf: [128]u8 = undefined;
    // A quoted, quote-escaped CD-ROM HMP command is the real-world trigger.
    try std.testing.expectEqualStrings(
        "change ide2-cd0 \\\"/tmp/a\\\\\\\"b.iso\\\"\\\"",
        jsonEscapeString("change ide2-cd0 \"/tmp/a\\\"b.iso\"\"", &buf).?,
    );
    try std.testing.expectEqualStrings("a\\u0000b", jsonEscapeString("a\x00b", &buf).?);
    try std.testing.expectEqualStrings("tab\\u0009nl\\u000a", jsonEscapeString("tab\tnl\n", &buf).?);
    try std.testing.expectEqualStrings("plain/path", jsonEscapeString("plain/path", &buf).?);
    // Too small to hold the two-byte escape → null, not a panic.
    var tiny: [1]u8 = undefined;
    try std.testing.expect(jsonEscapeString("\"", &tiny) == null);
}

test "fuzz: jsonEscapeString output is bounded and always valid JSON body" {
    var seed: u64 = 0xcafef00dd15ea5e5;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var in_buf: [80]u8 = undefined;
        const n = seed % in_buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            in_buf[j] = @truncate(s);
        }
        const arg = in_buf[0..n];
        var out_buf: [512]u8 = undefined;
        const r = jsonEscapeString(arg, &out_buf).?;
        // At most six output bytes per input byte (\u00XX worst case).
        try std.testing.expect(r.len <= arg.len * 6);
        // No bare control chars, and every '"' is backslash-escaped.
        var k: usize = 0;
        while (k < r.len) : (k += 1) {
            try std.testing.expect(r[k] >= 0x20);
            if (r[k] == '"') try std.testing.expect(k > 0 and r[k - 1] == '\\');
        }
        // Tiny buffer must return null, never overflow.
        var tiny: [4]u8 = undefined;
        _ = jsonEscapeString(arg, &tiny);
    }
}

test "fuzz: escapeHmpArg never emits an unescaped quote and stays bounded" {
    var seed: u64 = 0x243f6a8885a308d3;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var in_buf: [80]u8 = undefined;
        const n = seed % in_buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            // Bias toward quotes/backslashes so the escaping path is exercised.
            in_buf[j] = switch (@as(u8, @truncate(s)) % 4) {
                0 => '"',
                1 => '\\',
                else => @truncate(s >> 8),
            };
        }
        const arg = in_buf[0..n];
        // Oversized output buffer: the full escaped form always fits.
        var out_buf: [200]u8 = undefined;
        const r = escapeHmpArg(arg, &out_buf);
        // Bounded: at most two output bytes per input byte.
        try std.testing.expect(r.len <= arg.len * 2);
        // Documented invariant: every '"' in the output is preceded by '\\'.
        for (r, 0..) |c, k| {
            if (c == '"') {
                try std.testing.expect(k > 0 and r[k - 1] == '\\');
            }
        }
        // Truncation must never split an escape across the buffer boundary:
        // a trailing lone '\\' that was meant to precede an emitted '"' would
        // violate the invariant above, so this also guards the tiny-buffer case.
        var tiny: [8]u8 = undefined;
        _ = escapeHmpArg(arg, &tiny);
    }
}

test "fuzz: isValidSnapshotTag accepts only the documented charset" {
    var seed: u64 = 0xb7e151628aed2a6a;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var buf: [48]u8 = undefined;
        const n = seed % buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            buf[j] = @truncate(s);
        }
        const tag = buf[0..n];
        const valid = isValidSnapshotTag(tag);
        if (valid) {
            // A valid tag must be non-empty and contain only [A-Za-z0-9_-].
            try std.testing.expect(tag.len > 0);
            for (tag) |c| {
                const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or c == '-' or c == '_';
                try std.testing.expect(ok);
            }
        }
    }
}

// hmpReportedError gates every HMP command: a false negative silently turns a
// failed power/snapshot operation into a reported success, so its detection
// behavior is verified directly.

test "hmpReportedError: empty result is not an error" {
    try std.testing.expect(!hmpReportedError(""));
}

test "hmpReportedError: clean success output is not an error" {
    try std.testing.expect(!hmpReportedError("(qemu) "));
    try std.testing.expect(!hmpReportedError("snapshot 'base' saved"));
}

test "hmpReportedError: QEMU failure markers are detected" {
    try std.testing.expect(hmpReportedError("Could not open file"));
    try std.testing.expect(hmpReportedError("Error: device not found"));
    // Markers are matched anywhere in the line, not only at the start.
    try std.testing.expect(hmpReportedError("(qemu) Error while loading snapshot"));
}

test "hmpReportedError: matching is case-sensitive (known limitation)" {
    // Documents current behavior: lowercase variants are not treated as errors.
    try std.testing.expect(!hmpReportedError("could not find it"));
    try std.testing.expect(!hmpReportedError("error: lowercase"));
}

test "fuzz: hmpReportedError never panics and matches a reference scan" {
    var seed: u64 = 0x4849_4d50;
    const alphabet = "ErorCud nt:()qemu0123";
    var buf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const n = seed % buf.len;
        var s = seed;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            s = s *% 2862933555777941757 +% 3037000493;
            buf[j] = alphabet[s % alphabet.len];
        }
        const result = buf[0..n];
        const expected = result.len > 0 and
            (std.mem.indexOf(u8, result, "Could not") != null or
                std.mem.indexOf(u8, result, "Error") != null);
        try std.testing.expectEqual(expected, hmpReportedError(result));
    }
}
