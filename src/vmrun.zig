// SPDX-License-Identifier: MIT
//! vmrun — CLI tool for managing Hangar VMs remotely.
//!
//! Connects to a Hangar web server via the transport abstraction layer
//! and issues commands: list, start, stop, restart, clone, delete, suspend,
//! pause, resume, shutdown, reset, rename, cad, snapshots, linked-clone,
//! import, export.
//!
//! Usage:
//!   vmrun <server-url> list
//!   vmrun <server-url> start    <name|idx>
//!   vmrun <server-url> stop     <name|idx>
//!   vmrun <server-url> restart  <name|idx>
//!   vmrun <server-url> clone    <name|idx>
//!   vmrun <server-url> delete   <name|idx>
//!   vmrun <server-url> suspend  <name|idx>
//!   vmrun <server-url> pause    <name|idx>
//!   vmrun <server-url> resume   <name|idx>
//!   vmrun <server-url> shutdown <name|idx>
//!   vmrun <server-url> reset    <name|idx>
//!   vmrun <server-url> rename   <name|idx> <new-name>
//!   vmrun <server-url> cad      <name|idx>
//!   vmrun <server-url> linked-clone <name|idx>
//!   vmrun <server-url> snapshot list    <name|idx>
//!   vmrun <server-url> snapshot take    <name|idx> <tag>
//!   vmrun <server-url> snapshot revert  <name|idx> <tag>
//!   vmrun <server-url> snapshot delete  <name|idx> <tag>
//!   vmrun <server-url> import <disk-path>
//!   vmrun <server-url> export <name|idx>
//!   vmrun <server-url> status

const std = @import("std");
const c = std.c;
const transport = @import("transport.zig");

const usage =
    \\vmrun — Hangar remote VM manager
    \\
    \\Usage: vmrun <server-url> <command> [args...]
    \\
    \\Commands:
    \\  list                    List all VMs
    \\  start       <name|idx>  Power on a VM
    \\  stop        <name|idx>  Power off a VM
    \\  restart     <name|idx>  Restart a VM (stop + start)
    \\  clone       <name|idx>  Full clone (config only)
    \\  linked-clone <name|idx> Linked clone (qcow2 backing file)
    \\  delete      <name|idx>  Delete a VM
    \\  suspend     <name|idx>  Suspend VM to disk
    \\  pause       <name|idx>  Pause guest execution
    \\  resume      <name|idx>  Resume guest execution
    \\  shutdown    <name|idx>  Graceful ACPI shutdown
    \\  reset       <name|idx>  Hard reset guest
    \\  rename      <name|idx> <new-name>  Rename a VM
    \\  cad         <name|idx>  Send Ctrl+Alt+Del to guest
    \\  snapshot list    <name|idx>        List snapshots
    \\  snapshot take    <name|idx> <tag>  Take a snapshot
    \\  snapshot revert  <name|idx> <tag>  Revert to snapshot
    \\  snapshot delete  <name|idx> <tag>  Delete a snapshot
    \\  import      <disk-path>  Import a VM from disk image
    \\  export      <name|idx>   Export VM as OVF+VMDK
    \\  status                  Show server health
    \\
    \\Server URL formats:
    \\  http://host:port   HTTP over TCP (default)
    \\  unix:///path       Unix domain socket
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

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
        return cmdList(allocator, &conn, init.io);
    } else if (std.mem.eql(u8, command, "status")) {
        return cmdStatus(allocator, &conn, init.io);
    } else if (std.mem.eql(u8, command, "import")) {
        const path = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing disk path\n", 25);
            std.process.exit(1);
        };
        return cmdImport(allocator, &conn, path, init.io);
    } else if (std.mem.eql(u8, command, "snapshot")) {
        const sub = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: snapshot command requires subcommand: list|take|revert|delete\n", 69);
            std.process.exit(1);
        };
        const target = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing VM name or index\n", 31);
            std.process.exit(1);
        };
        const idx = resolveVm(allocator, &conn, target) orelse {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "Error: VM '{s}' not found\n", .{target}) catch "Error: VM not found\n";
            _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        };
        if (std.mem.eql(u8, sub, "list")) {
            return cmdSnapshotList(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, sub, "take")) {
            const tag = args_iter.next() orelse {
                _ = c.write(c.STDERR_FILENO, "Error: missing snapshot tag\n", 28);
                std.process.exit(1);
            };
            return cmdSnapshotTake(allocator, &conn, idx, tag, init.io);
        } else if (std.mem.eql(u8, sub, "revert")) {
            const tag = args_iter.next() orelse {
                _ = c.write(c.STDERR_FILENO, "Error: missing snapshot tag\n", 28);
                std.process.exit(1);
            };
            return cmdSnapshotRevert(allocator, &conn, idx, tag, init.io);
        } else if (std.mem.eql(u8, sub, "delete")) {
            const tag = args_iter.next() orelse {
                _ = c.write(c.STDERR_FILENO, "Error: missing snapshot tag\n", 28);
                std.process.exit(1);
            };
            return cmdSnapshotDelete(allocator, &conn, idx, tag, init.io);
        } else {
            _ = c.write(c.STDERR_FILENO, "Error: unknown snapshot subcommand (use: list|take|revert|delete)\n", 66);
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, command, "start") or
        std.mem.eql(u8, command, "stop") or
        std.mem.eql(u8, command, "restart") or
        std.mem.eql(u8, command, "clone") or
        std.mem.eql(u8, command, "linked-clone") or
        std.mem.eql(u8, command, "delete") or
        std.mem.eql(u8, command, "suspend") or
        std.mem.eql(u8, command, "pause") or
        std.mem.eql(u8, command, "resume") or
        std.mem.eql(u8, command, "shutdown") or
        std.mem.eql(u8, command, "reset") or
        std.mem.eql(u8, command, "cad") or
        std.mem.eql(u8, command, "export"))
    {
        const target = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing VM name or index\n", 31);
            std.process.exit(1);
        };

        // Resolve name or index to VM index.
        const idx = resolveVm(allocator, &conn, target) orelse {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "Error: VM '{s}' not found\n", .{target}) catch "Error: VM not found\n";
            _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        };

        if (std.mem.eql(u8, command, "start") or std.mem.eql(u8, command, "stop")) {
            return cmdPower(allocator, &conn, idx, command, init.io);
        } else if (std.mem.eql(u8, command, "restart")) {
            try cmdPower(allocator, &conn, idx, "stop", init.io);
            const ts: c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = c.nanosleep(&ts, null);
            return cmdPower(allocator, &conn, idx, "start", init.io);
        } else if (std.mem.eql(u8, command, "clone")) {
            return cmdClone(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, command, "linked-clone")) {
            return cmdLinkedClone(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, command, "delete")) {
            return cmdDelete(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, command, "suspend")) {
            return cmdSimple(allocator, &conn, idx, "/api/suspend/{d}", "suspend", init.io);
        } else if (std.mem.eql(u8, command, "pause")) {
            return cmdSimple(allocator, &conn, idx, "/api/pause/{d}", "pause", init.io);
        } else if (std.mem.eql(u8, command, "resume")) {
            return cmdSimple(allocator, &conn, idx, "/api/resume/{d}", "resume", init.io);
        } else if (std.mem.eql(u8, command, "shutdown")) {
            return cmdSimple(allocator, &conn, idx, "/api/shutdown/{d}", "shutdown", init.io);
        } else if (std.mem.eql(u8, command, "reset")) {
            return cmdSimple(allocator, &conn, idx, "/api/reset/{d}", "reset", init.io);
        } else if (std.mem.eql(u8, command, "cad")) {
            return cmdSimple(allocator, &conn, idx, "/api/cad/{d}", "cad", init.io);
        } else if (std.mem.eql(u8, command, "export")) {
            return cmdExport(allocator, &conn, idx, init.io);
        }
    } else if (std.mem.eql(u8, command, "rename")) {
        const target = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing VM name or index\n", 31);
            std.process.exit(1);
        };
        const new_name = args_iter.next() orelse {
            _ = c.write(c.STDERR_FILENO, "Error: missing new name\n", 23);
            std.process.exit(1);
        };
        const idx = resolveVm(allocator, &conn, target) orelse {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "Error: VM '{s}' not found\n", .{target}) catch "Error: VM not found\n";
            _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        };
        return cmdRename(allocator, &conn, idx, new_name, init.io);
    } else {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: unknown command '{s}'\n", .{command}) catch "Error: unknown command\n";
        _ = c.write(c.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    }
}

fn sendRequest(allocator: std.mem.Allocator, conn: *transport.Connection, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = conn.request(method, path, body, &buf);
    if (n == 0) return error.RequestFailed;
    return try allocator.dupe(u8, buf[0..n]);
}

/// Pure helper: given VM-list JSON and a VM name, find its "idx" field value.
/// Scans for `"name":"target"` then looks backwards for the nearest `"idx":N`.
fn findVmIdxInJson(json: []const u8, target: []const u8) ?usize {
    var search_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "\"name\":\"{s}\"", .{target}) catch return null;
    const name_pos = std.mem.indexOf(u8, json, pat) orelse return null;
    const idx_pat = "\"idx\":";
    const before = json[0..name_pos];
    var i: usize = before.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.startsWith(u8, before[i..], idx_pat)) {
            const num_start = i + idx_pat.len;
            const num_end = std.mem.indexOfScalar(u8, before[num_start..], ',') orelse
                std.mem.indexOfScalar(u8, before[num_start..], '}') orelse (before.len - num_start);
            return std.fmt.parseInt(usize, before[num_start..][0..num_end], 10) catch return null;
        }
    }
    return null;
}

fn resolveVm(allocator: std.mem.Allocator, conn: *transport.Connection, target: []const u8) ?usize {
    // Try parsing as numeric index first.
    if (std.fmt.parseInt(usize, target, 10)) |idx| {
        return idx;
    } else |_| {}

    const json = sendRequest(allocator, conn, "GET", "/api/vms", null) catch return null;
    defer allocator.free(json);
    return findVmIdxInJson(json, target);
}

fn cmdList(allocator: std.mem.Allocator, conn: *transport.Connection, io: std.Io) !void {
    _ = io;
    const json = try sendRequest(allocator, conn, "GET", "/api/vms", null);
    defer allocator.free(json);

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

fn cmdStatus(allocator: std.mem.Allocator, conn: *transport.Connection, io: std.Io) !void {
    _ = io;
    const resp = try sendRequest(allocator, conn, "GET", "/api/health", null);
    defer allocator.free(resp);
    _ = c.write(c.STDOUT_FILENO, resp.ptr, resp.len);
    _ = c.write(c.STDOUT_FILENO, "\n", 1);
}

fn cmdPower(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, action: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/power/{d}", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} VM [{d}]: {s}\n", .{ action, idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdClone(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    return cmdSimple(allocator, conn, idx, "/api/clone/{d}", "clone", io);
}

fn cmdLinkedClone(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/clone/{d}", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, "linked=1");
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "linked-clone VM [{d}]: {s}\n", .{ idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdDelete(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    return cmdSimple(allocator, conn, idx, "/api/delete/{d}", "delete", io);
}

fn cmdRename(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, new_name: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/rename/{d}", .{idx});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "name={s}", .{new_name});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "rename VM [{d}] -> {s}: {s}\n", .{ idx, new_name, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdImport(allocator: std.mem.Allocator, conn: *transport.Connection, disk_path: []const u8, io: std.Io) !void {
    _ = io;
    var body_buf: [vm.MAX_PATH + 64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "path={s}", .{disk_path});
    const resp = try sendRequest(allocator, conn, "POST", "/api/import", body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "import {s}: {s}\n", .{ disk_path, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdExport(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/export/{d}", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "export VM [{d}]: {s}\n", .{ idx, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdSnapshotList(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/snapshot/list/{d}", .{idx});
    const resp = try sendRequest(allocator, conn, "GET", path, null);
    defer allocator.free(resp);
    if (resp.len == 0 or std.mem.eql(u8, resp, "(none)")) {
        _ = c.write(c.STDOUT_FILENO, "No snapshots found.\n", 20);
    } else {
        _ = c.write(c.STDOUT_FILENO, resp.ptr, resp.len);
        _ = c.write(c.STDOUT_FILENO, "\n", 1);
    }
}

fn cmdSnapshotTake(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, tag: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/snapshot/take/{d}", .{idx});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "tag={s}", .{tag});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "snapshot take [{d}] '{s}': {s}\n", .{ idx, tag, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdSnapshotRevert(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, tag: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/snapshot/revert/{d}", .{idx});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "tag={s}", .{tag});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "snapshot revert [{d}] '{s}': {s}\n", .{ idx, tag, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn cmdSnapshotDelete(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, tag: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/snapshot/delete/{d}", .{idx});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "tag={s}", .{tag});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "snapshot delete [{d}] '{s}': {s}\n", .{ idx, tag, resp });
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

/// Generic POST to /api/{action}/{idx} with no body.
fn cmdSimple(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, comptime path_fmt: []const u8, action: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} VM [{d}]: {s}\n", .{ action, idx, resp });
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

const vm = @import("vm.zig");

// ── Tests ──────────────────────────────────────────────────────────

test "extractJsonString: extracts quoted value" {
    const obj = "{\"name\":\"myvm\",\"status\":\"running\"}";
    const name = extractJsonString(obj, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("myvm", name.?);
    const status = extractJsonString(obj, "status");
    try std.testing.expect(status != null);
    try std.testing.expectEqualStrings("running", status.?);
}

test "extractJsonString: returns null for missing key" {
    const obj = "{\"name\":\"myvm\"}";
    const result = extractJsonString(obj, "nonexistent");
    try std.testing.expect(result == null);
}

test "extractJsonString: handles empty string value" {
    const obj = "{\"notes\":\"\",\"name\":\"test\"}";
    const notes = extractJsonString(obj, "notes");
    try std.testing.expect(notes != null);
    try std.testing.expectEqualStrings("", notes.?);
}

test "extractJsonString: handles key with common prefix" {
    const obj = "{\"name\":\"foo\",\"name_long\":\"bar\"}";
    const name = extractJsonString(obj, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("foo", name.?);
}

test "extractJsonString: returns null for key that is a prefix of another" {
    // "name" should not match "name_long"
    const obj = "{\"name_long\":\"bar\"}";
    const result = extractJsonString(obj, "name");
    try std.testing.expect(result == null);
}

test "extractJsonInt: extracts integer value" {
    const obj = "{\"mem\":2048,\"cpu\":4}";
    const mem = extractJsonInt(obj, "mem");
    try std.testing.expect(mem != null);
    try std.testing.expectEqual(@as(usize, 2048), mem.?);
    const cpu = extractJsonInt(obj, "cpu");
    try std.testing.expect(cpu != null);
    try std.testing.expectEqual(@as(usize, 4), cpu.?);
}

test "extractJsonInt: returns null for missing key" {
    const obj = "{\"mem\":2048}";
    const result = extractJsonInt(obj, "nonexistent");
    try std.testing.expect(result == null);
}

test "extractJsonInt: handles value ending at closing brace" {
    const obj = "{\"disk\":40}";
    const disk = extractJsonInt(obj, "disk");
    try std.testing.expectEqual(@as(usize, 40), disk.?);
}

test "extractJsonInt: handles value ending at comma" {
    const obj = "{\"cpu\":8,\"mem\":4096}";
    const cpu = extractJsonInt(obj, "cpu");
    try std.testing.expectEqual(@as(usize, 8), cpu.?);
}

test "extractJsonInt: returns null for non-numeric value" {
    const obj = "{\"name\":\"notanumber\"}";
    const result = extractJsonInt(obj, "name");
    try std.testing.expect(result == null);
}

test "extractJsonInt: handles zero value" {
    const obj = "{\"vnc_port\":0,\"spice_port\":5900}";
    const port = extractJsonInt(obj, "vnc_port");
    try std.testing.expectEqual(@as(usize, 0), port.?);
}

test "findVmIdxInJson: finds VM by name in single-element array" {
    const json = "[{\"idx\":0,\"name\":\"myvm\",\"status\":\"running\"}]";
    const idx = findVmIdxInJson(json, "myvm");
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 0), idx.?);
}

test "findVmIdxInJson: finds correct VM in multi-element array" {
    const json = "[{\"idx\":0,\"name\":\"alpha\",\"status\":\"stopped\"},{\"idx\":1,\"name\":\"beta\",\"status\":\"running\"},{\"idx\":2,\"name\":\"gamma\",\"status\":\"suspended\"}]";
    const idx = findVmIdxInJson(json, "beta");
    try std.testing.expectEqual(@as(usize, 1), idx.?);
    const first = findVmIdxInJson(json, "alpha");
    try std.testing.expectEqual(@as(usize, 0), first.?);
    const last = findVmIdxInJson(json, "gamma");
    try std.testing.expectEqual(@as(usize, 2), last.?);
}

test "findVmIdxInJson: returns null for missing name" {
    const json = "[{\"idx\":0,\"name\":\"myvm\"}]";
    const idx = findVmIdxInJson(json, "nonexistent");
    try std.testing.expect(idx == null);
}

test "findVmIdxInJson: returns null for empty JSON" {
    const idx = findVmIdxInJson("[]", "myvm");
    try std.testing.expect(idx == null);
}

test "findVmIdxInJson: returns null for empty string" {
    const idx = findVmIdxInJson("", "myvm");
    try std.testing.expect(idx == null);
}

test "findVmIdxInJson: handles idx with trailing comma" {
    const json = "[{\"idx\":5,\"name\":\"vm5\"},{\"idx\":10,\"name\":\"vm10\"}]";
    const idx = findVmIdxInJson(json, "vm5");
    try std.testing.expectEqual(@as(usize, 5), idx.?);
}

test "findVmIdxInJson: handles multi-digit idx values" {
    const json = "[{\"idx\":42,\"name\":\"big\"}]";
    const idx = findVmIdxInJson(json, "big");
    try std.testing.expectEqual(@as(usize, 42), idx.?);
}

test "findVmIdxInJson: finds nearest preceding idx (not another object's)" {
    // The idx for "target" should be 7, not 99 (from the preceding object).
    const json = "[{\"idx\":99,\"name\":\"other\"},{\"idx\":7,\"name\":\"target\"}]";
    const idx = findVmIdxInJson(json, "target");
    try std.testing.expectEqual(@as(usize, 7), idx.?);
}

test "findVmIdxInJson: handles name containing special JSON characters" {
    // Names with hyphens, underscores, spaces.
    const json = "[{\"idx\":1,\"name\":\"Ubuntu-22.04\"},{\"idx\":2,\"name\":\"Win_Server_2022\"}]";
    const idx1 = findVmIdxInJson(json, "Ubuntu-22.04");
    try std.testing.expectEqual(@as(usize, 1), idx1.?);
    const idx2 = findVmIdxInJson(json, "Win_Server_2022");
    try std.testing.expectEqual(@as(usize, 2), idx2.?);
}

test "findVmIdxInJson: name that is a substring of another name" {
    // "vm" should match "vm" exactly, not "vm_special"
    const json = "[{\"idx\":0,\"name\":\"vm\"},{\"idx\":1,\"name\":\"vm_special\"}]";
    const idx = findVmIdxInJson(json, "vm");
    try std.testing.expectEqual(@as(usize, 0), idx.?);
}

test "findVmIdxInJson: name contains colon or other special chars" {
    const json = "[{\"idx\":3,\"name\":\"test:vm\"}]";
    const idx = findVmIdxInJson(json, "test:vm");
    try std.testing.expectEqual(@as(usize, 3), idx.?);
}

// ── Fuzz tests ──────────────────────────────────────────────────────

test "fuzz: extractJsonString never panics on random JSON-like input" {
    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;

    const keys = [_][]const u8{ "name", "status", "notes", "mac", "iso", "tag", "error" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        for (keys) |k| {
            if (extractJsonString(buf[0..len], k)) |result| {
                try std.testing.expect(result.len <= len);
            }
        }
    }
}

test "fuzz: extractJsonInt never panics on random JSON-like input" {
    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;

    const keys = [_][]const u8{ "mem", "cpu", "disk", "vnc_port", "spice_port", "ap_interval", "ap_max" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        for (keys) |k| {
            _ = extractJsonInt(buf[0..len], k);
        }
    }
}

test "fuzz: findVmIdxInJson never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xFEED_F00D);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;

    const names = [_][]const u8{ "myvm", "test", "alpha", "123", "a", "Ubuntu-22.04", "" };
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        for (names) |n| {
            if (findVmIdxInJson(buf[0..len], n)) |result| {
                // Name was found — result must be a valid index
                _ = result;
            }
        }
    }
}
