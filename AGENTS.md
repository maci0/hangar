# AGENTS.md — Hangar

Lightweight QEMU VM manager with web UI and optional native WebView wrapper.
Zig 0.16.0. No libvirt.

## Build / Run / Test Commands

```bash
zig build web          # Build + launch web backend (HTTP on :9080; also the remote daemon)
zig build webui        # Build + launch native WebView desktop wrapper
zig build test         # Run ALL unit + fuzz tests (hermetic; no network/browser)
zig build web-e2e      # Web UI end-to-end tests (Playwright; needs npm install + chromium)
zig build test-api     # HTTP API integration test (spawns a real daemon)
zig build test-vmrun   # vmrun CLI integration test (spawns a real daemon)
```

All executables (`hangar-web`, `hangar-webui`, `vmrun`) and all test binaries are built with `use_llvm = true, use_lld = true`.

### Running a single test module

Each test module is explicitly registered in `build.zig`. To run only one:

```bash
zig test src/persist.zig -lc -fllvm -flld
zig test src/qmp.zig     -lc -fllvm -flld
```

`-lc` is required (many modules reach `std.c`). `-fllvm -flld` is required because the self-hosted backend/linker cannot relocate `.sframe` entries in GCC's crt1.o.

## Critical Constraints

### No `std.json`
`std.json` pulls in f128 float math that causes linker errors with the system `cc` link step. All JSON is hand-rolled in `persist.zig` (also `qmp.zig`, `vnet.zig`). Never import or use `std.json`.

### Build link step
Tests and the three shipped executables must use `use_llvm = true, use_lld = true`.

### Zig 0.16 `std.Io` migration
Filesystem, process, networking, and threading go through `std.Io`. Never use the removed/emptied APIs:

- FS: `std.Io.Dir.cwd().<op>(appio.io(), ...)` — never `std.fs.cwd()`.
- Unix sockets: `usock.UnixStream` (libc-backed) — `std.net` is gone.
- Mutex: `sync.SpinMutex` — `std.Thread.Mutex` is gone.
- Env / sleep / clock: `appio.getenv`, `appio.sleepMs`, `std.c.clock_gettime`.
- Process spawn for QEMU: `qemu.forkExec` / `qemu.runWait` (manual `fork` + `execvp`). These preserve the real environment (`DISPLAY`, `HOME`, `XDG_RUNTIME_DIR`, ...). Never `std.process.spawn`.

### No glib `@cImport`
Zig 0.16's C importer rejects GLib headers (they emit file-scope `_Pragma`). `spice_client.zig` declares the few symbols it needs by hand (`extern fn` + opaque types). rfb (VNC) headers may be `@cImport`'ed.

## State & Wiring

- There is no `App` struct. All shared state lives as module-level globals in `appstate.zig`:
  - `vms` / `vm_count` / `vms_mutex`, `prefs`, `g_vmm` + `g_vmm_handles`, serial console ring + thread state, remote mode flags, undo state.
- `web_server.zig` is both the local web UI server and the remote daemon. Remote clients (`remote.zig`, `vmrun`) talk to it via `transport.zig` (Unix/TCP + HTTP helpers).
- Hypervisor abstraction: the `g_vmm.*Fn` dispatch table (`hv/interface.zig` + `hv/qemu_backend.zig`) covers PROCESS lifecycle only — `start`, `forceStop`, `isAlive`, `reap`, `createLinkedClone`, `deinit`. Guest control (pause/resume/shutdown/reset/cdrom/migrate/screenshot) goes directly to QMP via `web_server.vmQmpByName` (fresh connection, lock released); offline disk/snapshot ops call `qemu.*`/`qemu-img` directly. Extend the dispatch interface only when a real second backend needs more.

## Configuration (environment variables)

Runtime config is read once in `web_server.main`. All variables are optional.

| Variable | Default | Effect |
| --- | --- | --- |
| `KV_API_KEY` | `hangar` (built-in) | X-API-Key secret. **Setting it also opts the daemon into binding all interfaces (`::`).** With no key set, the daemon binds **loopback only** (`::ffff:127.0.0.1`, the IPv4-mapped loopback on its dual-stack socket) so the weak default is never reachable off-host. Must be 1–64 bytes; an invalid value aborts startup. Setting it to the built-in default value (`hangar`) is treated as unset — the daemon stays loopback-only rather than exposing all interfaces behind the known default. |
| `KV_PORT` | `9080` | TCP listen port. Must parse as a non-zero `u16`; otherwise startup aborts. |
| `HANGAR_CONFIG_HOME` | `$HOME` | Base dir for `~/.config/hangar/*` state (see Persistence). |

Never commit a real `KV_API_KEY`. For any non-local deployment, set a strong `KV_API_KEY` (which is also what exposes the daemon beyond loopback).

## Persistence

- VMs: `~/.config/hangar/vms.json` (override via `HANGAR_CONFIG_HOME`).
- Virtual networks: `~/.config/hangar/networks.json` (owned by `vnet.zig`).
- Only configuration is persisted. Runtime state (`status`, `pid`, ...) is never written.
- When adding fields to `VmConfig`, also update `VmJson`, `emitVmJson`, `fromVmJson` / `parseVmObject` in `persist.zig`, and add parser tests. Large string fields (e.g. `cloud_init`, 8 KB) also need the `parseVmObject` `str_buf`, the create/save `val_buf`, and the VM-detail render buffer sized to hold them.

## Testing

- Tests live at the bottom of each module's `.zig` (not in separate files), except for thin wrappers (`appstate_test.zig`, `hv_*_test.zig`).
- Fuzz tests are deterministic PRNG harnesses (fixed seed) and are ordinary `zig build test` entries. They cover parsers, setters, arg builders, and pure helpers.
- Every enum must have tests for: fromIndex round-trip, toIndex inverts fromIndex, toStr values, label values, out-of-range default.
- `qemu.zig` arg-builder tests must use the `buildScriptStr` / `buildArgs` functions — never by spawning QEMU.
- **Always confirm a change with `zig build` (the exe link), not only `zig test src/<mod>.zig`.** A single-module `zig test` may not instantiate code reachable solely through the exe (e.g. a handler called only via `std.Thread.spawn(serveHtml, …)`), so a generic/comptime error there can pass the module test yet fail the exe build. If `zig build` ever reports success but a known-new string is missing from `zig-out/bin/hangar-web` (`strings … | grep`), the install cache is stale — `rm -rf zig-out .zig-cache` and rebuild before trusting the binary.
- The Playwright e2e suite (`tests/e2e/`, config `playwright.config.mjs`) is a **standalone** `zig build web-e2e` step — NOT in the umbrella `test` (which stays hermetic). Playwright launches the built binary on a dedicated port against a temp `$HOME`. Run `npm install` and `npm run e2e:install` (Chromium) once before the first run. The shell integration tests `zig build test-api` / `zig build test-vmrun` are likewise standalone (they spawn a real daemon).
- **Every user-facing workflow must have an end-to-end Playwright test.** Any web-UI flow — VM create/clone/delete/rename, power on/off, snapshots, settings save, import/export, log viewer, console, vnet editor, preferences — needs a Playwright e2e test that drives the real built binary (temp port + temp `$HOME`, same as the smoke harness) and asserts the observable result. Add or extend the e2e test alongside the feature, never after. A new workflow without a Playwright e2e test is incomplete.

## Code Style & Conventions

- `//!` module doc at the top of every `.zig`; `///` docs on public functions (1-3 lines).
- Imports: `std` first, then local files as string literals (`@import("vm.zig")`).
- Enums follow the exact `vm.zig` pattern (see `DiskFormat`, `GuestOs`, etc.):
  - `count`, `toIndex`, `fromIndex` (safe default), `toStr` (QEMU CLI value), `label` (UI).
- Naming: `PascalCase` types, `camelCase` functions, `SCREAMING_SNAKE` hard limits, `snake_case` for enum variants and source lists.
- Fixed-size buffers for VM data (`name_buf`, `disk_path_buf`); C interop uses `[*:0]const u8`; internal slices are `[]const u8`.
- UI terminology follows VMware Workstation conventions:
  - "Power On" / "Power Off", "Suspend" / "Resume", "Shut Down Guest", "Take Snapshot" / "Revert to Snapshot", "VM Library", "Settings".
- Config enums are stored in JSON as their `toStr` values (e.g. `"qcow2"`, `"gtk"`, `"user"`).

## Zig Idioms & Rules

Target **Zig 0.16.0**. Never write code that assumes older `std.fs`, `std.net`, `std.posix`, or `std.Thread` APIs — see the `std.Io` migration constraint above for the required replacements.

### Builtins & comptime
- Reach for builtins/comptime where natural: `@typeInfo`, `@TypeOf`, `@intCast`, `@enumFromInt`, `@intFromEnum`, `@memcpy`, `@memset`, `@atomicLoad`, `@atomicStore`.
- There is **no** `@builtin`. Platform/build info comes from `const builtin = @import("builtin");`.

### Avoid low-level OS work
- No direct syscalls; no new `fork`/`exec` code.
- Avoid `std.os`, `std.posix`, and raw libc unless there is no Zig 0.16 API.
- Keep existing low-level code behind the local wrappers (`usock`, `appio`, `qemu`).
- Process spawning: use `std.process` only where Zig 0.16 environment handling is safe. Keep QEMU/`qemu-img` on the existing `qemu.forkExec`/`runWait` wrapper until the env-stripping issue is proven fixed with tests.

### Structured stdlib helpers
- `std.mem` for slicing/search/copying.
- `std.fmt.bufPrint` / `bufPrintZ` for fixed buffers.
- `std.testing` helpers in tests.
- `std.heap` allocators only when fixed buffers are not enough.

### Ownership
- Functions that allocate must document who frees.
- Prefer caller-provided buffers for hot paths and config serialization.
- Use `defer` / `errdefer` consistently.

### Slices over raw pointers
- Use `[]const u8` / `[]u8` for internal Zig logic.
- Reserve `[*:0]const u8` for C/QEMU interop boundaries.
- Convert with `std.mem.span()` only at boundaries.

### Errors
- Return `!T` / `!void`.
- `catch return` for non-critical failure paths.
- Avoid silent `catch {}` except known acceptable best-effort persistence cases.

### Concurrency
- Use `sync.SpinMutex` (per project rule); atomics for cross-thread scalar flags.
- Never touch `appstate.vms` / `vm_count` without `vms_mutex`.
- Do not hold locks during QEMU/QMP/filesystem/network I/O.

### build.zig
- Keep link/backend choices explicit (`use_llvm`/`use_lld` — see constraint above).
- Avoid global-machine assumptions; prefer project-local cache/config for reproducible test runs.

## References

- `CLAUDE.md` is a symlink to this file.
- Longer design notes (if needed) are in `docs/`.
