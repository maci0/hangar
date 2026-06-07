// SPDX-License-Identifier: MIT
//! Pure parser for the snapshot tables printed by `qemu-img snapshot -l` and
//! QMP `info snapshots`. No IO; deterministic.

const std = @import("std");

pub const MAX_SNAP_NODES = 16;
pub const SNAP_NAME_CAP = 24;

/// Parsed snapshot names, fixed storage (no heap). Names are truncated to
/// `SNAP_NAME_CAP-1` bytes; at most `MAX_SNAP_NODES` are kept.
pub const SnapNodes = struct {
    names: [MAX_SNAP_NODES][SNAP_NAME_CAP]u8 = undefined,
    name_len: [MAX_SNAP_NODES]u8 = [_]u8{0} ** MAX_SNAP_NODES,
    count: usize = 0,

    pub fn nameSlice(self: *const SnapNodes, i: usize) []const u8 {
        return self.names[i][0..self.name_len[i]];
    }
};

/// Parse a snapshot table: skip header lines ("Snapshot list:", a column
/// header beginning "ID", and "--" rules); for each data row (first token a
/// number, i.e. the snapshot ID), take the 2nd whitespace column as the tag.
pub fn parse(output: []const u8) SnapNodes {
    var nodes = SnapNodes{};
    // Split on \n and lone \r alike (a \r\n pair yields an empty token that the
    // trim/empty-line check below drops), so line splitting is robust for any
    // line ending and any input size — no fixed-size normalization buffer.
    var lines = std.mem.splitAny(u8, output, "\r\n");
    while (lines.next()) |line| {
        if (nodes.count >= MAX_SNAP_NODES) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Snapshot")) continue;
        if (std.mem.startsWith(u8, trimmed, "ID")) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        var toks = std.mem.tokenizeAny(u8, trimmed, " \t");
        const first = toks.next() orelse continue;
        if (first.len == 0 or first[0] < '0' or first[0] > '9') continue;
        const name = toks.next() orelse continue;
        const n = @min(name.len, SNAP_NAME_CAP - 1);
        @memcpy(nodes.names[nodes.count][0..n], name[0..n]);
        nodes.name_len[nodes.count] = @intCast(n);
        nodes.count += 1;
    }
    return nodes;
}

// ── Tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "snapparse: typical qemu-img table" {
    const out =
        \\Snapshot list:
        \\ID        TAG                 VM SIZE                DATE       VM CLOCK
        \\1         Base                      0 B 2024-01-01 00:00:00   00:00:00.000
        \\2         Updates                   0 B 2024-01-02 00:00:00   00:00:00.000
        \\3         App Installed             0 B 2024-01-03 00:00:00   00:00:00.000
    ;
    const n = parse(out);
    try t.expectEqual(@as(usize, 3), n.count);
    try t.expectEqualStrings("Base", n.nameSlice(0));
    try t.expectEqualStrings("Updates", n.nameSlice(1));
    try t.expectEqualStrings("App", n.nameSlice(2)); // 2nd token only ("Installed" dropped)
}

test "snapparse: empty / header-only yields no nodes" {
    try t.expectEqual(@as(usize, 0), parse("").count);
    try t.expectEqual(@as(usize, 0), parse("Snapshot list:\nID  TAG\n").count);
    try t.expectEqual(@as(usize, 0), parse("no digit first token here\n").count);
}

test "snapparse: long tag truncated to cap" {
    const out = "1 ThisTagIsWayTooLongToFitInTheBuffer 0 B\n";
    const n = parse(out);
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expect(n.nameSlice(0).len <= SNAP_NAME_CAP - 1);
    try t.expect(std.mem.startsWith(u8, "ThisTagIsWayTooLongToFitInTheBuffer", n.nameSlice(0)));
}

test "snapparse: caps at MAX_SNAP_NODES" {
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    var i: usize = 0;
    while (i < MAX_SNAP_NODES + 10) : (i += 1) {
        const line = std.fmt.bufPrint(buf[w..], "{d} tag{d} 0 B\n", .{ i + 1, i }) catch break;
        w += line.len;
    }
    try t.expectEqual(MAX_SNAP_NODES, parse(buf[0..w]).count);
}

test "fuzz: snapparse never panics and stays bounded" {
    var prng = std.Random.DefaultPrng.init(0x5A0F5A0F);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    const alphabet = "0123456789 \tABCabc-\nID Snapshot TAG";
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const n = parse(buf[0..len]);
        try t.expect(n.count <= MAX_SNAP_NODES);
        for (0..n.count) |k| try t.expect(n.name_len[k] < SNAP_NAME_CAP);
    }
}

test "snapparse: HMP info snapshots format" {
    // QMP `info snapshots` returns slightly different format than qemu-img.
    const out =
        \\1         Base               0 B 2024-01-01 00:00:00   00:00:00.000
        \\2         After Update       0 B 2024-06-15 12:30:00   00:00:00.000
    ;
    const n = parse(out);
    try t.expectEqual(@as(usize, 2), n.count);
    try t.expectEqualStrings("Base", n.nameSlice(0));
    try t.expectEqualStrings("After", n.nameSlice(1));
}

test "snapparse: single snapshot row" {
    const n = parse("1 SingleSnapshot 0 B\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("SingleSnapshot", n.nameSlice(0));
}

test "snapparse: rows with extra whitespace" {
    const n = parse("  1    MySnap    0 B   \n  2   Other   0 B  \n");
    try t.expectEqual(@as(usize, 2), n.count);
    try t.expectEqualStrings("MySnap", n.nameSlice(0));
    try t.expectEqualStrings("Other", n.nameSlice(1));
}

test "snapparse: row with only an ID and no tag returns empty" {
    // A row where the snapshot ID is valid but there's no TAG token after it.
    // (qemu-img can produce rows like "1  " for snapshots with empty tags.)
    const n = parse("1  \n"); // only ID "1", no tag
    try t.expectEqual(@as(usize, 0), n.count);
}

test "snapparse: Max name length exactly at cap" {
    var buf: [128]u8 = undefined;
    const name = "A" ** (SNAP_NAME_CAP + 10);
    const line = try std.fmt.bufPrint(&buf, "1 {s} 0 B\n", .{name});
    const n = parse(line);
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expect(n.nameSlice(0).len <= SNAP_NAME_CAP - 1);
}

test "snapparse: HMP output with 'VM SIZE' as column prefix" {
    // Some QEMU versions print "VM SIZE" as the size column header.
    const out =
        \\ID        TAG                 VM SIZE                DATE       VM CLOCK
        \\--        ---                 -------                ----       --------
        \\1         Base                     0 B 2024-01-01 00:00:00   00:00:00.000
    ;
    const n = parse(out);
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("Base", n.nameSlice(0));
}

test "snapparse: tags with spaces are truncated to first token only" {
    const n = parse("1 Before Update 0 B\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("Before", n.nameSlice(0));
}

test "snapparse: empty tag after numeric ID" {
    // "1  0 B" — second token is "0" (a valid tag name).
    const n = parse("1  0 B\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("0", n.nameSlice(0));
}

test "snapparse: truly empty tag (single token row)" {
    // Row with an ID but no second token — skipped.
    const n = parse("1\n");
    try t.expectEqual(@as(usize, 0), n.count);
}

test "snapparse: Carriage return only line endings" {
    const n = parse("1 Snap\r2 Other\r");
    try t.expectEqual(@as(usize, 2), n.count);
    try t.expectEqualStrings("Snap", n.nameSlice(0));
    try t.expectEqualStrings("Other", n.nameSlice(1));
}

test "snapparse: mix of empty lines and headers" {
    const out =
        \\
        \\Snapshot list:
        \\
        \\ID        TAG                 VM SIZE                DATE
        \\--        ---                 -------                ----
        \\
        \\1         Fresh                 0 B 2024-01-01 00:00:00   00:00:00.000
        \\
    ;
    const n = parse(out);
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("Fresh", n.nameSlice(0));
}

test "snapparse: row without size/date columns (minimal format)" {
    const n = parse("1 JustATag\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("JustATag", n.nameSlice(0));
}
