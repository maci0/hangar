const std = @import("std");

pub fn main() !void {
    // Run QEMU with a specific serial path
    var child = std.process.Child.init(&[_][]const u8{
        "qemu-system-x86_64",
        "-machine", "q35",
        "-m", "512",
        "-display", "none",
        "-serial", "unix:/tmp/kvmgui-serial-test_vm.sock,server=on,wait=off"
    }, std.heap.page_allocator);
    
    try child.spawn();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const stream = std.net.connectUnixSocket("/tmp/kvmgui-serial-test_vm.sock") catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        _ = try child.kill();
        return;
    };
    std.debug.print("Connected!\n", .{});
    
    stream.close();
    _ = try child.kill();
}
