const std = @import("std");

pub fn main() !void {
    const raw: []const u8 = "Hello\x00\x1B[2JWorld\n";
    var valid_len: usize = 0;
    var tmp_buf: [256]u8 = undefined;
    
    for (raw) |c| {
        if (c == '\n' or c == '\r' or c == '\t' or (c >= 32 and c <= 126)) {
            tmp_buf[valid_len] = c;
            valid_len += 1;
        }
    }
    tmp_buf[valid_len] = 0;
    
    std.debug.print("Cleaned: '{s}'\n", .{tmp_buf[0..valid_len]});
}
