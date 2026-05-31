# AGENTS.md — KVMGUI

Lightweight QEMU VM manager with a VMware Workstation-style GUI.
Zig 0.16.0 + IUP (GTK3 backend on Linux). No libvirt dependency.

## Build / Run / Test Commands

```bash
zig build              # Compile everything -> zig-out/bin/kvmgui
zig build run          # Build + launch the GUI
zig build test         # Run ALL unit + fuzz tests (12 modules)
zig build itest        # Headless IUP integration (Xvfb): builds every
                       #   icon/dialog/canvas + fuzzes vnc/spice/serial
zig build cbfuzz       # Headless (Xvfb): direct-fuzz main.zig GUI callbacks
bash tests/smoke_gui.sh # Xvfb+XTEST: drives the running app (callbacks fire)
bash tests/fuzz_gui.sh  # Xvfb+XTEST: random event-storm fuzz of the GUI
bash tests/fuzz_modals.sh # Xvfb: direct-fuzz modal callbacks w/ Escape watchdog
```

See `docs/TEST-COVERAGE.md` for the per-function map across the three layers
(unit+fuzz · itest · smoke_gui). Pure logic split out of IUP/IO modules lives in
`fbmath.zig`, `ringbuf.zig`, `uimath.zig`, `snapparse.zig` so it fuzzes without a
display.

### Running a single test file

There is no built-in single-test flag. Each test module is registered
separately in `build.zig`. To run only one module's tests, temporarily
comment out the other `test_step.dependOn(...)` lines, or run the test
binary directly. The modules reach `std.c`, so the direct invocation needs
`-lc` plus the LLVM backend/LLD (see "Build link step"):

```bash
zig test src/vm.zig      -lc -fllvm -flld
zig test src/qmp.zig     -lc -fllvm -flld
zig test src/persist.zig -lc -fllvm -flld
```

### Running the GUI under Xvfb (headless)

```bash
env -u WAYLAND_DISPLAY -u GDK_BACKEND -u XDG_SESSION_TYPE \
    xvfb-run -a zig build run
```

### Screenshotting the UI (headless)

To capture the GUI for visual inspection, the GTK backend MUST be forced to
X11 — otherwise GTK connects to the host Wayland compositor and nothing
renders on the virtual X display:

```bash
Xvfb :99 -screen 0 1280x800x24 -ac &
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 DISPLAY=:99 \
    ./zig-out/bin/kvmgui &
# wait a few seconds for the window to map, then:
DISPLAY=:99 ffmpeg -f x11grab -video_size 1280x800 -i :99.0 -frames:v 1 -update 1 out.png
```

`import -window root` produced black frames here; `ffmpeg x11grab` works. A
window manager is NOT required. Inject keys/clicks with python-Xlib `xtest`
(`Control_L`+`n` triggers the `K_cN` accelerator → New VM dialog).

### Widget sizing: RASTERSIZE, not SIZE

IUP `SIZE` is in character units (≈1/4 char width), so `SIZE="800x500"`
renders a ~1190×1158 px window that spills offscreen. Always size the top-level
dialog in pixels with `RASTERSIZE`. Likewise dark GTK themes render label/button
text light: set an explicit `FGCOLOR` on labels and toolbar buttons so text
stays visible (the Summary tab uses light text to match the themed dark panel).

### Layout: GTK boxes ignore EXPAND/RASTERSIZE — use IupGridBox

On the GTK backend, `IupVbox`/`IupHbox` children stretch to fill available
space and **ignore** `EXPAND="NO"/"HORIZONTAL"` and `RASTERSIZE` on the box
(verified: such changes produce identical frames; only `BGCOLOR` etc. apply).
A nested box in the middle of a vbox therefore absorbs all slack and opens a
huge gap. Fixes that actually work:
- Build content-packed sections with **`IupGridBox`** (`NUMDIV`, `GAPLIN`,
  `EXPANDCHILDREN="HORIZONTAL"`); it sizes rows to their natural height.
- Make every element a **direct** GridBox child (no nested vbox/hbox), and
  order them so the only naturally-expanding child (e.g. a sub-grid) is **last**
  — slack then falls to the bottom instead of mid-page.
The Summary tab is one flat `IupGridBox` built exactly this way.

### Theming (System / Light / Dark)

Theme is a persisted user setting (`vm.Theme`, default **Light**), stored as a
top-level `"theme"` key in `vms.json` and switchable via **View ▸ Theme**.
`main.zig` drives it with hand-declared GTK externs (aro can't `@cImport`
GLib). Colors live in ONE place — the `pal_light`/`pal_dark` `Palette` consts;
never hardcode colors at call sites, use `active.text`/`.surface`/`.chrome`/
`.button` via the `ta()` helper.
- **System** (`apply=false`): set nothing — follow the host GTK theme. `ta()`
  becomes a no-op so widgets stay native. This is the cleanest look.
- **Light/Dark**: `setenv("GTK_THEME","Breeze",1)` before `IupOpen`, toggle
  `gtk-application-prefer-dark-theme`, and install a high-priority (`800`)
  `GtkCssProvider` from the palette's `css` — this is what defeats the
  otherwise-themed GtkNotebook page.
- GtkNotebook **tab labels** ignore the CSS — set tab colors via IUP:
  `ta(tabs, "FGCOLOR"/"BGCOLOR", ...)`.
- Plain `IupHbox`/`IupVbox` (GtkBox) stay transparent; wrap chrome strips
  (toolbar, status bar) in **`IupBackgroundBox`** (honors `BGCOLOR`) for solid
  bands.
- Load config (and thus the theme) BEFORE `IupOpen` so `GTK_THEME` can be set
  pre-`gtk_init`; call `applyTheme` right after `IupOpen`, before building UI.
- Switching live re-applies CSS (recolors most) but IUP-set widget colors only
  fully refresh on restart — the menu shows a "restart for full effect" note.

### Icons

`icons.zig` builds toolbar/list/device/app icons as in-memory `IupImage` maps
(ASCII templates → palette). It has its OWN `@cImport("iup.h")`, so its
`Ihandle` type differs from `main.zig`'s — icon builders return `?*anyopaque`
and callers `@ptrCast`. Register list/label icons by name with `IupSetHandle`,
then reference via the `"IMAGE"` attribute (`IupSetAttributeId` for list items).

## Architecture Overview

```
src/
  main.zig         GUI layout, toolbar, callbacks, App struct, entry point
  dialogs.zig      New/Edit VM, Export Script, Snapshot Manager, Virtual Network Editor
  vm.zig           VM config model, enums (DiskFormat, GuestOs, VmStatus, ...)
  vnet.zig         Virtual switch model (VMnet0..N: type/subnet/DHCP) + own JSON store
  qemu.zig         QEMU/qemu-img process spawn (fork+execvp), disk image create
  qmp.zig          QMP client: pause/resume/powerdown/reset/snapshots/sendkey
  persist.zig      JSON save/load with hand-rolled parser (no std.json)
  display.zig      VNC/SPICE embedded display (IUP canvas + IupDrawImage)
  serial.zig       Serial console via Unix socket + background reader thread
  vnc_client.zig   libvncclient wrapper (@cImport rfb headers + poll thread)
  spice_client.zig spice-client-glib wrapper (hand-written extern decls)
  usock.zig        Blocking AF_UNIX socket (libc) — replaces std.net
  appio.zig        Global std.Io instance + getenv/sleepMs helpers
  sync.zig         SpinMutex — replaces std.Thread.Mutex

GUI toolkit: IUP (GTK3 backend on Linux), imported via @cImport("iup.h").
build.zig       Links prebuilt IUP static libs (deps/iup/*.a) via system cc.
deps/iup/       Vendored IUP headers + static libraries.
```

## Critical Constraints

### No `std.json`
`std.json` pulls in f128 float math that causes linker errors with the
system `cc` link step. All JSON parsing/emitting is hand-rolled in
`persist.zig`. Never import or use `std.json`.

### Global `app` must be accessed via pointer
The `App` struct is ~600KB (fixed-size VM array). In debug mode, passing
it by value overflows the stack. Always use:
```zig
var app_storage: App = .{};
const app: *App = &app_storage;
```
Never copy `App` by value or pass it to functions by value.

### VM list population order
The VM list must be populated AFTER the IUP widget is mapped (`IupShowXY`).
IUP silently ignores `APPENDITEM` set before mapping. See "GUI callbacks".

### Build link step
Final linking uses system `cc` (not Zig's linker) to work around
GCC 15+ `.sframe` section incompatibility. Test artifacts (`zig build test`)
can't use `cc`, so they set `use_llvm = true` + `use_lld = true` instead —
the self-hosted backend/linker can't relocate `.sframe` in GCC's crt1.o.

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
- `std` first, then the IUP `@cImport`, then local files.
- Local imports use string literal paths: `@import("vm.zig")`.
- IUP is reached via `@cImport` (no Zig module wrapper):

```zig
const std = @import("std");

const iup = @cImport({
    @cInclude("iup.h");
    @cInclude("iupcontrols.h");
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

### GUI callbacks
- IUP callbacks use C calling convention and return `c_int` (usually
  `iup.IUP_DEFAULT`):
  `fn onBtn(_: ?*iup.Ihandle) callconv(.c) c_int`.
- Callbacks should delegate to a named helper (e.g. `onLinkPower` calls
  `startSelectedVm()`).
- `IupPopup` returns `c_int` — discard with `_ =`.
- IUP's `APPENDITEM` is silently ignored before the widget is mapped — call
  list-population helpers AFTER `IupShowXY`, not before.
- Use `IupSetStrAttribute` (copies the string) instead of `IupSetAttribute`
  (stores the pointer) when the value comes from a stack buffer.

### Dialog pattern
Dialogs (`dialogs.zig`) use a static context struct + dialog lifecycle:
1. Define `var ctx = MyCtx{};` at module scope.
2. `showMyDialog()` creates an `IupDialog`, stores it in `ctx.dlg`.
3. Guard against double-open: `if (ctx.dlg != null) return;`
4. On close/cancel: `IupDestroy` the dialog, reset `ctx = MyCtx{}`.
5. `dialogs.zig` ↔ `main.zig` cycles are broken with `export fn` / `extern fn`.

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
Zig 0.16's `std.testing.fuzz` needs libfuzzer instrumentation that won't link
with the `cc`/`.sframe` setup here, so the input-facing surfaces are fuzzed
with deterministic PRNG harnesses (fixed seed → reproducible) that run as
ordinary `zig build test` tests. Covered surfaces: the hand-rolled JSON
parser (`persist.zig` — `parseVmObject`, primitives, emit→parse, mutated
JSON), `VmConfig` setters + every enum `fromIndex` (`vm.zig`), the QEMU arg
builder + `buildCArgv` (`qemu.zig`), the QMP response parser `extractJsonString` +
`socketPath` (`qmp.zig`), the virtual-network store (`vnet.zig` — `fromJson`,
`nextObject`), and the pure helpers split out of IUP/IO modules so they fuzz
without a display: `fbmath.fbFits` (framebuffer geometry, from `display.zig`),
`ringbuf.append` (serial ring, from `serial.zig`), `uimath` (`mapCoords` click
mapping from `display.zig`, `memToX` mem-bar from `dialogs.zig`, `serialSocketPath`
from `serial.zig`), and `snapparse.parse` (snapshot-table parser from
`dialogs.zig`). `sync.SpinMutex` has a 4-thread contention test.
Invariants asserted: never panic, parsers only return suffix slices of their
input, writers never exceed their buffers. Keep iteration counts modest (≤8k)
so `-fllvm` test builds stay fast. Three real bugs were caught this way: `-smp`
(`sockets * cores`) and the VNC/SPICE framebuffer `fw * fh` integer overflows
(both now compute in `u64` and bounds-check before casting), and a
`parseVmObject` **infinite loop** on malformed JSON (a stray `]` left
`skipJsonValue` non-advancing — now forces ≥1 byte progress). See
`docs/TEST-COVERAGE.md` for the full per-function tested/integration-only map.

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
