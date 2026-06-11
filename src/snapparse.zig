// SPDX-License-Identifier: MIT
//! Pure parser for the snapshot tables printed by `qemu-img snapshot -l` and
//! QMP `info snapshots`. No IO; deterministic.

const std = @import("std");

pub const MAX_SNAP_NODES = 16;
pub const SNAP_NAME_CAP = 24;
pub const SNAP_DATE_CAP = 20; // "YYYY-MM-DD HH:MM:SS" = 19 bytes

/// Parsed snapshot names + creation dates, fixed storage (no heap). Names are
/// truncated to `SNAP_NAME_CAP-1` bytes; at most `MAX_SNAP_NODES` are kept.
/// A date is stored only when the row carries a recognizable DATE+TIME pair.
pub const SnapNodes = struct {
    names: [MAX_SNAP_NODES][SNAP_NAME_CAP]u8 = undefined,
    name_len: [MAX_SNAP_NODES]u8 = [_]u8{0} ** MAX_SNAP_NODES,
    dates: [MAX_SNAP_NODES][SNAP_DATE_CAP]u8 = undefined,
    date_len: [MAX_SNAP_NODES]u8 = [_]u8{0} ** MAX_SNAP_NODES,
    count: usize = 0,

    pub fn nameSlice(self: *const SnapNodes, i: usize) []const u8 {
        return self.names[i][0..self.name_len[i]];
    }

    pub fn dateSlice(self: *const SnapNodes, i: usize) []const u8 {
        return self.dates[i][0..self.date_len[i]];
    }
};

/// "YYYY-MM-DD" — digits with dashes at positions 4 and 7.
fn isDateTok(s: []const u8) bool {
    if (s.len != 10) return false;
    for (s, 0..) |ch, i| {
        if (i == 4 or i == 7) {
            if (ch != '-') return false;
        } else if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// "HH:MM:SS" prefix — digits with colons at positions 2 and 5.
fn isTimeTok(s: []const u8) bool {
    if (s.len < 8) return false;
    for (s[0..8], 0..) |ch, i| {
        if (i == 2 or i == 5) {
            if (ch != ':') return false;
        } else if (ch < '0' or ch > '9') return false;
    }
    return true;
}

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
        // Scan remaining tokens for the DATE + TIME columns ("YYYY-MM-DD
        // HH:MM:SS"). Tag words and the size column are skipped; a date token
        // not followed by a time token is discarded (it was tag text).
        var date_tok: ?[]const u8 = null;
        while (toks.next()) |tok| {
            if (date_tok == null) {
                if (isDateTok(tok)) date_tok = tok;
            } else if (isTimeTok(tok)) {
                @memcpy(nodes.dates[nodes.count][0..10], date_tok.?[0..10]);
                nodes.dates[nodes.count][10] = ' ';
                @memcpy(nodes.dates[nodes.count][11..19], tok[0..8]);
                nodes.date_len[nodes.count] = 19;
                break;
            } else if (isDateTok(tok)) {
                date_tok = tok; // newer candidate
            } else {
                date_tok = null;
            }
        }
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
    try t.expectEqualStrings("2024-01-01 00:00:00", n.dateSlice(0));
    try t.expectEqualStrings("2024-01-02 00:00:00", n.dateSlice(1));
    try t.expectEqualStrings("2024-01-03 00:00:00", n.dateSlice(2));
}

test "snapparse: row without date columns has empty dateSlice" {
    const n = parse("1 JustATag\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("", n.dateSlice(0));
}

test "snapparse: date token without a following time is not a date" {
    const n = parse("1 tag 2024-01-01 notatime\n");
    try t.expectEqual(@as(usize, 1), n.count);
    try t.expectEqualStrings("", n.dateSlice(0));
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
    // Half the rounds use a table-shaped alphabet (to reach the data-row code
    // paths) and half use the full byte range (control chars, high bytes, NUL)
    // so the digit/whitespace boundaries are probed with arbitrary input too.
    const alphabet = "0123456789 \tABCabc-\nID Snapshot TAG";
    var iter: usize = 0;
    while (iter < 6000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        const structured = (iter & 1) == 0;
        for (buf[0..len]) |*c| {
            c.* = if (structured) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const n = parse(buf[0..len]);
        try t.expect(n.count <= MAX_SNAP_NODES);
        // Exercise the nameSlice accessor on every parsed node — a regression in
        // parse that recorded name_len >= SNAP_NAME_CAP would index out of the
        // fixed buffer here, which a count/len-only check would miss.
        for (0..n.count) |k| {
            try t.expect(n.name_len[k] < SNAP_NAME_CAP);
            const name = n.nameSlice(k);
            try t.expect(name.len < SNAP_NAME_CAP);
            try t.expect(name.len == n.name_len[k]);
            try t.expect(n.date_len[k] < SNAP_DATE_CAP);
            try t.expect(n.dateSlice(k).len == n.date_len[k]);
        }
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
