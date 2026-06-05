const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── zig-webui Desktop App ──
    const zig_webui_dep = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .is_static = true,
    });
    const webui_mod = zig_webui_dep.module("webui");

    const webui_app_mod = b.createModule(.{
        .root_source_file = b.path("src/webui_app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webui", .module = webui_mod },
        },
    });
    webui_app_mod.link_libc = true;

    const webui_app = b.addExecutable(.{
        .name = "hangar-webui",
        .root_module = webui_app_mod,
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(webui_app);

    const webui_run = b.step("webui", "Run webui desktop app");
    const webui_run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "hangar-webui")});
    webui_run_cmd.step.dependOn(&webui_app.step);
    webui_run.dependOn(&webui_run_cmd.step);

    // ── Web Backend ──
    const web_mod = b.createModule(.{ .root_source_file = b.path("src/web_server.zig"), .target = target, .optimize = optimize });

    web_mod.link_libc = true;
    web_mod.linkSystemLibrary("libvncclient", .{});
    web_mod.linkSystemLibrary("spice-client-glib-2.0", .{});
    web_mod.linkSystemLibrary("gio-2.0", .{});
    web_mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    const web_exe = b.addExecutable(.{ .name = "hangar-web", .root_module = web_mod, .use_llvm = true, .use_lld = true });
    b.installArtifact(web_exe);

    const web_run = b.step("web", "Run web frontend");
    const web_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "hangar-web")});
    web_cmd.step.dependOn(&web_exe.step);
    web_run.dependOn(&web_cmd.step);

    // ── vmrun CLI ──
    const vmrun_mod = b.createModule(.{ .root_source_file = b.path("src/vmrun.zig"), .target = target, .optimize = optimize });
    vmrun_mod.link_libc = true;
    const vmrun_exe = b.addExecutable(.{ .name = "vmrun", .root_module = vmrun_mod, .use_llvm = true, .use_lld = true });
    b.installArtifact(vmrun_exe);

    // ── Unit tests ──
    const test_step = b.step("test", "Run unit tests");
    const test_mods = [_][]const u8{ "vm", "persist", "qmp", "qemu", "vnet", "fbmath", "ringbuf", "serial_console", "serialpath", "uimath", "snapparse", "termfilter", "ovf", "autoprotect", "sync", "usock", "appio", "transport", "ws", "web_server", "vmrun", "remote", "filter", "vmlist", "urlencode", "spice_client", "vnc_client", "hv_qemu_backend_test", "hv_interface_test", "form_parsers", "path_helpers", "vnet_label", "appstate", "appstate_test", "webui_app" };
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
        if (std.mem.eql(u8, mod, "webui_app")) {
            tm.addImport("webui", webui_mod);
        }
        const tests = b.addTest(.{ .root_module = tm, .use_llvm = true, .use_lld = true });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
    // HV interface tests — compiled via wrapper at src/ so that
    // @import("../vm.zig") inside hv/interface.zig resolves within
    // the module root (src/).
    // Already covered by hv_interface_test in test_mods above.

    // ── Web UI E2E smoke test (Xvfb + Node/Puppeteer) ──
    const web_smoke = b.step("web-smoke", "Web UI end-to-end smoke test");
    web_smoke.dependOn(&web_exe.step);
    const web_smoke_cmd = b.addSystemCommand(&.{ "node", "tests/web_smoke.mjs" });
    web_smoke.dependOn(&web_smoke_cmd.step);

    // ── Include web-smoke in the umbrella test step ──
    test_step.dependOn(&web_smoke_cmd.step);
}
