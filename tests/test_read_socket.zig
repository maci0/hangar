const std = @import("std");

pub fn main() !void {
    var child = std.process.Child.init(&[_][]const u8{
        "qemu-system-x86_64", "-machine", "q35", "-m", "512", "-display", "none",
        "-serial", "unix:/tmp/test_socket.sock,server=on,wait=off"
    }, std.heap.page_allocator);
    try child.spawn();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const stream = try std.net.connectUnixSocket("/tmp/test_socket.sock");
    std.debug.print("Connected\n", .{});
    
    var buf: [10]u8 = undefined;
    const n = try stream.read(&buf);
    std.debug.print("Read returned: {}\n", .{n});
    
    _ = try child.kill();
}
