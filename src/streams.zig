//! Connection-streaming HTTP handlers — responses written directly to the socket
//! fd rather than returned as a token. Currently: screenshot (QMP screendump →
//! PNG). disk2 download/upload and OVF export are candidates to move here too.

const std = @import("std");
const c = std.c;
const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
const qemu = @import("qemu.zig");
const ovf = @import("ovf.zig");
const appio = @import("appio.zig");
const urlencode = @import("urlencode.zig");
const appstate = @import("appstate.zig");
const persist = @import("persist.zig");
const httpreq = @import("httpreq.zig");
const httpresp = @import("httpresp.zig");
const wlog = @import("wlog.zig");

const parseIdx = httpreq.parseIdx;
const parseContentLength = httpreq.parseContentLength;
const findHeader = httpreq.findHeader;
const writeAll = httpresp.writeAll;
const writeHttpResponse = httpresp.writeHttpResponse;
const jsonErr = httpresp.jsonErr;
const isServerErrToken = httpresp.isServerErrToken;
const logOpErr = wlog.logOpErr;
const logAudit = wlog.logAudit;
const logErr = wlog.logErr;
const logSaveErr = wlog.logSaveErr;
const sanitizeLogName = wlog.sanitizeLogName;
const sanitizeHeaderValue = httpresp.sanitizeHeaderValue;
const HTTP_OK = httpresp.HTTP_OK;
const HTTP_BAD_REQUEST = httpresp.HTTP_BAD_REQUEST;
const HTTP_NOT_FOUND = httpresp.HTTP_NOT_FOUND;
const HTTP_CONFLICT = httpresp.HTTP_CONFLICT;
const HTTP_INTERNAL_ERROR = httpresp.HTTP_INTERNAL_ERROR;

/// Reply to an upload with the unified JSON error mapping (server faults 500,
/// client mistakes 400) and close.
fn uploadErr(conn: c.fd_t, token: []const u8) void {
    const s: u16 = if (isServerErrToken(token)) HTTP_INTERNAL_ERROR else HTTP_BAD_REQUEST;
    var jb: [256]u8 = undefined;
    writeHttpResponse(conn, s, "application/json; charset=utf-8", jsonErr(&jb, token));
}

/// Extract the filename from a multipart part's Content-Disposition headers.
/// Handles quoted (`filename="x"`) and unquoted (`filename=x`) forms. Returns ""
/// when absent. The returned slice points into `part_headers`.
fn parseUploadFilename(part_headers: []const u8) []const u8 {
    if (std.mem.indexOf(u8, part_headers, "filename=\"")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=\"".len ..];
        if (std.mem.indexOfScalar(u8, fn_val, '"')) |fn_end| {
            if (fn_end > 0) return fn_val[0..fn_end];
        }
    } else if (std.mem.indexOf(u8, part_headers, "filename=")) |fn_start| {
        const fn_val = part_headers[fn_start + "filename=".len ..];
        var fn_end: usize = fn_val.len;
        if (std.mem.indexOfScalar(u8, fn_val, ';')) |semi| fn_end = semi;
        if (std.mem.indexOfScalar(u8, fn_val, '\r')) |cr| {
            if (cr < fn_end) fn_end = cr;
        }
        if (std.mem.indexOfScalar(u8, fn_val, '\n')) |nl| {
            if (nl < fn_end) fn_end = nl;
        }
        if (fn_end > 0) return std.mem.trimEnd(u8, fn_val[0..fn_end], " \t");
    }
    return "";
}

/// Capture the running guest's display and stream it back as PNG (QMP
/// screendump). Only meaningful for a running VM; a stopped VM gets 409.
pub fn screenshot(conn: c.fd_t, req: []const u8) void {
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid idx\"}");
            return;
        }
        const v = &appstate.vms[idx];
        if (!v.isAlive()) {
            writeHttpResponse(conn, HTTP_CONFLICT, "application/json; charset=utf-8", "{\"error\":\"vm not running\"}");
            return;
        }
        const nm = v.getNameSlice();
        if (nm.len > name_buf.len or !qmp.isPathSafeName(nm)) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        }
        @memcpy(name_buf[0..nm.len], nm);
        name_len = nm.len;
    }

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    var path_buf: [96]u8 = undefined;
    const png_path = std.fmt.bufPrintZ(&path_buf, "/tmp/hangar-shot-{d}-{d}.png", .{ std.c.getpid(), ts.nsec }) catch {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
        return;
    };

    {
        var client = qmp.QmpClient{};
        var sock_buf: [256]u8 = undefined;
        const sock = qmp.socketPath(name_buf[0..name_len], &sock_buf) orelse {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        };
        client.connect(sock) catch |e| {
            logOpErr("screenshot", e, name_buf[0..name_len]);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot err\"}");
            return;
        };
        defer client.disconnect();
        // Drop any pre-planted entry (e.g. an attacker symlink at this path)
        // before QEMU's screendump writes it, so it can't be redirected (CWE-59).
        _ = c.unlink(png_path);
        client.screenshotPng(png_path) catch |e| {
            logOpErr("screenshot", e, name_buf[0..name_len]);
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot failed\"}");
            return;
        };
    }
    defer _ = c.unlink(png_path);

    // O_NOFOLLOW: refuse a symlink planted at this predictable /tmp path between
    // QEMU's screendump and this read-back, so the daemon can never be tricked
    // into serving an arbitrary file it can read (TOCTOU symlink, CWE-59/367).
    const fd = c.open(png_path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true });
    if (fd < 0) {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot read failed\"}");
        return;
    }
    defer _ = c.close(fd);
    const seek_end = c.lseek(fd, 0, 2);
    if (seek_end <= 0) {
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"screenshot empty\"}");
        return;
    }
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(fd, 0, 0) < 0) return;

    var hdr_buf: [256]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{file_size}) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return;
    var sbuf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &sbuf, sbuf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &sbuf, @intCast(n))) return;
    }
    logAudit("screenshot", name_buf[0..name_len]);
}

/// Stream a VM's secondary-disk (disk2) image to the client as a download.
/// Captures the path + name under the lock, then streams with it released.
pub fn download(conn: c.fd_t, req: []const u8) !void {
    var path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        const idx = parseIdx(req, "GET /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad index\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no vm\"}");
            return;
        }
        const v = &appstate.vms[idx];
        if (!v.hasDisk2()) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no disk2\"}");
            return;
        }
        const dp = std.mem.span(v.getDisk2Path());
        if (dp.len == 0 or dp.len >= path_buf.len) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk2 path\"}");
            return;
        }
        @memcpy(path_buf[0..dp.len], dp);
        path_buf[dp.len] = 0;
        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }
    }

    const disk2_path: [*:0]const u8 = @ptrCast(&path_buf);
    const fd = c.open(disk2_path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) {
        var nb: [vm.MAX_NAME]u8 = undefined;
        var eb: [256]u8 = undefined;
        logErr(std.fmt.bufPrint(&eb, "disk2 download: open failed vm=\"{s}\"", .{sanitizeLogName(&nb, name_buf[0..name_len])}) catch "disk2 download: open failed");
        writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"disk2 open failed\"}");
        return;
    }
    defer _ = c.close(fd);

    const seek_end = c.lseek(fd, 0, 2); // SEEK_END
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(fd, 0, 0) < 0) return; // SEEK_SET

    const basename = std.fs.path.basename(std.mem.span(disk2_path));
    var fname_buf: [256]u8 = undefined;
    const safename = sanitizeHeaderValue(&fname_buf, basename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{safename}) catch return;

    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Disposition: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ cd, file_size },
    ) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return error.BrokenPipe;

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &buf, @intCast(n))) return error.BrokenPipe;
    }
    logAudit("disk2 download", name_buf[0..name_len]);
}

/// Accept a multipart/form-data disk2 upload, STREAMING the file body straight
/// to disk (never buffering the whole multi-GB image in memory). `initial` is the
/// already-read first chunk (headers + start of body).
pub fn upload(conn: c.fd_t, initial: []const u8) void {
    const idx = parseIdx(initial, "POST /api/vms/") orelse return uploadErr(conn, "invalid");
    const content_length = parseContentLength(initial) orelse return uploadErr(conn, "no content-length");
    const hdr_end = std.mem.indexOf(u8, initial, "\r\n\r\n") orelse return uploadErr(conn, "no body");
    const headers = initial[0..hdr_end];
    const ct_val = findHeader(headers, "content-type: ") orelse return uploadErr(conn, "no boundary");
    const ct_prefix = "multipart/form-data; boundary=";
    if (ct_val.len < ct_prefix.len or !std.ascii.eqlIgnoreCase(ct_val[0..ct_prefix.len], ct_prefix)) return uploadErr(conn, "no boundary");
    const boundary = ct_val[ct_prefix.len..];
    if (boundary.len == 0 or boundary.len > 200) return uploadErr(conn, "no boundary");

    // Honor Expect: 100-continue. curl/libcurl withhold a large body until the
    // server sends "100 Continue"; without this the body never arrives in the
    // first read. (Browsers' fetch doesn't use Expect.)
    if (findHeader(headers, "expect: ")) |exv| {
        if (std.ascii.indexOfIgnoreCase(exv, "100-continue") != null) {
            const cont = "HTTP/1.1 100 Continue\r\n\r\n";
            _ = writeAll(conn, cont, cont.len);
        }
    }

    const body_off = hdr_end + 4;
    var bd_buf: [256]u8 = undefined;
    const full_bd = std.fmt.bufPrint(&bd_buf, "--{s}", .{boundary}) catch return uploadErr(conn, "bd err");

    // Accumulate the multipart prefix (opening boundary + part headers + start of
    // the file bytes) into pbuf, reading from the socket as needed.
    var pbuf: [65536 + 256]u8 = undefined;
    var plen: usize = 0;
    var body_seen: usize = 0; // multipart-body bytes consumed so far
    {
        const seed = initial[body_off..];
        const sn = @min(seed.len, pbuf.len);
        @memcpy(pbuf[0..sn], seed[0..sn]);
        plen = sn;
        body_seen = sn;
    }
    var data_pos: usize = 0; // offset in pbuf where the file bytes begin
    var filename: []const u8 = "";
    while (true) {
        const pb = pbuf[0..plen];
        if (std.mem.indexOf(u8, pb, full_bd)) |fb| {
            var p = fb + full_bd.len;
            if (p < pb.len and pb[p] == '\r') p += 1;
            if (p < pb.len and pb[p] == '\n') p += 1;
            if (std.mem.indexOf(u8, pb[p..], "\r\n\r\n")) |phe| {
                data_pos = p + phe + 4;
                filename = parseUploadFilename(pb[p..][0..phe]);
                break;
            } else if (std.mem.indexOf(u8, pb[p..], "\n\n")) |phe2| {
                data_pos = p + phe2 + 2;
                filename = parseUploadFilename(pb[p..][0..phe2]);
                break;
            }
        }
        if (plen >= pbuf.len or body_seen >= content_length) return uploadErr(conn, "no headers end");
        const want = @min(pbuf.len - plen, content_length - body_seen);
        const n = c.read(conn, pbuf[plen..].ptr, want);
        if (n <= 0) return uploadErr(conn, "upload err");
        plen += @intCast(n);
        body_seen += @intCast(n);
    }

    // Reject path traversal + QEMU -drive comma/control injection (CWE-88).
    if (filename.len == 0) return uploadErr(conn, "no filename");
    for (filename) |ch| {
        if (ch == '/' or ch == '\\' or ch == ',' or ch < 0x20) return uploadErr(conn, "bad filename");
    }
    if (std.mem.indexOf(u8, filename, "..") != null) return uploadErr(conn, "bad filename");

    // Compute dest path under the lock, copy it + the VM name out, then release
    // the lock before the streamed write.
    var dest_buf: [vm.MAX_PATH]u8 = undefined;
    var dest: []const u8 = undefined;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx >= appstate.vm_count) return uploadErr(conn, "invalid idx");
        const v = &appstate.vms[idx];
        const primary = v.getDiskPathSlice();
        if (primary.len == 0) return uploadErr(conn, "no primary disk");
        const ext = std.fs.path.extension(primary);
        const dir = std.fs.path.dirname(primary) orelse ".";
        const basename = std.fs.path.basename(primary);
        dest = (if (filename.len > 0)
            std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, filename })
        else if (ext.len > 0 and ext.len < 16)
            std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2{s}", .{ dir, basename[0 .. basename.len - ext.len], ext })
        else
            std.fmt.bufPrint(&dest_buf, "{s}/{s}_disk2", .{ dir, basename })) catch return uploadErr(conn, "path err");
        if (std.mem.eql(u8, dest, primary)) return uploadErr(conn, "name collides with primary disk");
        const nm = v.getNameSlice();
        name_len = @min(nm.len, name_buf.len);
        @memcpy(name_buf[0..name_len], nm[0..name_len]);
    }

    // Open the destination, then stream the file body to it with the lock
    // released (it can be many GB).
    var dest_z: [vm.MAX_PATH + 1]u8 = undefined;
    if (dest.len >= dest_z.len) return uploadErr(conn, "path err");
    @memcpy(dest_z[0..dest.len], dest);
    dest_z[dest.len] = 0;
    const out_fd = std.c.open(@ptrCast(&dest_z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (out_fd < 0) {
        logOpErr("disk upload", error.AccessDenied, name_buf[0..name_len]);
        return uploadErr(conn, "write err");
    }

    // Hold-back delimiter stream: write file bytes but never the closing boundary
    // (`\r\n--<boundary>`), which may straddle two reads — retain the last
    // (marker-1) bytes until the next read confirms they aren't the boundary.
    var marker_buf: [256]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "\r\n--{s}", .{boundary}) catch {
        _ = std.c.close(out_fd);
        return uploadErr(conn, "bd err");
    };
    const keep = marker.len - 1;
    var work: [65536 + 256]u8 = undefined;
    var hold: [256]u8 = undefined;
    var hold_len: usize = 0;
    var first = true;
    var done = false;

    while (true) {
        @memcpy(work[0..hold_len], hold[0..hold_len]);
        var total = hold_len;
        if (first) {
            const chunk = pbuf[data_pos..plen];
            @memcpy(work[hold_len..][0..chunk.len], chunk);
            total += chunk.len;
            first = false;
        } else {
            if (body_seen >= content_length) break; // body exhausted, no closing boundary
            const want = @min(work.len - hold_len, content_length - body_seen);
            const n = c.read(conn, work[hold_len..].ptr, want);
            if (n <= 0) break;
            total += @intCast(n);
            body_seen += @intCast(n);
        }
        if (std.mem.indexOf(u8, work[0..total], marker)) |mi| {
            if (!writeAll(out_fd, &work, mi)) {
                _ = std.c.close(out_fd);
                _ = c.unlink(@ptrCast(&dest_z));
                return uploadErr(conn, "write err");
            }
            done = true;
            break;
        }
        if (total > keep) {
            if (!writeAll(out_fd, &work, total - keep)) {
                _ = std.c.close(out_fd);
                _ = c.unlink(@ptrCast(&dest_z));
                return uploadErr(conn, "write err");
            }
            hold_len = keep;
            @memcpy(hold[0..keep], work[total - keep .. total]);
        } else {
            hold_len = total;
            @memcpy(hold[0..total], work[0..total]);
        }
    }
    _ = std.c.close(out_fd);
    if (!done) {
        _ = c.unlink(@ptrCast(&dest_z));
        return uploadErr(conn, "upload err");
    }

    // Record the new disk2 path, re-validating the VM under the lock.
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        if (idx < appstate.vm_count and std.mem.eql(u8, appstate.vms[idx].getNameSlice(), name_buf[0..name_len])) {
            appstate.vms[idx].setDisk2Path(dest);
            persist.save(&appstate.vms, appstate.vm_count, appstate.prefs) catch |e| {
                logSaveErr("streams.upload: ", e);
                return uploadErr(conn, "save failed");
            };
        }
    }
    logAudit("disk upload", name_buf[0..name_len]);
    writeHttpResponse(conn, HTTP_OK, "text/plain", "ok");
}

/// Byte size of a file, or 0 if it can't be stat'd. Fills the OVF descriptor's
/// `ovf:size` from the converted VMDKs (strict importers validate it).
fn fileByteSize(path: []const u8) u64 {
    var pbuf: [vm.MAX_PATH + 1]u8 = undefined;
    if (path.len >= pbuf.len) return 0;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, 2); // SEEK_END
    if (end < 0) return 0;
    return @intCast(end);
}

/// Create an OVF+VMDK export, tar+gzip it, and stream the OVA as a download.
/// Captures all needed VM fields under the lock, then runs the (minutes-long)
/// qemu-img conversions / tar / stream with it released.
pub fn exportOva(conn: c.fd_t, req: []const u8) !void {
    var disk1_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk1_path_len: usize = 0;
    var disk2_path_buf: [vm.MAX_PATH + 1]u8 = undefined;
    var disk2_path_len: usize = 0;
    var name_buf: [vm.MAX_NAME]u8 = undefined;
    var name_len: usize = 0;
    var export_name_buf: [vm.MAX_NAME]u8 = undefined;
    var export_name_len: usize = 0;
    var disk_format: vm.DiskFormat = undefined;
    var disk2_format: vm.DiskFormat = undefined;
    var disk_size_gb: u32 = 0;
    var disk2_size_gb: u32 = 0;
    var has_disk2: bool = false;
    var has_network: bool = false;
    var cpu_cores: u32 = 0;
    var memory_mb: u32 = 0;
    var idx: usize = 0;
    {
        appstate.vms_mutex.lock();
        defer appstate.vms_mutex.unlock();
        idx = parseIdx(req, "POST /api/vms/") orelse {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"bad index\"}");
            return;
        };
        if (idx >= appstate.vm_count) {
            writeHttpResponse(conn, HTTP_NOT_FOUND, "application/json; charset=utf-8", "{\"error\":\"no vm\"}");
            return;
        }
        const v = &appstate.vms[idx];

        const body: []const u8 = if (std.mem.indexOf(u8, req, "\r\n\r\n")) |bs| req[bs + 4 ..] else "";
        var raw_name: []const u8 = "";
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const val = kv.next() orelse continue;
            if (std.mem.eql(u8, key, "name")) raw_name = val;
        }
        var name_decode_buf: [vm.MAX_NAME]u8 = undefined;
        const export_name: []const u8 = if (raw_name.len > 0) blk: {
            const decoded = urlencode.urlDecode(&name_decode_buf, raw_name);
            if (!vm.isValidVmName(decoded) or std.mem.indexOf(u8, decoded, "..") != null) {
                writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid name\"}");
                return;
            }
            break :blk decoded;
        } else v.getNameSlice();
        if (export_name.len > export_name_buf.len) {
            writeHttpResponse(conn, HTTP_BAD_REQUEST, "application/json; charset=utf-8", "{\"error\":\"invalid name\"}");
            return;
        }
        @memcpy(export_name_buf[0..export_name.len], export_name);
        export_name_len = export_name.len;

        const d1 = v.getDiskPathSlice();
        if (d1.len > disk1_path_buf.len - 1) {
            writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk path\"}");
            return;
        }
        @memcpy(disk1_path_buf[0..d1.len], d1);
        disk1_path_len = d1.len;

        has_disk2 = v.hasDisk2();
        if (has_disk2) {
            const d2 = v.getDisk2PathSlice();
            if (d2.len > disk2_path_buf.len - 1) {
                writeHttpResponse(conn, HTTP_INTERNAL_ERROR, "application/json; charset=utf-8", "{\"error\":\"bad disk2 path\"}");
                return;
            }
            @memcpy(disk2_path_buf[0..d2.len], d2);
            disk2_path_len = d2.len;
        }

        const nm = v.getNameSlice();
        if (nm.len <= name_buf.len) {
            @memcpy(name_buf[0..nm.len], nm);
            name_len = nm.len;
        }

        disk_format = v.disk_format;
        disk2_format = v.disk2_format;
        disk_size_gb = v.disk_size_gb;
        disk2_size_gb = v.disk2_size_gb;
        has_network = v.nics[0].mode != .none;
        cpu_cores = v.cpu_cores;
        memory_mb = v.memory_mb;
    }

    const disk1_path: []const u8 = disk1_path_buf[0..disk1_path_len];
    const disk2_path: []const u8 = disk2_path_buf[0..disk2_path_len];
    const export_name: []const u8 = export_name_buf[0..export_name_len];

    // Per-export unique directory to avoid races with concurrent exports.
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    var dir_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/ovf_export.{d}.{d}.{d}", .{ idx, std.c.getpid(), ts.nsec }) catch return;
    _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
        logErr("export: deleteTree (pre-create) failed");
    };
    std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {
        logErr("failed to create export dir");
        return error.ExportFailed;
    };
    var dir_cleanup: bool = true;
    defer if (dir_cleanup) {
        _ = std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
            logErr("export: deleteTree cleanup failed");
        };
    };

    var tar_buf: [160]u8 = undefined;
    const tar_path = std.fmt.bufPrintZ(&tar_buf, "/tmp/ovf_export.{d}.{d}.{d}.tar.gz", .{ idx, std.c.getpid(), ts.nsec }) catch return;
    var tar_cleanup: bool = false;
    defer if (tar_cleanup) {
        _ = c.unlink(tar_path);
    };

    const vmdk_name = "disk1.vmdk";
    var path_buf: [vm.MAX_PATH]u8 = undefined;
    const vmdk_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, vmdk_name }) catch return;

    qemu.convertDiskImage(disk1_path, disk_format, vmdk_path, .vmdk, std.heap.page_allocator) catch {
        logErr("export: disk1 conversion failed");
        return error.ExportFailed;
    };
    const vmdk1_size = fileByteSize(vmdk_path);

    var disk2_href: []const u8 = "";
    var disk2_cap: u64 = 0;
    var disk2_size: u64 = 0;
    if (has_disk2) {
        disk2_href = "disk2.vmdk";
        disk2_cap = @as(u64, disk2_size_gb) * 1024 * 1024 * 1024;
        const d2_path = std.fmt.bufPrint(&path_buf, "{s}/disk2.vmdk", .{dir_path}) catch return;
        qemu.convertDiskImage(disk2_path, disk2_format, d2_path, .vmdk, std.heap.page_allocator) catch {
            logErr("export: disk2 conversion failed");
            return error.ExportFailed;
        };
        disk2_size = fileByteSize(d2_path);
    }

    const disk_cap = @as(u64, disk_size_gb) * 1024 * 1024 * 1024;
    const spec = ovf.Spec{
        .name = export_name,
        .cpu_cores = cpu_cores,
        .memory_mb = memory_mb,
        .disk_capacity_bytes = disk_cap,
        .vmdk_href = vmdk_name,
        .vmdk_size_bytes = vmdk1_size,
        .has_network = has_network,
        .disk2_href = disk2_href,
        .disk2_capacity_bytes = disk2_cap,
        .disk2_size_bytes = disk2_size,
    };
    var ovf_buf: [ovf.max_descriptor_len]u8 = undefined;
    const xml = ovf.buildDescriptor(spec, &ovf_buf) catch {
        logErr("export: OVF descriptor build failed");
        return error.ExportFailed;
    };

    const ovf_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.ovf", .{ dir_path, export_name });
    defer std.heap.page_allocator.free(ovf_path);
    std.Io.Dir.cwd().writeFile(appio.io(), .{ .sub_path = ovf_path, .data = xml }) catch {
        logErr("export: failed to write OVF file");
        return error.ExportFailed;
    };

    {
        const tar_argv = [_][]const u8{ "tar", "-czf", tar_path, "-C", dir_path, "." };
        qemu.runWait(&tar_argv, std.heap.page_allocator, null) catch {
            logErr("export: tar+gzip failed");
            return error.ExportFailed;
        };
        tar_cleanup = true;
    }

    // O_NOFOLLOW: the tarball sits at a predictable /tmp path; refuse a symlink
    // swapped in before this read-back so a local attacker can't redirect the
    // streamed bytes to an arbitrary file (TOCTOU symlink, CWE-59/367).
    const tar_fd = c.open(tar_path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true });
    if (tar_fd < 0) return;
    defer _ = c.close(tar_fd);

    const seek_end = c.lseek(tar_fd, 0, 2);
    if (seek_end < 0) return;
    const file_size: u64 = @intCast(seek_end);
    if (c.lseek(tar_fd, 0, 0) < 0) return;

    const raw_filename = std.fmt.bufPrint(&path_buf, "{s}.ova", .{export_name}) catch "export.ova";
    var fname_buf2: [256]u8 = undefined;
    const filename = sanitizeHeaderValue(&fname_buf2, raw_filename);
    var cd_header: [512]u8 = undefined;
    const cd = std.fmt.bufPrint(&cd_header, "attachment; filename=\"{s}\"", .{filename}) catch return;

    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Cache-Control: no-store\r\n" ++
            "Content-Disposition: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n",
        .{ cd, file_size },
    ) catch return;
    if (!writeAll(conn, headers.ptr, headers.len)) return error.BrokenPipe;

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(tar_fd, &buf, buf.len);
        if (n <= 0) break;
        if (!writeAll(conn, &buf, @intCast(n))) return error.BrokenPipe;
    }

    std.Io.Dir.cwd().deleteTree(appio.io(), dir_path) catch {
        logErr("export cleanup deleteTree failed");
    };
    _ = c.unlink(tar_path);
    dir_cleanup = false;
    tar_cleanup = false;
    logAudit("export", name_buf[0..name_len]);
}

// ── Tests ───────────────────────────────────────────────────────────

test "streams: parseUploadFilename handles quoted + unquoted" {
    try std.testing.expectEqualStrings("a.img", parseUploadFilename("Content-Disposition: form-data; name=\"f\"; filename=\"a.img\"\r\n"));
    try std.testing.expectEqualStrings("b.img", parseUploadFilename("filename=b.img\r\n"));
    try std.testing.expectEqualStrings("", parseUploadFilename("no filename here"));
}

test "streams: uploadErr maps server vs client tokens (pipe fd)" {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    uploadErr(fds[1], "write err"); // server token -> 500
    var buf: [256]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0 and std.mem.indexOf(u8, buf[0..@intCast(n)], "500") != null);
}

test "streams: screenshot rejects a non-matching request (writes to a pipe)" {
    // Drive a real fd: a pipe whose read end we drain. parseIdx fails → 400.
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return; // skip if pipe unavailable
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    screenshot(fds[1], "GET /api/other HTTP/1.1");
    var buf: [256]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(n)], "400") != null);
}

test "fuzz: parseUploadFilename never panics and returns a sub-slice" {
    var prng = std.Random.DefaultPrng.init(0x5170_4144);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    // A small alphabet weighted toward the structural bytes the parser keys on
    // (quotes, semicolons, '=', CR/LF) so deep paths get exercised, not just
    // the "filename absent" early return.
    const alpha = "filename=\";\r\n \t ABxy./0";
    var i: usize = 0;
    while (i < 8000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| {
            b.* = if (rnd.boolean()) alpha[rnd.uintLessThan(usize, alpha.len)] else rnd.int(u8);
        }
        const headers = buf[0..len];
        const name = parseUploadFilename(headers);
        // Result is always empty or a slice contained within the input buffer.
        if (name.len > 0) {
            const base = @intFromPtr(headers.ptr);
            const start = @intFromPtr(name.ptr);
            std.debug.assert(start >= base);
            std.debug.assert(start + name.len <= base + headers.len);
            // Unquoted form trims trailing ASCII whitespace; quoted form keeps it.
            const last = name[name.len - 1];
            const quoted = std.mem.indexOf(u8, headers, "filename=\"") != null;
            std.debug.assert(quoted or (last != ' ' and last != '\t'));
        }
    }
}
