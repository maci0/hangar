//! Structured stderr logging for the daemon: one timestamped, leveled line per
//! call, with user-controlled names/request-lines sanitized against log-line
//! injection. Leaf module (std + vm + httpreq) so every handler (and future
//! split-out handler modules) can log without depending on web_server.zig.

const std = @import("std");
const vm = @import("vm.zig");
const httpreq = @import("httpreq.zig");

pub const LogLevel = enum {
    info,
    warn,
    err,

    fn tag(self: LogLevel) []const u8 {
        return switch (self) {
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

/// Log a message to stderr as a single timestamped, leveled line.
/// Format: `[<epoch_seconds>] hangar <level>: <msg>\n`. One write keeps
/// concurrent lines from interleaving. `msg` must be server-controlled text.
pub fn logAt(level: LogLevel, msg: []const u8) void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const epoch: i64 = @intCast(ts.sec);
    const lvl = level.tag();

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] hangar {s}: {s}\n", .{ epoch, lvl, msg }) catch blk: {
        // Message too long — emit a truncated, still-leveled line.
        var head_buf: [32]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "[?] hangar {s}: ", .{lvl}) catch "[?] hangar log: ";
        const room = buf.len - head.len - 1;
        const clipped = if (msg.len > room) msg[0..room] else msg;
        @memcpy(buf[0..head.len], head);
        @memcpy(buf[head.len .. head.len + clipped.len], clipped);
        buf[head.len + clipped.len] = '\n';
        break :blk buf[0 .. head.len + clipped.len + 1];
    };
    _ = std.c.write(2, line.ptr, line.len);
}

/// Log an error-level line (operator action likely required).
pub fn logErr(msg: []const u8) void {
    logAt(.err, msg);
}

/// Log a warn-level line (audit/security events such as rejected auth).
pub fn logWarn(msg: []const u8) void {
    logAt(.warn, msg);
}

/// Log a `persist.save` failure with the underlying error name so an operator
/// can distinguish a full disk / permissions / missing HOME from the log alone.
/// `context` is an optional prefix (e.g. "liveness: "); pass "" for none.
pub fn logSaveErr(context: []const u8, e: anyerror) void {
    var ebuf: [128]u8 = undefined;
    logErr(std.fmt.bufPrint(&ebuf, "{s}persist.save failed: {s}", .{ context, @errorName(e) }) catch "persist.save failed");
}

/// Log a request-handler failure with the underlying error name and the
/// sanitized request line. `context` is a short static label; `req` is the raw
/// request line. Format: `<context>: <ErrorName> [<reqline>]`.
pub fn logReqErr(context: []const u8, e: anyerror, req: []const u8) void {
    var rl_buf: [128]u8 = undefined;
    var eb: [320]u8 = undefined;
    logErr(std.fmt.bufPrint(&eb, "{s}: {s} [{s}]", .{ context, @errorName(e), httpreq.requestLine(req, &rl_buf) }) catch context);
}

/// Copy a user-controlled VM name into `out`, replacing every non-printable byte
/// with '?' so it cannot inject newlines into a log line.
pub fn sanitizeLogName(out: []u8, name: []const u8) []const u8 {
    const n = @min(name.len, out.len);
    for (name[0..n], 0..) |ch, i| {
        out[i] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    }
    return out[0..n];
}

/// Log an info-level audit line for a destructive state transition. The VM name
/// is sanitized. Format: `audit: <action> vm="<name>"`.
pub fn logAudit(action: []const u8, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogName(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logAt(.info, std.fmt.bufPrint(&msg, "audit: {s} vm=\"{s}\"", .{ action, safe }) catch action);
}

/// Log an error-level line for a failed destructive QMP/disk operation, with the
/// underlying error name and the sanitized VM name. `op` is a short static label.
/// Format: `<op> failed: <ErrorName> vm="<name>"`.
pub fn logOpErr(op: []const u8, e: anyerror, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogName(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logErr(std.fmt.bufPrint(&msg, "{s} failed: {s} vm=\"{s}\"", .{ op, @errorName(e), safe }) catch op);
}

// ── Tests ───────────────────────────────────────────────────────────

test "wlog: sanitizeLogName replaces control bytes" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a?b", sanitizeLogName(&out, "a\nb"));
    try std.testing.expectEqualStrings("ok", sanitizeLogName(&out, "ok"));
}

test "wlog: log calls never panic" {
    // Smoke: exercise every level + the truncation path (writes to fd 2).
    logAt(.info, "test info");
    logErr("test err");
    logWarn("test warn");
    logSaveErr("ctx: ", error.NoSpaceLeft);
    logOpErr("op", error.AccessDenied, "vm\nname");
    logAudit("action", "n\x00me");
    logReqErr("ctx", error.BrokenPipe, "GET /x\r\n");
    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    logAt(.err, &big); // truncation branch
}
