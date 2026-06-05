# AGENTS.md — Hangar

Lightweight QEMU VM manager with a web UI and optional native WebView wrapper.
Zig 0.16.0. No libvirt dependency.

## Build / Run / Test Commands

```bash
zig build web          # Build + launch web backend (HTTP on :9080)
zig build webui        # Build + launch native WebView desktop wrapper
zig build test         # Run ALL unit + fuzz tests (34 modules + HV)
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

## Architecture Overview

```
src/
  web_server.zig    Standalone HTTP daemon with embedded HTML/CSS/JS UI (port 9080)
  webui_app.zig     Native WebView desktop wrapper (zig-webui) that spawns hangar-web
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
  hv/
    interface.zig   Hypervisor abstraction interface (Vmm dispatch table)
    qemu_backend.zig  QEMU backend implementing the Vmm interface
  web/
    index.html      Single-page web UI (embedded in web_server.zig)
    app.js          Web frontend logic (VM management, theme, display, console)
    app.css         Web UI stylesheet (light + dark theme CSS variables)

Shared state: appstate.zig (VM arrays, mutex, serial state, remote mode).
```

### Frontend: Web UI (port 9080)

- Single-page HTML app with CSS custom properties for light/dark theming.
- All VM operations via REST API + WebSocket (framebuffer streaming).
- The `webui_app.zig` native wrapper uses zig-webui to open a desktop window
  showing the same web UI — no frontend changes needed.

### Global state (no App struct)

State is stored as flat module-level globals in `appstate.zig`:
- `vms: [MAX_VMS]vm.VmConfig` — fixed array of 64 VM configs
- `vm_count`, `prefs` — session state
- `g_vmm: hv_iface.Vmm`, `g_vmm_handles` — hypervisor dispatch table
- `remote_mode`, `remote_url`, `remote_url_len` — remote client mode
- `serial_*` — serial console ring buffer and reader thread state
- `undo_vm`, `undo_idx`, `undo_available` — delete undo support
- `vms_mutex` — protects the VM array

There is no `App` struct. State lives in `appstate.zig` globals, shared
by `web_server.zig`, `persist.zig`, `serial_console.zig`, `remote.zig`,
and `vnet.zig`.

### Remote client/daemon mode

`web_server.zig` serves as both local backend and remote daemon:
- `transport.zig`: URL parsing, TCP/Unix/SHM connection, HTTP request helpers
- `remote.zig`: remote client mode that fetches VM state via HTTP from a
  remote `web_server.zig` instance
- `vmrun.zig`: CLI wrapper for remote operations

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
- **Test artifacts** (`zig build test`): use `use_llvm = true` + `use_lld = true`
  because the self-hosted backend/linker can't relocate `.sframe` in GCC's crt1.o.
- **Web backend** (`hangar-web`): also uses `use_llvm = true, use_lld = true`.
- **WebUI app** (`hangar-webui`): uses `use_llvm = true, use_lld = true`.

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
- `std` first, then local files.
- Local imports use string literal paths: `@import("vm.zig")`.

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
- Use `catch return` for non-critical failures.
- Use `catch {}` only for persistence saves where failure is acceptable.

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
- Save path: `~/.config/hangar/vms.json`
- Enum fields stored as QEMU CLI strings (e.g. `"qcow2"`, `"gtk"`, `"user"`).
- Runtime state (`status`, `pid`) is never persisted.
- When adding new fields to VmConfig, also update: `VmJson` struct,
  `emitVmJson`, `fromVmJson` / `parseVmObject`, and add parser tests.
