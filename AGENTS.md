# AGENTS.md — KVMGUI

Lightweight QEMU VM manager with a VMware Workstation-style GUI.
Zig 0.16.0 + FLTK 1.4 (via cfltk C bindings). No libvirt dependency.

## Build / Run / Test Commands

```bash
zig build              # Compile FLTK frontend -> zig-out/bin/kvmgui
zig build run          # Build + launch the FLTK GUI
zig build web          # Build + launch web backend (HTTP on :9080)
zig build test         # Run ALL unit + fuzz tests (29 modules + HV)
zig build smoke        # Xvfb GUI smoke test (create + settings + about)
zig build fuzzgui      # Xvfb random event-storm fuzz
zig build fuzzmodals   # Xvfb direct-fuzz modal callbacks
```

### Running a single test file

Each test module is registered separately in `build.zig`. To run only one
module's tests, temporarily comment out the other `test_step.dependOn(...)`
lines, or run the test binary directly. The modules reach `std.c`, so the
direct invocation needs `-lc` plus the LLVM backend/LLD (see "Build link step"):

```bash
zig test src/vm.zig      -lc -fllvm -flld
zig test src/qmp.zig     -lc -fllvm -flld
zig test src/persist.zig -lc -fllvm -flld
zig test src/transport.zig -lc -fllvm -flld
```

### Running the FLTK GUI under Xvfb (headless)

The FLTK GUI requires a running X server:

```bash
Xvfb :99 -screen 0 1280x800x24 -ac &
DISPLAY=:99 ./zig-out/bin/kvmgui &
```

## Architecture Overview

```
src/
  main.zig          FLTK frontend — all GUI, callbacks, dialogs (monolith)
  web_server.zig    Standalone HTTP daemon with embedded HTML/CSS/JS UI (port 9080)
  vm.zig            VM config model, enums (DiskFormat, GuestOs, VmStatus, ...)
  vnet.zig          Virtual switch model (VMnet0..N: type/subnet/DHCP) + own JSON store
  qemu.zig          QEMU/qemu-img process spawn (fork+execvp), disk image create
  qmp.zig           QMP client: pause/resume/powerdown/reset/snapshots/sendkey
  persist.zig       JSON save/load with hand-rolled parser (no std.json)
  vnc_client.zig    libvncclient wrapper (@cImport rfb headers + poll thread)
  spice_client.zig  spice-client-glib wrapper (hand-written extern decls)
  ws.zig            WebSocket implementation (upgrade, frame read/write)
  usock.zig         Blocking AF_UNIX socket (libc) — replaces std.net
  appio.zig         Global std.Io instance + getenv/sleepMs helpers
  sync.zig          SpinMutex — replaces std.Thread.Mutex
  ringbuf.zig       Ring buffer for serial console
  termfilter.zig    Terminal output sanitization
  fbmath.zig        Framebuffer geometry math (fbFits)
  uimath.zig        UI math helpers (coordinate mapping, mem-bar, socket paths)
  snapparse.zig     Snapshot table parser (QMP + HMP variants)
  ovf.zig           OVF descriptor builder
  autoprotect.zig   AutoProtect snapshot scheduling logic
  transport.zig     Transport abstraction (Unix/TCP/SHM) for client↔daemon
  vmrun.zig         CLI tool for remote VM management (vmrun list/start/stop/...)
  dialogs.zig       Modal dialogs: prefs, VNet editor, about, OVF export, remote connect
  display.zig       VNC/SPICE framebuffer rendering onto FLTK Fl_RGB_Image (Display tab)
  hv/
    interface.zig   Hypervisor abstraction interface (Vmm dispatch table)
    qemu_backend.zig  QEMU backend implementing the Vmm interface

GUI toolkit: FLTK 1.4 via cfltk C bindings (@cImport of 12 cfltk headers).
build.zig       Links cfltk static lib + libfltk.a via system c++.
deps/cfltk/     Vendored cfltk C wrapper + prebuilt libcfltk.a.
```

### GUI toolkit: FLTK (not IUP)

- Widgets imported via `@cImport` of `cfltk/cfl.h` and 11 other cfltk headers.
- **Layout**: absolute pixel positioning — every widget has `(x, y, w, h)`.
- **Callbacks**: `callconv(.c) void` — FLTK callbacks are void, not `c_int`.
- **Dialogs**: stack-allocated anonymous structs with a static `go` method;
  closed via `Fl_Window_hide`, not destroyed. No dual-open guard needed.
- **No theming system**: single `Fl_set_scheme("gtk+")` call instead of
  IUP palettes / GTK CSS providers / `ta()` helper.
- **No icon system**: `icons.zig` does not exist in the FLTK version.
- **Display**: `Fl_RGB_Image` with BGRA→RGBA pixel swap (not `IupDrawImage`).
- **Tabs**: `Fl_Tabs` + `Fl_Group` for Summary / Display / Console tabs.
- **VM list**: `Fl_Browser` with favorites sorted first (star prefix).
- **Status bar**: `Fl_Box` at window bottom.

### Global state (no App struct)

State is stored as flat module-level globals in `main.zig`:
- `vms: [MAX_VMS]vm.VmConfig` — fixed array of 64 VM configs
- `vm_count`, `selected_idx`, `prefs` — session state
- `browser`, `status_bar`, `detail_labels[12]`, `win_handle` — widget handles
- `g_vmm: hv_iface.Vmm`, `g_vmm_handles` — hypervisor dispatch table
- `remote_mode`, `remote_url_buf`, `remote_auth_buf` — remote client mode

There is no `App` struct. The old IUP architecture used a ~600KB `App` struct
passed by pointer to avoid stack overflow; the FLTK port uses flat globals.

### Remote client/daemon mode

`main.zig` supports connecting to a remote `web_server.zig` instance:
- `transport.zig`: URL parsing, TCP/Unix/SHM connection, HTTP request helpers
- Many operations (`togglePower`, `suspendVm`, `newVmDialog`, `editVmDialog`,
  `cloneVm`, `importVm`) check `remote_mode` and dispatch HTTP API calls
  instead of local QEMU operations
- `apiGet()` / `apiPost()` helpers use `transport.Connection`

### HV abstraction layer

All QEMU operations go through `g_vmm.*Fn` dispatch table (`hv/interface.zig`)
when a VMM handle exists, falling back to direct `qemu.*` calls:
- Power: `powerOnFn` / `powerOffFn`
- Snapshots: `snapshotTakeFn` / `snapshotListFn` / `snapshotRevertFn` / `snapshotDeleteFn`
- Clone: `cloneFn` / `createLinkedCloneFn`
- Disk: `createDiskFn` / `convertDiskFn`

## Critical Constraints

### No `std.json`
`std.json` pulls in f128 float math that causes linker errors with the
system `cc` link step. All JSON parsing/emitting is hand-rolled in
`persist.zig`. Never import or use `std.json`.

### Build link step
- **FLTK binary** (`kvmgui`): final linking uses system `c++` to work around
  GCC 15+ `.sframe` section incompatibility.
- **Test artifacts** (`zig build test`): use `use_llvm = true` + `use_lld = true`
  because the self-hosted backend/linker can't relocate `.sframe` in GCC's crt1.o.
- **Web backend** (`kvmgui-web`): also uses `use_llvm = true, use_lld = true`.

### Zig 0.16 `std.Io` migration
0.16 routed filesystem, process, networking, and threading through the
`std.Io` interface and gutted `std.posix`. House rules:
- Filesystem: `std.Io.Dir.cwd().<op>(appio.io(), ...)` — never `std.fs.cwd()`.
- Unix sockets: `usock.UnixStream` (libc-backed) — `std.net` is gone.
- Mutex: `sync.SpinMutex` — `std.Thread.Mutex` is gone.
- `getenv` / sleep / monotonic clock: `appio.getenv` / `appio.sleepMs` /
  `std.c.clock_gettime` — `std.posix.getenv` / `std.Thread.sleep` /
  `std.time.milliTimestamp` are gone.
- Process spawn: `qemu.forkExec` / `qemu.runWait` (manual `fork`+`execvp`).
  Do NOT use `std.process.spawn` — its `Io` carries an empty environment,
  which strips `DISPLAY`/`XDG_RUNTIME_DIR`/`HOME` and breaks QEMU's GTK display.

### No glib `@cImport`
Zig 0.16's C importer (aro) rejects GLib headers — they emit file-scope
`_Pragma("GCC diagnostic ...")`. `spice_client.zig` declares the handful of
GLib/SPICE symbols it needs by hand (`extern fn` + opaque types) instead of
`@cImport`. The rfb (VNC) headers import fine.

## Code Style

### Language: Zig 0.16.0
- Use `zig fmt` conventions (4-space indent, no tabs).
- All source files use `//!` doc comments at the top describing the module.
- Functions use `///` doc comments. Keep them concise (1-3 lines).

### Imports
- `std` first, then cfltk `@cImport`, then local files.
- Local imports use string literal paths: `@import("vm.zig")`.
- cfltk is reached via `@cImport` (no Zig module wrapper):

```zig
const std = @import("std");

const cfltk = @cImport({
    @cInclude("cfltk/cfl.h");
    @cInclude("cfltk/cfl_window.h");
    @cInclude("cfltk/cfl_button.h");
    @cInclude("cfltk/cfl_box.h");
    @cInclude("cfltk/cfl_group.h");
    @cInclude("cfltk/cfl_input.h");
    @cInclude("cfltk/cfl_menu.h");
    @cInclude("cfltk/cfl_browser.h");
    @cInclude("cfltk/cfl_tree.h");
    @cInclude("cfltk/cfl_text.h");
    @cInclude("cfltk/cfl_misc.h");
    @cInclude("cfltk/cfl_valuator.h");
});

const vm = @import("vm.zig");
const qmp = @import("qmp.zig");
```

### Naming
- Types/structs: `PascalCase` (`VmConfig`, `QmpClient`, `DiskFormat`)
- Functions: `camelCase` (`startVm`, `saveSnapshot`, `refreshDetails`)
- Constants: `SCREAMING_SNAKE` for hard limits (`MAX_VMS`, `MAX_NAME`, `MAX_PATH`)
- Constants: `snake_case` for source lists and config values
- Enum variants: `snake_case` (`qcow2`, `user`, `running`)
- File names: `snake_case.zig`

### Enum pattern
Every enum in `vm.zig` follows the same API surface. When adding a new
enum, replicate this pattern exactly:

```zig
pub const MyEnum = enum(u8) {
    variant_a = 0,
    variant_b = 1,

    pub const count: usize = @typeInfo(@This()).@"enum".fields.len;

    pub fn toIndex(self: MyEnum) usize {
        return @intFromEnum(self);
    }

    pub fn fromIndex(i: usize) MyEnum {
        if (i >= count) return .variant_a; // safe default
        return @enumFromInt(@as(u8, @intCast(i)));
    }

    pub fn toStr(self: MyEnum) [*:0]const u8 { ... }  // QEMU CLI value
    pub fn label(self: MyEnum) [*:0]const u8 { ... }   // UI display label
};
```

### Strings
- Fixed-size buffers for VM data (`name_buf`, `disk_path_buf`), not heap.
- C interop strings: `[*:0]const u8` (null-terminated pointers).
- Zig slices: `[]const u8` for internal logic.
- Use `std.fmt.bufPrint` / `std.fmt.bufPrintZ` for formatting into stack buffers.

### Error handling
- Functions return `!void` or `!T` for operations that can fail.
- GUI-facing errors: call `setStatus(msg)` to show in the status bar.
  Do NOT propagate errors to the user via panics or crashes.
- Use `catch return` for non-critical failures in UI callbacks.
- Use `catch {}` only for persistence saves where failure is acceptable.

### FLTK callbacks
- FLTK callbacks use C calling convention and return `void`:
  `fn onBtn(_: ?*cfltk.Fl_Widget, data: ?*anyopaque) callconv(.c) void`.
- Pass context via `data` pointer — use a stack-allocated anonymous struct
  with a static `go` method as the callback.
- Use `Fl_Widget_set_callback(widget, callback, ctx_ptr)` to wire callbacks.

### Dialog pattern (FLTK)
1. Allocate a stack struct holding every input widget pointer + VM config.
2. Create a modal window via `Fl_Window_new_wh(x, y, "Title")`.
3. Build form fields inside the window with absolute positioning.
4. Wire OK/Cancel buttons: OK reads values back, Cancel just hides.
5. Close with `Fl_Window_hide(win)`, not destroy.

### Testing
- Tests live at the bottom of each module (not in separate files).
- Use `std.testing.expectEqual` for values, `std.testing.expectEqualStrings`
  for string comparisons (with `std.mem.span()` to convert `[*:0]const u8`).
- Test names: `"TypeName: description"` (e.g. `"DiskFormat: fromIndex round-trip"`).
- Every enum needs: fromIndex round-trip, toIndex inverts fromIndex,
  toStr values, label values, out-of-range default.
- `qemu.zig` also has a test module (registered in `build.zig`) for its arg
  builder — `buildScriptStr`/`buildArgs` must never be tested via spawning.

### Fuzz tests
Deterministic PRNG harnesses (fixed seed → reproducible) that run as
ordinary `zig build test` tests. Covered surfaces: JSON parser (`persist.zig`),
`VmConfig` setters + enum `fromIndex` (`vm.zig`), QEMU arg builder (`qemu.zig`),
QMP response parser (`qmp.zig`), virtual-network store (`vnet.zig`), pure
helpers: `fbmath.fbFits`, `ringbuf.append`, `uimath`, `snapparse.parse`,
`sync.SpinMutex` (4-thread contention).
Invariants asserted: never panic, parsers only return suffix slices of their
input, writers never exceed their buffers. Keep iteration counts modest (≤8k)
so `-fllvm` test builds stay fast.

### UI terminology
Follow VMware Workstation conventions:
- "Power On" / "Power Off" (not Start/Stop)
- "Suspend" / "Resume" (not Pause/Unpause)
- "Shut Down Guest" (ACPI powerdown)
- "VM Library" (not VM list)
- "Settings" (not Edit/Configure)
- "Take Snapshot" / "Revert to Snapshot"

### Config persistence
- Save path: `~/.config/kvmgui/vms.json`
- Enum fields stored as QEMU CLI strings (e.g. `"qcow2"`, `"gtk"`, `"user"`).
- Runtime state (`status`, `pid`) is never persisted.
- When adding new fields to VmConfig, also update: `VmJson` struct,
  `emitVmJson`, `fromVmJson` / `parseVmObject`, and add parser tests.
