const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── FLTK Frontend ──
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.link_libc = true;
    exe_mod.link_libcpp = true;
    exe_mod.linkSystemLibrary("libvncclient", .{});
    exe_mod.linkSystemLibrary("spice-client-glib-2.0", .{});
    exe_mod.addIncludePath(b.path("deps/cfltk/include"));
    exe_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe_mod.addObjectFile(.{ .cwd_relative = "deps/cfltk/build_manual/libcfltk.a" });
    exe_mod.addObjectFile(.{ .cwd_relative = "/usr/lib/libfltk_images.a" });
    exe_mod.addObjectFile(.{ .cwd_relative = "/usr/lib/libfltk.a" });
    for ([_][]const u8{ "jpeg", "png", "z", "X11", "Xext", "Xinerama", "Xcursor", "Xrender", "Xfixes", "Xft", "fontconfig", "pango-1.0", "pangoxft-1.0", "pangoft2-1.0", "pangocairo-1.0", "cairo", "gobject-2.0", "glib-2.0", "harfbuzz", "freetype", "wayland-client", "wayland-cursor", "xkbcommon", "dbus-1", "decor-0", "dl", "pthread" }) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }

    const exe_obj = b.addObject(.{ .name = "kvmgui", .root_module = exe_mod });
    const cxx = b.findProgram(&.{"c++"}, &.{}) catch "c++";
    const exe_link = b.addSystemCommand(&.{cxx});
    exe_link.addArtifactArg(exe_obj);
    exe_link.addArg("deps/cfltk/build_manual/libcfltk.a");
    exe_link.addArg("-lfltk_images");
    exe_link.addArg("-lfltk");
    exe_link.addArgs(&.{ "-lX11", "-lXext", "-lXinerama", "-lXcursor", "-lXrender", "-lXfixes", "-lXft", "-lfontconfig", "-lpango-1.0", "-lpangoxft-1.0", "-lpangoft2-1.0", "-lpangocairo-1.0", "-lcairo", "-lgobject-2.0", "-lglib-2.0", "-lharfbuzz", "-lfreetype", "-lwayland-client", "-lwayland-cursor", "-lxkbcommon", "-ldbus-1", "-ldecor-0", "-ldl", "-lpthread", "-lm", "-ljpeg", "-lpng", "-lz", "-lvncclient", "-lspice-client-glib-2.0", "-lgio-2.0", "-lfltk_gl", "-lGL" });
    const exe_output = exe_link.addPrefixedOutputFileArg("-o", "kvmgui");
    const exe_install = b.addInstallBinFile(exe_output, "kvmgui");
    b.getInstallStep().dependOn(&exe_install.step);

    const run = b.step("run", "Run kvmgui");
    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "kvmgui")});
    run_cmd.step.dependOn(&exe_install.step);
    run.dependOn(&run_cmd.step);

    // ── Web Backend ──
    const web_mod = b.createModule(.{ .root_source_file = b.path("src/web_server.zig"), .target = target, .optimize = optimize });

    web_mod.link_libc = true;
    web_mod.linkSystemLibrary("libvncclient", .{});
    web_mod.linkSystemLibrary("spice-client-glib-2.0", .{});
    web_mod.linkSystemLibrary("gio-2.0", .{});
    web_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    const web_exe = b.addExecutable(.{ .name = "kvmgui-web", .root_module = web_mod, .use_llvm = true, .use_lld = true });
    b.installArtifact(web_exe);

    const web_run = b.step("web", "Run web frontend");
    const web_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "kvmgui-web")});
    web_cmd.step.dependOn(&web_exe.step);
    web_run.dependOn(&web_cmd.step);

    // ── vmrun CLI ──
    const vmrun_mod = b.createModule(.{ .root_source_file = b.path("src/vmrun.zig"), .target = target, .optimize = optimize });
    vmrun_mod.link_libc = true;
    const vmrun_exe = b.addExecutable(.{ .name = "vmrun", .root_module = vmrun_mod, .use_llvm = true, .use_lld = true });
    b.installArtifact(vmrun_exe);

    // ── Unit tests ──
    const test_step = b.step("test", "Run unit tests");
    const test_mods = [_][]const u8{ "vm", "persist", "qmp", "qemu", "vnet", "fbmath", "ringbuf", "serialpath", "uimath", "snapparse", "termfilter", "ovf", "autoprotect", "sync", "usock", "appio", "transport", "ws", "web_server", "vmrun", "remote", "filter", "vmlist", "urlencode", "spice_client", "vnc_client", "hv_qemu_backend_test", "hv_interface_test", "form_parsers", "path_helpers", "vnet_label" };
    for (test_mods) |mod| {
        const src_path = b.fmt("src/{s}.zig", .{mod});
        const tm = b.createModule(.{ .root_source_file = b.path(src_path), .target = target, .optimize = optimize });
        tm.link_libc = true;
        if (std.mem.eql(u8, mod, "spice_client")) {
            tm.linkSystemLibrary("spice-client-glib-2.0", .{});
            tm.linkSystemLibrary("gio-2.0", .{});
            tm.linkSystemLibrary("gobject-2.0", .{});
            tm.linkSystemLibrary("glib-2.0", .{});
        }
        if (std.mem.eql(u8, mod, "vnc_client")) {
            tm.linkSystemLibrary("libvncclient", .{});
        }
        const tests = b.addTest(.{ .root_module = tm, .use_llvm = true, .use_lld = true });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
    // HV interface tests — compiled via wrapper at src/ so that
    // @import("../vm.zig") inside hv/interface.zig resolves within
    // the module root (src/).
    // Already covered by hv_interface_test in test_mods above.

    // ── GUI smoke/fuzz test steps ──
    const smoke = b.step("smoke", "Run GUI smoke test (Xvfb)");
    smoke.dependOn(&exe_install.step);
    const smoke_cmd = b.addSystemCommand(&.{ "bash", "tests/smoke_gui.sh" });
    smoke.dependOn(&smoke_cmd.step);

    const fuzzgui = b.step("fuzzgui", "Run GUI fuzz test (Xvfb)");
    fuzzgui.dependOn(&exe_install.step);
    const fuzzgui_cmd = b.addSystemCommand(&.{ "bash", "tests/fuzz_gui.sh" });
    fuzzgui.dependOn(&fuzzgui_cmd.step);

    const fuzzmodals = b.step("fuzzmodals", "Run modal fuzz test (Xvfb)");
    fuzzmodals.dependOn(&exe_install.step);
    const fuzzmodals_cmd = b.addSystemCommand(&.{ "bash", "tests/fuzz_modals.sh" });
    fuzzmodals.dependOn(&fuzzmodals_cmd.step);
}
