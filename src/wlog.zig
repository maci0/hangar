//! Structured stderr logging for the daemon: one timestamped, leveled line per
//! call, with user-controlled names/request-lines sanitized against log-line
//! injection. Leaf module (std + vm + httpreq) so every handler (and future
//! split-out handler modules) can log without depending on web_server.zig.

const std = @import("std");
const builtin = @import("builtin");
const vm = @import("vm.zig");
const httpreq = @import("httpreq.zig");

/// Destination fd for every log line. Defaults to stderr; a negative value
/// drops the line. Test builds default to dropped so a passing `zig build test`
/// is not buried in log output, and `wlog`'s own tests point it at a pipe.
pub var log_fd: c_int = if (builtin.is_test) -1 else 2;

/// Hard cap on one rendered log line, including the trailing newline.
const LINE_MAX = 512;

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

/// Render one log line into `buf`: `[<epoch_seconds>] hangar <level>: <msg>\n`.
/// A message too long for `buf` falls back to a `[?]`-stamped clipped line, so
/// the level is always present. Returns the slice of `buf` to write.
fn formatLine(buf: *[LINE_MAX]u8, level: LogLevel, epoch: i64, msg: []const u8) []const u8 {
    const lvl = level.tag();
    return std.fmt.bufPrint(buf, "[{d}] hangar {s}: {s}\n", .{ epoch, lvl, msg }) catch blk: {
        var head_buf: [32]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "[?] hangar {s}: ", .{lvl}) catch "[?] hangar log: ";
        const room = buf.len - head.len - 1;
        const clipped = if (msg.len > room) msg[0..room] else msg;
        @memcpy(buf[0..head.len], head);
        @memcpy(buf[head.len .. head.len + clipped.len], clipped);
        buf[head.len + clipped.len] = '\n';
        break :blk buf[0 .. head.len + clipped.len + 1];
    };
}

/// Log a message as a single timestamped, leveled line on `log_fd`. One write
/// keeps concurrent lines from interleaving. `msg` must be server-controlled
/// text; pass untrusted text through `sanitizeLogText` first.
pub fn logAt(level: LogLevel, msg: []const u8) void {
    if (log_fd < 0) return;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    var buf: [LINE_MAX]u8 = undefined;
    const line = formatLine(&buf, level, @intCast(ts.sec), msg);
    _ = std.c.write(log_fd, line.ptr, line.len);
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

/// Copy untrusted text (a VM name, a QEMU reply, an argv value) into `out`,
/// replacing every non-printable byte with '?' so it cannot inject newlines or
/// terminal escapes into a log line.
pub fn sanitizeLogText(out: []u8, text: []const u8) []const u8 {
    const n = @min(text.len, out.len);
    for (text[0..n], 0..) |ch, i| {
        out[i] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
    }
    return out[0..n];
}

/// Log an info-level audit line for a destructive state transition. The VM name
/// is sanitized. Format: `audit: <action> vm="<name>"`.
pub fn logAudit(action: []const u8, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogText(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logAt(.info, std.fmt.bufPrint(&msg, "audit: {s} vm=\"{s}\"", .{ action, safe }) catch action);
}

/// Log an error-level line for a failed destructive QMP/disk operation, with the
/// underlying error name and the sanitized VM name. `op` is a short static label.
/// Format: `<op> failed: <ErrorName> vm="<name>"`.
pub fn logOpErr(op: []const u8, e: anyerror, vm_name: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    const safe = sanitizeLogText(&name_buf, vm_name);
    var msg: [320]u8 = undefined;
    logErr(std.fmt.bufPrint(&msg, "{s} failed: {s} vm=\"{s}\"", .{ op, @errorName(e), safe }) catch op);
}

// ── Tests ───────────────────────────────────────────────────────────

test "wlog: sanitizeLogText replaces control bytes" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a?b", sanitizeLogText(&out, "a\nb"));
    try std.testing.expectEqualStrings("ok", sanitizeLogText(&out, "ok"));
}

test "wlog: formatLine renders a timestamped, leveled line per level" {
    var buf: [LINE_MAX]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[1700000000] hangar info: started\n",
        formatLine(&buf, .info, 1700000000, "started"),
    );
    try std.testing.expectEqualStrings(
        "[42] hangar warn: auth rejected\n",
        formatLine(&buf, .warn, 42, "auth rejected"),
    );
    try std.testing.expectEqualStrings(
        "[42] hangar error: boom\n",
        formatLine(&buf, .err, 42, "boom"),
    );
}

test "wlog: formatLine clips an oversize message to a leveled [?] line" {
    var buf: [LINE_MAX]u8 = undefined;
    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    const line = formatLine(&buf, .err, 1700000000, &big);
    try std.testing.expect(line.len <= buf.len);
    try std.testing.expect(std.mem.startsWith(u8, line, "[?] hangar error: x"));
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    // Every byte between the head and the newline came from the message.
    try std.testing.expect(std.mem.count(u8, line, "x") == line.len - "[?] hangar error: ".len - 1);
}

test "wlog: log calls drop when log_fd is negative and restore it after" {
    const saved = log_fd;
    defer log_fd = saved;
    log_fd = -1;
    logAt(.info, "test info");
    logErr("test err");
    logWarn("test warn");
    logSaveErr("ctx: ", error.NoSpaceLeft);
    logOpErr("op", error.AccessDenied, "vm\nname");
    logAudit("action", "n\x00me");
    logReqErr("ctx", error.BrokenPipe, "GET /x\r\n");
}
