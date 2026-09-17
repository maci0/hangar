//! Structured stderr logging for the daemon: one timestamped, leveled line per
//! call, with user-controlled names/request-lines sanitized against log-line
//! injection. Leaf module (std + vm + httpreq) so every handler (and future
//! split-out handler modules) can log without depending on web_server.zig.

const std = @import("std");
const builtin = @import("builtin");
const vm = @import("vm.zig");
const httpreq = @import("httpreq.zig");
const appio = @import("appio.zig");

var next_request_id: u64 = 0;
threadlocal var request_id: u64 = 0;
threadlocal var request_started: i96 = 0;
threadlocal var request_is_post: bool = false;
threadlocal var request_route: [128]u8 = undefined;
threadlocal var request_route_len: usize = 0;

pub fn beginRequest(req: []const u8) void {
    request_id = @atomicRmw(u64, &next_request_id, .Add, 1, .monotonic) +% 1;
    request_started = std.Io.Clock.awake.now(appio.io()).nanoseconds;
    request_is_post = std.mem.startsWith(u8, req, "POST ");
    const end = std.mem.indexOfAny(u8, req, "?\r\n") orelse req.len;
    request_route_len = httpreq.requestLine(req[0..end], &request_route).len;
}

pub fn endRequest() void {
    request_id = 0;
    request_route_len = 0;
    request_is_post = false;
}

pub fn requestId() u64 {
    return request_id;
}

pub fn logResponse(status: u16, sent: bool) void {
    if (request_id == 0 or (!request_is_post and status < 500 and sent)) return;
    const elapsed = @max(0, std.Io.Clock.awake.now(appio.io()).nanoseconds - request_started);
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "http_response status={d} duration_ms={d} sent={} request=[{s}]", .{
        status, @divTrunc(elapsed, std.time.ns_per_ms), sent, request_route[0..request_route_len],
    }) catch "http_response";
    logAt(if (status >= 500) .err else if (!sent or status >= 400) .warn else .info, msg);
}

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
fn formatLine(buf: *[LINE_MAX]u8, level: LogLevel, epoch: i64, msg: []const u8) []const u8 {
    const head = std.fmt.bufPrint(buf, "[{d}] hangar {s}: ", .{ epoch, level.tag() }) catch unreachable;
    const len = @min(msg.len, buf.len - head.len - 1);
    @memcpy(buf[head.len .. head.len + len], msg[0..len]);
    buf[head.len + len] = '\n';
    return buf[0 .. head.len + len + 1];
}

/// Log a message as a single timestamped, leveled line on `log_fd`. One write
/// keeps concurrent lines from interleaving. `msg` must be server-controlled
/// text; pass untrusted text through `sanitizeLogText` first.
pub fn logAt(level: LogLevel, msg: []const u8) void {
    if (log_fd < 0) return;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    var buf: [LINE_MAX]u8 = undefined;
    var correlated: [448]u8 = undefined;
    const text = if (request_id != 0)
        std.fmt.bufPrint(&correlated, "request_id={d} {s}", .{ request_id, msg[0..@min(msg.len, 400)] }) catch msg
    else
        msg;
    const line = formatLine(&buf, level, @intCast(ts.sec), text);
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

test "wlog: formatLine preserves timestamp and severity when clipping" {
    var buf: [LINE_MAX]u8 = undefined;
    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    const line = formatLine(&buf, .err, 1700000000, &big);
    const prefix = "[1700000000] hangar error: ";
    try std.testing.expectEqual(buf.len, line.len);
    try std.testing.expect(std.mem.startsWith(u8, line, prefix));
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expectEqual(line.len - prefix.len - 1, std.mem.count(u8, line, "x"));
}

test "wlog fuzz: formatLine preserves headers across lengths and epochs" {
    var prng = std.Random.DefaultPrng.init(0x10_61_1E);
    const random = prng.random();
    var msg: [LINE_MAX * 4]u8 = undefined;
    @memset(&msg, 'x');
    for (0..1000) |_| {
        const epoch = random.int(i64);
        const len = random.uintLessThan(usize, msg.len + 1);
        inline for (.{ LogLevel.info, LogLevel.warn, LogLevel.err }) |level| {
            var buf: [LINE_MAX]u8 = undefined;
            const line = formatLine(&buf, level, epoch, msg[0..len]);
            var prefix_buf: [64]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "[{d}] hangar {s}: ", .{ epoch, level.tag() });
            try std.testing.expect(std.mem.startsWith(u8, line, prefix));
            try std.testing.expectEqual(@min(LINE_MAX, prefix.len + len + 1), line.len);
            try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
            try std.testing.expectEqual(line.len - prefix.len - 1, std.mem.count(u8, line, "x"));
        }
    }
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
