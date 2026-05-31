const std = @import("std");

pub fn main() !void {
    const fw: usize = 1920;
    const fh: usize = 1080;
    const num_pixels = fw * fh;

    // Simulate VNC BGRA pixels
    const pixels = try std.heap.page_allocator.alloc(u8, num_pixels * 4);
    defer std.heap.page_allocator.free(pixels);

    var fb_copy = try std.heap.page_allocator.alloc(u8, num_pixels * 4);
    defer std.heap.page_allocator.free(fb_copy);

    var timer = try std.time.Timer.start();
    
    // Original byte-by-byte iteration
    var i: usize = 0;
    while (i < num_pixels * 4) : (i += 4) {
        fb_copy[i] = pixels[i+2];
        fb_copy[i+1] = pixels[i+1];
        fb_copy[i+2] = pixels[i];
        fb_copy[i+3] = 255;
    }
    const byte_time = timer.read();

    timer.reset();

    // Fast 32-bit swap approach
    const src_u32: [*]const u32 = @ptrCast(@alignCast(pixels.ptr));
    const dst_u32: [*]u32 = @ptrCast(@alignCast(fb_copy.ptr));
    
    for (0..num_pixels) |idx| {
        const p = src_u32[idx];
        // B G R A (VNC) -> R G B A
        // Little endian u32: A is msb, B is lsb
        // Actually VNC is usually uint8_t [B, G, R, A]
        // Memory layout: [B, G, R, A]
        // u32 little endian: A=FF000000, R=00FF0000, G=0000FF00, B=000000FF
        // We want memory layout: [R, G, B, 255]
        dst_u32[idx] = ((p & 0x00FF0000) >> 16) | (p & 0x0000FF00) | ((p & 0x000000FF) << 16) | 0xFF000000;
    }
    const word_time = timer.read();

    std.debug.print("Byte-by-byte: {} ns\n", .{byte_time});
    std.debug.print("Word-by-word: {} ns\n", .{word_time});
    std.debug.print("Speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(byte_time)) / @as(f64, @floatFromInt(word_time))});
}
