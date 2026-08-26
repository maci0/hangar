// SPDX-License-Identifier: MIT
//! Unit tests for VM array delete/undo logic and status-bar text formatting.
//!
//! Tests the core delete/undo algorithms shared by web_server.zig.
//! All VM manipulation logic is exercised
//! against local arrays so the tests are pure logic checks.

const std = @import("std");
const testing = std.testing;
const vm = @import("vm.zig");

const MAX_VMS = vm.MAX_VMS;

// ── Helper: replicate core delete logic ──────────────────────────────

/// Delete the VM at `idx` from the given arrays. Returns the new selected_idx.
fn simulateDelete(
    vms: []vm.VmConfig,
    vm_count: *usize,
    handles: []?usize,
    started: []i64,
    idx: usize,
) ?usize {
    // Shift VMs left from idx+1..vm_count
    var i: usize = idx;
    while (i + 1 < vm_count.*) : (i += 1) {
        vms[i] = vms[i + 1];
        handles[i] = handles[i + 1];
        started[i] = started[i + 1];
    }
    handles[vm_count.* - 1] = null;
    started[vm_count.* - 1] = 0;
    vm_count.* -= 1;
    // Adjust selected index
    return if (vm_count.* > 0) @min(idx, vm_count.* - 1) else null;
}

// ── Helper: replicate core undo logic ────────────────────────────────

/// Restore a VM at its original index (undo a previous delete).
fn simulateUndo(
    vms: []vm.VmConfig,
    vm_count: *usize,
    handles: []?usize,
    started: []i64,
    saved_vm: vm.VmConfig,
    undo_idx: usize,
) usize {
    // Shift VMs down from undo_idx to make room
    var i: usize = vm_count.*;
    while (i > undo_idx) {
        vms[i] = vms[i - 1];
        handles[i] = handles[i - 1];
        started[i] = started[i - 1];
        i -= 1;
    }
    vms[undo_idx] = saved_vm;
    handles[undo_idx] = null;
    started[undo_idx] = 0;
    vm_count.* += 1;
    return undo_idx;
}

// ── Helper: status-bar text formatting ───────────────────────────────

/// Format the status bar text for the "no VM selected" case.
fn formatStatusBarEmpty(out: []u8, count: usize) []const u8 {
    return std.fmt.bufPrintZ(out, "{d} virtual machine(s)", .{count}) catch "(fmt error)";
}

/// Format the status bar text for a selected (but not running) VM.
fn formatStatusBarVm(out: []u8, name: []const u8, status_label: []const u8, count: usize) []const u8 {
    return std.fmt.bufPrintZ(out, "{s}, {s}    |    {d} virtual machine(s)", .{ name, status_label, count }) catch "(fmt error)";
}

/// Format the status bar text for a running VM with uptime.
fn formatStatusBarRunning(out: []u8, name: []const u8, status_label: []const u8, hrs: u64, mins: u64, secs: u64, count: usize) []const u8 {
    return std.fmt.bufPrintZ(out, "{s}, {s} | Uptime: {d}:{d:0>2}:{d:0>2} | {d} VM(s)", .{ name, status_label, hrs, mins, secs, count }) catch "(fmt error)";
}

// ── Tests ────────────────────────────────────────────────────────────

test "delete: single VM, selected_idx becomes null, count zero" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 1;
    _ = vms[0].setName("test-vm");
    handles[0] = 42;
    started[0] = 12345;

    const new_idx = simulateDelete(&vms, &vm_count, &handles, &started, 0);
    try testing.expectEqual(@as(usize, 0), vm_count);
    try testing.expectEqual(@as(?usize, null), new_idx);
    try testing.expectEqual(@as(?usize, null), handles[0]);
    try testing.expectEqual(@as(i64, 0), started[0]);
}

test "delete: middle VM, selected stays at same index, count decremented" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 5;

    // Set up names so we can verify which VM is at which position.
    _ = vms[0].setName("vm-A");
    _ = vms[1].setName("vm-B");
    _ = vms[2].setName("vm-C");
    _ = vms[3].setName("vm-D");
    _ = vms[4].setName("vm-E");
    handles[0] = 10;
    handles[1] = 20;
    handles[2] = 30;
    handles[3] = 40;
    handles[4] = 50;
    started[0] = 100;
    started[1] = 200;
    started[2] = 300;
    started[3] = 400;
    started[4] = 500;

    // Delete index 2 (vm-C). vm-D should shift to index 2, vm-E to index 3.
    const new_idx = simulateDelete(&vms, &vm_count, &handles, &started, 2);

    try testing.expectEqual(@as(usize, 4), vm_count);
    try testing.expectEqual(@as(usize, 2), new_idx.?);

    // vm-C should be gone; vm-D is now at index 2.
    try testing.expectEqualStrings("vm-A", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-B", vms[1].getNameSlice());
    try testing.expectEqualStrings("vm-D", vms[2].getNameSlice());
    try testing.expectEqualStrings("vm-E", vms[3].getNameSlice());

    // Handles should shift accordingly.
    try testing.expectEqual(@as(?usize, 10), handles[0]);
    try testing.expectEqual(@as(?usize, 20), handles[1]);
    try testing.expectEqual(@as(?usize, 40), handles[2]);
    try testing.expectEqual(@as(?usize, 50), handles[3]);
    try testing.expectEqual(@as(?usize, null), handles[4]);

    // started should shift accordingly, last cleared.
    try testing.expectEqual(@as(i64, 100), started[0]);
    try testing.expectEqual(@as(i64, 200), started[1]);
    try testing.expectEqual(@as(i64, 400), started[2]);
    try testing.expectEqual(@as(i64, 500), started[3]);
    try testing.expectEqual(@as(i64, 0), started[4]);
}

test "delete: last VM, selected_idx shifts to previous, count decremented" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 4;

    _ = vms[0].setName("vm-0");
    _ = vms[1].setName("vm-1");
    _ = vms[2].setName("vm-2");
    _ = vms[3].setName("vm-3");

    // Delete index 3 (last one). selected should become 2.
    const new_idx = simulateDelete(&vms, &vm_count, &handles, &started, 3);

    try testing.expectEqual(@as(usize, 3), vm_count);
    try testing.expectEqual(@as(usize, 2), new_idx.?);
    try testing.expectEqualStrings("vm-0", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-1", vms[1].getNameSlice());
    try testing.expectEqualStrings("vm-2", vms[2].getNameSlice());
}

test "delete: first VM, index 0 stays 0, later VMs shift left" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("vm-Z");
    _ = vms[1].setName("vm-Y");
    _ = vms[2].setName("vm-X");

    const new_idx = simulateDelete(&vms, &vm_count, &handles, &started, 0);

    try testing.expectEqual(@as(usize, 2), vm_count);
    try testing.expectEqual(@as(usize, 0), new_idx.?);
    try testing.expectEqualStrings("vm-Y", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-X", vms[1].getNameSlice());
}

test "delete: last valid index decrements count and reselects new last" {
    // The caller (web_server.zig handleDelete) guards out-of-range via
    // `if (idx >= vm_count) return;`, so simulateDelete only ever sees a
    // valid idx. Exercise the highest valid index (vm_count - 1), the
    // boundary most likely to mis-handle the left-shift / reselect logic.
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("vm-0");
    _ = vms[1].setName("vm-1");
    _ = vms[2].setName("vm-2");

    const sel = simulateDelete(&vms, &vm_count, &handles, &started, 2);
    try testing.expectEqual(@as(usize, 2), vm_count);
    try testing.expectEqual(@as(?usize, 1), sel);
    // Surviving VMs are untouched and in order.
    try testing.expectEqualStrings("vm-0", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-1", vms[1].getNameSlice());

    // Deleting down to empty yields a null selection.
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    const empty_sel = simulateDelete(&vms, &vm_count, &handles, &started, 0);
    try testing.expectEqual(@as(usize, 0), vm_count);
    try testing.expectEqual(@as(?usize, null), empty_sel);
}

test "undo: restore VM at original index, count incremented" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("vm-0");
    _ = vms[1].setName("vm-1");
    _ = vms[2].setName("vm-2");
    started[0] = 111;
    started[1] = 222;
    started[2] = 333;

    // Simulate deleting index 1 (vm-1), saving undo state.
    const saved_vm = vms[1];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    try testing.expectEqual(@as(usize, 2), vm_count);
    try testing.expectEqualStrings("vm-0", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-2", vms[1].getNameSlice());
    // started should have shifted: [111, 333, 0]
    try testing.expectEqual(@as(i64, 111), started[0]);
    try testing.expectEqual(@as(i64, 333), started[1]);
    try testing.expectEqual(@as(i64, 0), started[2]);

    // Now undo: restore at index 1.
    const new_idx = simulateUndo(&vms, &vm_count, &handles, &started, saved_vm, 1);

    try testing.expectEqual(@as(usize, 3), vm_count);
    try testing.expectEqual(@as(usize, 1), new_idx);
    try testing.expectEqualStrings("vm-0", vms[0].getNameSlice());
    try testing.expectEqualStrings("vm-1", vms[1].getNameSlice());
    try testing.expectEqualStrings("vm-2", vms[2].getNameSlice());
    // started restored: [111, 0, 333], restored VM gets 0, others keep their values
    try testing.expectEqual(@as(i64, 111), started[0]);
    try testing.expectEqual(@as(i64, 0), started[1]);
    try testing.expectEqual(@as(i64, 333), started[2]);
}

test "undo: restore at position 0" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("first");
    _ = vms[1].setName("second");
    _ = vms[2].setName("third");

    const saved_vm2 = vms[0];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 0);

    const new_idx = simulateUndo(&vms, &vm_count, &handles, &started, saved_vm2, 0);
    try testing.expectEqual(@as(usize, 3), vm_count);
    try testing.expectEqual(@as(usize, 0), new_idx);
    try testing.expectEqualStrings("first", vms[0].getNameSlice());
    try testing.expectEqualStrings("second", vms[1].getNameSlice());
    try testing.expectEqualStrings("third", vms[2].getNameSlice());
}

test "undo: restore at end (original last)" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("a");
    _ = vms[1].setName("b");
    _ = vms[2].setName("c");

    const saved_vm3 = vms[2];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 2);

    const new_idx = simulateUndo(&vms, &vm_count, &handles, &started, saved_vm3, 2);
    try testing.expectEqual(@as(usize, 3), vm_count);
    try testing.expectEqual(@as(usize, 2), new_idx);
    try testing.expectEqualStrings("a", vms[0].getNameSlice());
    try testing.expectEqualStrings("b", vms[1].getNameSlice());
    try testing.expectEqualStrings("c", vms[2].getNameSlice());
}

test "undo: delete-undo-delete cycle" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 4;

    _ = vms[0].setName("p");
    _ = vms[1].setName("q");
    _ = vms[2].setName("r");
    _ = vms[3].setName("s");

    // Delete index 1 (q)
    var saved_q = vms[1];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    try testing.expectEqual(@as(usize, 3), vm_count);
    try testing.expectEqualStrings("r", vms[1].getNameSlice());

    // Undo
    _ = simulateUndo(&vms, &vm_count, &handles, &started, saved_q, 1);
    try testing.expectEqual(@as(usize, 4), vm_count);

    // Delete again, same index 1
    saved_q = vms[1];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    try testing.expectEqual(@as(usize, 3), vm_count);

    // Undo again
    _ = simulateUndo(&vms, &vm_count, &handles, &started, saved_q, 1);
    try testing.expectEqual(@as(usize, 4), vm_count);
    try testing.expectEqualStrings("p", vms[0].getNameSlice());
    try testing.expectEqualStrings("q", vms[1].getNameSlice());
    try testing.expectEqualStrings("r", vms[2].getNameSlice());
    try testing.expectEqualStrings("s", vms[3].getNameSlice());
}

test "undo: delete last VM then undo restores count to 1" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 1;

    _ = vms[0].setName("lonely");

    const saved = vms[0];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 0);
    try testing.expectEqual(@as(usize, 0), vm_count);

    _ = simulateUndo(&vms, &vm_count, &handles, &started, saved, 0);
    try testing.expectEqual(@as(usize, 1), vm_count);
    try testing.expectEqualStrings("lonely", vms[0].getNameSlice());
}

test "status bar: empty format shows correct count" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("0 virtual machine(s)", formatStatusBarEmpty(&buf, 0));
    try testing.expectEqualStrings("1 virtual machine(s)", formatStatusBarEmpty(&buf, 1));
    try testing.expectEqualStrings("5 virtual machine(s)", formatStatusBarEmpty(&buf, 5));
    try testing.expectEqualStrings("42 virtual machine(s)", formatStatusBarEmpty(&buf, 42));
}

test "status bar: VM format updates count after delete" {
    var buf: [128]u8 = undefined;

    // 5 VMs, show status for selected VM
    const before = formatStatusBarVm(&buf, "myvm", "Stopped", 5);
    try testing.expectEqualStrings("myvm, Stopped    |    5 virtual machine(s)", before);

    // After delete, count is 4
    const after = formatStatusBarVm(&buf, "myvm", "Stopped", 4);
    try testing.expectEqualStrings("myvm, Stopped    |    4 virtual machine(s)", after);
}

test "status bar: after undo, count returns to original" {
    var buf: [128]u8 = undefined;

    // After delete: 4 VMs
    const deleted = formatStatusBarVm(&buf, "vm-x", "Stopped", 4);
    try testing.expectEqualStrings("vm-x, Stopped    |    4 virtual machine(s)", deleted);

    // After undo: back to 5 VMs
    const restored = formatStatusBarVm(&buf, "vm-x", "Stopped", 5);
    try testing.expectEqualStrings("vm-x, Stopped    |    5 virtual machine(s)", restored);
}

test "status bar: running VM format with uptime" {
    var buf: [128]u8 = undefined;

    const result = formatStatusBarRunning(&buf, "webserver", "Running", 2, 15, 33, 3);
    try testing.expectEqualStrings("webserver, Running | Uptime: 2:15:33 | 3 VM(s)", result);
}

test "status bar: running VM format with zero uptime" {
    var buf: [128]u8 = undefined;

    const result = formatStatusBarRunning(&buf, "fresh", "Running", 0, 0, 0, 1);
    try testing.expectEqualStrings("fresh, Running | Uptime: 0:00:00 | 1 VM(s)", result);
}

test "status bar: running VM format with count after delete" {
    var buf: [128]u8 = undefined;

    // Before delete: 3 VMs
    const before = formatStatusBarRunning(&buf, "db", "Running", 1, 30, 45, 3);
    try testing.expectEqualStrings("db, Running | Uptime: 1:30:45 | 3 VM(s)", before);

    // After delete: 2 VMs
    const after = formatStatusBarRunning(&buf, "db", "Running", 1, 30, 45, 2);
    try testing.expectEqualStrings("db, Running | Uptime: 1:30:45 | 2 VM(s)", after);
}

test "status bar: empty count matches vm_count after each operation" {
    // This test ties together the delete/undo logic with the status-bar
    // formatting to verify the end-to-end invariant: after every operation,
    // the status bar text reflects the current vm_count.

    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 4;

    _ = vms[0].setName("a");
    _ = vms[1].setName("b");
    _ = vms[2].setName("c");
    _ = vms[3].setName("d");

    var buf: [128]u8 = undefined;

    // Initial
    try testing.expectEqualStrings("4 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Delete index 1
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    try testing.expectEqualStrings("3 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Delete index 2 (now last)
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 2);
    try testing.expectEqualStrings("2 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Delete index 0
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 0);
    try testing.expectEqualStrings("1 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Delete last
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 0);
    try testing.expectEqualStrings("0 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));
}

test "delete + undo: status bar count invariant holds" {
    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 3;

    _ = vms[0].setName("x");
    _ = vms[1].setName("y");
    _ = vms[2].setName("z");

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("3 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Delete index 1
    const saved = vms[1];
    _ = simulateDelete(&vms, &vm_count, &handles, &started, 1);
    try testing.expectEqualStrings("2 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));

    // Undo
    _ = simulateUndo(&vms, &vm_count, &handles, &started, saved, 1);
    try testing.expectEqualStrings("3 virtual machine(s)", formatStatusBarEmpty(&buf, vm_count));
}

test "fuzz: random delete/undo sequence keeps count consistent" {
    var prng = std.Random.DefaultPrng.init(0x570175);
    const rnd = prng.random();

    var vms = [_]vm.VmConfig{.{}} ** MAX_VMS;
    var handles = [_]?usize{null} ** MAX_VMS;
    var started = [_]i64{0} ** MAX_VMS;
    var vm_count: usize = 10;

    // Initialise with names.
    for (0..vm_count) |i| {
        var name_buf: [8]u8 = undefined;
        _ = std.fmt.bufPrintZ(&name_buf, "vm-{d}", .{i}) catch unreachable;
        _ = vms[i].setName(&name_buf);
    }

    var saved_vm: vm.VmConfig = .{};
    var saved_idx: usize = 0;
    var undo_avail: bool = false;

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        if (vm_count == 0) {
            // Can't delete when empty, just verify
            try testing.expectEqual(@as(usize, 0), vm_count);
            continue;
        }

        const op = rnd.uintLessThan(u8, 2); // 0 = delete, 1 = undo
        if (op == 0) {
            // Delete a random index
            const idx = rnd.uintLessThan(usize, vm_count);
            saved_vm = vms[idx];
            saved_idx = idx;
            _ = simulateDelete(&vms, &vm_count, &handles, &started, idx);
            undo_avail = true;
        } else if (undo_avail and vm_count < MAX_VMS) {
            _ = simulateUndo(&vms, &vm_count, &handles, &started, saved_vm, saved_idx);
            undo_avail = false;
        }
        // else: undo not available or full, skip

        // Invariant: vm_count must be in valid range.
        try testing.expect(vm_count <= MAX_VMS);

        // Verify that vm_count matches the last non-null handle + names.
        var counted: usize = 0;
        for (0..vm_count) |i| {
            // Every VM at a valid index must have a non-empty name.
            try testing.expect(vms[i].getNameSlice().len > 0);
            counted += 1;
        }
        // After vm_count, handles should be null (already cleared by
        // simulateDelete, but double-check with the handles array).
        for (vm_count..MAX_VMS) |i| {
            try testing.expectEqual(@as(?usize, null), handles[i]);
        }
        try testing.expectEqual(vm_count, counted);
    }
}
