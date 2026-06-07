//! Built-in VM quickstart catalog: the template table plus the `/api/catalog`
//! and `/api/capabilities` JSON renderers. Pure (depends only on `vm.zig` +
//! std) — the quickstart handler in web_server.zig looks up a template here and
//! does the (stateful) VM creation itself.

const std = @import("std");
const vm = @import("vm.zig");

pub const CatalogEntry = struct {
    id: []const u8,
    name: []const u8,
    guest_os: usize,
    memory_mb: u32,
    cpu_cores: u32,
    disk_size_gb: u32,
    description: []const u8,
};

pub const entries: [3]CatalogEntry = .{
    .{ .id = "ubuntu2404", .name = "Ubuntu 24.04 LTS", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 40, .description = "Ubuntu 24.04 Noble Numbat — latest LTS" },
    .{ .id = "fedora40", .name = "Fedora 40", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .description = "Fedora 40 Workstation" },
    .{ .id = "debian12", .name = "Debian 12", .guest_os = vm.GuestOs.linux.toIndex(), .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .description = "Debian 12 Bookworm — stable" },
};

/// The catalog entry whose id equals `slug`, or null.
pub fn find(slug: []const u8) ?CatalogEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, slug)) return entry;
    }
    return null;
}

/// Backend capabilities (max NICs / disks / displays / VMs) as JSON. The
/// frontend reads this to render form fields dynamically instead of hardcoding.
pub fn capabilitiesJson(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"max_vms":{d},"max_nics":{d},"max_extra_disks":{d},"max_displays":{d},"version":"1.0"}}
    , .{ vm.MAX_VMS, vm.MAX_NICS, vm.MAX_EXTRA_DISKS, vm.MAX_DISPLAYS }) catch "{}";
}

/// The catalog as a JSON array into `buf`. Returns "[]" on overflow.
pub fn catalogJson(buf: []u8) []const u8 {
    if (buf.len == 0) return "[]";
    var w: usize = 0;
    buf[w] = '[';
    w += 1;
    for (entries, 0..) |entry, i| {
        if (i > 0) {
            if (w >= buf.len) return "[]";
            buf[w] = ',';
            w += 1;
        }
        const part = std.fmt.bufPrint(buf[w..],
            \\{{"id":"{s}","name":"{s}","guest_os":{d},"memory_mb":{d},"cpu_cores":{d},"disk_size_gb":{d},"description":"{s}"}}
        , .{ entry.id, entry.name, entry.guest_os, entry.memory_mb, entry.cpu_cores, entry.disk_size_gb, entry.description }) catch return "[]";
        w += part.len;
    }
    if (w >= buf.len) return "[]";
    buf[w] = ']';
    w += 1;
    return buf[0..w];
}

// ── Tests ───────────────────────────────────────────────────────────

test "catalog: find returns the matching entry and null otherwise" {
    try std.testing.expectEqualStrings("Ubuntu 24.04 LTS", find("ubuntu2404").?.name);
    try std.testing.expect(find("nope") == null);
}

test "catalog: catalogJson is a well-formed array containing every entry" {
    var buf: [2048]u8 = undefined;
    const s = catalogJson(&buf);
    try std.testing.expect(s[0] == '[' and s[s.len - 1] == ']');
    for (entries) |e| try std.testing.expect(std.mem.indexOf(u8, s, e.id) != null);
}

test "catalog: capabilitiesJson reports the compile-time limits" {
    var buf: [256]u8 = undefined;
    const s = capabilitiesJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"max_nics\":8") != null);
}
