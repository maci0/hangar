//! OVF (Open Virtualization Format) descriptor generation.
//!
//! Exports a VM as a standard OVF 1.0 directory: a `<name>.ovf` XML envelope
//! plus a `<name>-disk1.vmdk` (produced by `qemu-img convert`). The XML is built
//! here as pure string formatting so it can be unit-tested + fuzzed without any
//! filesystem or qemu-img. The IO half (file dialog + qemu-img + writeFile)
//! lives in the GUI layer and calls `buildDescriptor`.

const std = @import("std");

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
};

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

/// Build a minimal but valid OVF 1.0 envelope for `spec`. Caller owns the slice.
pub fn buildDescriptor(spec: Spec, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const a = allocator;
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
    try list.print(a, "  <References>\n    <File ovf:href=\"", .{});
    try esc(&list, a, spec.vmdk_href);
    try list.print(a, "\" ovf:id=\"file1\" ovf:size=\"{d}\"/>\n  </References>\n", .{spec.vmdk_size_bytes});

    // DiskSection
    try w(&list, a, "  <DiskSection>\n    <Info>Virtual disks</Info>\n");
    try list.print(a,
        "    <Disk ovf:capacity=\"{d}\" ovf:capacityAllocationUnits=\"byte\" ovf:diskId=\"vmdisk1\"" ++
        " ovf:fileRef=\"file1\" ovf:format=\"http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized\"/>\n" ++
        "  </DiskSection>\n", .{spec.disk_capacity_bytes});

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
    try list.print(a,
        "      <Item><rasd:Description>Number of Virtual CPUs</rasd:Description>" ++
        "<rasd:ElementName>{d} virtual CPU(s)</rasd:ElementName>" ++
        "<rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType>" ++
        "<rasd:VirtualQuantity>{d}</rasd:VirtualQuantity></Item>\n", .{ spec.cpu_cores, spec.cpu_cores });

    // Memory item (MB)
    try list.print(a,
        "      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>" ++
        "<rasd:Description>Memory Size</rasd:Description>" ++
        "<rasd:ElementName>{d} MB of memory</rasd:ElementName>" ++
        "<rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType>" ++
        "<rasd:VirtualQuantity>{d}</rasd:VirtualQuantity></Item>\n", .{ spec.memory_mb, spec.memory_mb });

    // SCSI controller + disk
    try w(&list, a,
        "      <Item><rasd:Address>0</rasd:Address><rasd:ElementName>SCSI Controller</rasd:ElementName>" ++
        "<rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>" ++
        "<rasd:ResourceType>6</rasd:ResourceType></Item>\n" ++
        "      <Item><rasd:ElementName>Hard Disk 1</rasd:ElementName>" ++
        "<rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource><rasd:InstanceID>4</rasd:InstanceID>" ++
        "<rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>\n");

    if (spec.has_network) {
        try w(&list, a,
            "      <Item><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>" ++
            "<rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>Ethernet 1</rasd:ElementName>" ++
            "<rasd:InstanceID>5</rasd:InstanceID><rasd:ResourceSubType>E1000</rasd:ResourceSubType>" ++
            "<rasd:ResourceType>10</rasd:ResourceType></Item>\n");
    }

    try w(&list, a, "    </VirtualHardwareSection>\n  </VirtualSystem>\n</Envelope>\n");
    return list.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "ovf: descriptor contains required envelope elements" {
    const spec = Spec{
        .name = "Test VM",
        .cpu_cores = 4,
        .memory_mb = 4096,
        .disk_capacity_bytes = 64 * 1024 * 1024 * 1024,
        .vmdk_href = "test-disk1.vmdk",
        .vmdk_size_bytes = 1234567,
        .has_network = true,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.startsWith(u8, xml, "<?xml"));
    try t.expect(std.mem.indexOf(u8, xml, "<Envelope") != null);
    try t.expect(std.mem.indexOf(u8, xml, "</Envelope>") != null);
    try t.expect(std.mem.indexOf(u8, xml, "test-disk1.vmdk") != null);
    try t.expect(std.mem.indexOf(u8, xml, "Test VM") != null);
    try t.expect(std.mem.indexOf(u8, xml, "ovf:size=\"1234567\"") != null);
    try t.expect(std.mem.indexOf(u8, xml, "<rasd:VirtualQuantity>4</rasd:VirtualQuantity>") != null); // cpu
    try t.expect(std.mem.indexOf(u8, xml, "<rasd:VirtualQuantity>4096</rasd:VirtualQuantity>") != null); // mem
    try t.expect(std.mem.indexOf(u8, xml, "E1000") != null);
}

test "ovf: no network omits the Ethernet item + NetworkSection" {
    const spec = Spec{
        .name = "NoNet",
        .cpu_cores = 1,
        .memory_mb = 512,
        .disk_capacity_bytes = 1024,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 10,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "NetworkSection") == null);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") == null);
}

test "ovf: name with XML metacharacters is escaped" {
    const spec = Spec{
        .name = "a<b>&\"c'",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "a&lt;b&gt;&amp;&quot;c&apos;") != null);
    try t.expect(std.mem.indexOf(u8, xml, "<b>") == null); // raw metachar must not leak
}

test "fuzz: buildDescriptor never crashes on random specs" {
    var prng = std.Random.DefaultPrng.init(0x0FF_C0DE);
    const rnd = prng.random();
    var namebuf: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, namebuf.len);
        for (namebuf[0..n]) |*c| c.* = rnd.int(u8); // arbitrary bytes incl. <>&"'
        const spec = Spec{
            .name = namebuf[0..n],
            .cpu_cores = rnd.int(u32),
            .memory_mb = rnd.int(u32),
            .disk_capacity_bytes = rnd.int(u64),
            .vmdk_href = "d.vmdk",
            .vmdk_size_bytes = rnd.int(u64),
            .has_network = rnd.boolean(),
        };
        const xml = buildDescriptor(spec, t.allocator) catch continue;
        defer t.allocator.free(xml);
        try t.expect(std.mem.endsWith(u8, xml, "</Envelope>\n"));
    }
}

test "ovf: zero disk capacity" {
    const spec = Spec{
        .name = "Zero",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 0,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 0,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "capacity=\"0\"") != null);
}

test "ovf: max u64 disk capacity" {
    const spec = Spec{
        .name = "Huge",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 18446744073709551615, // max u64
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "capacity=\"18446744073709551615\"") != null);
}

test "ovf: name with only safe characters" {
    const spec = Spec{
        .name = "SimpleVM_2024-v2",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "SimpleVM_2024-v2") != null);
}

test "ovf: network section omitted when has_network is false" {
    const spec = Spec{
        .name = "NoNet",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = false,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "NetworkSection") == null);
}

test "ovf: network section present when has_network is true" {
    const spec = Spec{
        .name = "WithNet",
        .cpu_cores = 1,
        .memory_mb = 1,
        .disk_capacity_bytes = 1,
        .vmdk_href = "d.vmdk",
        .vmdk_size_bytes = 1,
        .has_network = true,
    };
    const xml = try buildDescriptor(spec, t.allocator);
    defer t.allocator.free(xml);
    try t.expect(std.mem.indexOf(u8, xml, "E1000") != null);
}

test "fuzz: esc function handles all byte values" {
    var prng = std.Random.DefaultPrng.init(0x0FF_5EED);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        const n = rnd.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*c| c.* = rnd.int(u8);
        var list: std.ArrayList(u8) = .empty;
        // esc must never crash on arbitrary bytes.
        esc(&list, t.allocator, buf[0..n]) catch {
            list.deinit(t.allocator);
            continue;
        };
        list.deinit(t.allocator);
    }
}
