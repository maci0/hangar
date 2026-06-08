// SPDX-License-Identifier: MIT
//! vmrun — CLI tool for managing Hangar VMs remotely.
//!
//! Connects to a Hangar web server via the transport abstraction layer
//! and issues commands: list, status, start, stop, restart, clone,
//! linked-clone, delete, suspend, pause, resume, shutdown, reset, rename,
//! cad, snapshot, import, export.
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
const urlencode = @import("urlencode.zig");

const usage =
    \\vmrun — Hangar remote VM manager
    \\
    \\Usage: vmrun <server-url> <command> [args...]
    \\
    \\Commands:
    \\  list                    List all VMs
    \\  create <name> <mem-mb> <cpu> <disk-gb>   Create a VM
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
    \\  resize      <name|idx> <new-gb>    Grow the primary disk (stopped VM)
    \\  cd          <name|idx> <iso-path>  Change the mounted CD/ISO
    \\  eject       <name|idx>             Eject the mounted CD/ISO
    \\  compact     <name|idx>             Compact the primary disk (stopped VM)
    \\  set         <name|idx> <field> <value>  Set a config field
    \\              (field: mem|cpu|cpu_sockets|network|notes|boot_order|vnc_port|spice_port)
    \\  cad         <name|idx>  Send Ctrl+Alt+Del to guest
    \\  snapshot list    <name|idx>        List snapshots
    \\  snapshot take    <name|idx> <tag>  Take a snapshot
    \\  snapshot revert  <name|idx> <tag>  Revert to snapshot
    \\  snapshot delete  <name|idx> <tag>  Delete a snapshot
    \\  import      <disk-path>  Import a VM from disk image
    \\  export      <name|idx>   Export VM as OVF+VMDK
    \\  log         <name|idx>   Show the VM's QEMU stderr log
    \\  info        <name|idx>   Show VM details
    \\  migrate     <name|idx> <host> <port>  Live-migrate to another host
    \\  status                  Show server health
    \\
    \\Server URL formats:
    \\  http://host:port   HTTP over TCP (port defaults to 9080)
    \\  unix:///path       Unix domain socket
    \\
    \\Global (accepted in any position):
    \\  help, -h, --help     Show this help and exit
    \\  -v, --version        Show version and exit
    \\
    \\Environment:
    \\  KV_API_KEY           X-API-Key sent with every request (default: built-in
    \\                       key). Must match the daemon's KV_API_KEY.
    \\
    \\Exit codes: 0 success, 1 runtime error, 2 usage error.
    \\
    \\Examples:
    \\  vmrun http://localhost:9080 list
    \\  vmrun http://localhost:9080 start myvm
    \\  vmrun unix:///run/hangar.sock snapshot take 0 before-update
    \\
;

const version = "vmrun 0.1.0\n";

/// Write a slice to a file descriptor using its real length.
/// Replaces error-prone hand-counted byte lengths in `c.write` calls.
fn fdWrite(fd: c_int, msg: []const u8) void {
    _ = c.write(fd, msg.ptr, msg.len);
}

/// Exit code for usage/argument errors (POSIX convention: 2).
const EXIT_USAGE: u8 = 2;

/// True when `arg` is any accepted spelling of the help flag. The bare word
/// `help` is accepted as an alias (matching hangar-web / hangar-webui).
fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help");
}

/// True when `arg` is any accepted spelling of the version flag.
fn isVersionArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version");
}

pub fn main(init: std.process.Init) !void {
    // Translate any runtime error from the command dispatch into a clean,
    // single-line diagnostic and exit code 1 (the documented "runtime error"
    // code) instead of letting Zig dump an error-return trace at the user.
    run(init) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: {s}\n", .{@errorName(err)}) catch "Error: command failed\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = args_iter.next(); // program name

    const server_url = args_iter.next() orelse {
        fdWrite(c.STDERR_FILENO, usage);
        std.process.exit(EXIT_USAGE);
    };

    // Help / version are accepted in the first positional slot.
    if (isHelpArg(server_url)) {
        fdWrite(c.STDOUT_FILENO, usage);
        std.process.exit(0);
    }
    if (isVersionArg(server_url)) {
        fdWrite(c.STDOUT_FILENO, version);
        std.process.exit(0);
    }

    const command = args_iter.next() orelse {
        fdWrite(c.STDERR_FILENO, usage);
        std.process.exit(EXIT_USAGE);
    };

    // Help / version are also accepted in the command slot (e.g. after the
    // URL) so `vmrun <url> --help` works and never needs a connection.
    if (isHelpArg(command)) {
        fdWrite(c.STDOUT_FILENO, usage);
        std.process.exit(0);
    }
    if (isVersionArg(command)) {
        fdWrite(c.STDOUT_FILENO, version);
        std.process.exit(0);
    }

    // Collect the remaining positional arguments once so the command's
    // argument shape can be validated *before* opening a connection. A usage
    // mistake (unknown command, missing argument, bad subcommand) must fail
    // fast with exit code 2 and never require a running daemon — this is what
    // makes the tool predictable in scripts.
    var rest: [16][]const u8 = undefined;
    var rest_n: usize = 0;
    while (args_iter.next()) |a| : (rest_n += 1) {
        if (rest_n < rest.len) rest[rest_n] = a;
    }
    const args = rest[0..@min(rest_n, rest.len)];

    // Accept help/version anywhere in the trailing args too, so
    // `vmrun <url> <cmd> --help` behaves like every other CLI (and never needs
    // a running daemon). Done before validateArgs so it wins over an
    // "argument count" complaint.
    for (args) |a| {
        if (isHelpArg(a)) {
            fdWrite(c.STDOUT_FILENO, usage);
            std.process.exit(0);
        }
        if (isVersionArg(a)) {
            fdWrite(c.STDOUT_FILENO, version);
            std.process.exit(0);
        }
    }

    validateArgs(command, args);

    const url = transport.Url.parse(server_url) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: invalid server URL '{s}' (expected http://host:port or unix:///path)\n", .{server_url}) catch "Error: invalid server URL\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(EXIT_USAGE);
    };

    var conn = transport.Connection.connect(&url) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: failed to connect to server '{s}' (is the daemon running?)\n", .{server_url}) catch "Error: failed to connect to server\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(1);
    };
    defer conn.close();

    // Argument shape was validated by validateArgs() before we connected, so
    // the positional accesses below are known to be in range.
    if (std.mem.eql(u8, command, "list")) {
        return cmdList(allocator, &conn, init.io);
    } else if (std.mem.eql(u8, command, "status")) {
        return cmdStatus(allocator, &conn, init.io);
    } else if (std.mem.eql(u8, command, "import")) {
        return cmdImport(allocator, &conn, args[0], init.io);
    } else if (std.mem.eql(u8, command, "create")) {
        return cmdCreate(allocator, &conn, args[0], args[1], args[2], args[3], init.io);
    } else if (std.mem.eql(u8, command, "snapshot")) {
        const sub = args[0];
        const target = args[1];
        const idx = resolveVm(allocator, &conn, target) orelse return notFound(target);
        if (std.mem.eql(u8, sub, "list")) {
            return cmdSnapshotList(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, sub, "take")) {
            return cmdSnapshotOp(allocator, &conn, idx, args[2], "take", init.io);
        } else if (std.mem.eql(u8, sub, "revert")) {
            return cmdSnapshotOp(allocator, &conn, idx, args[2], "revert", init.io);
        } else {
            return cmdSnapshotOp(allocator, &conn, idx, args[2], "delete", init.io);
        }
    } else if (std.mem.eql(u8, command, "rename")) {
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdRename(allocator, &conn, idx, args[1], init.io);
    } else if (std.mem.eql(u8, command, "resize")) {
        _ = std.fmt.parseInt(u32, args[1], 10) catch return error.InvalidSize;
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdResize(allocator, &conn, idx, args[1], init.io);
    } else if (std.mem.eql(u8, command, "cd")) {
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdCdrom(allocator, &conn, idx, args[1], init.io);
    } else if (std.mem.eql(u8, command, "eject")) {
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdCdrom(allocator, &conn, idx, null, init.io);
    } else if (std.mem.eql(u8, command, "compact")) {
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdSimplePost(allocator, &conn, idx, "/disk/compact", "compact", init.io);
    } else if (std.mem.eql(u8, command, "migrate")) {
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdMigrate(allocator, &conn, idx, args[1], args[2], init.io);
    } else if (std.mem.eql(u8, command, "set")) {
        if (!isSettableField(args[1])) {
            var sb: [256]u8 = undefined;
            const m = std.fmt.bufPrintZ(&sb, "Error: unknown field '{s}' (settable: {s})\n", .{ args[1], SETTABLE_FIELDS_HELP }) catch "Error: unknown field\n";
            fdWrite(c.STDERR_FILENO, m);
            std.process.exit(EXIT_USAGE);
        }
        const idx = resolveVm(allocator, &conn, args[0]) orelse return notFound(args[0]);
        return cmdSet(allocator, &conn, idx, args[1], args[2], init.io);
    } else {
        // Single-target VM operations: start/stop/restart/clone/linked-clone/
        // delete/suspend/pause/resume/shutdown/reset/cad/export.
        const target = args[0];
        const idx = resolveVm(allocator, &conn, target) orelse return notFound(target);

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
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/suspend", "suspend", init.io);
        } else if (std.mem.eql(u8, command, "pause")) {
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/pause", "pause", init.io);
        } else if (std.mem.eql(u8, command, "resume")) {
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/resume", "resume", init.io);
        } else if (std.mem.eql(u8, command, "shutdown")) {
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/shutdown", "shutdown", init.io);
        } else if (std.mem.eql(u8, command, "reset")) {
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/reset", "reset", init.io);
        } else if (std.mem.eql(u8, command, "cad")) {
            return cmdSimple(allocator, &conn, idx, "/api/vms/{d}/cad", "cad", init.io);
        } else if (std.mem.eql(u8, command, "log")) {
            return cmdLog(allocator, &conn, idx, init.io);
        } else if (std.mem.eql(u8, command, "info")) {
            return cmdInfo(allocator, &conn, idx, init.io);
        } else {
            return cmdExport(allocator, &conn, idx, init.io);
        }
    }
}

/// Number of positional arguments a command requires (after the URL and the
/// command word). Returns null for an unknown command. Snapshot is handled
/// separately because its arity depends on the subcommand.
fn commandArity(command: []const u8) ?usize {
    const zero = [_][]const u8{ "list", "status" };
    const one = [_][]const u8{
        "import",       "start", "stop",     "restart", "clone",
        "linked-clone", "delete", "suspend", "pause",   "resume",
        "shutdown",     "reset", "cad",      "export",  "log",
        "info",
    };
    for (zero) |k| if (std.mem.eql(u8, command, k)) return 0;
    for (one) |k| if (std.mem.eql(u8, command, k)) return 1;
    if (std.mem.eql(u8, command, "rename")) return 2;
    if (std.mem.eql(u8, command, "resize")) return 2; // target new-gb
    if (std.mem.eql(u8, command, "cd")) return 2; // target iso-path
    if (std.mem.eql(u8, command, "eject")) return 1; // target
    if (std.mem.eql(u8, command, "compact")) return 1; // target
    if (std.mem.eql(u8, command, "migrate")) return 3; // target host port
    if (std.mem.eql(u8, command, "set")) return 3; // target field value
    if (std.mem.eql(u8, command, "create")) return 4; // name mem cpu disk
    return null;
}

/// Validate the command name and positional-argument count before any network
/// activity. On any problem this prints a one-line diagnostic to stderr and
/// exits with EXIT_USAGE (2) — usage errors never require a running daemon.
fn validateArgs(command: []const u8, args: []const []const u8) void {
    if (std.mem.eql(u8, command, "snapshot")) {
        if (args.len == 0) {
            fdWrite(c.STDERR_FILENO, "Error: snapshot command requires subcommand: list|take|revert|delete\n");
            std.process.exit(EXIT_USAGE);
        }
        const sub = args[0];
        const is_list = std.mem.eql(u8, sub, "list");
        const needs_tag = std.mem.eql(u8, sub, "take") or
            std.mem.eql(u8, sub, "revert") or std.mem.eql(u8, sub, "delete");
        if (!is_list and !needs_tag) {
            fdWrite(c.STDERR_FILENO, "Error: unknown snapshot subcommand (use: list|take|revert|delete)\n");
            std.process.exit(EXIT_USAGE);
        }
        if (args.len < 2) {
            fdWrite(c.STDERR_FILENO, "Error: missing VM name or index\n");
            std.process.exit(EXIT_USAGE);
        }
        if (needs_tag and args.len < 3) {
            fdWrite(c.STDERR_FILENO, "Error: missing snapshot tag\n");
            std.process.exit(EXIT_USAGE);
        }
        // Reject trailing junk so a typo (e.g. an extra word) fails loudly
        // instead of being silently dropped. list takes 2 args (sub + target),
        // take/revert/delete take 3 (sub + target + tag).
        const max: usize = if (needs_tag) 3 else 2;
        if (args.len > max) {
            fdWrite(c.STDERR_FILENO, "Error: too many arguments for snapshot command (run with --help for usage)\n");
            std.process.exit(EXIT_USAGE);
        }
        return;
    }

    const arity = commandArity(command) orelse {
        // A dash-prefixed token in the command slot is almost always a mistyped
        // flag, so name it as such — matching hangar-web / hangar-webui, which
        // both report "unknown option" for stray dash args.
        const kind = if (command.len > 0 and command[0] == '-') "option" else "command";
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: unknown {s} '{s}' (run with --help for usage)\n", .{ kind, command }) catch "Error: unknown command\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(EXIT_USAGE);
    };
    if (args.len < arity) {
        const msg = if (std.mem.eql(u8, command, "import"))
            "Error: missing disk path\n"
        else if (arity == 2 and args.len == 1)
            "Error: missing new name\n"
        else
            "Error: missing VM name or index\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(EXIT_USAGE);
    }
    // Reject excess positional arguments. Without this an invocation like
    // `vmrun <url> start vm1 vm2` silently ignores `vm2`, so a mistyped
    // command appears to succeed — bad for interactive use and worse in scripts.
    if (args.len > arity) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: too many arguments for '{s}' (run with --help for usage)\n", .{command}) catch "Error: too many arguments\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(EXIT_USAGE);
    }
}

/// Print a "VM not found" diagnostic and exit 1 (runtime error). A lookup that
/// fails against a live daemon is a runtime condition, not a usage mistake.
fn notFound(target: []const u8) noreturn {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Error: VM '{s}' not found\n", .{target}) catch "Error: VM not found\n";
    fdWrite(c.STDERR_FILENO, msg);
    std.process.exit(1);
}

fn sendRequest(allocator: std.mem.Allocator, conn: *transport.Connection, method: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    // Match the server's /api/vms render cap (vm.MAX_VMS * 4096). A small fixed
    // buffer here silently truncated large fleets, so `list` stopped early and
    // name→index resolution failed for any VM past the cutoff. Allocate on the
    // heap — a buffer this size cannot live on the stack.
    const cap = vm.MAX_VMS * 4096;
    const buf = try allocator.alloc(u8, cap);
    defer allocator.free(buf);
    const n = conn.request(method, path, body, buf);
    if (n == 0) return error.RequestFailed;
    // The daemon normalizes every API failure (validation, not-found, auth, and
    // server-side errors) to a `{"error":"<msg>"}` JSON envelope. Without this
    // check vmrun printed that body to stdout as a fake success line and exited
    // 0 — so a failed `start`/`delete`/`snapshot` looked successful in scripts.
    // Map the envelope to a stderr diagnostic and exit 1 (the documented
    // runtime-error code) instead.
    if (errorEnvelopeMsg(buf[0..n])) |detail| {
        var ebuf: [320]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&ebuf, "Error: {s}\n", .{detail}) catch "Error: server returned an error\n";
        fdWrite(c.STDERR_FILENO, msg);
        std.process.exit(1);
    }
    return try allocator.dupe(u8, buf[0..n]);
}

/// If `resp` is the daemon's JSON error envelope (`{"error":"<msg>"}`), return
/// the inner message (empty string when the envelope carries no detail);
/// otherwise null. Every API error the daemon returns is normalized to this
/// envelope (see web_server `jsonErr`), while success bodies are plain text
/// ("ok"), a JSON array, or a health object — none begin with this prefix.
fn errorEnvelopeMsg(resp: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, resp, "{\"error\":")) return null;
    return extractJsonString(resp, "error") orelse "";
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

/// Pure helper: given VM-list JSON and a numeric index, return that VM's
/// "status" string (e.g. "running", "stopped"). Matches the object whose
/// `"idx":N` field equals `idx`. Returns null when no such object exists.
fn findVmStatusInJson(json: []const u8, idx: usize) ?[]const u8 {
    var rest = json;
    while (std.mem.indexOfScalar(u8, rest, '{')) |obj_start| {
        rest = rest[obj_start..];
        const obj_end = std.mem.indexOfScalar(u8, rest, '}') orelse break;
        const obj = rest[0 .. obj_end + 1];
        rest = rest[obj_end + 1 ..];
        const obj_idx = extractJsonInt(obj, "idx") orelse continue;
        if (obj_idx == idx) return extractJsonString(obj, "status");
    }
    return null;
}

/// True when a VM-list status string denotes a powered-on VM (running or
/// paused), mirroring the daemon's `VmConfig.isAlive`.
fn statusIsAlive(status: []const u8) bool {
    return std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "paused");
}

fn resolveVm(allocator: std.mem.Allocator, conn: *transport.Connection, target: []const u8) ?usize {
    // Try parsing as numeric index first.
    if (std.fmt.parseInt(usize, target, 10)) |idx| {
        return idx;
    } else |_| {}

    const json = sendRequest(allocator, conn, "GET", "/api/vms", null) catch return null;
    defer allocator.free(json);
    // VM names are not unique. Acting on the first match would silently target an
    // arbitrary VM, so refuse an ambiguous name and tell the user to use the index.
    if (countVmNameMatches(json, target) > 1) {
        var b: [192]u8 = undefined;
        const m = std.fmt.bufPrintZ(&b, "Error: multiple VMs named '{s}'; address it by index (run `list`)\n", .{target}) catch "Error: ambiguous VM name\n";
        fdWrite(c.STDERR_FILENO, m);
        std.process.exit(1);
    }
    return findVmIdxInJson(json, target);
}

/// Pure helper: count how many VMs in the list JSON have exactly `name`. Uses
/// the same quoted `"name":"<name>"` pattern as findVmIdxInJson, so it matches
/// whole names only ("vm1" does not match "vm10").
fn countVmNameMatches(json: []const u8, name: []const u8) usize {
    var search_buf: [128]u8 = undefined;
    const pat = std.fmt.bufPrint(&search_buf, "\"name\":\"{s}\"", .{name}) catch return 0;
    var n: usize = 0;
    var rest = json;
    while (std.mem.indexOf(u8, rest, pat)) |p| {
        n += 1;
        rest = rest[p + pat.len ..];
    }
    return n;
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
        fdWrite(c.STDOUT_FILENO, line);
        idx += 1;
    }

    if (idx == 0) {
        fdWrite(c.STDOUT_FILENO, "No VMs found.\n");
    }
}

fn cmdStatus(allocator: std.mem.Allocator, conn: *transport.Connection, io: std.Io) !void {
    _ = io;
    const resp = try sendRequest(allocator, conn, "GET", "/api/health", null);
    defer allocator.free(resp);
    fdWrite(c.STDOUT_FILENO, resp);
    fdWrite(c.STDOUT_FILENO, "\n");
}

fn cmdPower(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, action: []const u8, io: std.Io) !void {
    _ = io;
    // The daemon's /api/vms/<id>/power endpoint is a toggle (start if off, stop if on).
    // The CLI exposes explicit `start`/`stop` verbs, so issuing the toggle
    // blindly inverts the user's intent: `stop` on an already-off VM would
    // power it ON, and `start` on a running VM would power it OFF. Query the
    // current state first and only toggle when it actually needs to change,
    // making `start`/`stop` idempotent and faithful to the documented verbs.
    const want_on = std.mem.eql(u8, action, "start");
    const json = try sendRequest(allocator, conn, "GET", "/api/vms", null);
    defer allocator.free(json);
    const is_on = if (findVmStatusInJson(json, idx)) |s| statusIsAlive(s) else false;
    if (is_on == want_on) {
        var nbuf: [256]u8 = undefined;
        const noop = try std.fmt.bufPrint(&nbuf, "VM [{d}] already {s}\n", .{ idx, if (want_on) "powered on" else "powered off" });
        fdWrite(c.STDOUT_FILENO, noop);
        return;
    }

    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/power", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} VM [{d}]: {s}\n", .{ action, idx, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

fn cmdClone(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    return cmdSimple(allocator, conn, idx, "/api/vms/{d}/clone", "clone", io);
}

fn cmdLinkedClone(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/clone", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, "linked=1");
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "linked-clone VM [{d}]: {s}\n", .{ idx, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

fn cmdDelete(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    return cmdSimple(allocator, conn, idx, "/api/vms/{d}/delete", "delete", io);
}

/// Grow a VM's primary disk to `new_gb` GiB (POST /api/vms/<id>/disk/resize).
fn cmdResize(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, new_gb: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [40]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/disk/resize", .{idx});
    var body_buf: [32]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "size={s}", .{new_gb});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "resize VM [{d}] -> {s} GB: {s}\n", .{ idx, new_gb, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

/// POST to /api/vms/<idx><suffix> with no body and print "<label> VM [idx]: <resp>".
fn cmdSimplePost(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, suffix: []const u8, label: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const url = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}{s}", .{ idx, suffix });
    const resp = try sendRequest(allocator, conn, "POST", url, "");
    defer allocator.free(resp);
    var b: [128]u8 = undefined;
    fdWrite(c.STDOUT_FILENO, std.fmt.bufPrint(&b, "{s} VM [{d}]: {s}\n", .{ label, idx, resp }) catch "ok\n");
}

/// Change (path != null) or eject (path == null) the VM's CD/ISO.
fn cmdCdrom(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, path: ?[]const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [40]u8 = undefined;
    if (path) |p| {
        const url = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/cdrom", .{idx});
        var enc_buf: [vm.MAX_PATH * 3]u8 = undefined;
        const enc = try urlencode.percentEncode(&enc_buf, p);
        var body_buf: [vm.MAX_PATH * 3 + 8]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "path={s}", .{enc});
        const resp = try sendRequest(allocator, conn, "POST", url, body);
        defer allocator.free(resp);
        var b: [128]u8 = undefined;
        fdWrite(c.STDOUT_FILENO, std.fmt.bufPrint(&b, "cd VM [{d}] -> {s}: {s}\n", .{ idx, p, resp }) catch "cd\n");
    } else {
        const url = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/cdrom/eject", .{idx});
        const resp = try sendRequest(allocator, conn, "POST", url, "");
        defer allocator.free(resp);
        var b: [96]u8 = undefined;
        fdWrite(c.STDOUT_FILENO, std.fmt.bufPrint(&b, "eject VM [{d}]: {s}\n", .{ idx, resp }) catch "eject\n");
    }
}

fn cmdRename(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, new_name: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/rename", .{idx});
    // Percent-encode the name so values containing &, =, %, +, or spaces reach
    // the daemon intact (it URL-decodes form values, exactly like the web UI).
    var name_enc_buf: [vm.MAX_NAME * 3]u8 = undefined;
    const enc_name = try urlencode.percentEncode(&name_enc_buf, new_name);
    var body_buf: [vm.MAX_NAME * 3 + 16]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "name={s}", .{enc_name});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "rename VM [{d}] -> {s}: {s}\n", .{ idx, new_name, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

/// Fields `vmrun set` accepts. A curated, stable subset of the daemon's save
/// keys (handleSave) whose names and semantics are unlikely to drift; keeping
/// it small avoids the silent no-op a typo'd or server-unknown key would cause.
const SETTABLE_FIELDS = [_][]const u8{
    "mem", "cpu", "cpu_sockets", "network", "notes", "tags", "boot_order", "rtc", "vnc_port", "spice_port",
};
const SETTABLE_FIELDS_HELP = "mem, cpu, cpu_sockets, network, notes, tags, boot_order, rtc, vnc_port, spice_port";

/// Pure: is `field` one this CLI will forward to the daemon's save endpoint?
fn isSettableField(field: []const u8) bool {
    for (SETTABLE_FIELDS) |f| {
        if (std.mem.eql(u8, f, field)) return true;
    }
    return false;
}

/// Update one config field of VM `idx` via a partial save (POST /api/vms/<id>).
/// handleSave applies only the keys present in the body, so a single field is
/// changed and the rest are untouched. The field is allowlisted by the caller.
fn cmdSet(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, field: []const u8, value: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}", .{idx});
    var val_enc_buf: [768]u8 = undefined;
    const enc = try urlencode.percentEncode(&val_enc_buf, value);
    var body_buf: [832]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{s}={s}", .{ field, enc });
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "set VM [{d}] {s}={s}: {s}\n", .{ idx, field, value, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

/// Start a live migration of VM `idx` to `host`:`port`. Mirrors the web UI,
/// which posts `dest=tcp:<host>:<port>`. The daemon kicks off the migration and
/// replies `{"status":"started"}`; poll `info`/the web UI for progress.
fn cmdMigrate(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, host: []const u8, port: []const u8, io: std.Io) !void {
    _ = io;
    const port_num = std.fmt.parseInt(u16, port, 10) catch return error.InvalidPort;
    if (port_num == 0) return error.InvalidPort;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/migrate", .{idx});
    // dest=tcp:<host>:<port>, percent-encoded so the daemon's URL-decode rebuilds it.
    var dest_buf: [320]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "tcp:{s}:{d}", .{ host, port_num });
    var enc_buf: [960]u8 = undefined;
    const enc = try urlencode.percentEncode(&enc_buf, dest);
    var body_buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "dest={s}", .{enc});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "migrate VM [{d}] -> {s}: {s}\n", .{ idx, dest, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

/// Create a VM: POST /api/vms with name/mem/cpu/disk. Advanced fields take the
/// daemon's defaults; edit them afterwards via the web UI or a future setter.
fn cmdCreate(allocator: std.mem.Allocator, conn: *transport.Connection, name: []const u8, mem: []const u8, cpu: []const u8, disk: []const u8, io: std.Io) !void {
    _ = io;
    // Validate the numeric fields client-side so a typo fails fast with a clear
    // message instead of being silently clamped to a default by the daemon.
    _ = std.fmt.parseInt(u32, mem, 10) catch return error.InvalidMemory;
    _ = std.fmt.parseInt(u32, cpu, 10) catch return error.InvalidCpu;
    _ = std.fmt.parseInt(u32, disk, 10) catch return error.InvalidDisk;
    var name_enc_buf: [vm.MAX_NAME * 3]u8 = undefined;
    const enc_name = try urlencode.percentEncode(&name_enc_buf, name);
    var body_buf: [vm.MAX_NAME * 3 + 64]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "name={s}&mem={s}&cpu={s}&disk={s}", .{ enc_name, mem, cpu, disk });
    const resp = try sendRequest(allocator, conn, "POST", "/api/vms", body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "create {s}: {s}\n", .{ name, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

fn cmdImport(allocator: std.mem.Allocator, conn: *transport.Connection, disk_path: []const u8, io: std.Io) !void {
    _ = io;
    // Percent-encode the path so values with spaces or reserved characters
    // round-trip through the daemon's URL-decode (matching the web UI).
    var path_enc_buf: [vm.MAX_PATH * 3]u8 = undefined;
    const enc_path = try urlencode.percentEncode(&path_enc_buf, disk_path);
    var body_buf: [vm.MAX_PATH * 3 + 16]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "path={s}", .{enc_path});
    const resp = try sendRequest(allocator, conn, "POST", "/api/vms/import", body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "import {s}: {s}\n", .{ disk_path, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

fn cmdExport(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/export", .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "export VM [{d}]: {s}\n", .{ idx, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

fn cmdSnapshotList(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/snapshots", .{idx});
    const resp = try sendRequest(allocator, conn, "GET", path, null);
    defer allocator.free(resp);
    if (resp.len == 0 or std.mem.eql(u8, resp, "(none)")) {
        fdWrite(c.STDOUT_FILENO, "No snapshots found.\n");
    } else {
        fdWrite(c.STDOUT_FILENO, resp);
        fdWrite(c.STDOUT_FILENO, "\n");
    }
}

/// GET a VM's detail object and print a readable summary.
fn cmdInfo(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}", .{idx});
    const obj = try sendRequest(allocator, conn, "GET", path, null);
    defer allocator.free(obj);
    const name = extractJsonString(obj, "name") orelse "?";
    const status = extractJsonString(obj, "status") orelse "?";
    const os = extractJsonString(obj, "os") orelse "?";
    const net = extractJsonString(obj, "net") orelse "?";
    const mem = extractJsonInt(obj, "mem") orelse 0;
    const cpu = extractJsonInt(obj, "cpu") orelse 0;
    const disk = extractJsonInt(obj, "disk") orelse 0;
    var buf: [512]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "VM [{d}] {s}\n  Status:  {s}\n  Guest:   {s}\n  Memory:  {d} MB\n  CPU:     {d} cores\n  Disk:    {d} GB\n  Network: {s}\n", .{ idx, name, status, os, mem, cpu, disk, net });
    fdWrite(c.STDOUT_FILENO, out);
}

/// GET the tail of a VM's QEMU stderr log and print it. Useful for diagnosing a
/// "start err" from the CLI without opening the web UI.
fn cmdLog(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/vms/{d}/log", .{idx});
    const resp = try sendRequest(allocator, conn, "GET", path, null);
    defer allocator.free(resp);
    if (resp.len == 0) {
        fdWrite(c.STDOUT_FILENO, "No log available (VM not started, or QEMU produced no output).\n");
        return;
    }
    fdWrite(c.STDOUT_FILENO, resp);
    if (resp[resp.len - 1] != '\n') fdWrite(c.STDOUT_FILENO, "\n");
}

/// POST snapshot op with a `tag=` body. `action` is one of
/// "take", "revert", "delete".
fn cmdSnapshotOp(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, tag: []const u8, comptime action: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path_fmt = comptime if (std.mem.eql(u8, action, "take"))
        "/api/vms/{d}/snapshots"
    else if (std.mem.eql(u8, action, "revert"))
        "/api/vms/{d}/snapshots/revert"
    else
        "/api/vms/{d}/snapshots/delete";
    const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{idx});
    // Percent-encode the tag so the daemon's URL-decode reproduces it exactly.
    var tag_enc_buf: [768]u8 = undefined;
    const enc_tag = try urlencode.percentEncode(&tag_enc_buf, tag);
    var body_buf: [800]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "tag={s}", .{enc_tag});
    const resp = try sendRequest(allocator, conn, "POST", path, body);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "snapshot " ++ action ++ " [{d}] '{s}': {s}\n", .{ idx, tag, resp });
    fdWrite(c.STDOUT_FILENO, line);
}

/// Generic POST to /api/vms/{idx}/{action} with no body.
fn cmdSimple(allocator: std.mem.Allocator, conn: *transport.Connection, idx: usize, comptime path_fmt: []const u8, action: []const u8, io: std.Io) !void {
    _ = io;
    var path_buf: [48]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{idx});
    const resp = try sendRequest(allocator, conn, "POST", path, null);
    defer allocator.free(resp);
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} VM [{d}]: {s}\n", .{ action, idx, resp });
    fdWrite(c.STDOUT_FILENO, line);
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

test "countVmNameMatches: counts exact whole-name matches" {
    const json = "[{\"idx\":0,\"name\":\"web\"},{\"idx\":1,\"name\":\"web10\"},{\"idx\":2,\"name\":\"web\"}]";
    try std.testing.expectEqual(@as(usize, 2), countVmNameMatches(json, "web"));
    try std.testing.expectEqual(@as(usize, 1), countVmNameMatches(json, "web10"));
    try std.testing.expectEqual(@as(usize, 0), countVmNameMatches(json, "db"));
    try std.testing.expectEqual(@as(usize, 0), countVmNameMatches("", "web"));
}

test "fuzz: countVmNameMatches never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xC0FF_EE42);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = countVmNameMatches(buf[0..len], "web");
    }
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

test "findVmStatusInJson: returns status for matching idx" {
    const json = "[{\"idx\":0,\"name\":\"a\",\"status\":\"running\"},{\"idx\":1,\"name\":\"b\",\"status\":\"stopped\"}]";
    try std.testing.expectEqualStrings("running", findVmStatusInJson(json, 0).?);
    try std.testing.expectEqualStrings("stopped", findVmStatusInJson(json, 1).?);
}

test "findVmStatusInJson: returns null for missing idx or empty list" {
    const json = "[{\"idx\":0,\"name\":\"a\",\"status\":\"running\"}]";
    try std.testing.expect(findVmStatusInJson(json, 9) == null);
    try std.testing.expect(findVmStatusInJson("[]", 0) == null);
    try std.testing.expect(findVmStatusInJson("", 0) == null);
}

test "statusIsAlive: running and paused are alive; others are not" {
    try std.testing.expect(statusIsAlive("running"));
    try std.testing.expect(statusIsAlive("paused"));
    try std.testing.expect(!statusIsAlive("stopped"));
    try std.testing.expect(!statusIsAlive("suspended"));
    try std.testing.expect(!statusIsAlive(""));
}

test "fuzz: findVmStatusInJson and statusIsAlive never panic on random input" {
    var prng = std.Random.DefaultPrng.init(0x57A705);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        if (findVmStatusInJson(buf[0..len], rnd.uintLessThan(usize, 8))) |s| {
            _ = statusIsAlive(s);
        }
    }
}

test "errorEnvelopeMsg: detects error envelope and extracts message" {
    const msg = errorEnvelopeMsg("{\"error\":\"not found\"}");
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("not found", msg.?);
}

test "errorEnvelopeMsg: empty-detail envelope returns empty string, not null" {
    const msg = errorEnvelopeMsg("{\"error\":\"\"}");
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("", msg.?);
}

test "errorEnvelopeMsg: success bodies are not treated as errors" {
    try std.testing.expect(errorEnvelopeMsg("ok") == null);
    try std.testing.expect(errorEnvelopeMsg("[{\"idx\":0,\"name\":\"vm\"}]") == null);
    try std.testing.expect(errorEnvelopeMsg("{\"status\":\"ok\"}") == null);
    try std.testing.expect(errorEnvelopeMsg("") == null);
    // A snapshot tag or VM name containing the word "error" must not trip it.
    try std.testing.expect(errorEnvelopeMsg("fix-error") == null);
}

test "commandArity: zero-arg commands" {
    try std.testing.expectEqual(@as(?usize, 0), commandArity("list"));
    try std.testing.expectEqual(@as(?usize, 0), commandArity("status"));
}

test "commandArity: single-target commands" {
    const one = [_][]const u8{
        "import",       "start", "stop",     "restart", "clone",
        "linked-clone", "delete", "suspend", "pause",   "resume",
        "shutdown",     "reset", "cad",      "export",  "log",
        "info",
    };
    for (one) |cmd| {
        try std.testing.expectEqual(@as(?usize, 1), commandArity(cmd));
    }
}

test "commandArity: rename takes two args" {
    try std.testing.expectEqual(@as(?usize, 2), commandArity("rename"));
}

test "commandArity: create takes four args" {
    try std.testing.expectEqual(@as(?usize, 4), commandArity("create"));
}

test "commandArity: migrate takes three args" {
    try std.testing.expectEqual(@as(?usize, 3), commandArity("migrate"));
}

test "commandArity: resize takes two args" {
    try std.testing.expectEqual(@as(?usize, 2), commandArity("resize"));
}

test "commandArity: cd takes two args, eject/compact one" {
    try std.testing.expectEqual(@as(?usize, 2), commandArity("cd"));
    try std.testing.expectEqual(@as(?usize, 1), commandArity("eject"));
    try std.testing.expectEqual(@as(?usize, 1), commandArity("compact"));
}

test "commandArity: set takes three args" {
    try std.testing.expectEqual(@as(?usize, 3), commandArity("set"));
}

test "isSettableField: allowlist membership" {
    try std.testing.expect(isSettableField("mem"));
    try std.testing.expect(isSettableField("vnc_port"));
    try std.testing.expect(isSettableField("boot_order"));
    try std.testing.expect(isSettableField("tags"));
    try std.testing.expect(!isSettableField("disk")); // not safely settable post-create
    try std.testing.expect(!isSettableField("name")); // use rename
    try std.testing.expect(!isSettableField(""));
    try std.testing.expect(!isSettableField("mem ")); // exact match only
}

test "fuzz: isSettableField never panics on arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0x5E77_AB1E);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = isSettableField(buf[0..len]);
    }
}

test "commandArity: snapshot is not covered (subcommand-dependent)" {
    // snapshot arity depends on its subcommand and is validated separately.
    try std.testing.expectEqual(@as(?usize, null), commandArity("snapshot"));
}

test "commandArity: unknown command returns null" {
    try std.testing.expectEqual(@as(?usize, null), commandArity("bogus"));
    try std.testing.expectEqual(@as(?usize, null), commandArity(""));
    try std.testing.expectEqual(@as(?usize, null), commandArity("START")); // case-sensitive
}

test "isHelpArg: accepts all help spellings, rejects others" {
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("help"));
    try std.testing.expect(!isHelpArg("-H"));
    try std.testing.expect(!isHelpArg("--Help"));
    try std.testing.expect(!isHelpArg("-v"));
    try std.testing.expect(!isHelpArg("start"));
    try std.testing.expect(!isHelpArg(""));
}

test "isVersionArg: accepts version spellings, rejects others" {
    try std.testing.expect(isVersionArg("-v"));
    try std.testing.expect(isVersionArg("--version"));
    try std.testing.expect(!isVersionArg("version")); // bare word is not a version alias
    try std.testing.expect(!isVersionArg("-V"));
    try std.testing.expect(!isVersionArg("-h"));
    try std.testing.expect(!isVersionArg(""));
}

// ── Fuzz tests ──────────────────────────────────────────────────────

test "fuzz: isHelpArg and isVersionArg never panic on random input" {
    var prng = std.Random.DefaultPrng.init(0x4E1D_0042);
    const rnd = prng.random();
    var buf: [32]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = isHelpArg(buf[0..len]);
        _ = isVersionArg(buf[0..len]);
    }
}

test "fuzz: errorEnvelopeMsg never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xB0A7_F00D);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        if (errorEnvelopeMsg(buf[0..len])) |msg| {
            try std.testing.expect(msg.len <= len);
        }
    }
}

test "fuzz: commandArity never panics on random input" {
    var prng = std.Random.DefaultPrng.init(0xA11CE_BEEF);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        rnd.bytes(buf[0..len]);
        _ = commandArity(buf[0..len]);
    }
}

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
