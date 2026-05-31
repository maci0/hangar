//! vmrun — CLI tool for managing KVMGUI VMs remotely.
//!
//! Connects to a KVMGUI web server via the transport abstraction layer
//! and issues commands: list, start, stop, restart, clone, delete.
//!
//! Usage:
//!   vmrun <server-url> list
//!   vmrun <server-url> start  <name|idx>
//!   vmrun <server-url> stop   <name|idx>
//!   vmrun <server-url> restart <name|idx>
//!   vmrun <server-url> clone  <name|idx>
//!   vmrun <server-url> delete <name|idx>
//!   vmrun <server-url> status

const std = @import("std");
const c = std.c;
const transport = @import("transport.zig");

const usage =
    \\vmrun — KVMGUI remote VM manager
    \\
    \\Usage: vmrun <server-url> <command> [args...]
    \\
    \\Commands:
    \\  list               List all VMs
    \\  start  <name|idx>  Power on a VM
    \\  stop   <name|idx>  Power off a VM
    \\  restart <name|idx> Restart a VM (stop + start)
    \\  clone  <name|idx>  Clone a VM
    \\  delete <name|idx>  Delete a VM
    \\  status            Show server health
    \\
    \\Server URL formats:
    \\  http://host:port   HTTP over TCP (default)
    \\  unix:///path       Unix domain socket
    \\
;

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    const prog = args_iter.next() orelse {
        _ = c.write(c.STDERR_FILENO, usage.ptr, usage.len);
        std.process.exit(1);
    };
    _ = prog;

    const server_url = args_iter.next() orelse {
        _ = c.write(c.STDERR_FILENO, usage.ptr, usage.len);
        std.process.exit(1);
    };
    const command = args_iter.next() orelse {
        _ = c.write(c.STDERR_FILENO, usage.ptr, usage.len);
        std.process.exit(1);
    };

    const url = transport.Url.parse(server_url) orelse {
        _ = c.write(c.STDERR_FILENO, "Error: invalid server URL\n", 26);
        std.process.exit(1);
    };

    var conn = transport.Connection.connect(&url) orelse {
        _ = c.write(c.STDERR_FILENO, "Error: failed to connect to server\n", 34);
        std.process.exit(1);
    };
    defer conn.close();

    if (std.mem.eql(u8, command, "list")) {
        return cmdList(&conn, init.io);
    } else if (std.mem.eql(u8, command, "status")) {
        return cmdStatus(&conn, init.io);
    } else if (std.mem.eql(u8, command, "start") or
               std.mem.eql(u8, command, "stop") or
               std.mem.eql(u8, command, "restart") or
               std.mem.eql(u8, command, "clone") or
               std.mem.eql(u8, command, "delete"))
    {
        const target = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing VM name or index\n", 31);
            std.process.exit(1);
        };

        // Resolve name or index to VM index.
        const idx = resolveVm(&conn, target) orelse {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "Error: VM '{s}' not found\n", .{target}) catch "Error: VM not found\n";
            _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        };

        if (std.mem.eql(u8, command, "start") or std.mem.eql(u8, command, "stop")) {
            return cmdPower(&conn, idx, command, init.io);
        } else if (std.mem.eql(u8, command, "restart")) {
            try cmdPower(&conn, idx, "stop", init.io);
            const ts: c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = c.nanosleep(&ts, null);
            return cmdPower(&conn, idx, "start", init.io);
        } else if (std.mem.eql(u8, command, "clone")) {
            return cmdClone(&conn, idx, init.io);
        } else if (std.mem.eql(u8, command, "delete")) {
            return cmdDelete(&conn, idx, init.io);
        }
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: unknown command '{s}'\n", .{command}) catch "Error: unknown command\n";
        _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    }
}

fn sendRequest(conn: *transport.Connection, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = conn.request(method, path, body, &buf);
    if (n == 0) return error.RequestFailed;
    // Allocate response string from page allocator (caller handles lifetime via Arena).
    const resp = try std.heap.page_allocator.dupe(u8, buf[0..n]);
    return resp;
}

fn resolveVm(conn: *transport.Connection, target: []const u8) ?usize {
    // Try parsing as numeric index first.
    if (std.fmt.parseInt(usize, target, 10)) |idx| {
        return idx;
    } else |_| {}

    // Search by name in the VM list JSON.
    const json = sendRequest(conn, "GET", "/api/vms", null) catch return null;
    // Simple scan for "name":"target"
    var search_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "\"name\":\"{s}\"", .{target}) catch return null;
    if (std.mem.indexOf(u8, json, pat)) |_| {
        // Find the preceding "idx":N
        const idx_pat = "\"idx\":";
        const before = json[0..std.mem.indexOf(u8, json, pat).?];
        var i: usize = before.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, before[i..], idx_pat)) {
                const num_start = i + idx_pat.len;
                const num_end = std.mem.indexOfScalar(u8, before[num_start..], ',') orelse
                                std.mem.indexOfScalar(u8, before[num_start..], '}') orelse before.len;
                return std.fmt.parseInt(usize, before[num_start..][0..(num_end - num_start)], 10) catch return null;
            }
        }
    }
    return null;
}

fn cmdList(conn: *transport.Connection, io: std.Io) !void {
    _ = io;
    const json = try sendRequest(conn, "GET", "/api/vms", null);
    defer std.heap.page_allocator.free(json);

    // Parse and display VM names from JSON array.
    var rest = json;
    var idx: usize = 0;
    while (std.mem.indexOfScalar(u8, rest, '{')) |obj_start| {
        rest = rest[obj_start..];
        const obj_end = std.mem.indexOfScalar(u8, rest, '}') orelse break;
        const obj = rest[0 .. obj_end + 1];
        rest = rest[obj_end + 1 ..];

        // Extract name and status
        const name = extractJsonString(obj, "name") orelse "?";
        const status = extractJsonString(obj, "status") orelse "?";
        const mem = extractJsonInt(obj, "mem") orelse 0;
        const cpu = extractJsonInt(obj, "cpu") orelse 0;

        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "[{d}] {s}  status={s}  mem={d}MB  cpu={d}\n", .{ idx, name, status, mem, cpu });
        _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
        idx += 1;
    }
}

fn cmdStatus(conn: *transport.Connection, io: std.Io) !void {
    _ = io;
    const resp = try sendRequest(conn, "GET", "/api/health", null);
    defer std.heap.page_allocator.free(resp);
    _ = c.write(c.STDOUT_FILENO, resp.ptr, resp.len);
    _ = c.write(c.STDOUT_FILENO, "\n", 1);
}

fn cmdPower(conn: *transport.Connection, idx: usize, action: []const u8, io: std.Io) !void {
    _ = io;
    // Both start and stop use the same /api/power/N toggle endpoint.
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/power/{d}", .{idx});
    const resp = try sendRequest(conn, "POST", path, null);
    defer std.heap.page_allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} VM [{d}]: {s}\n", .{ action, idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdClone(conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/clone/{d}", .{idx});
    const resp = try sendRequest(conn, "POST", path, null);
    defer std.heap.page_allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "clone VM [{d}]: {s}\n", .{ idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdDelete(conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/delete/{d}", .{idx});
    const resp = try sendRequest(conn, "POST", path, null);
    defer std.heap.page_allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "delete VM [{d}]: {s}\n", .{ idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

/// Extract a quoted string value from a JSON object snippet.
fn extractJsonString(obj: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, pat) orelse return null;
    const val_start = start + pat.len;
    const val_end = std.mem.indexOfScalar(u8, obj[val_start..], '"') orelse return null;
    return obj[val_start .. val_start + val_end];
}

/// Extract an integer value from a JSON object snippet.
fn extractJsonInt(obj: []const u8, key: []const u8) ?usize {
    var search_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, obj, pat) orelse return null;
    const val_start = start + pat.len;
    const val_end = std.mem.indexOfScalar(u8, obj[val_start..], ',') orelse
                    std.mem.indexOfScalar(u8, obj[val_start..], '}') orelse obj.len - val_start;
    return std.fmt.parseInt(usize, obj[val_start..][0..val_end], 10) catch null;
}
