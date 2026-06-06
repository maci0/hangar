// SPDX-License-Identifier: MIT
//! Virtual network model + persistence — the data behind the Virtual Network
//! Editor (VMware Workstation-style "VMnet" switches).
//!
//! Each `VirtualNetwork` is a named host switch (VMnet0, VMnet1, ...) with a
//! type (bridged / NAT / host-only), an IPv4 subnet + mask, an optional DHCP
//! range, and — for bridged switches — the host interface it bridges to.
//!
//! Stored separately from VM configs in `~/.config/hangar/networks.json`, so
//! the editor owns its own tiny hand-rolled JSON reader/writer here (std.json
//! is banned project-wide due to f128 linker errors with the system `cc` link
//! step). The format mirrors `persist.zig`: a flat array of flat objects.

const std = @import("std");
const appio = @import("appio.zig");
const appstate = @import("appstate.zig");

/// Hard cap on virtual switches. VMware Workstation exposes VMnet0..VMnet19.
pub const MAX_VNETS: usize = 20;

const NAME_CAP = 16;
const IP_CAP = 16; // "255.255.255.255" + NUL fits
const IFACE_CAP = 32;
const PORTFWD_CAP = 256; // NAT port-forward rule list

// ── Virtual network type ─────────────────────────────────────────────

/// How a virtual switch connects guests to the outside world. Mirrors the
/// three modes the VMware Virtual Network Editor offers.
pub const VNetType = enum(u8) {
    bridged = 0,
    nat = 1,
    host_only = 2,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: VNetType) usize {
        return @intFromEnum(self);
    }

    /// Maps a combobox index to a `VNetType`. Out-of-range defaults to `.nat`.
    pub fn fromIndex(i: usize) VNetType {
        if (i >= count) return .nat;
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    /// Stable persistence/CLI token.
    pub fn toStr(self: VNetType) [*:0]const u8 {
        return switch (self) {
            .bridged => "bridged",
            .nat => "nat",
            .host_only => "host_only",
        };
    }

    /// Inverse of `toStr`. Unknown strings default to `.nat`.
    pub fn fromStr(s: []const u8) VNetType {
        if (std.ascii.eqlIgnoreCase(s, "bridged")) return .bridged;
        if (std.ascii.eqlIgnoreCase(s, "host_only")) return .host_only;
        return .nat;
    }

    /// Human-facing label for the editor UI.
    pub fn label(self: VNetType) [*:0]const u8 {
        return switch (self) {
            .bridged => "Bridged",
            .nat => "NAT",
            .host_only => "Host-only",
        };
    }
};

// ── A single virtual switch ──────────────────────────────────────────

/// One named virtual switch. Strings use fixed inline buffers (no heap) to
/// match the rest of the codebase's VM-config style.
pub const VirtualNetwork = struct {
    name_buf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    name_len: u16 = 0,
    vtype: VNetType = .nat,
    subnet_buf: [IP_CAP]u8 = [_]u8{0} ** IP_CAP,
    subnet_len: u16 = 0,
    mask_buf: [IP_CAP]u8 = [_]u8{0} ** IP_CAP,
    mask_len: u16 = 0,
    dhcp: bool = false,
    dhcp_start_buf: [IP_CAP]u8 = [_]u8{0} ** IP_CAP,
    dhcp_start_len: u16 = 0,
    dhcp_end_buf: [IP_CAP]u8 = [_]u8{0} ** IP_CAP,
    dhcp_end_len: u16 = 0,
    host_iface_buf: [IFACE_CAP]u8 = [_]u8{0} ** IFACE_CAP,
    host_iface_len: u16 = 0,
    /// NAT gateway IP (NAT switches only; configured via NAT Settings dialog).
    gateway_buf: [IP_CAP]u8 = [_]u8{0} ** IP_CAP,
    gateway_len: u16 = 0,
    /// NAT port-forwarding rules, "hostport:guestip:guestport,..." (NAT only).
    port_fwd_buf: [PORTFWD_CAP]u8 = [_]u8{0} ** PORTFWD_CAP,
    port_fwd_len: u16 = 0,

    fn setBuf(buf: []u8, len: *u16, s: []const u8) void {
        const n: usize = @min(s.len, buf.len - 1);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        len.* = @intCast(n);
    }

    pub fn getName(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.name_buf);
    }
    pub fn getNameSlice(self: *const VirtualNetwork) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn setName(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.name_buf, &self.name_len, s);
    }

    pub fn getSubnet(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.subnet_buf);
    }
    pub fn getSubnetSlice(self: *const VirtualNetwork) []const u8 {
        return self.subnet_buf[0..self.subnet_len];
    }
    pub fn setSubnet(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.subnet_buf, &self.subnet_len, s);
    }

    pub fn getMask(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.mask_buf);
    }
    pub fn getMaskSlice(self: *const VirtualNetwork) []const u8 {
        return self.mask_buf[0..self.mask_len];
    }
    pub fn setMask(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.mask_buf, &self.mask_len, s);
    }

    pub fn getDhcpStart(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.dhcp_start_buf);
    }
    pub fn getDhcpStartSlice(self: *const VirtualNetwork) []const u8 {
        return self.dhcp_start_buf[0..self.dhcp_start_len];
    }
    pub fn setDhcpStart(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.dhcp_start_buf, &self.dhcp_start_len, s);
    }

    pub fn getDhcpEnd(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.dhcp_end_buf);
    }
    pub fn getDhcpEndSlice(self: *const VirtualNetwork) []const u8 {
        return self.dhcp_end_buf[0..self.dhcp_end_len];
    }
    pub fn setDhcpEnd(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.dhcp_end_buf, &self.dhcp_end_len, s);
    }

    pub fn getHostIface(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.host_iface_buf);
    }
    pub fn getHostIfaceSlice(self: *const VirtualNetwork) []const u8 {
        return self.host_iface_buf[0..self.host_iface_len];
    }
    pub fn setHostIface(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.host_iface_buf, &self.host_iface_len, s);
    }

    pub fn getGateway(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.gateway_buf);
    }
    pub fn getGatewaySlice(self: *const VirtualNetwork) []const u8 {
        return self.gateway_buf[0..self.gateway_len];
    }
    pub fn setGateway(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.gateway_buf, &self.gateway_len, s);
    }

    pub fn getPortForwards(self: *const VirtualNetwork) [*:0]const u8 {
        return @ptrCast(&self.port_fwd_buf);
    }
    pub fn getPortForwardsSlice(self: *const VirtualNetwork) []const u8 {
        return self.port_fwd_buf[0..self.port_fwd_len];
    }
    pub fn setPortForwards(self: *VirtualNetwork, s: []const u8) void {
        setBuf(&self.port_fwd_buf, &self.port_fwd_len, s);
    }
};

// ── The full set of switches ─────────────────────────────────────────

/// Fixed-capacity collection of virtual switches, mirroring `App`'s VM array.
pub const NetworkSet = struct {
    nets: [MAX_VNETS]VirtualNetwork = [_]VirtualNetwork{.{}} ** MAX_VNETS,
    count: usize = 0,

    /// Appends a fully-specified switch. No-op when full. Returns success.
    pub fn add(self: *NetworkSet, name: []const u8, vtype: VNetType, subnet: []const u8, mask: []const u8, dhcp: bool, dstart: []const u8, dend: []const u8, iface: []const u8) bool {
        if (self.count >= MAX_VNETS) return false;
        var n = &self.nets[self.count];
        n.* = .{};
        n.setName(name);
        n.vtype = vtype;
        n.setSubnet(subnet);
        n.setMask(mask);
        n.dhcp = dhcp;
        n.setDhcpStart(dstart);
        n.setDhcpEnd(dend);
        n.setHostIface(iface);
        self.count += 1;
        return true;
    }

    /// Removes the switch at `idx`, shifting the tail down. No-op if invalid.
    pub fn remove(self: *NetworkSet, idx: usize) void {
        if (idx >= self.count) return;
        var i = idx;
        while (i + 1 < self.count) : (i += 1) {
            self.nets[i] = self.nets[i + 1];
        }
        self.count -= 1;
    }

    /// The factory defaults VMware ships: a bridged auto switch, a host-only
    /// switch, and a NAT switch with DHCP — so the editor is never empty.
    pub fn defaults() NetworkSet {
        var s = NetworkSet{};
        _ = s.add("VMnet0", .bridged, "", "", false, "", "", "auto");
        _ = s.add("VMnet1", .host_only, "192.168.118.0", "255.255.255.0", true, "192.168.118.128", "192.168.118.254", "");
        _ = s.add("VMnet8", .nat, "192.168.140.0", "255.255.255.0", true, "192.168.140.128", "192.168.140.254", "");
        if (s.count >= 3) {
            s.nets[2].setGateway("192.168.140.2"); // NAT gateway
            s.nets[2].setPortForwards("2222:192.168.140.128:22"); // sample fwd
        }
        return s;
    }
};

// ── Emit ─────────────────────────────────────────────────────────────

const List = std.ArrayList(u8);

fn emit(list: *List, alloc: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(alloc, s);
}

fn writeFileAtomic(file_path: []const u8, data: []const u8) !void {
    // Propagate the real error (NoSpaceLeft, AccessDenied, ...) rather than
    // masking it as a generic WriteFailed, so the actual cause reaches callers.
    var af = try std.Io.Dir.cwd().createFileAtomic(appio.io(), file_path, .{ .replace = true });
    defer af.deinit(appio.io());

    try af.file.writeStreamingAll(appio.io(), data);
    try af.file.sync(appio.io());
    try af.replace(appio.io());
}

/// Append `s` as a quoted, escaped JSON string.
fn emitStr(list: *List, alloc: std.mem.Allocator, s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{@as(u32, c)}) catch
                        return error.OutOfMemory;
                    try list.appendSlice(alloc, esc);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
    try list.append(alloc, '"');
}

/// Serialize one switch into `list` (no leading comma).
fn emitOne(list: *List, alloc: std.mem.Allocator, n: *const VirtualNetwork) !void {
    try emit(list, alloc, "\n    { \"name\": ");
    try emitStr(list, alloc, n.getNameSlice());
    try emit(list, alloc, ", \"type\": ");
    try emitStr(list, alloc, std.mem.span(n.vtype.toStr()));
    try emit(list, alloc, ", \"subnet\": ");
    try emitStr(list, alloc, n.getSubnetSlice());
    try emit(list, alloc, ", \"mask\": ");
    try emitStr(list, alloc, n.getMaskSlice());
    try emit(list, alloc, ", \"dhcp\": ");
    try emit(list, alloc, if (n.dhcp) "true" else "false");
    try emit(list, alloc, ", \"dhcp_start\": ");
    try emitStr(list, alloc, n.getDhcpStartSlice());
    try emit(list, alloc, ", \"dhcp_end\": ");
    try emitStr(list, alloc, n.getDhcpEndSlice());
    try emit(list, alloc, ", \"host_iface\": ");
    try emitStr(list, alloc, n.getHostIfaceSlice());
    try emit(list, alloc, ", \"gateway\": ");
    try emitStr(list, alloc, n.getGatewaySlice());
    try emit(list, alloc, ", \"port_forwards\": ");
    try emitStr(list, alloc, n.getPortForwardsSlice());
    try emit(list, alloc, " }");
}

/// Serialize a full `NetworkSet` to a JSON byte buffer owned by `alloc`.
/// Exposed for round-trip testing without touching the filesystem.
pub fn toJson(set: *const NetworkSet, alloc: std.mem.Allocator) ![]u8 {
    var list: List = .empty;
    errdefer list.deinit(alloc);
    try emit(&list, alloc, "{\n  \"version\": 1,\n  \"networks\": [");
    const n = @min(set.count, MAX_VNETS);
    for (0..n) |i| {
        if (i > 0) try emit(&list, alloc, ",");
        try emitOne(&list, alloc, &set.nets[i]);
    }
    try emit(&list, alloc, "\n  ]\n}\n");
    return list.toOwnedSlice(alloc);
}

/// Persist `set` to `~/.config/hangar/networks.json`. Best-effort: creates the
/// config dir if missing.
pub fn save(set: *const NetworkSet) !void {
    const alloc = std.heap.page_allocator;

    var dir_buf: [512]u8 = undefined;
    if (appstate.configDir(&dir_buf)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(appio.io(), dir_path) catch {
            _ = std.c.write(2, "vnet: createDirPath failed\n", 27);
        };
    }

    var path_buf: [512]u8 = undefined;
    const file_path = appstate.networksPath(&path_buf) orelse return error.HomeNotFound;

    const json = try toJson(set, alloc);
    defer alloc.free(json);

    try writeFileAtomic(file_path, json);
}

// ── Parse ────────────────────────────────────────────────────────────

fn skipWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
    return s[i..];
}

/// Current on-disk `networks.json` format version. Bump when the schema changes
/// in a way that older parsers cannot safely round-trip.
pub const CUR_VERSION: u32 = 1;

/// Extract the top-level `"version"` value from raw bytes. Defaults to 1 when
/// absent. If the version is higher than `CUR_VERSION`, writes a warning to
/// stderr so the user knows the file was saved by a newer Hangar. Exposed for
/// testing.
pub fn parseVersion(content: []const u8) u32 {
    if (std.mem.indexOf(u8, content, "\"version\"")) |vidx| {
        var cur = skipWs(content[vidx + "\"version\"".len ..]);
        if (cur.len > 0 and cur[0] == ':') {
            cur = skipWs(cur[1..]);
            var i: usize = 0;
            var val: u32 = 0;
            while (i < cur.len and cur[i] >= '0' and cur[i] <= '9') : (i += 1) {
                val = val *| 10 +| (cur[i] - '0');
            }
            if (i == 0) return 1; // non-numeric (e.g. "abc", true) → default
            if (val > CUR_VERSION and !@import("builtin").is_test) {
                const msg = "hangar: networks file version newer than supported (max 1); some settings may be ignored\n";
                _ = std.c.write(2, msg, msg.len);
            }
            return val;
        }
    }
    return 1;
}

/// Read a JSON string starting at `s[0] == '"'` into `out`. Returns the
/// unescaped slice (of `out`) and the input remainder after the closing quote.
/// Returns null on a missing/unterminated string. The returned `rest` is always
/// a suffix slice of the input (fuzz invariant).
fn readString(s: []const u8, out: []u8) ?struct { value: []const u8, rest: []const u8 } {
    if (s.len == 0 or s[0] != '"') return null;
    var i: usize = 1;
    var out_len: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') return .{ .value = out[0..out_len], .rest = s[i + 1 ..] };
        if (c == '\\' and i + 1 < s.len) {
            if (s[i + 1] == 'u' and i + 5 < s.len) {
                const hex = s[i + 2 .. i + 6];
                const codepoint = std.fmt.parseInt(u16, hex, 16) catch return null;
                if (codepoint < 0x80) {
                    if (out_len >= out.len) return null;
                    out[out_len] = @intCast(codepoint);
                    out_len += 1;
                } else if (codepoint < 0x800) {
                    if (out_len + 1 >= out.len) return null;
                    out[out_len] = @intCast(0xC0 | (codepoint >> 6));
                    out[out_len + 1] = @intCast(0x80 | (codepoint & 0x3F));
                    out_len += 2;
                } else {
                    if (out_len + 2 >= out.len) return null;
                    out[out_len] = @intCast(0xE0 | (codepoint >> 12));
                    out[out_len + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                    out[out_len + 2] = @intCast(0x80 | (codepoint & 0x3F));
                    out_len += 3;
                }
                i += 6;
                continue;
            }
            const esc: u8 = switch (s[i + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => s[i + 1],
            };
            if (out_len >= out.len) return null;
            out[out_len] = esc;
            out_len += 1;
            i += 2;
            continue;
        }
        if (out_len >= out.len) return null;
        out[out_len] = c;
        out_len += 1;
        i += 1;
    }
    return null;
}

/// Validates an IPv4 address string (e.g. "192.168.1.1"). Returns true
/// iff the string consists of four decimal octets (0–255) separated by dots.
fn isValidIpv4(s: []const u8) bool {
    if (s.len == 0 or s.len > 15) return false;
    var octets: u8 = 0;
    var cur: u16 = 0;
    var digits: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (digits == 0 or cur > 255) return false;
            octets += 1;
            cur = 0;
            digits = 0;
            continue;
        }
        if (c < '0' or c > '9') return false;
        if (digits > 0 and cur == 0) return false; // leading zero
        if (digits >= 3) return false; // an octet is at most 3 digits
        cur = cur * 10 + (c - '0');
        digits += 1;
    }
    if (digits == 0 or cur > 255) return false;
    octets += 1;
    return octets == 4;
}

/// Validates a subnet mask in dotted-decimal form (e.g. "255.255.255.0").
/// A valid mask has all 1-bits contiguous from the left (CIDR-style).
fn isValidSubnetMask(s: []const u8) bool {
    if (!isValidIpv4(s)) return false;
    // Parse the 4 octets directly; we know they are valid from isValidIpv4.
    var bits: u32 = 0;
    var octet: u32 = 0;
    for (s) |c| {
        if (c == '.') {
            bits = (bits << 8) | octet;
            octet = 0;
        } else {
            octet = octet * 10 + (c - '0');
        }
    }
    bits = (bits << 8) | octet;
    // A valid mask is all 1s then all 0s: bits | (bits - 1) == all-ones (except 0)
    if (bits == 0) return false;
    const inv: u32 = ~bits;
    return (inv & (inv +% 1)) == 0;
}

/// Within a single object slice `obj`, find `"key"` and read the string value
/// that follows `:`. Writes into `out`, returns the slice (empty if absent).
fn fieldStr(obj: []const u8, key: []const u8, out: []u8) []const u8 {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return out[0..0];
    const idx = std.mem.indexOf(u8, obj, pat) orelse return out[0..0];
    var cur = skipWs(obj[idx + pat.len ..]);
    if (cur.len == 0 or cur[0] != ':') return out[0..0];
    cur = skipWs(cur[1..]);
    const r = readString(cur, out) orelse return out[0..0];
    return r.value;
}

/// Within `obj`, return the boolean value of `"key"` (default false).
fn fieldBool(obj: []const u8, key: []const u8) bool {
    var pat_buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return false;
    const idx = std.mem.indexOf(u8, obj, pat) orelse return false;
    var cur = skipWs(obj[idx + pat.len ..]);
    if (cur.len == 0 or cur[0] != ':') return false;
    cur = skipWs(cur[1..]);
    return cur.len >= 4 and std.mem.eql(u8, cur[0..4], "true");
}

/// Find the next brace-balanced `{...}` object in `s` (string-aware so braces
/// inside string values don't confuse the depth counter). Returns the object
/// slice (including braces) and the remainder after it. `obj` and `rest` are
/// always sub-slices of the input (fuzz invariant).
fn nextObject(s: []const u8) ?struct { obj: []const u8, rest: []const u8 } {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var i: usize = start;
    var in_str = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (c == '\\') {
                i += 1; // skip escaped char
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .obj = s[start .. i + 1], .rest = s[i + 1 ..] };
            },
            else => {},
        }
    }
    return null; // unbalanced
}

/// Parse a `networks.json` byte buffer into a `NetworkSet`. Unknown/missing
/// keys fall back to safe defaults; never panics. Exposed for testing.
pub fn fromJson(content: []const u8) NetworkSet {
    var set = NetworkSet{};

    // Forward-compat: warn (once) if the file was written by a newer Hangar.
    _ = parseVersion(content);

    // Narrow to the "networks" array; if absent, parse the whole buffer (the
    // object scanner ignores the outer wrapper object anyway because we start
    // after the array bracket).
    var cur: []const u8 = content;
    if (std.mem.indexOf(u8, content, "\"networks\"")) |idx| {
        cur = content[idx + "\"networks\"".len ..];
        cur = skipWs(cur);
        if (cur.len > 0 and cur[0] == ':') cur = skipWs(cur[1..]);
        if (cur.len > 0 and cur[0] == '[') cur = cur[1..];
    } else {
        return set;
    }

    while (set.count < MAX_VNETS) {
        const r = nextObject(cur) orelse break;
        cur = r.rest;
        const obj = r.obj;

        var n = &set.nets[set.count];
        n.* = .{};
        var tmp: [IFACE_CAP]u8 = undefined;
        n.setName(fieldStr(obj, "name", &tmp));
        var tbuf: [IP_CAP]u8 = undefined;
        n.vtype = VNetType.fromStr(fieldStr(obj, "type", &tbuf));
        const subnet_val = fieldStr(obj, "subnet", &tmp);
        n.setSubnet(if (isValidIpv4(subnet_val)) subnet_val else "");
        const mask_val = fieldStr(obj, "mask", &tmp);
        n.setMask(if (isValidSubnetMask(mask_val)) mask_val else "");
        n.dhcp = fieldBool(obj, "dhcp");
        const dhcp_start_val = fieldStr(obj, "dhcp_start", &tmp);
        n.setDhcpStart(if (dhcp_start_val.len == 0 or isValidIpv4(dhcp_start_val)) dhcp_start_val else "");
        const dhcp_end_val = fieldStr(obj, "dhcp_end", &tmp);
        n.setDhcpEnd(if (dhcp_end_val.len == 0 or isValidIpv4(dhcp_end_val)) dhcp_end_val else "");
        n.setHostIface(fieldStr(obj, "host_iface", &tmp));
        const gateway_val = fieldStr(obj, "gateway", &tmp);
        n.setGateway(if (gateway_val.len == 0 or isValidIpv4(gateway_val)) gateway_val else "");
        var pf_tmp: [PORTFWD_CAP]u8 = undefined;
        n.setPortForwards(fieldStr(obj, "port_forwards", &pf_tmp));
        set.count += 1;
    }
    return set;
}

/// Load the saved switches, or the factory defaults if the file is absent or
/// empty. Never fails — the editor always has something to show.
pub fn load() NetworkSet {
    const alloc = std.heap.page_allocator;
    var path_buf: [512]u8 = undefined;
    const file_path = appstate.networksPath(&path_buf) orelse return NetworkSet.defaults();

    const content = std.Io.Dir.cwd().readFileAlloc(
        appio.io(),
        file_path,
        alloc,
        .limited(4 * 1024 * 1024),
    ) catch |e| {
        // FileNotFound is normal before the first save. Any other failure means
        // an existing networks.json could not be read — surface it instead of
        // silently falling back to defaults (which a later save would persist).
        if (e != error.FileNotFound) {
            const msg = "vnet: load failed to read networks.json (existing config not loaded)\n";
            _ = std.c.write(2, msg, msg.len);
        }
        return NetworkSet.defaults();
    };
    defer alloc.free(content);

    if (content.len == 0) return NetworkSet.defaults();
    const set = fromJson(content);
    if (set.count == 0) return NetworkSet.defaults();
    return set;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "VNetType: fromIndex round-trip" {
    try testing.expectEqual(VNetType.bridged, VNetType.fromIndex(0));
    try testing.expectEqual(VNetType.nat, VNetType.fromIndex(1));
    try testing.expectEqual(VNetType.host_only, VNetType.fromIndex(2));
    try testing.expectEqual(VNetType.nat, VNetType.fromIndex(99)); // safe default
}

test "VNetType: toIndex inverts fromIndex" {
    for (0..VNetType.count) |i| {
        try testing.expectEqual(i, VNetType.fromIndex(i).toIndex());
    }
}

test "VNetType: toStr/fromStr round-trip" {
    for (0..VNetType.count) |i| {
        const t = VNetType.fromIndex(i);
        try testing.expectEqual(t, VNetType.fromStr(std.mem.span(t.toStr())));
    }
    try testing.expectEqual(VNetType.nat, VNetType.fromStr("garbage"));
}

test "NetworkSet: defaults populate three switches" {
    const s = NetworkSet.defaults();
    try testing.expectEqual(@as(usize, 3), s.count);
    try testing.expectEqualStrings("VMnet0", s.nets[0].getNameSlice());
    try testing.expectEqual(VNetType.bridged, s.nets[0].vtype);
    try testing.expectEqual(VNetType.nat, s.nets[2].vtype);
    try testing.expect(s.nets[2].dhcp);
}

test "NetworkSet: add respects MAX_VNETS" {
    var s = NetworkSet{};
    var i: usize = 0;
    while (i < MAX_VNETS + 5) : (i += 1) {
        _ = s.add("VMnetX", .nat, "10.0.0.0", "255.255.255.0", false, "", "", "");
    }
    try testing.expectEqual(MAX_VNETS, s.count);
}

test "NetworkSet: remove shifts tail" {
    var s = NetworkSet.defaults();
    s.remove(0); // drop VMnet0
    try testing.expectEqual(@as(usize, 2), s.count);
    try testing.expectEqualStrings("VMnet1", s.nets[0].getNameSlice());
    s.remove(99); // out of range → no-op
    try testing.expectEqual(@as(usize, 2), s.count);
}

test "vnet: emit -> parse round-trip preserves fields" {
    const orig = NetworkSet.defaults();
    const json = try toJson(&orig, testing.allocator);
    defer testing.allocator.free(json);

    const back = fromJson(json);
    try testing.expectEqual(orig.count, back.count);
    for (0..orig.count) |i| {
        try testing.expectEqualStrings(orig.nets[i].getNameSlice(), back.nets[i].getNameSlice());
        try testing.expectEqual(orig.nets[i].vtype, back.nets[i].vtype);
        try testing.expectEqualStrings(orig.nets[i].getSubnetSlice(), back.nets[i].getSubnetSlice());
        try testing.expectEqualStrings(orig.nets[i].getMaskSlice(), back.nets[i].getMaskSlice());
        try testing.expectEqual(orig.nets[i].dhcp, back.nets[i].dhcp);
        try testing.expectEqualStrings(orig.nets[i].getDhcpStartSlice(), back.nets[i].getDhcpStartSlice());
        try testing.expectEqualStrings(orig.nets[i].getDhcpEndSlice(), back.nets[i].getDhcpEndSlice());
        try testing.expectEqualStrings(orig.nets[i].getHostIfaceSlice(), back.nets[i].getHostIfaceSlice());
        try testing.expectEqualStrings(orig.nets[i].getGatewaySlice(), back.nets[i].getGatewaySlice());
        try testing.expectEqualStrings(orig.nets[i].getPortForwardsSlice(), back.nets[i].getPortForwardsSlice());
    }
}

test "vnet: setters clamp to buffer capacity" {
    var n = VirtualNetwork{};
    const huge = "x" ** 200;
    n.setName(huge);
    n.setSubnet(huge);
    n.setHostIface(huge);
    try testing.expect(n.getNameSlice().len <= NAME_CAP - 1);
    try testing.expect(n.getSubnetSlice().len <= IP_CAP - 1);
    try testing.expect(n.getHostIfaceSlice().len <= IFACE_CAP - 1);
    // NUL-terminated for C interop.
    try testing.expectEqual(@as(u8, 0), n.name_buf[n.name_len]);
}

test "vnet fuzz: fromJson never panics and stays bounded" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "{}[]\":,truefalsenamtypsubdhcp019.VMnet \\";

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (0..len) |i| {
            buf[i] = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        }
        const set = fromJson(buf[0..len]);
        // Invariant: never exceed capacity, every name slice in-bounds.
        try testing.expect(set.count <= MAX_VNETS);
        for (0..set.count) |i| {
            try testing.expect(set.nets[i].name_len < NAME_CAP);
            try testing.expect(set.nets[i].subnet_len < IP_CAP);
            try testing.expect(set.nets[i].host_iface_len < IFACE_CAP);
        }
    }
}

test "vnet: parseVersion reads version from JSON" {
    try testing.expectEqual(@as(u32, 1), parseVersion("{\"version\":1}"));
    try testing.expectEqual(@as(u32, 7), parseVersion("{\"version\": 7}")); // newer than supported — warns to stderr (suppressed in test)
    try testing.expectEqual(@as(u32, 1), parseVersion("{\"networks\":[]}")); // absent → default 1
}

test "vnet: parseVersion survives malformed version" {
    try testing.expectEqual(@as(u32, 1), parseVersion("{\"version\":\"abc\"}"));
    try testing.expectEqual(@as(u32, 1), parseVersion("{\"version\":true}"));
    try testing.expectEqual(@as(u32, 1), parseVersion("{\"version\":}"));
    try testing.expectEqual(@as(u32, 1), parseVersion(""));
}

test "vnet fuzz: parseVersion never panics and never overflows" {
    var prng = std.Random.DefaultPrng.init(0xCAFE01);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;
    const alphabet = "{}\"version:0123456789 truefalse,";
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (0..len) |i| buf[i] = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        _ = parseVersion(buf[0..len]); // saturating arithmetic → never traps
    }
}

test "vnet fuzz: nextObject rest is always a suffix slice" {
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const alphabet = "{}\"\\abc ";

    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (0..len) |i| buf[i] = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
        const s = buf[0..len];
        if (nextObject(s)) |r| {
            // rest must be a suffix of s (pointer within, length consistent).
            try testing.expect(@intFromPtr(r.rest.ptr) >= @intFromPtr(s.ptr));
            try testing.expect(@intFromPtr(r.rest.ptr) + r.rest.len == @intFromPtr(s.ptr) + s.len);
        }
    }
}

// ── Remaining direct coverage: label + C-string accessors + escaping ──

test "VNetType: label values" {
    try testing.expectEqualStrings("Bridged", std.mem.span(VNetType.bridged.label()));
    try testing.expectEqualStrings("NAT", std.mem.span(VNetType.nat.label()));
    try testing.expectEqualStrings("Host-only", std.mem.span(VNetType.host_only.label()));
}

test "VirtualNetwork: C-string (NUL-terminated) accessors" {
    var n = VirtualNetwork{};
    n.setName("VMnet5");
    n.setSubnet("10.0.0.0");
    n.setMask("255.0.0.0");
    n.setDhcpStart("10.0.0.10");
    n.setDhcpEnd("10.0.0.99");
    n.setHostIface("eth0");
    n.setGateway("10.0.0.1");
    try testing.expectEqualStrings("VMnet5", std.mem.span(n.getName()));
    try testing.expectEqualStrings("10.0.0.0", std.mem.span(n.getSubnet()));
    try testing.expectEqualStrings("255.0.0.0", std.mem.span(n.getMask()));
    try testing.expectEqualStrings("10.0.0.10", std.mem.span(n.getDhcpStart()));
    try testing.expectEqualStrings("10.0.0.99", std.mem.span(n.getDhcpEnd()));
    try testing.expectEqualStrings("eth0", std.mem.span(n.getHostIface()));
    try testing.expectEqualStrings("10.0.0.1", std.mem.span(n.getGateway()));
    // Each span length must equal the tracked slice length.
    try testing.expectEqual(n.getNameSlice().len, std.mem.span(n.getName()).len);
}

test "vnet: emitStr escapes control characters as \\uXXXX" {
    var list: List = .empty;
    try emitStr(&list, testing.allocator, "\x00\x01\x1f");
    const s = try list.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(s);
    // nul → \u0000, SOH → \u0001, US → \u001f
    try testing.expectEqualStrings("\"\\u0000\\u0001\\u001f\"", s);
}

test "vnet: emitStr escapes survive emit -> parse round-trip" {
    var s = NetworkSet{};
    _ = s.add("a\"b\\c", .nat, "1.1.1.1", "255.255.255.0", true, "10.0.0.10", "10.0.0.20", "if\r0");
    s.nets[0].setGateway("10.0.0.1");
    s.nets[0].setPortForwards("host\\\"rule");
    const json = try toJson(&s, testing.allocator);
    defer testing.allocator.free(json);
    const back = fromJson(json);
    try testing.expectEqual(@as(usize, 1), back.count);
    try testing.expectEqualStrings("a\"b\\c", back.nets[0].getNameSlice());
    try testing.expectEqualStrings("10.0.0.10", back.nets[0].getDhcpStartSlice());
    try testing.expectEqualStrings("10.0.0.20", back.nets[0].getDhcpEndSlice());
    try testing.expectEqualStrings("if\r0", back.nets[0].getHostIfaceSlice());
    try testing.expectEqualStrings("10.0.0.1", back.nets[0].getGatewaySlice());
    try testing.expectEqualStrings("host\\\"rule", back.nets[0].getPortForwardsSlice());
}

// ── Missing standalone coverage ─────────────────────────────────────

test "vnet: fromJson empty input returns empty set" {
    const s = fromJson("");
    try testing.expectEqual(@as(usize, 0), s.count);
}

test "vnet: fromJson empty array returns empty set" {
    const s = fromJson("{\"networks\": []}");
    try testing.expectEqual(@as(usize, 0), s.count);
}

test "vnet: fromJson no networks key returns empty set" {
    const s = fromJson("{\"version\": 1}");
    try testing.expectEqual(@as(usize, 0), s.count);
}

test "vnet: fromJson caps at MAX_VNETS" {
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    const hdr = "{\"networks\": [";
    @memcpy(buf[w..][0..hdr.len], hdr);
    w += hdr.len;
    var i: usize = 0;
    while (i < MAX_VNETS + 5) : (i += 1) {
        const obj = std.fmt.bufPrint(buf[w..], "{{\"name\": \"VMnet{d}\"}},", .{i}) catch break;
        w += obj.len;
    }
    @memcpy(buf[w..][0..2], "]}");
    w += 2;
    const s = fromJson(buf[0..w]);
    try testing.expectEqual(MAX_VNETS, s.count);
}

test "vnet: readString unterminated returns null" {
    var out: [64]u8 = undefined;
    try testing.expect(readString("\"no close", &out) == null);
}

test "vnet: readString escape at end returns null" {
    var out: [64]u8 = undefined;
    try testing.expect(readString("\"trailing\\", &out) == null);
}

test "vnet: readString \\u escape decodes UTF-8" {
    var out: [64]u8 = undefined;
    // \u20AC = € (3-byte UTF-8: E2 82 AC)
    const r = readString("\"\\u20AC100\"", &out).?;
    try testing.expectEqualStrings("€100", r.value);
}

test "vnet: readString invalid \\u hex returns null" {
    var out: [64]u8 = undefined;
    try testing.expect(readString("\"\\uGGGG\"", &out) == null);
}

test "vnet: readString truncation returns null" {
    var out: [3]u8 = undefined;
    try testing.expect(readString("\"abcd\"", &out) == null);
}

test "vnet: readString \\u truncation returns null" {
    var out: [3]u8 = undefined;
    // \u20AC = € needs 3 bytes, "€x" needs 4 → overflow
    try testing.expect(readString("\"\\u20ACx\"", &out) == null);
}

test "vnet: fieldStr with missing key returns empty" {
    var out: [64]u8 = undefined;
    const obj = "{\"name\": \"test\"}";
    const result = fieldStr(obj, "nonexistent", &out);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "vnet: fieldBool with false" {
    const obj = "{\"dhcp\": false}";
    try testing.expect(!fieldBool(obj, "dhcp"));
}

test "vnet: fieldBool with true after whitespace" {
    const obj = "{\"dhcp\":  true}";
    try testing.expect(fieldBool(obj, "dhcp"));
}

test "vnet: fieldBool with missing key defaults false" {
    const obj = "{\"name\": \"test\"}";
    try testing.expect(!fieldBool(obj, "dhcp"));
}

test "vnet: nextObject with no braces returns null" {
    try testing.expect(nextObject("no braces here") == null);
}

test "vnet: nextObject unbalanced returns null" {
    try testing.expect(nextObject("{{") == null);
}

test "vnet: toJson empty set produces valid JSON" {
    var s = NetworkSet{};
    const json = try toJson(&s, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"networks\": [") != null);
    try testing.expect(std.mem.indexOf(u8, json, "]") != null);
}

test "vnet: VNetType.fromStr unknown defaults to nat" {
    try testing.expectEqual(VNetType.nat, VNetType.fromStr(""));
    try testing.expectEqual(VNetType.nat, VNetType.fromStr("garbage"));
    try testing.expectEqual(VNetType.nat, VNetType.fromStr("bogus"));
}

test "vnet: VirtualNetwork port_forwards + gateway setters" {
    var n = VirtualNetwork{};
    n.setPortForwards("2222:192.168.1.1:22");
    try testing.expectEqualStrings("2222:192.168.1.1:22", n.getPortForwardsSlice());
    try testing.expectEqualStrings("2222:192.168.1.1:22", std.mem.span(n.getPortForwards()));

    n.setGateway("192.168.1.1");
    try testing.expectEqualStrings("192.168.1.1", n.getGatewaySlice());
    try testing.expectEqualStrings("192.168.1.1", std.mem.span(n.getGateway()));
}

test "vnet: setBuf clamps to buffer capacity" {
    var n = VirtualNetwork{};
    const huge = "A" ** 300;
    n.setName(huge);
    n.setPortForwards(huge);
    try testing.expect(n.getNameSlice().len <= 15); // NAME_CAP - 1
    try testing.expect(n.getPortForwardsSlice().len <= 255); // PORTFWD_CAP - 1
}

test "isValidIpv4: valid addresses" {
    try testing.expect(isValidIpv4("192.168.1.1"));
    try testing.expect(isValidIpv4("0.0.0.0"));
    try testing.expect(isValidIpv4("255.255.255.255"));
    try testing.expect(isValidIpv4("10.0.0.1"));
    try testing.expect(isValidIpv4("172.16.254.1"));
}

test "isValidIpv4: invalid addresses" {
    try testing.expect(!isValidIpv4(""));
    try testing.expect(!isValidIpv4("256.1.1.1"));
    try testing.expect(!isValidIpv4("1.2.3.256"));
    try testing.expect(!isValidIpv4("1.2.3"));
    try testing.expect(!isValidIpv4("1.2.3.4.5"));
    try testing.expect(!isValidIpv4("01.1.1.1"));
    try testing.expect(!isValidIpv4("abc.def.ghi.jkl"));
    try testing.expect(!isValidIpv4("1.2.3."));
    try testing.expect(!isValidIpv4(".1.2.3"));
    // Regression: a long run of digits in one octet must not overflow `cur`.
    try testing.expect(!isValidIpv4("999999999999.1.1"));
    try testing.expect(!isValidIpv4("1234.1.1.1"));
}

test "isValidSubnetMask: valid masks" {
    try testing.expect(isValidSubnetMask("255.255.255.0"));
    try testing.expect(isValidSubnetMask("255.0.0.0"));
    try testing.expect(isValidSubnetMask("255.255.0.0"));
    try testing.expect(isValidSubnetMask("255.255.255.128"));
    try testing.expect(isValidSubnetMask("255.255.255.192"));
    try testing.expect(isValidSubnetMask("255.255.255.252"));
    try testing.expect(isValidSubnetMask("128.0.0.0"));
}

test "isValidSubnetMask: invalid masks" {
    try testing.expect(!isValidSubnetMask(""));
    try testing.expect(!isValidSubnetMask("0.0.0.0"));
    try testing.expect(!isValidSubnetMask("255.0.0.255"));
    try testing.expect(!isValidSubnetMask("255.255.1.0"));
    try testing.expect(!isValidSubnetMask("192.168.1.0"));
    try testing.expect(!isValidSubnetMask("abc"));
}

test "vnet: fromJson rejects invalid subnet and mask" {
    const json = "{\"networks\": [{\"name\": \"VMnet0\", \"type\": \"nat\", \"subnet\": \"not.an.ip\", \"mask\": \"garbage\"}]}";
    const set = fromJson(json);
    try testing.expectEqual(@as(usize, 1), set.count);
    try testing.expectEqualStrings("VMnet0", set.nets[0].getNameSlice());
    // Invalid subnet → should be empty
    try testing.expectEqual(@as(usize, 0), set.nets[0].getSubnetSlice().len);
    // Invalid mask → should be empty
    try testing.expectEqual(@as(usize, 0), set.nets[0].getMaskSlice().len);
}

test "vnet: fromJson rejects invalid DHCP and gateway IPs" {
    const json = "{\"networks\": [{\"name\": \"bad\", \"type\": \"nat\", \"dhcp\": true, \"dhcp_start\": \"999.1.1.1\", \"dhcp_end\": \"10.0.0.x\", \"gateway\": \"not-ip\"}]}";
    const set = fromJson(json);
    try testing.expectEqual(@as(usize, 1), set.count);
    try testing.expectEqual(@as(usize, 0), set.nets[0].getDhcpStartSlice().len);
    try testing.expectEqual(@as(usize, 0), set.nets[0].getDhcpEndSlice().len);
    try testing.expectEqual(@as(usize, 0), set.nets[0].getGatewaySlice().len);
}

test "vnet: fromJson accepts valid subnet and mask" {
    const json = "{\"networks\": [{\"name\": \"VMnet8\", \"type\": \"nat\", \"subnet\": \"192.168.140.0\", \"mask\": \"255.255.255.0\"}]}";
    const set = fromJson(json);
    try testing.expectEqualStrings("192.168.140.0", set.nets[0].getSubnetSlice());
    try testing.expectEqualStrings("255.255.255.0", set.nets[0].getMaskSlice());
}

test "vnet: fromJson rejects non-contiguous mask" {
    const json = "{\"networks\": [{\"name\": \"bad\", \"type\": \"nat\", \"subnet\": \"10.0.0.0\", \"mask\": \"255.255.1.0\"}]}";
    const set = fromJson(json);
    try testing.expectEqualStrings("10.0.0.0", set.nets[0].getSubnetSlice()); // subnet is valid
    try testing.expectEqual(@as(usize, 0), set.nets[0].getMaskSlice().len); // mask rejected
}

test "fuzz: fromJson on mutated valid JSON never crashes" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7E7_BEEF);
    const rnd = prng.random();

    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const orig = NetworkSet.defaults();
        const json = try toJson(&orig, alloc);
        defer alloc.free(json);

        // Apply a handful of random byte mutations to otherwise-valid JSON.
        const muts = rnd.uintLessThan(usize, 16);
        var m: usize = 0;
        while (m < muts and json.len > 0) : (m += 1) {
            json[rnd.uintLessThan(usize, json.len)] = rnd.int(u8);
        }

        const set = fromJson(json);
        try testing.expect(set.count <= MAX_VNETS);
    }
}
