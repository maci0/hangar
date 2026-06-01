// SPDX-License-Identifier: MIT
//! VNC/SPICE framebuffer display rendering for the FLTK frontend.
//!
//! Polls the active VNC or SPICE client for dirty framebuffer pixels,
//! copies + converts BGRA→RGBA, wraps an Fl_RGB_Image, and attaches
//! it to the display box widget.

const std = @import("std");
const fbmath = @import("fbmath.zig");
const app = @import("appstate.zig");
const display_gl = @import("display_gl.zig");
const cfltk = @import("cfltk_import.zig").c;

/// Previous framebuffer image — freed before creating a new one to avoid
/// the ~500 MB/min leak from unreleased Fl_RGB_Image objects.
var prev_img: ?*cfltk.Fl_RGB_Image = null;

/// Polling callback (100 ms). Reads the VNC or SPICE framebuffer,
/// renders it via GPU (OpenGL) if available, falling back to software.
pub fn displayTimerCB(_: ?*anyopaque) callconv(.c) void {
    if (app.modal_active) { _ = cfltk.Fl_repeat_timeout(0.1, displayTimerCB, null); return; }
    if (app.gl_display != null) {
        // GL path: render directly to the Fl_Gl_Window
        if (app.vnc_client) |vc| {
            if (vc.checkDirty()) {
                if (vc.lockFb()) |fb| {
                    defer vc.unlockFb();
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (vc.getSize(&fw, &fh)) {
                        display_gl.renderGL(fb, fw, fh);
                    }
                }
            }
        } else if (app.spice_client) |sc| {
            if (sc.checkDirty()) {
                if (sc.lockFb()) |fb| {
                    defer sc.unlockFb();
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (sc.getSize(&fw, &fh)) {
                        display_gl.renderGL(fb, fw, fh);
                    }
                }
            }
        }
    } else if (app.display_box) |db| {
        // Software path: BGRA→RGBA + Fl_RGB_Image
        const box_w = cfltk.Fl_Box_width(db);
        const box_h = cfltk.Fl_Box_height(db);
        if (app.vnc_client) |vc| {
            if (vc.checkDirty()) {
                if (vc.lockFb()) |fb| {
                    defer vc.unlockFb();
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (vc.getSize(&fw, &fh)) {
                        renderFramebuffer(db, fb, fw, fh, 0, box_w, box_h);
                    }
                }
            }
        } else if (app.spice_client) |sc| {
            if (sc.checkDirty()) {
                if (sc.lockFb()) |fb| {
                    defer sc.unlockFb();
                    var fw: c_int = 0;
                    var fh: c_int = 0;
                    if (sc.getSize(&fw, &fh)) {
                        renderFramebuffer(db, fb, fw, fh, sc.stride, box_w, box_h);
                    }
                }
            }
        }
    }
    _ = cfltk.Fl_repeat_timeout(0.1, displayTimerCB, null);
}

/// Copy+swap a BGRA framebuffer to RGBA, wrap in an Fl_RGB_Image,
/// scale to fit the display box, and attach it.
pub fn renderFramebuffer(
    db: *cfltk.Fl_Box,
    fb: [*]const u8,
    fw: c_int,
    fh: c_int,
    src_stride: c_int,
    box_w: c_int,
    box_h: c_int,
) void {
    const px = fbmath.fbFits(fw, fh, std.math.maxInt(usize) / 4) orelse return;
    const buf_size: usize = px * 4;
    const stride: usize = if (src_stride > 0) @intCast(src_stride) else @as(usize, @intCast(fw)) * 4;

    const rgba = std.heap.c_allocator.alloc(u8, buf_size) catch return;
    defer std.heap.c_allocator.free(rgba);

    const dst_stride: usize = @as(usize, @intCast(fw)) * 4;
    const src_slice: []const u8 = fb[0 .. @as(usize, @intCast(fh)) * stride];
    fbmath.bgraToRgba(rgba, src_slice, @intCast(fw), @intCast(fh), stride, dst_stride);

    // Copy the pixel data (Ld=1) so FLTK owns its own buffer — avoids
    // use-after-free when we release `rgba` below.
    const img = cfltk.Fl_RGB_Image_new(@ptrCast(rgba.ptr), fw, fh, 4, 1);
    if (img == null) return;

    if (fw > box_w or fh > box_h) {
        cfltk.Fl_RGB_Image_scale(img, box_w, box_h, 1, 0);
    }

    // Free the previous image before attaching a new one.
    if (prev_img) |old| {
        cfltk.Fl_RGB_Image_delete(old);
        prev_img = null;
    }

    cfltk.Fl_Box_set_label(db, "");
    cfltk.Fl_Box_set_image(db, @ptrCast(img));
    cfltk.Fl_Box_redraw(db);
    prev_img = img;
}

/// Clear the display box — release any image and restore placeholder text.
pub fn clearDisplay() void {
    display_gl.hideGL();
    if (prev_img) |old| {
        cfltk.Fl_RGB_Image_delete(old);
        prev_img = null;
    }
    if (app.display_box) |db| {
        cfltk.Fl_Box_set_image(db, null);
        cfltk.Fl_Box_set_label(db, "▸ Power on a VM to start display\n▸ VNC and SPICE displays appear here");
        cfltk.Fl_Box_set_align(db, 16 | 5); // FL_ALIGN_INSIDE | FL_ALIGN_CENTER
        cfltk.Fl_Box_redraw(db);
    }
}
