const std = @import("std");

pub fn build(b: *std.Build) !void {
    if (comptime !std.mem.eql(u8, @import("builtin").zig_version_string, @import("build.zig.zon").minimum_zig_version)) @compileError("Use the Zig version declared in build.zig.zon");
    const local_global_cache = b.pathFromRoot(".zig-cache/global");
    const local_global_cache_dir = try std.Io.Dir.cwd().createDirPathOpen(b.graph.io, local_global_cache, .{});
    b.graph.global_cache_root = .{
        .path = local_global_cache,
        .handle = local_global_cache_dir,
    };

    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
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
    const install_webui_app = b.addInstallArtifact(webui_app, .{});
    b.getInstallStep().dependOn(&install_webui_app.step);

    const webui_run = b.step("webui", "Run webui desktop app");
    const webui_run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "hangar-webui")});
    webui_run_cmd.step.dependOn(&install_webui_app.step);
    webui_run.dependOn(&webui_run_cmd.step);

    // ── Web Backend ──
    const web_mod = b.createModule(.{ .root_source_file = b.path("src/web_server.zig"), .target = target, .optimize = optimize });

    web_mod.link_libc = true;
    web_mod.linkSystemLibrary("libvncclient", .{});
    const web_exe = b.addExecutable(.{ .name = "hangar-web", .root_module = web_mod, .use_llvm = true, .use_lld = true });
    const install_web_exe = b.addInstallArtifact(web_exe, .{});
    b.getInstallStep().dependOn(&install_web_exe.step);

    const web_run = b.step("web", "Run web frontend");
    const web_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "hangar-web")});
    web_cmd.step.dependOn(&install_web_exe.step);
    web_run.dependOn(&web_cmd.step);

    // ── vmrun CLI ──
    const vmrun_mod = b.createModule(.{ .root_source_file = b.path("src/vmrun.zig"), .target = target, .optimize = optimize });
    vmrun_mod.link_libc = true;
    const vmrun_exe = b.addExecutable(.{ .name = "vmrun", .root_module = vmrun_mod, .use_llvm = true, .use_lld = true });
    for ([_]*std.Build.Step.Compile{ webui_app, web_exe, vmrun_exe }) |exe| exe.pie = true;
    const install_vmrun_exe = b.addInstallArtifact(vmrun_exe, .{});
    b.getInstallStep().dependOn(&install_vmrun_exe.step);

    // ── Unit tests ──
    const test_step = b.step("test", "Run the hermetic unit + fuzz test suite");
    const test_mods = [_][]const u8{ "vm", "persist", "qmp", "qemu", "vnet", "fbmath", "snapparse", "ovf", "autoprotect", "sync", "usock", "appio", "transport", "ws", "web_server", "vmrun", "urlencode", "vnc_client", "hv_qemu_backend_test", "hv_interface_test", "form_parsers", "path_helpers", "appstate", "appstate_test", "catalog", "framebuffer", "httpreq", "wlog", "snapshots", "migrate", "disk", "cdrom", "guestagent", "httpresp", "streams", "auth", "netutil", "wsproxy", "vmrender", "webui_app", "dbusdisplay", "hostinfo" };
    for (test_mods) |mod| {
        const src_path = b.fmt("src/{s}.zig", .{mod});
        const tm = b.createModule(.{ .root_source_file = b.path(src_path), .target = target, .optimize = optimize });
        tm.link_libc = true;
        if (std.mem.eql(u8, mod, "vnc_client") or std.mem.eql(u8, mod, "framebuffer") or std.mem.eql(u8, mod, "web_server")) {
            tm.linkSystemLibrary("libvncclient", .{});
        }
        if (std.mem.eql(u8, mod, "webui_app")) {
            tm.addImport("webui", webui_mod);
        }
        const tests = b.addTest(.{ .root_module = tm, .use_llvm = true, .use_lld = true });
        const run_tests = b.addRunArtifact(tests);
        const module_test = b.step(b.fmt("test-unit-{s}", .{mod}), b.fmt("Run {s} module tests (including imported tests)", .{mod}));
        module_test.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }
    // HV interface tests: compiled via wrapper at src/ so that
    // @import("../vm.zig") inside hv/interface.zig resolves within
    // the module root (src/).
    // Already covered by hv_interface_test in test_mods above.

    // ── Web UI E2E tests (Playwright) ──
    // Per AGENTS.md, every user-facing workflow has a Playwright e2e test in
    // tests/e2e. Playwright launches the built binary itself (see
    // playwright.config.mjs); we only need the binary installed first. Requires
    // `bun install` and `bun run e2e:install` (Chromium) to have been run once.
    // Standalone (not in the umbrella `test` step): Playwright needs `bun
    // install` + a downloaded Chromium, so depending on it would make the
    // canonical `zig build test` non-hermetic and fail on a clean checkout. Keep
    // `zig build test` to the hermetic unit + fuzz suite; run e2e explicitly.
    const web_e2e = b.step("web-e2e", "Web UI end-to-end tests (Playwright)");
    const web_e2e_cmd = b.addSystemCommand(&.{ "bun", "./node_modules/@playwright/test/cli.js", "test" });
    web_e2e_cmd.step.dependOn(&install_web_exe.step);
    web_e2e.dependOn(&web_e2e_cmd.step);

    // ── Shell integration tests (standalone; not in the umbrella) ──
    // They spawn a real daemon on a temp port + $HOME and exercise the HTTP API
    // and the vmrun CLI end to end. Kept out of `test` so the umbrella stays
    // fast/deterministic, but exposed as build steps so they don't rot.
    const api_test = b.step("test-api", "HTTP API integration test (tests/test_web_api.sh)");
    const api_cmd = b.addSystemCommand(&.{ "bash", "tests/test_web_api.sh" });
    api_cmd.step.dependOn(&install_web_exe.step);
    api_test.dependOn(&api_cmd.step);

    const vmrun_test = b.step("test-vmrun", "vmrun CLI integration test (tests/test_vmrun.sh)");
    const vmrun_cmd = b.addSystemCommand(&.{ "bash", "tests/test_vmrun.sh" });
    vmrun_cmd.step.dependOn(&install_web_exe.step);
    vmrun_test.dependOn(&vmrun_cmd.step);

    // ── Static analysis (also enforced as blocking CI steps) ──
    // fmt-check / lint-* scope to git-tracked files so vendored code (zig-pkg/,
    // src/web bundles) and scratch trees are never formatted or flagged.
    const fmt_check = b.step("fmt-check", "Check formatting of tracked Zig sources (zig fmt)");
    const fmt_cmd = b.addSystemCommand(&.{
        "bash", "-euo", "pipefail", "-c", "git ls-files -z '*.zig' '*.zon' | xargs -0 \"$1\" fmt --check", "fmt-check", b.graph.zig_exe,
    });
    fmt_check.dependOn(&fmt_cmd.step);

    const lint_shell = b.step("lint-shell", "Lint shell scripts (shellcheck)");
    // Same git-tracked scoping as fmt-check: a newly added .sh is covered
    // automatically instead of silently falling outside a hardcoded list.
    const lint_shell_cmd = b.addSystemCommand(&.{
        "bash", "-euo", "pipefail", "-c", "git ls-files -z '*.sh' | xargs -0 shellcheck --enable=add-default-case,avoid-negated-conditions,avoid-nullary-conditions,check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase,deprecate-which,quote-safe-variables,useless-use-of-cat",
    });
    lint_shell.dependOn(&lint_shell_cmd.step);

    // Syntax gate over hand-written JS (app.js is @embedFile'd raw, so the exe
    // builds fine even when it does not parse). Excludes the vendored bundles
    // listed in src/web/AGENTS.md; any new non-vendored file is covered.
    const lint_js = b.step("lint-js", "Syntax-check hand-written JS (bun build)");
    const lint_js_cmd = b.addSystemCommand(&.{
        "bash", "-euo", "pipefail", "-c",
        \\git ls-files -z '*.js' '*.mjs' |
        \\grep -zvE '^src/web/(novnc|spice|elk|van|xterm(-fit|-webgl)?)\.js$' |
        \\xargs -0rn1 bun build --no-bundle >/dev/null
        \\
    });
    lint_js.dependOn(&lint_js_cmd.step);

    const cli_test = b.step("test-cli", "Check CLI help/version output and write failures without a daemon");
    for ([_]*std.Build.Step.Compile{ vmrun_exe, web_exe, webui_app }) |exe| {
        const cli_cmd = b.addSystemCommand(&.{
            "bash",     "-euo", "pipefail", "-c",
            \\for flag in --help --version; do
            \\  output=$("$1" "$flag")
            \\  test -n "$output"
            \\  for sink in full closed; do
            \\    rc=0
            \\    if [ "$sink" = full ]; then
            \\      "$1" "$flag" >/dev/full 2>/dev/null || rc=$?
            \\    else
            \\      "$1" "$flag" >&- 2>/dev/null || rc=$?
            \\    fi
            \\    test "$rc" -eq 1
            \\  done
            \\done
            ,
            "test-cli",
        });
        cli_cmd.addArtifactArg(exe);
        cli_cmd.setEnvironmentVariable("NO_COLOR", "1");
        cli_cmd.setEnvironmentVariable("TERM", "dumb");
        cli_test.dependOn(&cli_cmd.step);
    }

    const check = b.step("check", "Run CI checks (build, format, lint, unit + fuzz tests)");
    check.dependOn(cli_test);
    check.dependOn(b.getInstallStep());
    check.dependOn(fmt_check);
    check.dependOn(lint_shell);
    check.dependOn(lint_js);
    check.dependOn(test_step);
}
