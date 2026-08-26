//! Built-in VM quickstart catalog: the template table plus the `/api/catalog`
//! and `/api/capabilities` JSON renderers. Pure (depends only on `vm.zig` +
//! std), the quickstart handler in web_server.zig looks up a template here and
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
    /// Firmware the guest expects: BootFirmware index (0 = BIOS, 1 = UEFI).
    /// Modern Linux/Windows install cleanly on UEFI; Windows 11 requires it.
    firmware: usize,
    description: []const u8,
};

const LINUX = vm.GuestOs.linux.toIndex();
const WINDOWS = vm.GuestOs.windows.toIndex();
const FREEBSD = vm.GuestOs.freebsd.toIndex();
const BIOS = @as(usize, 0);
const UEFI = @as(usize, 1);

pub const entries: [10]CatalogEntry = .{
    .{ .id = "ubuntu2404", .name = "Ubuntu 24.04 LTS", .guest_os = LINUX, .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 40, .firmware = UEFI, .description = "Ubuntu 24.04 Noble Numbat, latest LTS" },
    .{ .id = "debian12", .name = "Debian 12", .guest_os = LINUX, .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .firmware = UEFI, .description = "Debian 12 Bookworm, rock-stable" },
    .{ .id = "fedora40", .name = "Fedora 40", .guest_os = LINUX, .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 30, .firmware = UEFI, .description = "Fedora 40 Workstation" },
    .{ .id = "rocky9", .name = "Rocky Linux 9", .guest_os = LINUX, .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 40, .firmware = UEFI, .description = "Rocky Linux 9, RHEL-compatible server" },
    .{ .id = "archlinux", .name = "Arch Linux", .guest_os = LINUX, .memory_mb = 4096, .cpu_cores = 4, .disk_size_gb = 30, .firmware = UEFI, .description = "Arch Linux, rolling release" },
    .{ .id = "alpine320", .name = "Alpine 3.20", .guest_os = LINUX, .memory_mb = 1024, .cpu_cores = 2, .disk_size_gb = 8, .firmware = BIOS, .description = "Alpine Linux 3.20, minimal, container-friendly" },
    .{ .id = "win11", .name = "Windows 11", .guest_os = WINDOWS, .memory_mb = 8192, .cpu_cores = 4, .disk_size_gb = 80, .firmware = UEFI, .description = "Windows 11, UEFI (enable TPM + Secure Boot in Settings)" },
    .{ .id = "win2022", .name = "Windows Server 2022", .guest_os = WINDOWS, .memory_mb = 8192, .cpu_cores = 4, .disk_size_gb = 80, .firmware = UEFI, .description = "Windows Server 2022, datacenter workloads" },
    .{ .id = "freebsd14", .name = "FreeBSD 14", .guest_os = FREEBSD, .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .firmware = UEFI, .description = "FreeBSD 14, BSD server/router" },
    .{ .id = "openbsd75", .name = "OpenBSD 7.5", .guest_os = FREEBSD, .memory_mb = 2048, .cpu_cores = 2, .disk_size_gb = 20, .firmware = BIOS, .description = "OpenBSD 7.5, security-focused BSD" },
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
            \\{{"id":"{s}","name":"{s}","guest_os":{d},"memory_mb":{d},"cpu_cores":{d},"disk_size_gb":{d},"firmware":{d},"description":"{s}"}}
        , .{ entry.id, entry.name, entry.guest_os, entry.memory_mb, entry.cpu_cores, entry.disk_size_gb, entry.firmware, entry.description }) catch return "[]";
        w += part.len;
    }
    if (w >= buf.len) return "[]";
    buf[w] = ']';
    w += 1;
    return buf[0..w];
}

// ── Tests ───────────────────────────────────────────────────────────

test "catalog: every entry has valid guest_os, firmware, and sane specs" {
    try std.testing.expect(entries.len >= 10);
    for (entries) |e| {
        try std.testing.expect(e.guest_os < vm.GuestOs.count);
        try std.testing.expect(e.firmware <= 1); // BIOS=0, UEFI=1
        try std.testing.expect(e.memory_mb >= 256 and e.cpu_cores >= 1 and e.disk_size_gb >= 1);
        try std.testing.expect(e.id.len > 0 and e.name.len > 0);
    }
    // Windows 11 must be UEFI; Alpine is the minimal BIOS image.
    try std.testing.expectEqual(@as(usize, 1), find("win11").?.firmware);
    try std.testing.expectEqual(vm.GuestOs.windows.toIndex(), find("win11").?.guest_os);
    try std.testing.expectEqual(@as(usize, 0), find("alpine320").?.firmware);
    try std.testing.expectEqual(vm.GuestOs.freebsd.toIndex(), find("freebsd14").?.guest_os);
}

test "catalog: catalogJson includes the firmware field" {
    var buf: [4096]u8 = undefined;
    const s = catalogJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"firmware\":") != null);
}

test "catalog: find returns the matching entry and null otherwise" {
    try std.testing.expectEqualStrings("Ubuntu 24.04 LTS", find("ubuntu2404").?.name);
    try std.testing.expect(find("nope") == null);
}

test "catalog: catalogJson is a well-formed array containing every entry" {
    var buf: [4096]u8 = undefined;
    const s = catalogJson(&buf);
    try std.testing.expect(s[0] == '[' and s[s.len - 1] == ']');
    for (entries) |e| try std.testing.expect(std.mem.indexOf(u8, s, e.id) != null);
}

test "catalog: capabilitiesJson reports the compile-time limits" {
    var buf: [256]u8 = undefined;
    const s = capabilitiesJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"max_nics\":8") != null);
}

test "fuzz: find never panics on random slug bytes" {
    // The quickstart endpoint feeds an untrusted path slug straight into find().
    var prng = std.Random.DefaultPrng.init(0xCA7A106);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = find(buf[0..len]);
    }
}

test "fuzz: catalogJson/capabilitiesJson never overflow an undersized buffer" {
    // Both writers must stay within the caller buffer for every capacity and
    // always return a well-formed (possibly fallback) JSON slice.
    var buf: [4096]u8 = undefined;
    var cap: usize = 0;
    while (cap <= buf.len) : (cap += 1) {
        const c = catalogJson(buf[0..cap]);
        try std.testing.expect(c.len > 0 and c[0] == '[' and c[c.len - 1] == ']');
        const k = capabilitiesJson(buf[0..cap]);
        try std.testing.expect(k.len > 0 and k[0] == '{' and k[k.len - 1] == '}');
    }
}
