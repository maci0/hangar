// SPDX-License-Identifier: MIT
//! OVF (Open Virtualization Format) descriptor generation.
//!
//! Exports a VM as a standard OVF 1.0 directory: a `<name>.ovf` XML envelope
//! plus a `<name>-disk1.vmdk` (produced by `qemu-img convert`). The XML is built
//! here as pure string formatting so it can be unit-tested + fuzzed without any
//! filesystem or qemu-img. The IO half (qemu-img convert + streaming write)
//! lives in `streams.zig` (`exportOva`) and calls `buildDescriptor`.

const std = @import("std");

/// Maximum output size of a descriptor (~2 KB; 4 KB is plenty).
pub const max_descriptor_len = 4096;

pub const Spec = struct {
    name: []const u8,
    cpu_cores: u32,
    memory_mb: u32,
    /// Virtual disk capacity in bytes.
    disk_capacity_bytes: u64,
    /// The VMDK file name referenced from the envelope (e.g. "vm-disk1.vmdk").
    vmdk_href: []const u8,
    /// On-disk size of the VMDK in bytes (for the <File ovf:size>).
    vmdk_size_bytes: u64,
    /// true → an e1000 NIC item is emitted.
    has_network: bool,
    /// Optional second disk (omitted when href is empty).
    disk2_capacity_bytes: u64 = 0,
    disk2_href: []const u8 = "",
    disk2_size_bytes: u64 = 0,
};

/// Build a minimal but valid OVF 1.0 envelope for `spec` into `buf`.
/// Returns the written slice. `buf` must be at least `max_descriptor_len`.
pub fn buildDescriptor(spec: Spec, buf: []u8) ![]u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const a = fba.allocator();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);

    const w = struct {
        fn s(l: *std.ArrayList(u8), al: std.mem.Allocator, txt: []const u8) !void {
            try l.appendSlice(al, txt);
        }
    }.s;

    try w(&list, a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w(&list, a, "<Envelope xmlns=\"http://schemas.dmtf.org/ovf/envelope/1\"" ++
        " xmlns:ovf=\"http://schemas.dmtf.org/ovf/envelope/1\"" ++
        " xmlns:rasd=\"http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData\"" ++
        " xmlns:vssd=\"http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData\">\n");

    // References
    try w(&list, a, "  <References>\n");
    try list.print(a, "    <File ovf:href=\"", .{});
    try esc(&list, a, spec.vmdk_href);
    try list.print(a, "\" ovf:id=\"file1\" ovf:size=\"{d}\"/>", .{spec.vmdk_size_bytes});
    if (spec.disk2_href.len > 0) {
        try w(&list, a, "\n    <File ovf:href=\"");
        try esc(&list, a, spec.disk2_href);
        try list.print(a, "\" ovf:id=\"file2\" ovf:size=\"{d}\"/>", .{spec.disk2_size_bytes});
    }
    try w(&list, a, "\n  </References>\n");

    // DiskSection
    try w(&list, a, "  <DiskSection>\n    <Info>Virtual disks</Info>\n");
    try list.print(a, "    <Disk ovf:capacity=\"{d}\" ovf:capacityAllocationUnits=\"byte\" ovf:diskId=\"vmdisk1\"" ++
        " ovf:fileRef=\"file1\" ovf:format=\"http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized\"/>", .{spec.disk_capacity_bytes});
    if (spec.disk2_href.len > 0) {
        try list.print(a, "\n    <Disk ovf:capacity=\"{d}\" ovf:capacityAllocationUnits=\"byte\" ovf:diskId=\"vmdisk2\"" ++
            " ovf:fileRef=\"file2\" ovf:format=\"http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized\"/>", .{spec.disk2_capacity_bytes});
    }
    try w(&list, a, "\n  </DiskSection>\n");

    // NetworkSection
    if (spec.has_network) {
        try w(&list, a, "  <NetworkSection>\n    <Info>Networks</Info>\n" ++
            "    <Network ovf:name=\"VM Network\"><Description>NAT</Description></Network>\n" ++
            "  </NetworkSection>\n");
    }

    // VirtualSystem
    try w(&list, a, "  <VirtualSystem ovf:id=\"");
    try esc(&list, a, spec.name);
    try w(&list, a, "\">\n    <Info>A virtual machine</Info>\n    <Name>");
    try esc(&list, a, spec.name);
    try w(&list, a, "</Name>\n    <VirtualHardwareSection>\n      <Info>Virtual hardware</Info>\n");

    // CPU item
    try list.print(a, "      <Item><rasd:Description>Number of Virtual CPUs</rasd:Description>" ++
        "<rasd:ElementName>{d} virtual CPU(s)</rasd:ElementName>" ++
        "<rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType>" ++
        "<rasd:VirtualQuantity>{d}</rasd:VirtualQuantity></Item>\n", .{ spec.cpu_cores, spec.cpu_cores });

    // Memory item (MB)
    try list.print(a, "      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>" ++
        "<rasd:Description>Memory Size</rasd:Description>" ++
        "<rasd:ElementName>{d} MB of memory</rasd:ElementName>" ++
        "<rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType>" ++
        "<rasd:VirtualQuantity>{d}</rasd:VirtualQuantity></Item>\n", .{ spec.memory_mb, spec.memory_mb });

    // SCSI controller + disk(s)
    try w(&list, a, "      <Item><rasd:Address>0</rasd:Address><rasd:ElementName>SCSI Controller</rasd:ElementName>" ++
        "<rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>" ++
        "<rasd:ResourceType>6</rasd:ResourceType></Item>\n" ++
        "      <Item><rasd:ElementName>Hard Disk 1</rasd:ElementName>" ++
        "<rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID>" ++
        "<rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>\n");
    if (spec.disk2_href.len > 0) {
        try w(&list, a, "      <Item><rasd:ElementName>Hard Disk 2</rasd:ElementName>" ++
            "<rasd:HostResource>ovf:/disk/vmdisk2</rasd:HostResource><rasd:InstanceID>5</rasd:InstanceID>" ++
            "<rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>\n");
    }

    if (spec.has_network) {
        const net_id: u8 = if (spec.disk2_href.len > 0) 6 else 5;
        try list.print(a, "      <Item><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>" ++
            "<rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>Ethernet 1</rasd:ElementName>" ++
            "<rasd:InstanceID>{d}</rasd:InstanceID><rasd:ResourceSubType>E1000</rasd:ResourceSubType>" ++
            "<rasd:ResourceType>10</rasd:ResourceType></Item>\n", .{net_id});
    }

    try w(&list, a, "    </VirtualHardwareSection>\n  </VirtualSystem>\n</Envelope>\n");
    return list.toOwnedSlice(a);
}

/// XML-escape `s` into `list` (&,<,>," and ').
fn esc(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try list.appendSlice(alloc, "&amp;"),
        '<' => try list.appendSlice(alloc, "&lt;"),
        '>' => try list.appendSlice(alloc, "&gt;"),
        '"' => try list.appendSlice(alloc, "&quot;"),
        '\'' => try list.appendSlice(alloc, "&apos;"),
        else => try list.append(alloc, c),
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "ovf: descriptor contains required envelope elements" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "Test VM",
        .cpu_cores = 4,
        .memory_mb = 4096,
        .disk_capacity_bytes = 64 * 1024 * 1024 * 1024,
        .vmdk_href = "test-disk1.vmdk",
        .vmdk_size_bytes = 1234567,
        .has_network = true,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.startsWith(u8, xml, "<?xml"));
    try t.expect(std.mem.indexOf(u8, xml, "<Envelope") != null);
    try t.expect(std.mem.indexOf(u8, xml, "</Envelope>") != null);
    try t.expect(std.mem.indexOf(u8, xml, "test-disk1.vmdk") != null);
    try t.expect(std.mem.indexOf(u8, xml, "Test VM") != null);
    try t.expect(std.mem.indexOf(u8, xml, "ovf:size=\"1234567\"") != null);
    try t.expect(std.mem.indexOf(u8, xml, "<rasd:VirtualQuantity>4</rasd:VirtualQuantity>") != null);
    try t.expect(std.mem.indexOf(u8, xml, "<rasd:VirtualQuantity>4096</rasd:VirtualQuantity>") != null);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") != null);
}

test "ovf: no network omits the Ethernet item + NetworkSection" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "NoNet",
        .cpu_cores = 1,
        .memory_mb = 512,
        .disk_capacity_bytes = 1024,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 10,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "NetworkSection") == null);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") == null);
}

test "ovf: name with XML metacharacters is escaped" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "a<b>&\"c'",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "a&lt;b&gt;&amp;&quot;c&apos;") != null);
    try t.expect(std.mem.indexOf(u8, xml, "<b>") == null);
}

test "fuzz: buildDescriptor never crashes on random specs" {
    var buf: [max_descriptor_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x0FF_C0DE);
    const rnd = prng.random();
    var namebuf: [64]u8 = undefined;
    var hrefbuf: [32]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, namebuf.len);
        for (namebuf[0..n]) |*c| c.* = rnd.int(u8);
        const hlen = rnd.uintLessThan(usize, hrefbuf.len);
        for (hrefbuf[0..hlen]) |*c| c.* = rnd.int(u8);
        const spec = Spec{
            .name = namebuf[0..n],
            .cpu_cores = rnd.int(u32),
            .memory_mb = rnd.int(u32),
            .disk_capacity_bytes = rnd.int(u64),
            .vmdk_href = "d.vmdk",
            .vmdk_size_bytes = rnd.int(u64),
            .has_network = rnd.boolean(),
            .disk2_href = hrefbuf[0..hlen],
            .disk2_capacity_bytes = rnd.int(u64),
            .disk2_size_bytes = rnd.int(u64),
        };
        const xml = buildDescriptor(spec, &buf) catch continue;
        try t.expect(std.mem.endsWith(u8, xml, "</Envelope>\n"));
    }
}

test "ovf: zero disk capacity" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "Zero",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 0,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 0,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "capacity=\"0\"") != null);
}

test "ovf: max u64 disk capacity" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "Huge",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 18446744073709551615,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "capacity=\"18446744073709551615\"") != null);
}

test "ovf: name with only safe characters" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "SimpleVM_2024-v2",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "SimpleVM_2024-v2") != null);
}

test "ovf: network section omitted when has_network is false" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "NoNet",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "NetworkSection") == null);
}

test "ovf: network section present when has_network is true" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "WithNet",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = true,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") != null);
}

test "ovf: dual disk descriptor includes file2 + vmdisk2 + Hard Disk 2" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "DualDisk",
        .cpu_cores = 2,
        .memory_mb = 2048,
        .disk_capacity_bytes = 10 * 1024 * 1024 * 1024,
        .vmdk_href = "disk1.vmdk",
        .vmdk_size_bytes = 5000000,
        .has_network = true,
        .disk2_href = "disk2.vmdk",
        .disk2_capacity_bytes = 5 * 1024 * 1024 * 1024,
        .disk2_size_bytes = 3000000,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "file2") != null);
    try t.expect(std.mem.indexOf(u8, xml, "disk2.vmdk") != null);
    try t.expect(std.mem.indexOf(u8, xml, "vmdisk2") != null);
    try t.expect(std.mem.indexOf(u8, xml, "Hard Disk 2") != null);
    try t.expect(std.mem.indexOf(u8, xml, "ovf:size=\"3000000\"") != null);
    try t.expect(std.mem.indexOf(u8, xml, "capacity=\"5368709120\"") != null);
    // Ethernet InstanceID should be 6 when disk2 is present.
    try t.expect(std.mem.indexOf(u8, xml, "<rasd:InstanceID>6</rasd:InstanceID>") != null);
}

test "ovf: dual disk without network, InstanceID 5 is disk2, no Ethernet" {
    var buf: [max_descriptor_len]u8 = undefined;
    const spec = Spec{
        .name = "DualNoNet",
        .cpu_cores = 1,
        .memory_mb = 1024,
        .disk_capacity_bytes = 1024,
        .vmdk_href = "d1.vmdk",
        .vmdk_size_bytes = 100,
        .has_network = false,
        .disk2_href = "d2.vmdk",
        .disk2_capacity_bytes = 512,
        .disk2_size_bytes = 50,
    };
    const xml = try buildDescriptor(spec, &buf);
    try t.expect(std.mem.indexOf(u8, xml, "vmdisk2") != null);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") == null);
    try t.expect(std.mem.indexOf(u8, xml, "NetworkSection") == null);
}

test "fuzz: esc function handles all byte values" {
    var buf: [max_descriptor_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x0FF_5EED);
    const rnd = prng.random();
    var raw: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, raw.len);
        for (raw[0..n]) |*c| c.* = rnd.int(u8);
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = fba.allocator();
        var list: std.ArrayList(u8) = .empty;
        esc(&list, a, raw[0..n]) catch {
            list.deinit(a);
            continue;
        };
        // XML-injection contract: escaped output must never carry a raw markup
        // metacharacter, and every '&' must open one of the five entities esc
        // emits. A regression that stops escaping any of these would surface here.
        const out = list.items;
        for (out, 0..) |c, idx| {
            try std.testing.expect(c != '<' and c != '>' and c != '"' and c != '\'');
            if (c == '&') {
                const rest = out[idx..];
                const ok = std.mem.startsWith(u8, rest, "&amp;") or
                    std.mem.startsWith(u8, rest, "&lt;") or
                    std.mem.startsWith(u8, rest, "&gt;") or
                    std.mem.startsWith(u8, rest, "&quot;") or
                    std.mem.startsWith(u8, rest, "&apos;");
                try std.testing.expect(ok);
            }
        }
        list.deinit(a);
    }
}
