//! FLTK build for KVMGUI.
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the FLTK-based KVMGUI executable.
    const exe = b.addExecutable(.{
        .name = "kvmgui-fltk",
        .root_source_file = b.path("src/test_fltk.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.link_libc = true;
    exe.link_libcpp = true;

    // zfltk module from vendored source.
    const zfltk_mod = b.addModule("zfltk", .{
        .root_source_file = b.path("deps/zfltk/src/zfltk.zig"),
        .target = target,
        .optimize = optimize,
    });
    zfltk_mod.link_libc = true;
    zfltk_mod.link_libcpp = true;

    // Link cfltk and fltk
    zfltk_mod.addIncludePath(b.path("deps/cfltk/include"));
    zfltk_mod.addIncludePath(b.path("/usr/local/include"));
    zfltk_mod.addObjectFile(b.path("deps/cfltk/build_manual/libcfltk.a"));
    zfltk_mod.addObjectFile(b.path("/usr/lib/libfltk.a"));
    zfltk_mod.addObjectFile(b.path("/usr/lib/libfltk_images.a"));
    zfltk_mod.addObjectFile(b.path("/usr/lib/libfltk_png.a"));
    zfltk_mod.addObjectFile(b.path("/usr/lib/libfltk_jpeg.a"));
    zfltk_mod.addObjectFile(b.path("/usr/lib/libfltk_z.a"));

    // Link X11 and system libs
    zfltk_mod.linkSystemLibrary("X11", .{});
    zfltk_mod.linkSystemLibrary("Xext", .{});
    zfltk_mod.linkSystemLibrary("Xinerama", .{});
    zfltk_mod.linkSystemLibrary("Xcursor", .{});
    zfltk_mod.linkSystemLibrary("Xrender", .{});
    zfltk_mod.linkSystemLibrary("Xfixes", .{});
    zfltk_mod.linkSystemLibrary("Xft", .{});
    zfltk_mod.linkSystemLibrary("fontconfig", .{});
    zfltk_mod.linkSystemLibrary("pango-1.0", .{});
    zfltk_mod.linkSystemLibrary("pangoxft-1.0", .{});
    zfltk_mod.linkSystemLibrary("pangocairo-1.0", .{});
    zfltk_mod.linkSystemLibrary("cairo", .{});
    zfltk_mod.linkSystemLibrary("gobject-2.0", .{});
    zfltk_mod.linkSystemLibrary("glib-2.0", .{});
    zfltk_mod.linkSystemLibrary("harfbuzz", .{});
    zfltk_mod.linkSystemLibrary("freetype", .{});
    zfltk_mod.linkSystemLibrary("wayland-client", .{});
    zfltk_mod.linkSystemLibrary("wayland-cursor", .{});
    zfltk_mod.linkSystemLibrary("xkbcommon", .{});
    zfltk_mod.linkSystemLibrary("dbus-1", .{});
    zfltk_mod.linkSystemLibrary("dl", .{});
    zfltk_mod.linkSystemLibrary("pthread", .{});

    exe.root_module.addImport("zfltk", zfltk_mod);

    b.installArtifact(exe);
}
