// SPDX-License-Identifier: MIT
//! Virtual network label formatter extracted from dialogs.zig vnetDialog.
//!
//! Formats a human-readable label for a VirtualNetwork switch (bridged, host-only, NAT).
//! Pure function: no FLTK, no I/O, no global state.

const std = @import("std");
const vnet = @import("vnet.zig");

/// Format a display label for a virtual network switch.
/// Returns the formatted string (in `buf`) or "?" on overflow.
pub fn formatVnetLabel(net: *const vnet.VirtualNetwork, buf: []u8) ![]const u8 {
    return switch (net.vtype) {
        .bridged => blk: {
            const iface = net.getHostIfaceSlice();
            if (iface.len > 0) {
                break :blk std.fmt.bufPrint(buf, "{s} — Bridged ({s})", .{ net.getNameSlice(), iface });
            }
            break :blk std.fmt.bufPrint(buf, "{s} — Bridged (auto)", .{net.getNameSlice()});
        },
        .host_only => std.fmt.bufPrint(buf, "{s} — Host-only ({s}/{s}{s})", .{
            net.getNameSlice(),
            net.getSubnetSlice(),
            net.getMaskSlice(),
            if (net.dhcp) ", DHCP" else "",
        }),
        .nat => std.fmt.bufPrint(buf, "{s} — NAT ({s}/{s}{s})", .{
            net.getNameSlice(),
            net.getSubnetSlice(),
            net.getMaskSlice(),
            if (net.dhcp) ", DHCP" else "",
        }),
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "formatVnetLabel: bridged with interface" {
    var net: vnet.VirtualNetwork = .{};
    net.setName("VMnet0");
    net.vtype = .bridged;
    net.setHostIface("eth0");
    var buf: [256]u8 = undefined;
    const label = try formatVnetLabel(&net, &buf);
    try std.testing.expect(std.mem.indexOf(u8, label, "VMnet0 — Bridged (eth0)") != null);
}

test "formatVnetLabel: bridged auto" {
    var net: vnet.VirtualNetwork = .{};
    net.setName("VMnet1");
    net.vtype = .bridged;
    var buf: [256]u8 = undefined;
    const label = try formatVnetLabel(&net, &buf);
    try std.testing.expect(std.mem.indexOf(u8, label, "Bridged (auto)") != null);
}

test "formatVnetLabel: host-only with DHCP" {
    var net: vnet.VirtualNetwork = .{};
    net.setName("VMnet2");
    net.vtype = .host_only;
    net.setSubnet("192.168.100.0");
    net.setMask("255.255.255.0");
    net.dhcp = true;
    var buf: [256]u8 = undefined;
    const label = try formatVnetLabel(&net, &buf);
    try std.testing.expect(std.mem.indexOf(u8, label, "Host-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "DHCP") != null);
}

test "formatVnetLabel: host-only without DHCP" {
    var net: vnet.VirtualNetwork = .{};
    net.setName("VMnet3");
    net.vtype = .host_only;
    net.setSubnet("10.0.0.0");
    net.setMask("255.0.0.0");
    net.dhcp = false;
    var buf: [256]u8 = undefined;
    const label = try formatVnetLabel(&net, &buf);
    try std.testing.expect(std.mem.indexOf(u8, label, "Host-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "DHCP") == null);
}

test "formatVnetLabel: nat" {
    var net: vnet.VirtualNetwork = .{};
    net.setName("VMnet8");
    net.vtype = .nat;
    net.setSubnet("10.0.2.0");
    net.setMask("255.255.255.0");
    net.dhcp = true;
    var buf: [256]u8 = undefined;
    const label = try formatVnetLabel(&net, &buf);
    try std.testing.expect(std.mem.indexOf(u8, label, "NAT") != null);
}

test "fuzz: formatVnetLabel never panics on random network configs" {
    var prng = std.Random.DefaultPrng.init(0x7E771A23);
    const rnd = prng.random();
    for (0..4000) |_| {
        var net: vnet.VirtualNetwork = .{};
        net.vtype = @enumFromInt(rnd.uintLessThan(u8, 3));
        var name_buf: [20]u8 = undefined;
        const name_len = rnd.uintLessThan(usize, 16);
        for (name_buf[0..name_len]) |*b| b.* = rnd.int(u8);
        net.setName(name_buf[0..name_len]);
        var subnet_buf: [20]u8 = undefined;
        const sn_len = rnd.uintLessThan(usize, 16);
        for (subnet_buf[0..sn_len]) |*b| b.* = rnd.int(u8);
        net.setSubnet(subnet_buf[0..sn_len]);
        net.setMask("255.255.255.0");
        net.dhcp = rnd.boolean();
        if (net.vtype == .bridged) {
            var iface_buf: [36]u8 = undefined;
            const ilen = rnd.uintLessThan(usize, 36);
            for (iface_buf[0..ilen]) |*b| b.* = rnd.int(u8);
            net.setHostIface(iface_buf[0..ilen]);
        }
        var out_buf: [256]u8 = undefined;
        _ = formatVnetLabel(&net, &out_buf) catch continue;
    }
}
